import Foundation

/// Pure timing policy for NOOP's opportunistic iOS app refresh lane.
///
/// `BGAppRefreshTaskRequest.earliestBeginDate` is a lower bound, not an appointment: iOS may run the
/// request much later or not at all. Keeping the policy pure makes the battery/debounce behavior easy to
/// test without suggesting a guaranteed cadence anywhere in the product.
enum BackgroundSyncPolicy {
    static let regularDelay: TimeInterval = 60 * 60
    static let retryDelay: TimeInterval = 20 * 60
    static let duplicateAttemptFloor: TimeInterval = 10 * 60

    static func delay(afterSuccess success: Bool) -> TimeInterval {
        success ? regularDelay : retryDelay
    }

    static func shouldStart(now: Date, lastAttempt: Date?) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= duplicateAttemptFloor
    }
}

/// Shared policy for the quiet reminder that a paired band has gone two hours without app-visible sync.
enum BandSyncStaleReminderPolicy {
    static let delay: TimeInterval = 2 * 60 * 60

    static func shouldSchedule(
        hasPairedBand: Bool,
        notificationsAuthorized: Bool
    ) -> Bool {
        hasPairedBand && notificationsAuthorized
    }

    static func shouldRefreshAfterDurableProgress(
        appIsActive: Bool,
        hasPairedBand: Bool
    ) -> Bool {
        !appIsActive && hasPairedBand
    }
}

#if os(iOS)
@preconcurrency import BackgroundTasks
import UIKit
import UserNotifications

/// Hands one privacy-safe stale-sync reminder to Notification Center when NOOP leaves the foreground.
///
/// Notification access is never requested here. A fresh sync replaces the two-hour countdown, while
/// foregrounding removes it. Durable in-flight progress replaces the same stable request so process
/// suspension before HISTORY_COMPLETE cannot leave the user without a later stale-data reminder.
@MainActor
enum BandSyncStaleReminder {
    static let requestIdentifier = "noop.band-sync.stale"

    private static var generation: UInt64 = 0

    static func scheduleIfEligible(hasPairedBand: Bool) async {
        generation &+= 1
        let expectedGeneration = generation
        guard UIApplication.shared.applicationState != .active else {
            cancel()
            return
        }
        guard hasPairedBand else {
            cancel()
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard expectedGeneration == generation else { return }
        guard BandSyncStaleReminderPolicy.shouldSchedule(
            hasPairedBand: hasPairedBand,
            notificationsAuthorized: canPost(using: settings.authorizationStatus)
        ) else {
            LocalNotificationLifecycle.suppressed(
                identifier: requestIdentifier,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            cancel()
            return
        }

        await DailyReviewNotifications.ensurePrivacyCategory(on: center)
        guard expectedGeneration == generation else { return }

        let content = UNMutableNotificationContent()
        content.applyProminence(.ambient)
        content.title = String(
            localized: "sync.stale.notification.title",
            defaultValue: "Keep NOOP syncing"
        )
        content.body = String(
            localized: "sync.stale.notification.body",
            defaultValue: "Open NOOP to catch up with your band. Leave it running in the background so history stays up to date."
        )
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.connection-health"
        content.userInfo = [
            NotificationRouteBridge.userInfoKey: NoopNotificationRoute.devices.rawValue,
        ]

        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: BandSyncStaleReminderPolicy.delay,
                repeats: false
            )
        )
        do {
            try await LocalNotificationLifecycle.schedule(request, on: center)
            if expectedGeneration != generation { cancel() }
        } catch {
            if expectedGeneration != generation { cancel() }
        }
    }

    static func cancel() {
        generation &+= 1
        LocalNotificationLifecycle.cancel(
            identifiers: [requestIdentifier],
            presented: true
        )
    }

    private static func canPost(using status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}

/// Best-effort maintenance wake for recent HealthKit ingestion, an already-connected strap's history
/// request, and explicitly enabled self-hosted/Friends delivery.
///
/// This complements rather than replaces the durable data paths:
/// - CoreBluetooth restoration and strap events remain the primary background BLE triggers;
/// - HealthKit observers remain the primary Apple Health trigger;
/// - foreground catch-up remains the reliable reconciliation path.
///
/// iOS owns whether and when a submitted request runs. NOOP therefore persists only attempt/completion
/// diagnostics, debounces duplicate wakes, retries a failed/expired wake sooner, and never labels this as
/// a fixed interval or guaranteed background sync.
@MainActor
enum BackgroundSyncScheduler {
    private enum Key {
        static let lastAttempt = "backgroundSync.lastAttempt"
        static let lastCompleted = "backgroundSync.lastCompleted"
        static let lastSubmission = "backgroundSync.lastSubmission"
    }

    static let taskIdentifier =
        (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".refresh"

    private static var operation: (@MainActor () async -> Bool)?
    private static var activeWork: Task<Void, Never>?
    private static var activeGeneration: UUID?

    static var lastCompletedAt: Date? {
        date(forKey: Key.lastCompleted)
    }

    /// Register during application initialization. The operation is deliberately injected by the app
    /// composition root so this scheduler owns no database, BLE, HealthKit, or network lifetime.
    static func register(operation: @escaping @MainActor () async -> Bool) {
        self.operation = operation
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                run(refreshTask)
            }
        }
    }

    /// Submit one single-shot request. Call when the app backgrounds; the handler re-submits after each
    /// delivery. Cancel-before-submit prevents pending-request buildup. The earliest date is intentionally
    /// conservative; iOS can coalesce it with other system work or defer it beyond that date.
    static func scheduleNext(afterSuccess success: Bool = true, now: Date = Date()) {
        guard UIApplication.shared.backgroundRefreshStatus == .available else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(
            BackgroundSyncPolicy.delay(afterSuccess: success)
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Key.lastSubmission)
        } catch {
            // Scheduling is advisory. Foreground catch-up, Bluetooth restoration, and HealthKit observer
            // delivery stay active even when the OS rejects this request (for example after refresh is off).
        }
    }

    private static func run(_ backgroundTask: BGAppRefreshTask, now: Date = Date()) {
        let lastAttempt = date(forKey: Key.lastAttempt)
        guard BackgroundSyncPolicy.shouldStart(now: now, lastAttempt: lastAttempt) else {
            scheduleNext(afterSuccess: true, now: now)
            backgroundTask.setTaskCompleted(success: true)
            return
        }
        guard let operation else {
            scheduleNext(afterSuccess: false, now: now)
            backgroundTask.setTaskCompleted(success: false)
            return
        }

        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Key.lastAttempt)
        let generation = UUID()
        activeGeneration = generation
        let work = Task { @MainActor in
            let success = await operation()
            guard !Task.isCancelled else { return }
            finish(backgroundTask, generation: generation, success: success)
        }
        activeWork = work
        backgroundTask.expirationHandler = {
            Task { @MainActor in
                expire(backgroundTask, generation: generation)
            }
        }
    }

    private static func expire(_ backgroundTask: BGAppRefreshTask, generation: UUID) {
        guard activeGeneration == generation else { return }
        activeWork?.cancel()
        finish(backgroundTask, generation: generation, success: false)
    }

    private static func finish(
        _ backgroundTask: BGAppRefreshTask,
        generation: UUID,
        success: Bool
    ) {
        guard activeGeneration == generation else { return }
        activeGeneration = nil
        activeWork = nil
        if success {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.lastCompleted)
        }
        scheduleNext(afterSuccess: success)
        backgroundTask.setTaskCompleted(success: success)
    }

    private static func date(forKey key: String) -> Date? {
        guard let seconds = UserDefaults.standard.object(forKey: key) as? Double,
              seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
#endif
