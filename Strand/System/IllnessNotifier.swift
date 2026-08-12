import Foundation
import UserNotifications

/// Surfaces a private multi-signal check-in when the in-app banner transitions
/// from clear to raised — today it is silent unless the window is open (the menu-bar extra keeps
/// NOOP alive). Rate-limited to once per local calendar day; the in-app banner stays the live
/// surface. On-device only; the summary is APPROXIMATE — informational, not a diagnosis.
enum IllnessNotifier {
    private static let lastDayKey = "behavior.illnessLastNotifiedDay"

    /// Ask up front (called when the user enables the watch) so the system dialog appears at a
    /// predictable moment, not on the first 3 a.m. transition.
    static func requestAuthorization() {
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Post the private check-in, at most once per local calendar day. Measurements and inferred
    /// state deliberately stay inside the unlocked app; notification previews never expose them.
    static func post() {
        let day = dayKey(Date())
        let d = UserDefaults.standard
        guard d.string(forKey: lastDayKey) != day else { return }
        // Mark the day up front so the once-per-day limit holds even if the user declined
        // notifications or delivery is deferred — the in-app banner stays the live surface either
        // way, and we never re-prompt or retry on every transition.
        d.set(day, forKey: lastDayKey)
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            // Authorization is requested once via requestAuthorization() when the watch is enabled;
            // here we only check status (no second system prompt).
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            DailyReviewNotifications.registerPrivacyCategory(on: center)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Private wellness check-in")
            content.body = String(localized: "Open NOOP to review it.")
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.wellness-check-in"
            content.userInfo = [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.today.rawValue]
            try? await center.add(UNNotificationRequest(identifier: "wellness-check-in",
                                                        content: content, trigger: nil))
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
