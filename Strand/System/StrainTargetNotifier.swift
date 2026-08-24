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
enum StrainTargetNotifier {
    private static let lastDayKey = "behavior.strainTargetLastDay"

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

    /// Ask up front (called when the user enables the nudge) so the system dialog appears at a
    /// predictable moment, not on the first crossing. BatteryNotifier idiom.
    static func requestAuthorization() {
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
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
              let range = guidance.range else { return }
        let title = String(localized: "daily_plan.notification.title")
        let body = String(
            format: String(localized: "daily_plan.notification.body"),
            Int(current.rounded()),
            range.lower,
            range.upper
        )
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            // Authorization is requested once via requestAuthorization() when the toggle is enabled; here we
            // only check status (no second system prompt) — the BatteryNotifier idiom.
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized,
                  localCalendarDay() == currentLocalDay else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.daily-effort"
            content.userInfo = [
                NotificationRouteBridge.userInfoKey: NoopNotificationRoute.today.rawValue,
            ]
            do {
                DailyReviewNotifications.registerPrivacyCategory(on: center)
                try await center.add(
                    UNNotificationRequest(identifier: "strain-target", content: content, trigger: nil)
                )
                UserDefaults.standard.set(currentLocalDay, forKey: lastDayKey)
            } catch {
                // Keep the day unset so a later analytics pass can retry after a transient add failure.
            }
        }
    }
}
