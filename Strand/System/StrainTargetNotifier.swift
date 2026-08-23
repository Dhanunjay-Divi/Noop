import Foundation
import UserNotifications

// MARK: - Target-strain notification (#593)
//
// A single opt-in, default-OFF informational nudge: once per day, when the day's canonical 0–100 Effort
// reaches the LOW end of DailyActionPlanner's evidence-gated personal range, post an "Effort marker
// reached" notification. Twin of the Android `StrainTargetNotifier`/`StrainTargetPolicy` - the pure policy
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
        /// Fire at most once per day: only when enabled, BOTH the day strain and the target are known,
        /// the day strain has reached the target, and we haven't already posted for `today`. `dayStrain`
        /// and `target` must be on the SAME canonical 0–100 Effort axis. A nil target means the planner
        /// withheld the range (unanswered check-in, stale/thin evidence, or recovery shift) ⇒ never fires.
        static func shouldNotify(enabled: Bool,
                                 dayStrain: Double?,
                                 target: Double?,
                                 lastNotifiedDay: String?,
                                 today: String) -> Bool {
            guard enabled, let dayStrain, let target else { return false }
            return dayStrain >= target && lastNotifiedDay != today
        }

        /// Title + body for the nudge. `target` is the marker on canonical 0–100 Effort. The wording
        /// deliberately avoids "optimal", "earned", or permission-to-push claims.
        static func copy(target: Int) -> (title: String, body: String) {
            (String(localized: "Effort marker reached"),
             String(localized: "You've reached today's Effort marker of \(target). It is a planning cue, not a limit-check how you feel before adding more."))
        }
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
    /// `dayEffort`/`targetEffort` are both on canonical 0–100 Effort. No-op on every path that fails the
    /// policy, so the caller can fire it freely each time history republishes. The persisted day marker
    /// advances only after an authorized post, so a notifications-denied day can retry later that day.
    static func onDayUpdate(day: String, dayEffort: Double?, targetEffort: Int?, enabled: Bool) {
        let d = UserDefaults.standard
        guard StrainTargetPolicy.shouldNotify(enabled: enabled,
                                              dayStrain: dayEffort,
                                              target: targetEffort.map(Double.init),
                                              lastNotifiedDay: d.string(forKey: lastDayKey),
                                              today: day) else { return }
        // Non-nil: shouldNotify above required a non-nil target before returning true.
        let copy = StrainTargetPolicy.copy(target: targetEffort!)
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            // Authorization is requested once via requestAuthorization() when the toggle is enabled; here we
            // only check status (no second system prompt) — the BatteryNotifier idiom.
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            do {
                try await center.add(
                    UNNotificationRequest(identifier: "strain-target", content: content, trigger: nil)
                )
                UserDefaults.standard.set(day, forKey: lastDayKey)
            } catch {
                // Keep the day unset so a later analytics pass can retry after a transient add failure.
            }
        }
    }
}
