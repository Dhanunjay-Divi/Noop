import Foundation
import UserNotifications

/// Opt-in, privacy-safe water reminders.
///
/// The OS notification schedule is the durable lane: it can present while NOOP is suspended and may
/// mirror to Apple Watch according to the user's iPhone/Watch notification settings. A WHOOP buzz is a
/// separate best-effort lane. `AppModel` claims a due slot only while fresh live packets prove that the
/// encrypted strap connection is active; this file deliberately makes no background-delivery promise.
@MainActor
enum HydrationReminders {
    static let enabledKey = "hydrationReminders.enabled"
    static let intervalMinutesKey = "hydrationReminders.intervalMinutes"
    static let activeStartMinutesKey = "hydrationReminders.activeStartMinutes"
    static let activeEndMinutesKey = "hydrationReminders.activeEndMinutes"
    static let strapBuzzEnabledKey = "hydrationReminders.strapBuzzEnabled"
    /// One-time boundary between the legacy combined reminder switch and the independent phone/wrist
    /// channels. An old hidden wrist flag must never become active merely because the app was updated.
    static let independentChannelsMigrationKey = "hydrationReminders.independentChannels.v1"

    private static let scheduledRequestIDsKey = "hydrationReminders.scheduledRequestIDs"
    private static let lastClaimedStrapSlotKey = "hydrationReminders.lastClaimedStrapSlot"
    private static let requestIDPrefix = "hydration-reminder-"
    private static let masterWristAlertsKey = "notif.masterEnabled"
    private static let quietHoursEnabledKey = "notif.quietHoursEnabled"
    private static let quietStartMinutesKey = "notif.quietStartMinutes"
    private static let quietEndMinutesKey = "notif.quietEndMinutes"
    private static let minimumIntervalMinutes = 60
    private static let maximumIntervalMinutes = 240

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

    struct DueSlot: Equatable, Sendable {
        let minuteOfDay: Int
        /// Local calendar day on which this exact occurrence began (`yyyy-MM-dd`).
        let localDay: String

        var token: String { "\(localDay)-\(minuteOfDay)" }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var intervalMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: intervalMinutesKey) as? Int ?? 120
        return clampedInterval(raw)
    }

    static var activeStartMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: activeStartMinutesKey) as? Int ?? 8 * 60
        return DailyReviewNotifications.clampMinute(raw)
    }

    static var activeEndMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: activeEndMinutesKey) as? Int ?? 21 * 60
        return DailyReviewNotifications.clampMinute(raw)
    }

    static var strapBuzzEnabled: Bool {
        UserDefaults.standard.bool(forKey: strapBuzzEnabledKey)
    }

    /// Preserve an explicitly active legacy pair, but clear a dormant hidden wrist flag when the old
    /// master reminder was OFF. From this build onward each channel persists independently.
    static func migrateIndependentChannelsIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: independentChannelsMigrationKey) else { return }
        if !defaults.bool(forKey: enabledKey) {
            defaults.set(false, forKey: strapBuzzEnabledKey)
            defaults.removeObject(forKey: lastClaimedStrapSlotKey)
        }
        defaults.set(true, forKey: independentChannelsMigrationKey)
    }

    static func setEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            removeScheduledRequests()
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
                    completion?(.denied)
                }
            default:
                UserDefaults.standard.set(false, forKey: enabledKey)
                completion?(.denied)
            }
        }
    }

    static func setIntervalMinutes(_ minutes: Int) {
        UserDefaults.standard.set(clampedInterval(minutes), forKey: intervalMinutesKey)
        if isEnabled { schedule() }
    }

    static func setActiveStartMinutes(_ minutes: Int) {
        UserDefaults.standard.set(DailyReviewNotifications.clampMinute(minutes), forKey: activeStartMinutesKey)
        if isEnabled { schedule() }
    }

    static func setActiveEndMinutes(_ minutes: Int) {
        UserDefaults.standard.set(DailyReviewNotifications.clampMinute(minutes), forKey: activeEndMinutesKey)
        if isEnabled { schedule() }
    }

    static func setStrapBuzzEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: strapBuzzEnabledKey)
        if !on { UserDefaults.standard.removeObject(forKey: lastClaimedStrapSlotKey) }
    }

    /// Rebuild pending requests after an upgrade without ever prompting for permission on launch.
    static func restoreScheduleIfAuthorized() {
        guard isEnabled else {
            removeScheduledRequests()
            return
        }
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                schedule()
            default:
                break
            }
        }
    }

    /// Daily reminder slots in a start-inclusive/end-exclusive window, including overnight windows.
    /// Equal start/end means all day, matching the Android policy and common quiet-hours semantics.
    static func reminderMinutes(start: Int, end: Int, interval: Int) -> [Int] {
        let start = DailyReviewNotifications.clampMinute(start)
        let end = DailyReviewNotifications.clampMinute(end)
        let step = clampedInterval(interval)
        let wrappedDuration = (end - start + 24 * 60) % (24 * 60)
        let duration = wrappedDuration == 0 ? 24 * 60 : wrappedDuration
        return stride(from: 0, to: duration, by: step).map { (start + $0) % (24 * 60) }
    }

    static func reminderSpecs(start: Int, end: Int, interval: Int) -> [ReminderSpec] {
        reminderMinutes(start: start, end: end, interval: interval).map { minute in
            ReminderSpec(
                identifier: requestIDPrefix + String(minute),
                minuteOfDay: minute,
                title: String(localized: "Hydration check-in"),
                body: String(localized: "Take a moment to drink some water if you need it."),
                route: .today
            )
        }
    }

    static func clampedInterval(_ minutes: Int) -> Int {
        min(max(minutes, minimumIntervalMinutes), maximumIntervalMinutes)
    }

    /// Shared quiet-hours semantics: inclusive start, exclusive end, with midnight wrapping. Matching
    /// start/end is an empty quiet window, consistent with Android `NotifPrefs.inQuietHours` and the
    /// existing Apple inactivity-alert policy (hydration's own matching active times still mean all day).
    static func windowContains(_ minuteOfDay: Int, start: Int, end: Int) -> Bool {
        let minute = DailyReviewNotifications.clampMinute(minuteOfDay)
        let start = DailyReviewNotifications.clampMinute(start)
        let end = DailyReviewNotifications.clampMinute(end)
        if start <= end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    /// The most recent due occurrence inside a small grace window. Kept pure for deterministic tests.
    static func dueSlot(
        now: Date,
        calendar: Calendar = .current,
        slots: [Int],
        graceMinutes: Int = 5
    ) -> DueSlot? {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let grace = max(0, graceMinutes)

        let candidates: [(slot: Int, elapsed: Int)] = slots.map { raw in
            let slot = DailyReviewNotifications.clampMinute(raw)
            return (slot, (nowMinute - slot + 24 * 60) % (24 * 60))
        }.filter { $0.elapsed <= grace }

        guard let candidate = candidates.min(by: { $0.elapsed < $1.elapsed }),
              let occurrence = calendar.date(byAdding: .minute, value: -candidate.elapsed, to: now)
        else { return nil }

        let day = calendar.dateComponents([.year, .month, .day], from: occurrence)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
        return DueSlot(
            minuteOfDay: candidate.slot,
            localDay: String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        )
    }

    /// Atomically claims one live WHOOP-buzz occurrence. `AppModel` still gates the actual command on
    /// bonded + encrypted live state. This preference gate keeps the automation opt-in and de-duplicated.
    static func claimDueStrapBuzz(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let defaults = UserDefaults.standard
        guard strapBuzzEnabled,
              defaults.bool(forKey: masterWristAlertsKey)
        else { return false }

        if defaults.bool(forKey: quietHoursEnabledKey) {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let quietStart = defaults.object(forKey: quietStartMinutesKey) as? Int ?? 22 * 60
            let quietEnd = defaults.object(forKey: quietEndMinutesKey) as? Int ?? 7 * 60
            if windowContains(nowMinute, start: quietStart, end: quietEnd) { return false }
        }

        let slots = reminderMinutes(
            start: activeStartMinutes,
            end: activeEndMinutes,
            interval: intervalMinutes
        )
        guard let due = dueSlot(now: now, calendar: calendar, slots: slots),
              defaults.string(forKey: lastClaimedStrapSlotKey) != due.token
        else { return false }

        defaults.set(due.token, forKey: lastClaimedStrapSlotKey)
        return true
    }

    private static var storedRequestIDs: [String] {
        UserDefaults.standard.stringArray(forKey: scheduledRequestIDsKey) ?? []
    }

    private static func removeScheduledRequests() {
        let ids = storedRequestIDs
        if !ids.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
        UserDefaults.standard.removeObject(forKey: scheduledRequestIDsKey)
    }

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        let oldIDs = storedRequestIDs
        if !oldIDs.isEmpty { center.removePendingNotificationRequests(withIdentifiers: oldIDs) }
        DailyReviewNotifications.registerPrivacyCategory(on: center)

        let specs = reminderSpecs(
            start: activeStartMinutes,
            end: activeEndMinutes,
            interval: intervalMinutes
        )
        UserDefaults.standard.set(specs.map(\.identifier), forKey: scheduledRequestIDsKey)

        for spec in specs {
            let content = UNMutableNotificationContent()
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.hydration"
            content.userInfo = [NotificationRouteBridge.userInfoKey: spec.route.rawValue]

            var components = DateComponents()
            components.hour = spec.minuteOfDay / 60
            components.minute = spec.minuteOfDay % 60
            center.add(
                UNNotificationRequest(
                    identifier: spec.identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
            )
        }
    }
}
