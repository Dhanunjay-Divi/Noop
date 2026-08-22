import Foundation
import StrandAnalytics
import UserNotifications

/// OS boundary for one manually armed personal check-in reminder.
///
/// The reminder is local and best-effort. It never sends a message, contacts a trusted person, reports
/// health data, or calls emergency services. Those constraints are repeated in the UI and pure policy.
@MainActor
enum SafetyCheckInNotifications {
    static let requestIdentifier = "noop.safety.personal-check-in"

    enum ScheduleOutcome: Equatable {
        case scheduled
        case denied
        case failed
    }

    enum DeliveryState: Equatable {
        case unknown
        case scheduled
        case notificationsOff
        case requestMissing
        case notApplicable
    }

    static func schedule(dueAt: Date) async -> ScheduleOutcome {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized: Bool

        switch settings.authorizationStatus {
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = isAuthorized(settings.authorizationStatus)
        }
        guard authorized else { return .denied }

        let remaining = dueAt.timeIntervalSinceNow
        guard remaining >= 1 else { return .failed }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "safety.notification.title")
        content.body = String(localized: "safety.notification.body")
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.safety.check-in"
        content.userInfo = [
            NotificationRouteBridge.userInfoKey: NoopNotificationRoute.safety.rawValue,
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: trigger
        )

        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        DailyReviewNotifications.registerPrivacyCategory(on: center)
        do {
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed
        }
    }

    static func deliveryState(dueAt: Date?) async -> DeliveryState {
        guard let dueAt, dueAt.timeIntervalSinceNow >= 1 else { return .notApplicable }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard isAuthorized(settings.authorizationStatus) else {
            return .notificationsOff
        }

        let identifier = requestIdentifier
        let exists = await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(
                    returning: requests.contains { $0.identifier == identifier }
                )
            }
        }
        return exists ? .scheduled : .requestMissing
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
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
