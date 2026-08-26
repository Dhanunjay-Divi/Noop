import Foundation
import UserNotifications

/// A destination carried by a NOOP notification. The route is deliberately small: notifications
/// open a trusted top-level screen, never a URL or arbitrary stored navigation value.
enum NoopNotificationRoute: String, Equatable, Sendable {
    case today
    case trends
    case sleep
    case hydration
    case devices
    case safety
    case coach
}

/// Durable hand-off between `UNUserNotificationCenterDelegate` and the SwiftUI app shells.
///
/// A notification response can arrive before the root view exists during a cold launch. Persisting
/// one pending route first, then posting an in-process wake-up, covers both cases:
/// - cold launch: RootTabView / RootView consumes the stored route on appear;
/// - warm launch: the live notification wakes the already-mounted shell.
///
/// Consumption removes the value before returning it, so a reminder tap never re-opens the same
/// screen on a later foreground or relaunch.
enum NotificationRouteBridge {
    static let userInfoKey = "noop.notification.route"
    static let pendingRouteKey = "noop.notification.pendingRoute"
    static let routeRequested = Notification.Name("noop.notification.routeRequested")

    static func route(from userInfo: [AnyHashable: Any]) -> NoopNotificationRoute? {
        guard let raw = userInfo[userInfoKey] as? String else { return nil }
        return NoopNotificationRoute(rawValue: raw)
    }

    static func recordPending(_ route: NoopNotificationRoute) {
        UserDefaults.standard.set(route.rawValue, forKey: pendingRouteKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: routeRequested, object: nil)
        }
    }

    static func consumePending() -> NoopNotificationRoute? {
        guard let raw = UserDefaults.standard.string(forKey: pendingRouteKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingRouteKey)
        return NoopNotificationRoute(rawValue: raw)
    }
}

/// Two privacy-safe local reminders that help users review data already stored on their device.
///
/// This is a true opt-in automation:
/// - default OFF;
/// - notification permission is requested only from `setEnabled(true)`, after the explanatory UI;
/// - no health value is embedded in notification content;
/// - schedules live in the OS notification center and work while NOOP is not running.
@MainActor
enum DailyReviewNotifications {
    static let enabledKey = "dailyReview.enabled"
    static let morningMinutesKey = "dailyReview.morningMinutes"
    static let eveningMinutesKey = "dailyReview.eveningMinutes"

    private static let morningRequestID = "daily-review-morning"
    private static let eveningRequestID = "daily-review-evening"
    private static let requestIDs = [morningRequestID, eveningRequestID]
    /// Shared by every wellness notification that must keep detail out of hidden lock-screen previews.
    static let privacyCategoryID = "noop.daily-review.private"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var morningMinutes: Int {
        let value = UserDefaults.standard.object(forKey: morningMinutesKey) as? Int ?? 8 * 60
        return clampMinute(value)
    }

    static var eveningMinutes: Int {
        let value = UserDefaults.standard.object(forKey: eveningMinutesKey) as? Int ?? 19 * 60
        return clampMinute(value)
    }

    enum EnableOutcome: Equatable, Sendable {
        case scheduled
        case denied
        case off
    }

    struct ReminderSpec: Equatable, Sendable {
        let identifier: String
        let minuteOfDay: Int
        let title: String
        let body: String
        let route: NoopNotificationRoute
    }

    /// Enable/disable the pair. A denied permission never leaves a misleading ON preference behind.
    static func setEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            LocalNotificationLifecycle.cancel(identifiers: requestIDs)
            completion?(.off)
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UserDefaults.standard.set(true, forKey: enabledKey)
                schedule()
                completion?(.scheduled)
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    UserDefaults.standard.set(true, forKey: enabledKey)
                    schedule()
                    completion?(.scheduled)
                } else {
                    UserDefaults.standard.set(false, forKey: enabledKey)
                    recordSuppressedRequests()
                    completion?(.denied)
                }
            default:
                UserDefaults.standard.set(false, forKey: enabledKey)
                recordSuppressedRequests()
                completion?(.denied)
            }
        }
    }

    static func setMorningMinutes(_ minutes: Int) {
        UserDefaults.standard.set(clampMinute(minutes), forKey: morningMinutesKey)
        if isEnabled { schedule() }
    }

    static func setEveningMinutes(_ minutes: Int) {
        UserDefaults.standard.set(clampMinute(minutes), forKey: eveningMinutesKey)
        if isEnabled { schedule() }
    }

    /// Reconcile persisted opt-in state after an upgrade or reinstall of pending notification requests.
    /// This never asks for permission; it only restores requests when authorization already exists.
    static func restoreScheduleIfAuthorized() {
        guard isEnabled else {
            LocalNotificationLifecycle.cancel(identifiers: requestIDs)
            return
        }
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                schedule()
            default:
                recordSuppressedRequests()
                break
            }
        }
    }

    static func reminderSpecs(morning: Int, evening: Int) -> [ReminderSpec] {
        [
            ReminderSpec(
                identifier: morningRequestID,
                minuteOfDay: clampMinute(morning),
                title: String(localized: "Morning check-in"),
                body: String(localized: "Review Sleep and Recovery, then log how rested you feel."),
                route: .sleep
            ),
            ReminderSpec(
                identifier: eveningRequestID,
                minuteOfDay: clampMinute(evening),
                title: String(localized: "Evening check-in"),
                body: String(localized: "Compare today’s Effort, then log what shaped your day."),
                route: .today
            ),
        ]
    }

    nonisolated static func clampMinute(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        LocalNotificationLifecycle.cancel(identifiers: requestIDs, on: center)
        registerPrivacyCategory(on: center)

        for spec in reminderSpecs(morning: morningMinutes, evening: eveningMinutes) {
            let content = UNMutableNotificationContent()
            content.applyProminence(.ambient)
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            // The normal copy contains no values or conditions. When the user hides previews, keep even
            // the metric names off the lock screen while retaining a recognizable app-level placeholder.
            content.categoryIdentifier = privacyCategoryID
            content.threadIdentifier = "noop.daily-review"
            content.userInfo = [NotificationRouteBridge.userInfoKey: spec.route.rawValue]

            var components = DateComponents()
            components.hour = spec.minuteOfDay / 60
            components.minute = spec.minuteOfDay % 60
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            LocalNotificationLifecycle.schedule(
                UNNotificationRequest(
                    identifier: spec.identifier,
                    content: content,
                    trigger: trigger
                ),
                on: center
            )
        }
    }

    private static func recordSuppressedRequests() {
        for identifier in requestIDs {
            LocalNotificationLifecycle.suppressed(
                identifier: identifier,
                categoryIdentifier: privacyCategoryID
            )
        }
    }

    /// Notification categories are process-global, so merge instead of replacing categories registered
    /// by alarms or future features. The category-level placeholder is what iOS uses when the user has
    /// chosen to hide notification previews; individual notification content has no such property.
    static func registerPrivacyCategory(on center: UNUserNotificationCenter) {
        Task { @MainActor in
            await ensurePrivacyCategory(on: center)
        }
    }

    /// Awaitable variant for an immediate notification. Repeating reminders can register in parallel
    /// because their first fire is in the future; an immediate connection-health alert must install the
    /// category before it is added or hidden-preview behavior depends on whether another feature happened
    /// to register the shared category earlier in this process.
    static func ensurePrivacyCategory(on center: UNUserNotificationCenter) async {
        let existing = await center.notificationCategories()
        let category = privacyCategory()
        var merged = existing.filter { $0.identifier != privacyCategoryID }
        merged.insert(category)
        center.setNotificationCategories(merged)
    }

    static func privacyCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: privacyCategoryID,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "Private NOOP check-in"),
            options: []
        )
    }
}

/// A quiet, authorization-respecting alert for a real Bluetooth outage that pauses an already-paired
/// wearable. The CoreBluetooth owner supplies the runtime episode gates; this helper owns preference,
/// privacy-safe copy, delivery, and stale-notification cleanup.
///
/// Important consent boundary: this feature defaults on because it is operational rather than a wellness
/// prompt, but it NEVER requests notification access. Without authorization the post is simply skipped.
@MainActor
enum BluetoothAvailabilityNotifications {
    static let enabledKey = "connectionHealth.bluetoothOffAlert"
    static let monitoringExpectedKey = "connectionHealth.monitoringExpected"
    static let requestID = "bluetooth-powered-off"

    /// Default ON without writing a migration value: an explicit false remains false across upgrades.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if !enabled { clear() }
    }

    /// Tri-state on purpose. nil is an upgraded install that has not expressed monitoring intent in this
    /// build yet, so BLEManager may conservatively use live pairing evidence. Explicit false (Disconnect /
    /// Remove device) overrides a stale CoreBluetooth identifier; true survives a normal app relaunch.
    static var monitoringExpected: Bool? {
        UserDefaults.standard.object(forKey: monitoringExpectedKey) as? Bool
    }

    static func setMonitoringExpected(_ expected: Bool, pairedEvidence: Bool = false) {
        // A secondary-device removal must not silence alerts for the still-active wearable. False is
        // authoritative only when there is no live/persisted pairing evidence left; true always records
        // a genuine bond or verified data stream.
        let resolved = expected || pairedEvidence
        UserDefaults.standard.set(resolved, forKey: monitoringExpectedKey)
        if !resolved { clear() }
    }

    static func hasRelevantWearable(pairedEvidence: Bool, explicitExpectation: Bool?) -> Bool {
        explicitExpectation ?? pairedEvidence
    }

    /// Pure policy seam used by BLEManager and tests. All four facts are required: explicit preference,
    /// a powered-on observation (avoids launch-state false alarms), paired relevance, and episode de-dup.
    static func shouldPost(
        enabled: Bool,
        radioWasPoweredOn: Bool,
        hasPairedDevice: Bool,
        outageAlreadyHandled: Bool
    ) -> Bool {
        enabled && radioWasPoweredOn && hasPairedDevice && !outageAlreadyHandled
    }

    /// Generation-aware counterpart used around asynchronous delivery. A matching token alone is not
    /// enough: recovery clears the outage, a later CoreBluetooth state can cease to be powered-off, and
    /// device removal can make the episode irrelevant before Notification Center answers.
    static func isCurrentOutageEpisode(
        expectedEpisode: UInt64,
        currentEpisode: UInt64,
        outageActive: Bool,
        radioIsPoweredOff: Bool,
        hasRelevantWearable: Bool
    ) -> Bool {
        expectedEpisode == currentEpisode
            && outageActive
            && radioIsPoweredOff
            && hasRelevantWearable
    }

    static func postIfAuthorized(
        stillRelevant: @escaping @MainActor () -> Bool = { true }
    ) async {
        guard deliveryStillAllowed(stillRelevant: stillRelevant) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard canPost(using: settings.authorizationStatus),
              deliveryStillAllowed(stillRelevant: stillRelevant) else { return }

        // This alert is immediate, so defensively install the privacy category before adding it. Recheck
        // after the await: Bluetooth may have recovered, the monitored device may have been removed, or
        // the user may have opted out while Notification Center was answering.
        await DailyReviewNotifications.ensurePrivacyCategory(on: center)
        guard deliveryStillAllowed(stillRelevant: stillRelevant) else { return }

        let content = UNMutableNotificationContent()
        content.applyProminence(.ambient)
        content.title = String(localized: "Bluetooth is off")
        content.body = String(localized: "Wearable sync is paused. Turn Bluetooth on and NOOP will reconnect automatically.")
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.connection-health"
        content.userInfo = [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.devices.rawValue]

        do {
            try await LocalNotificationLifecycle.schedule(
                UNNotificationRequest(identifier: requestID, content: content, trigger: nil),
                on: center
            )
            // `add` itself is an await point. If recovery/opt-out raced the daemon request, remove the
            // just-added notification now instead of leaving a stale "Bluetooth is off" banner behind.
            if !deliveryStillAllowed(stillRelevant: stillRelevant) { clear() }
        } catch {
            // A future radio episode may try again. Delivery failure never interrupts reconnect. A
            // cancellation can still race a daemon-side add, so cleanup remains the safe final action.
            if !deliveryStillAllowed(stillRelevant: stillRelevant) { clear() }
        }
    }

    /// Pure seam for the pre/post-await gates. Keeping task cancellation separate from preference and
    /// episode state lets tests pin all three ways an in-flight immediate alert becomes obsolete.
    static func shouldContinueDelivery(
        enabled: Bool,
        episodeStillActive: Bool,
        taskCancelled: Bool
    ) -> Bool {
        enabled && episodeStillActive && !taskCancelled
    }

    private static func deliveryStillAllowed(
        stillRelevant: @MainActor () -> Bool
    ) -> Bool {
        shouldContinueDelivery(
            enabled: isEnabled,
            episodeStillActive: stillRelevant(),
            taskCancelled: Task.isCancelled
        )
    }

    /// Remove both not-yet-presented and already-presented copies on recovery or explicit opt-out.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        LocalNotificationLifecycle.cancel(
            identifiers: [requestID],
            presented: true,
            on: center
        )
    }

    static func canPost(using status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
#if os(iOS)
        case .ephemeral:
            return true
#endif
        default:
            return false
        }
    }
}

/// Privacy-safe alerts for a candidate that needs approval or a future validated policy just saved.
/// Both open Today: Ask offers Save/dismiss, while the dormant review path offers Keep/Not a workout.
/// Permission is requested only from the explicit Settings opt-in; notification copy never embeds a
/// health value.
@MainActor
enum AutoWorkoutNotifications {
    /// Lock-screen interruptions are deliberately separate from quiet, in-app detection. A fresh
    /// install may offer an activity for review on Today, but it must never interrupt the user until
    /// they explicitly opt in here.
    static let enabledKey = "autoWorkout.suggestionNotificationsEnabled"
    private static let requestID = "auto-workout-candidate"
    private static let lastTokenKey = "autoWorkout.lastNotifiedToken"
    private static let tokenHistoryKey = "autoWorkout.notifiedTokenHistory"
    private static let tokenUserInfoKey = "noop.autoWorkout.deliveryToken"
    private static let maxRememberedTokens = 32
    /// Permission is requested only from the explicit Settings switch. Keeping that async transition
    /// separate from posting also lets an off-tap win if the system prompt is still in flight.
    enum EnableOutcome: Equatable, Sendable {
        case enabled
        case denied
        case off
    }

    /// Small injected boundary around `UNUserNotificationCenter`. Production uses `.system`; focused
    /// tests can suspend `add` to prove that an opt-out/clear wins the exact in-flight race that used to
    /// resurrect a stale notification after `removeDeliveredNotifications` had already returned.
    struct NotificationClient {
        let authorizationStatus: () async -> UNAuthorizationStatus
        let requestAuthorization: () async -> Bool
        let add: (UNNotificationRequest) async throws -> Void
        let remove: ([String]) -> Void

        static var system: NotificationClient {
            NotificationClient(
                authorizationStatus: {
                    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                },
                requestAuthorization: {
                    (try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])) ?? false
                },
                add: { request in
                    try await LocalNotificationLifecycle.schedule(request)
                },
                remove: { identifiers in
                    LocalNotificationLifecycle.cancel(
                        identifiers: identifiers,
                        presented: true
                    )
                }
            )
        }
    }

    private struct QueuedDelivery {
        let generation: UInt64
        let deliveryToken: String
        let kind: Kind
        let startSec: Int
        let content: UNMutableNotificationContent
        let client: NotificationClient
    }

    /// Posting is serialized because every delivery intentionally replaces the same request identifier.
    /// A generation invalidates the active await; queued work is discarded synchronously by `clear`.
    private static var deliveryGeneration: UInt64 = 0
    private static var preferenceGeneration: UInt64 = 0
    private static var deliveryQueue: [QueuedDelivery] = []
    private static var activeDeliveryToken: String?
    private static var isDrainingDeliveries = false

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        setEnabled(enabled, client: .system, completion: completion)
    }

    /// Enabling is a real authorization transaction, not just a preference write. The stored switch stays
    /// false until iOS/macOS confirms that notifications are permitted, so Settings never promises an alert
    /// the OS will silently discard. This is invoked only from the explicit user action in Settings.
    static func setEnabled(
        _ enabled: Bool,
        client: NotificationClient,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        preferenceGeneration &+= 1
        let attempt = preferenceGeneration

        guard enabled else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            clear(client: client)
            completion?(.off)
            return
        }

        // Fail closed while the OS decision is pending, and retire any notification left by an older build.
        UserDefaults.standard.set(false, forKey: enabledKey)
        clear(client: client)
        Task { @MainActor in
            let status = await client.authorizationStatus()
            guard attempt == preferenceGeneration else { return }

            let allowed: Bool
            switch status {
            case .authorized, .provisional:
                allowed = true
#if os(iOS)
            case .ephemeral:
                allowed = true
#endif
            case .notDetermined:
                allowed = await client.requestAuthorization()
            default:
                allowed = false
            }

            guard attempt == preferenceGeneration else { return }
            UserDefaults.standard.set(allowed, forKey: enabledKey)
            completion?(allowed ? .enabled : .denied)
        }
    }

    static func token(startSec: Int, endSec: Int) -> String {
        AutoWorkoutSuggestionIdentity.token(startSec: startSec, endSec: endSec)
    }

    static func postIfAuthorized(startSec: Int, endSec: Int) async {
        await postIfAuthorized(startSec: startSec, endSec: endSec, client: .system)
    }

    static func postIfAuthorized(
        startSec: Int,
        endSec: Int,
        client: NotificationClient
    ) async {
        guard PuffinExperiment.autoDetectWorkoutsEnabled, isEnabled else {
            clear(client: client)
            return
        }
        await post(kind: .candidate, startSec: startSec, endSec: endSec, client: client)
    }

    static func postAutoSavedIfAuthorized(startSec: Int, endSec: Int) async {
        guard PuffinExperiment.autoWorkoutMode == .autoSave else { return }
        await post(kind: .autoSaved, startSec: startSec, endSec: endSec, client: .system)
    }

    enum Kind: String {
        case candidate
        case autoSaved

        var title: String {
            switch self {
            case .candidate: return String(localized: "Possible workout found")
            case .autoSaved: return String(localized: "Workout saved automatically")
            }
        }

        var body: String {
            switch self {
            case .candidate:
                return String(localized: "Open NOOP to review the activity and choose whether to save it.")
            case .autoSaved:
                return String(localized: "Open NOOP to keep it or mark it as not a workout.")
            }
        }
    }

    private static func post(
        kind: Kind,
        startSec: Int,
        endSec: Int,
        client: NotificationClient
    ) async {
        let candidateToken = token(startSec: startSec, endSec: endSec)
        let deliveryToken = kind.rawValue + ":" + candidateToken
        guard shouldDeliver(deliveryToken: deliveryToken, kind: kind,
                            startSec: startSec, defaults: .standard),
              activeDeliveryToken != deliveryToken,
              !deliveryQueue.contains(where: { $0.deliveryToken == deliveryToken }) else { return }

        let content = UNMutableNotificationContent()
        content.applyProminence(.ambient)
        content.title = kind.title
        content.body = kind.body
        content.sound = .default
        content.userInfo = [
            NotificationRouteBridge.userInfoKey: NoopNotificationRoute.today.rawValue,
            tokenUserInfoKey: deliveryToken,
        ]

        deliveryQueue.append(QueuedDelivery(
            generation: deliveryGeneration,
            deliveryToken: deliveryToken,
            kind: kind,
            startSec: startSec,
            content: content,
            client: client
        ))
        guard !isDrainingDeliveries else { return }
        isDrainingDeliveries = true

        while !deliveryQueue.isEmpty {
            let delivery = deliveryQueue.removeFirst()
            activeDeliveryToken = delivery.deliveryToken
            await deliver(delivery)
            activeDeliveryToken = nil
        }
        isDrainingDeliveries = false
    }

    private static func deliver(_ delivery: QueuedDelivery) async {
        guard delivery.generation == deliveryGeneration,
              shouldDeliver(deliveryToken: delivery.deliveryToken, kind: delivery.kind,
                            startSec: delivery.startSec, defaults: .standard) else { return }

        let status = await delivery.client.authorizationStatus()
        guard delivery.generation == deliveryGeneration else { return }
        guard canPost(using: status), delivery.kind == .autoSaved || isEnabled else {
            delivery.client.remove([requestID])
            return
        }

        do {
            try await delivery.client.add(UNNotificationRequest(
                identifier: requestID,
                content: delivery.content,
                trigger: nil
            ))
            guard delivery.generation == deliveryGeneration,
                  delivery.kind == .autoSaved || isEnabled else {
                // `clear` may have run while `add` was suspended. Because this drain is serialized, no
                // newer delivery can be installed until this stale completion has been removed.
                delivery.client.remove([requestID])
                return
            }
            remember(deliveryToken: delivery.deliveryToken, defaults: .standard)
        } catch {
            // Keep the token unset so a later completed sync can retry delivery.
            // The daemon can still have accepted a request before reporting a cancellation/error. The
            // serialized drain guarantees this cleanup cannot erase a newer queued delivery.
            if delivery.generation != deliveryGeneration
                || (delivery.kind != .autoSaved && !isEnabled) {
                delivery.client.remove([requestID])
            }
        }
    }

    /// Pure deduplication seam. Remembering a bounded history avoids A→B→A notification loops after
    /// repeated backfills, while the legacy single-token check preserves upgrade behavior.
    static func shouldDeliver(deliveryToken: String, kind: Kind,
                              startSec: Int, defaults: UserDefaults) -> Bool {
        if defaults.stringArray(forKey: tokenHistoryKey)?.contains(deliveryToken) == true { return false }
        if let previous = defaults.string(forKey: lastTokenKey) {
            if previous == deliveryToken { return false }
            // Pre-mode builds stored only `start:<ts>` for candidate prompts. Honor that identity so an
            // upgrade never re-alerts an already reviewed suggestion.
            if kind == .candidate,
               AutoWorkoutSuggestionIdentity.matches(previous, startSec: startSec) { return false }
        }
        return true
    }

    private static func remember(deliveryToken: String, defaults: UserDefaults) {
        var history = defaults.stringArray(forKey: tokenHistoryKey) ?? []
        history.removeAll { $0 == deliveryToken }
        history.append(deliveryToken)
        if history.count > maxRememberedTokens {
            history.removeFirst(history.count - maxRememberedTokens)
        }
        defaults.set(history, forKey: tokenHistoryKey)
        defaults.set(deliveryToken, forKey: lastTokenKey)
    }

    /// Remove a handled suggestion from Notification Center. The stable last-token stays persisted so a
    /// later scan of the same bout cannot post it again.
    static func removeHandled() {
        clear()
    }

    /// Clears both pending and already-delivered copies. Used when detection/interruptions are off,
    /// when a completed sync no longer has an eligible current candidate, and during launch repair of
    /// surfaces left behind by an older build.
    static func clear() {
        clear(client: .system)
    }

    static func clear(client: NotificationClient) {
        deliveryGeneration &+= 1
        deliveryQueue.removeAll()
        // The suspended delivery still owns the drain, but it belongs to the retired generation. Do
        // not let its token suppress a same-candidate retry that arrives after this clear.
        activeDeliveryToken = nil
        client.remove([requestID])
    }

    /// `ephemeral` is an iOS-only authorization state. Keep the shared macOS target compiling while
    /// accepting every state in which Apple permits a notification without another permission prompt.
    private static func canPost(using status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
#if os(iOS)
        case .ephemeral:
            return true
#endif
        default:
            return false
        }
    }
}
