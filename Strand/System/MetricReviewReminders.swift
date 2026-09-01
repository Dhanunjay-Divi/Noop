import Foundation
import UserNotifications

/// Privacy-safe metric reviews at a cadence that matches the selected signal.
///
/// Metrics at the same cadence share one request, so even a broad selection consumes at most three
/// pending-notification slots. Slow model estimates default to monthly, body-composition and aerobic
/// trends default to weekly, and day-scale signals default to daily. The user can override this.
/// Notifications never embed values or interpretations and never claim to trigger a sensor reading.
@MainActor
enum MetricReviewReminders {
    static let enabledIDsKey = "metricReview.enabledIDs"
    static let minuteOfDayKey = "metricReview.minuteOfDay"
    static let cadenceByIDKey = "metricReview.cadenceByID"

    enum Cadence: String, CaseIterable, Identifiable, Sendable {
        case daily
        case weekly
        case monthly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .daily: return String(localized: "Daily")
            case .weekly: return String(localized: "Weekly")
            case .monthly: return String(localized: "Monthly")
            }
        }

        fileprivate var requestID: String { "metric-review-\(rawValue)" }
    }

    enum EnableOutcome: Equatable, Sendable {
        case scheduled
        case denied
        case off
    }

    struct ReminderSpec: Equatable, Sendable {
        let identifier: String
        let minuteOfDay: Int
        let cadence: Cadence
        let title: String
        let body: String
        let route: NoopNotificationRoute
    }

    static var enabledIDs: [String] {
        let values = UserDefaults.standard.stringArray(forKey: enabledIDsKey) ?? []
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static var minuteOfDay: Int {
        let stored = UserDefaults.standard.object(forKey: minuteOfDayKey) as? Int ?? 18 * 60
        return DailyReviewNotifications.clampMinute(stored)
    }

    static func isEnabled(metricID: String) -> Bool {
        enabledIDs.contains(metricID)
    }

    static func recommendedCadence(metricID: String) -> Cadence {
        let key = metricID.split(separator: ":").last.map(String.init) ?? metricID
        switch key {
        case "fitness_age", "body_age", "vitality":
            return .monthly
        case "vo2max", "vo2max_est", "weight", "body_fat", "lean_mass", "bmi":
            return .weekly
        default:
            return .daily
        }
    }

    static func cadence(metricID: String) -> Cadence {
        let stored = UserDefaults.standard.dictionary(forKey: cadenceByIDKey) as? [String: String]
        return stored?[metricID].flatMap(Cadence.init(rawValue:))
            ?? recommendedCadence(metricID: metricID)
    }

    static func setCadence(metricID: String, cadence: Cadence) {
        var stored = UserDefaults.standard.dictionary(forKey: cadenceByIDKey) as? [String: String] ?? [:]
        stored[metricID] = cadence.rawValue
        UserDefaults.standard.set(stored, forKey: cadenceByIDKey)
        if isEnabled(metricID: metricID) { schedule() }
    }

    static func setMetric(
        id: String,
        enabled: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        var ids = enabledIDs
        if !enabled {
            ids.removeAll { $0 == id }
            persist(ids)
            if ids.isEmpty {
                removeRequest()
                completion?(.off)
            } else {
                schedule()
                completion?(.scheduled)
            }
            return
        }

        guard !ids.contains(id) else {
            schedule()
            completion?(.scheduled)
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let authorized: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorized = true
            case .notDetermined:
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            default:
                authorized = false
            }

            guard authorized else {
                for cadence in Cadence.allCases {
                    LocalNotificationLifecycle.suppressed(
                        identifier: cadence.requestID,
                        categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                    )
                }
                completion?(.denied)
                return
            }
            // Authorization may have suspended this task while another metric toggle completed.
            // Re-read on the main actor so two quick opt-ins merge instead of the last stale array winning.
            var currentIDs = enabledIDs
            if !currentIDs.contains(id) { currentIDs.append(id) }
            persist(currentIDs)
            schedule()
            completion?(.scheduled)
        }
    }

    static func setMinuteOfDay(_ minutes: Int) {
        UserDefaults.standard.set(DailyReviewNotifications.clampMinute(minutes), forKey: minuteOfDayKey)
        if !enabledIDs.isEmpty { schedule() }
    }

    /// Per-metric reminders were retired in favor of the central Daily guidance automations. Clear
    /// existing selections and pending requests so an upgrade cannot keep sending an alert the user
    /// can no longer manage.
    static func retireLegacySchedule() {
        UserDefaults.standard.removeObject(forKey: enabledIDsKey)
        UserDefaults.standard.removeObject(forKey: minuteOfDayKey)
        UserDefaults.standard.removeObject(forKey: cadenceByIDKey)
        removeRequest()
    }

    static func reminderSpec(
        minuteOfDay: Int,
        metricTitles: [String],
        cadence: Cadence = .daily
    ) -> ReminderSpec? {
        var seen = Set<String>()
        let titles = metricTitles.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !titles.isEmpty else { return nil }

        let body: String
        switch titles.count {
        case 1:
            body = String(localized: "Review \(titles[0]) and compare it with your personal baseline.")
        case 2:
            body = String(localized: "Review \(titles[0]) and \(titles[1]) in your Trends.")
        default:
            body = String(localized: "Review \(titles[0]), \(titles[1]), and \(titles.count - 2) more selected metrics.")
        }
        return ReminderSpec(
            identifier: cadence.requestID,
            minuteOfDay: DailyReviewNotifications.clampMinute(minuteOfDay),
            cadence: cadence,
            title: String(localized: "Metric review"),
            body: body,
            route: .trends
        )
    }

    private static func persist(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: enabledIDsKey)
    }

    private static func schedule() {
        let selected = enabledIDs.compactMap { id -> (id: String, title: String)? in
            guard let title = MetricCatalog.all.first(where: { $0.id == id })?.title else {
                return nil
            }
            return (id, title)
        }
        let center = UNUserNotificationCenter.current()
        LocalNotificationLifecycle.cancel(
            identifiers: Cadence.allCases.map(\.requestID),
            on: center
        )
        guard !selected.isEmpty else { return }
        DailyReviewNotifications.registerPrivacyCategory(on: center)

        for cadence in Cadence.allCases {
            let titles = selected
                .filter { Self.cadence(metricID: $0.id) == cadence }
                .map(\.title)
            guard let spec = reminderSpec(
                minuteOfDay: minuteOfDay,
                metricTitles: titles,
                cadence: cadence
            ) else { continue }

            let content = UNMutableNotificationContent()
            content.applyProminence(.ambient)
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.metric-review"
            content.userInfo = [NotificationRouteBridge.userInfoKey: spec.route.rawValue]

            var components = DateComponents()
            components.hour = spec.minuteOfDay / 60
            components.minute = spec.minuteOfDay % 60
            switch spec.cadence {
            case .daily:
                break
            case .weekly:
                components.weekday = 1
            case .monthly:
                components.day = 1
            }
            LocalNotificationLifecycle.schedule(
                UNNotificationRequest(
                    identifier: spec.identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: components,
                        repeats: true
                    )
                ),
                on: center
            )
        }
    }

    private static func removeRequest() {
        LocalNotificationLifecycle.cancel(
            identifiers: Cadence.allCases.map(\.requestID)
        )
    }
}
