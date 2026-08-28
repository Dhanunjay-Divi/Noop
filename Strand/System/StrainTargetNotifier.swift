import Foundation
import UserNotifications
import StrandAnalytics

// MARK: - Target-strain notification (#593)
//
// A single opt-in, default-OFF informational nudge: once per day, when the day's canonical 0–100 Effort
// reaches DailyActionPlanner's evidence-gated personal range, post a once-daily informational nudge.
// Twin of the Android `StrainTargetNotifier`/`StrainTargetPolicy` - the pure policy
// must stay byte-identical (feature-level parity).
//
// CLEAN-ROOM: this reimplements the BEHAVIOUR only. The copy is NOOP's own — NOT WHOOP's decompiled
// strings — and the target is NOOP's own personal-history planner output, not a value read off another app.
//
// It is NOT "the instant" you cross the target - daily Effort is a per-analytics-pass rollup, so it fires
// on the first pass at/after the crossing. Once-per-day dedupe uses a persisted day string, the same
// crossing-dedupe idiom as BatteryNotifier / the Android ScheduledReportPolicy.
@MainActor
enum StrainTargetNotifier {
    private static let lastDayKey = "behavior.strainTargetLastDay"
    private static let requestID = "strain-target"
    private static var preferenceGeneration: UInt64 = 0
    private static var deliveryGeneration: UInt64 = 0
    private static var activeDay: String?

    enum EnableOutcome: Equatable, Sendable {
        case enabled
        case denied
        case off
    }

    struct NotificationClient {
        let authorizationStatus: () async -> UNAuthorizationStatus
        let requestAuthorization: () async -> Bool
        let preparePrivateCategory: () async -> Void
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
                preparePrivateCategory: {
                    await DailyReviewNotifications.ensurePrivacyCategory(
                        on: UNUserNotificationCenter.current()
                    )
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

    /// Pure, testable policy + copy — no notification/UserDefaults runtime, so the decision logic is
    /// pinned by StrainTargetPolicyTests. Byte-identical twin of the Android `StrainTargetPolicy`.
    enum StrainTargetPolicy {
        /// Fire at most once per local calendar day, only for that day's measured Effort and only when it
        /// is within or above the planner's complete range. An unavailable result means the planner withheld
        /// the range or the current value is not trustworthy, so the policy fails closed.
        static func shouldNotify(enabled: Bool,
                                 guidance: DailyEffortGuidance.Result,
                                 dataDay: String,
                                 currentLocalDay: String,
                                 lastNotifiedDay: String?) -> Bool {
            guard enabled,
                  dataDay == currentLocalDay,
                  lastNotifiedDay != currentLocalDay else { return false }
            return guidance.state == .inRange || guidance.state == .aboveRange
        }
    }

    /// ISO day key in the device's current civil time zone. The notifier intentionally does not use the
    /// dashboard's 04:00 logical-day carry because a notification must describe the actual calendar day.
    private static func localCalendarDay(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Treat authorization as part of the switch transaction. The caller persists its BehaviorStore
    /// preference only after `.enabled`; denial therefore cannot leave an inert ON switch behind.
    static func setEnabled(
        _ enabled: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        setEnabled(enabled, client: .system, completion: completion)
    }

    static func setEnabled(
        _ enabled: Bool,
        client: NotificationClient,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        preferenceGeneration &+= 1
        let attempt = preferenceGeneration
        guard enabled else {
            clear(client: client)
            completion?(.off)
            return
        }

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
            completion?(allowed ? .enabled : .denied)
        }
    }

    /// Run the policy against the resolved today-row's values and post at most one notification per day.
    /// `dayEffort`/`targetRange` are both on canonical 0–100 Effort. No-op on every path that fails the
    /// policy, so the caller can fire it freely each time history republishes. The persisted day marker
    /// advances only after an authorized post, so a notifications-denied day can retry later that day.
    static func onDayUpdate(
        day: String,
        dayEffort: Double?,
        targetRange: DailyActionPlanner.EffortRange?,
        enabled: Bool
    ) {
        onDayUpdate(
            day: day,
            dayEffort: dayEffort,
            targetRange: targetRange,
            enabled: enabled,
            client: .system
        )
    }

    static func onDayUpdate(
        day: String,
        dayEffort: Double?,
        targetRange: DailyActionPlanner.EffortRange?,
        enabled: Bool,
        client: NotificationClient
    ) {
        let d = UserDefaults.standard
        let currentLocalDay = localCalendarDay()
        let guidance = DailyEffortGuidance.evaluate(
            currentEffort: dayEffort,
            range: targetRange
        )
        guard StrainTargetPolicy.shouldNotify(enabled: enabled,
                                              guidance: guidance,
                                              dataDay: day,
                                              currentLocalDay: currentLocalDay,
                                              lastNotifiedDay: d.string(forKey: lastDayKey)),
              let current = guidance.current,
              let range = guidance.range,
              activeDay != currentLocalDay else { return }
        let title = String(localized: "daily_plan.notification.title")
        let body = String(
            format: String(localized: "daily_plan.notification.body"),
            Int(current.rounded()),
            range.lower,
            range.upper
        )
        let generation = deliveryGeneration
        activeDay = currentLocalDay
        Task { @MainActor in
            defer {
                if activeDay == currentLocalDay { activeDay = nil }
            }
            let status = await client.authorizationStatus()
            guard canPost(using: status) else {
                LocalNotificationLifecycle.suppressed(
                    identifier: requestID,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
                return
            }
            guard generation == deliveryGeneration,
                  localCalendarDay() == currentLocalDay else {
                LocalNotificationLifecycle.suppressed(
                    identifier: requestID,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
                return
            }
            await client.preparePrivateCategory()
            guard generation == deliveryGeneration,
                  localCalendarDay() == currentLocalDay else { return }

            let content = UNMutableNotificationContent()
            content.applyProminence(.ambient)
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.daily-effort"
            content.userInfo = [
                NotificationRouteBridge.userInfoKey: NoopNotificationRoute.today.rawValue,
            ]
            do {
                try await client.add(
                    UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
                )
                guard generation == deliveryGeneration,
                      localCalendarDay() == currentLocalDay else {
                    client.remove([requestID])
                    return
                }
                UserDefaults.standard.set(currentLocalDay, forKey: lastDayKey)
            } catch {
                if generation != deliveryGeneration {
                    client.remove([requestID])
                }
            }
        }
    }

    static func clear() {
        clear(client: .system)
    }

    static func clear(client: NotificationClient) {
        deliveryGeneration &+= 1
        activeDay = nil
        client.remove([requestID])
    }

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
