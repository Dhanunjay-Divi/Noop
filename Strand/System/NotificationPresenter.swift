import Foundation
import NoopRemoteSync
import UserNotifications

enum LocalNotificationLifecycleState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case presented
    case cancelled
    case suppressed
    case unknown
}

struct LocalNotificationLifecycleRecord: Codable, Equatable, Sendable {
    let identifier: String
    let categoryIdentifier: String
    let state: LocalNotificationLifecycleState
    let timestamp: Date
}

/// A deliberately narrow, bounded record of app-observable notification lifecycle events.
///
/// It never stores notification copy, userInfo, routes, health values, errors, or delivery claims.
/// `scheduled` means Notification Center accepted a request. `presented` means a delegate callback was
/// observed. Neither state implies that an unobserved background banner, sound, or device alert occurred.
final class LocalNotificationLifecycleLedger: @unchecked Sendable {
    static let shared = LocalNotificationLifecycleLedger()
    static let defaultCapacity = 128

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let capacity: Int
    private var recordsStorage: [LocalNotificationLifecycleRecord]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "diagnostics.localNotificationLifecycle.v1",
        capacity: Int = defaultCapacity
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.capacity = max(1, capacity)
        let decoded = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([LocalNotificationLifecycleRecord].self, from: $0)
        } ?? []
        self.recordsStorage = Array(
            decoded.map(Self.sanitizedRecord).suffix(max(1, capacity))
        )
        if let data = try? JSONEncoder().encode(recordsStorage) {
            defaults.set(data, forKey: storageKey)
        }
    }

    func record(
        identifier: String,
        categoryIdentifier: String,
        state: LocalNotificationLifecycleState,
        timestamp: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(
            LocalNotificationLifecycleRecord(
                identifier: Self.stableIdentifier(identifier),
                categoryIdentifier: Self.stableCategory(categoryIdentifier),
                state: state,
                timestamp: timestamp
            )
        )
    }

    /// Cancellation records an app request to remove a notification. Notification Center does not report
    /// whether a matching pending or presented request existed, so no stronger claim is made.
    func recordCancellation(
        identifier: String,
        categoryIdentifier: String? = nil,
        timestamp: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        let stableIdentifier = Self.stableIdentifier(identifier)
        let category = categoryIdentifier.map {
            Self.stableCategory($0)
        } ?? recordsStorage.last(where: {
            $0.identifier == stableIdentifier
        })?.categoryIdentifier ?? "unknown"
        appendLocked(
            LocalNotificationLifecycleRecord(
                identifier: stableIdentifier,
                categoryIdentifier: category,
                state: .cancelled,
                timestamp: timestamp
            )
        )
    }

    func records() -> [LocalNotificationLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsStorage
    }

    func serializedRecords() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return (try? JSONEncoder().encode(recordsStorage)) ?? Data("[]".utf8)
    }

    func diagnosticLines(limit: Int = 24) -> [String] {
        let snapshot = Array(records().suffix(max(0, limit)))
        var lines = [
            String(repeating: "-", count: 40),
            "Local notification lifecycle",
            "Evidence only: scheduled=OS accepted request; presented=app delegate callback observed.",
        ]
        guard !snapshot.isEmpty else {
            lines.append("(no lifecycle events recorded)")
            return lines
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lines += snapshot.map {
            "\(formatter.string(from: $0.timestamp)) "
                + "state=\($0.state.rawValue) "
                + "id=\($0.identifier) "
                + "category=\($0.categoryIdentifier)"
        }
        return lines
    }

    private func appendLocked(_ record: LocalNotificationLifecycleRecord) {
        recordsStorage.append(record)
        if recordsStorage.count > capacity {
            recordsStorage.removeFirst(recordsStorage.count - capacity)
        }
        if let data = try? JSONEncoder().encode(recordsStorage) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func sanitizedRecord(
        _ record: LocalNotificationLifecycleRecord
    ) -> LocalNotificationLifecycleRecord {
        LocalNotificationLifecycleRecord(
            identifier: stableIdentifier(record.identifier),
            categoryIdentifier: stableCategory(record.categoryIdentifier),
            state: record.state,
            timestamp: record.timestamp
        )
    }

    /// Maps producer-owned request identifiers to a fixed diagnostic vocabulary.
    /// Prefixes intentionally discard dates, reminder slots, metric names, and other suffixes.
    static func stableIdentifier(_ raw: String) -> String {
        let canonical = Set([
            "coach_check_in", "connection", "auto_workout", "strain_target",
            "morning_recap",
            "safety_check_in", "safety_contact_setup", "safety_sos_result",
            "illness_check_in", "daily_review", "inactivity", "smart_alarm",
            "battery", "wind_down", "hydration", "metric_review",
            "contextual_vital", "adaptive_day", "caffeine_cutoff", "stale_sync",
            "managed_poke", "unknown",
        ])
        if canonical.contains(raw) {
            return raw
        }
        let exact: [String: String] = [
            "noop.coach.local-check-in": "coach_check_in",
            "bluetooth-powered-off": "connection",
            "auto-workout-candidate": "auto_workout",
            "strain-target": "strain_target",
            "morning-recap": "morning_recap",
            "noop.safety.personal-check-in": "safety_check_in",
            "noop.safety.contacts.setup": "safety_contact_setup",
            "safety-gesture-result": "safety_sos_result",
            "wellness-check-in": "illness_check_in",
            "noop.band-sync.stale": "stale_sync",
            "managed-poke": "managed_poke",
            "contextual-adaptivePlannedWorkout-boundary": "adaptive_day",
        ]
        if let mapped = exact[raw] {
            return mapped
        }
        let prefixes: [(String, String)] = [
            ("daily-review-", "daily_review"),
            ("inactivity-", "inactivity"),
            ("smart-alarm-", "smart_alarm"),
            ("battery-", "battery"),
            ("wind-down-nudge", "wind_down"),
            ("hydration-reminder", "hydration"),
            ("metric-review-", "metric_review"),
            ("contextual-", "contextual_vital"),
            ("vital-", "contextual_vital"),
            ("caffeine-cutoff-", "caffeine_cutoff"),
            ("illness-", "illness_check_in"),
            ("managed-poke-", "managed_poke"),
        ]
        return prefixes.first(where: { raw.hasPrefix($0.0) })?.1 ?? "unknown"
    }

    static func stableCategory(_ raw: String) -> String {
        switch raw {
        case "":
            return "none"
        case DailyReviewNotifications.privacyCategoryID, "private":
            return "private"
        case "none", "unknown":
            return raw
        default:
            return "unknown"
        }
    }
}

/// Central boundary for local notification adds and removals. Callers still own authorization and policy;
/// this boundary records only the observable result of their interaction with Notification Center.
enum LocalNotificationLifecycle {
    static func schedule(
        _ request: UNNotificationRequest,
        on center: UNUserNotificationCenter = .current()
    ) async throws {
        do {
            try await center.add(request)
            record(request, state: .scheduled)
        } catch {
            record(request, state: .unknown)
            throw error
        }
    }

    static func schedule(
        _ request: UNNotificationRequest,
        on center: UNUserNotificationCenter = .current()
    ) {
        center.add(request) { error in
            record(request, state: error == nil ? .scheduled : .unknown)
        }
    }

    static func cancel(
        identifiers: [String],
        pending: Bool = true,
        presented: Bool = false,
        on center: UNUserNotificationCenter = .current()
    ) {
        guard !identifiers.isEmpty else { return }
        if pending {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        if presented {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        for identifier in identifiers {
            LocalNotificationLifecycleLedger.shared.recordCancellation(
                identifier: identifier
            )
        }
    }

    static func suppressed(
        identifier: String,
        categoryIdentifier: String = "none"
    ) {
        LocalNotificationLifecycleLedger.shared.record(
            identifier: identifier,
            categoryIdentifier: categoryIdentifier,
            state: .suppressed
        )
    }

    static func presented(_ request: UNNotificationRequest) {
        record(request, state: .presented)
    }

    private static func record(
        _ request: UNNotificationRequest,
        state: LocalNotificationLifecycleState
    ) {
        LocalNotificationLifecycleLedger.shared.record(
            identifier: request.identifier,
            categoryIdentifier: request.content.categoryIdentifier,
            state: state
        )
    }
}

/// Foreground presentation delegate for the app's local notifications (wind-down nudge, smart-alarm
/// backup, battery/illness alerts).
///
/// Without a `UNUserNotificationCenterDelegate`, iOS/macOS suppress a notification's banner while the
/// app is in the FOREGROUND (the default). A user testing a reminder with the app open would see
/// nothing and conclude notifications are broken. Returning banner + sound + list here makes them
/// visible whether the app is open or not — matching what the user expects from a reminder.
///
/// Cross-platform (iOS + macOS). Register once at launch:
/// `UNUserNotificationCenter.current().delegate = NotificationPresenter.shared`.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    private override init() { super.init() }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
#if os(iOS)
        if ManagedSafetyPushPayload.incidentID(
            from: notification.request.content.userInfo
        ) != nil {
            Task { @MainActor in
                guard ManagedRuntimeAuthorization.isAllowed else {
                    AppDiagnosticsRecorder.shared.record(
                        "managed_safety.push_presented",
                        fields: [
                            "outcome": "deferred",
                            "failure_kind": "terms_required",
                        ]
                    )
                    completionHandler([])
                    return
                }
                LocalNotificationLifecycle.presented(notification.request)
                AppDiagnosticsRecorder.shared.record(
                    "managed_safety.push_presented",
                    fields: ["outcome": "foreground"]
                )
                ContextualActionCenter.shared.capture(notification.request)
                completionHandler([.banner, .sound, .list])
            }
            return
        }
#endif
        LocalNotificationLifecycle.presented(notification.request)
        Task { @MainActor in
            ContextualActionCenter.shared.capture(notification.request)
        }
        completionHandler([.banner, .sound, .list])
    }

    /// Route a tapped review reminder into the relevant top-level screen. The bridge persists first,
    /// which is essential during a cold launch: SwiftUI may not have mounted RootView/RootTabView yet.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // A response is direct evidence that Notification Center surfaced this request to the user. It
        // does not retroactively make any claim about other scheduled notifications.
        LocalNotificationLifecycle.presented(response.notification.request)
        Task { @MainActor in
            ContextualActionCenter.shared.capture(response.notification.request)
        }
        #if os(iOS)
        if let incidentID = ManagedSafetyPushPayload.incidentIDForUserResponse(
            from: response.notification.request.content.userInfo
        ) {
            NotificationRouteBridge.recordPending(.safety)
            Task { @MainActor in
                guard ManagedRuntimeAuthorization.isAllowed else {
                    AppDiagnosticsRecorder.shared.record(
                        "managed_safety.push_opened",
                        fields: [
                            "outcome": "deferred",
                            "failure_kind": "terms_required",
                        ]
                    )
                    return
                }
                AppDiagnosticsRecorder.shared.record(
                    "managed_safety.push_opened",
                    fields: ["outcome": "accepted"]
                )
                _ = await ManagedCloudService.shared
                    .handleManagedSafetyPush(incidentID: incidentID)
            }
        } else if let route = NotificationRouteBridge.route(
            from: response.notification.request.content.userInfo
        ) {
            NotificationRouteBridge.recordPending(route)
        }
        #else
        if let route = NotificationRouteBridge.route(
            from: response.notification.request.content.userInfo
        ) {
            NotificationRouteBridge.recordPending(route)
        }
        #endif
        completionHandler()
    }
}

// MARK: - Prominence policy

/// How loudly a notification is allowed to arrive.
///
/// iOS silences the default `.active` level under Focus and Do Not Disturb. Before this existed every
/// NOOP notification used that default, which produced two opposite defects at once: a safety check-in
/// the user had explicitly armed could be silenced by a Focus mode, while a strap-battery nudge arrived
/// with exactly the same prominence as that safety message.
///
/// The vocabulary is deliberately three-valued. Adding a fourth tier invites per-notification tuning,
/// and prominence creep is how apps train users to swipe everything away.
///
/// `.timeSensitive` requires the `com.apple.developer.usernotifications.time-sensitive` entitlement.
/// Without it iOS silently downgrades the request to `.active`, so the entitlement and this policy have
/// to travel together. It does NOT require, and NOOP does not request, the critical-alert entitlement:
/// that one pierces silent mode and is reserved for medical devices, which NOOP explicitly is not.
enum NotificationProminence {
    /// A safety flow the user armed themselves: check-ins and SOS results. Allowed to pierce Focus,
    /// because a safety feature that Do Not Disturb can mute is not a safety feature.
    case safetyCritical
    /// Everything score- or coaching-related. Keeps the ordinary `.active` behaviour.
    case standard
    /// Housekeeping the user never needs woken for: battery, review reminders, digests.
    case ambient

    var level: UNNotificationInterruptionLevel {
        switch self {
        case .safetyCritical: return .timeSensitive
        case .standard:       return .active
        case .ambient:        return .passive
        }
    }
}

extension UNMutableNotificationContent {
    /// Applies the prominence tier. Call this on every content object so the choice is explicit at the
    /// producer rather than inherited from an iOS default nobody chose.
    func applyProminence(_ prominence: NotificationProminence) {
        interruptionLevel = prominence.level
    }
}
