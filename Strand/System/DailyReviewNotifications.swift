import Foundation
import UserNotifications

/// A destination carried by a NOOP notification. The route is deliberately small: notifications
/// open a trusted top-level screen, never a URL or arbitrary stored navigation value.
enum NoopNotificationRoute: String, Codable, Equatable, Sendable {
    case today
    case trends
    case workouts
    case sleep
    case journal
    case hydration
    case breathe
    case devices
    case friends
    case safety
    case coach
}

struct PendingNotificationRouteRequest: Equatable, Sendable {
    let route: NoopNotificationRoute
    let journalDay: String?
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
    static let journalDayUserInfoKey = "noop.notification.journalDay"
    static let pendingRouteKey = "noop.notification.pendingRoute"
    static let pendingJournalDayKey = "noop.notification.pendingJournalDay"
    static let routeRequested = Notification.Name("noop.notification.routeRequested")

    static func route(from userInfo: [AnyHashable: Any]) -> NoopNotificationRoute? {
        guard let raw = userInfo[userInfoKey] as? String else { return nil }
        return NoopNotificationRoute(rawValue: raw)
    }

    static func journalDay(from userInfo: [AnyHashable: Any]) -> String? {
        canonicalJournalDay(userInfo[journalDayUserInfoKey] as? String)
    }

    static func recordPending(
        _ route: NoopNotificationRoute,
        journalDay: String? = nil
    ) {
        UserDefaults.standard.set(route.rawValue, forKey: pendingRouteKey)
        if route == .journal, let journalDay = canonicalJournalDay(journalDay) {
            UserDefaults.standard.set(journalDay, forKey: pendingJournalDayKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingJournalDayKey)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: routeRequested, object: nil)
        }
    }

    static func consumePendingRequest() -> PendingNotificationRouteRequest? {
        guard let raw = UserDefaults.standard.string(forKey: pendingRouteKey) else {
            UserDefaults.standard.removeObject(forKey: pendingJournalDayKey)
            return nil
        }
        let journalDay = UserDefaults.standard.string(forKey: pendingJournalDayKey)
        UserDefaults.standard.removeObject(forKey: pendingRouteKey)
        UserDefaults.standard.removeObject(forKey: pendingJournalDayKey)
        guard let route = NoopNotificationRoute(rawValue: raw) else { return nil }
        return PendingNotificationRouteRequest(
            route: route,
            journalDay: route == .journal ? canonicalJournalDay(journalDay) : nil
        )
    }

    static func consumePending() -> NoopNotificationRoute? {
        consumePendingRequest()?.route
    }

    static func journalDayOffset(
        for request: PendingNotificationRouteRequest,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        guard request.route == .journal,
              let raw = request.journalDay,
              let date = date(fromCanonicalJournalDay: raw, calendar: calendar)
        else { return nil }
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day
        guard let offset, (-1...31).contains(offset) else { return nil }
        return offset
    }

    static func canonicalJournalDay(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard date(fromCanonicalJournalDay: raw, calendar: calendar) != nil else {
            return nil
        }
        return raw
    }

    private static func date(
        fromCanonicalJournalDay raw: String,
        calendar: Calendar
    ) -> Date? {
        let fields = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4,
              fields[1].count == 2,
              fields[2].count == 2,
              let year = Int(fields[0]),
              let month = Int(fields[1]),
              let day = Int(fields[2]),
              let date = calendar.date(
                  from: DateComponents(year: year, month: month, day: day)
              )
        else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year,
              components.month == month,
              components.day == day
        else { return nil }
        return date
    }
}

/// One completed sync may make several routine notifications eligible at once. This in-memory budget
/// lets the highest-priority eligible lane own that sync without consuming lower-lane dedupe state.
/// Safety alerts and active-workout cautions do not use this budget.
@MainActor
final class PostSyncRoutineNotificationBudget {
    enum Lane: String, Equatable, Sendable {
        case autoWorkout = "auto_workout"
        case adaptiveDay = "adaptive_day"
        case postWorkoutSummary = "post_workout_summary"
        case morningRecap = "morning_recap"
    }

    private(set) var claimedLane: Lane?
    private var reservedLane: Lane?

    var isClaimed: Bool {
        claimedLane != nil
    }

    @discardableResult
    func reserve(_ lane: Lane) -> Bool {
        guard claimedLane == nil, reservedLane == nil else { return false }
        reservedLane = lane
        return true
    }

    @discardableResult
    func commit(_ lane: Lane) -> Bool {
        guard claimedLane == nil, reservedLane == lane else { return false }
        reservedLane = nil
        claimedLane = lane
        return true
    }

    func release(_ lane: Lane) {
        guard reservedLane == lane else { return }
        reservedLane = nil
    }

    @discardableResult
    func claim(_ lane: Lane) -> Bool {
        reserve(lane) && commit(lane)
    }
}

/// Two privacy-safe local reminders that help users review data already stored on their device.
///
/// This is a true opt-in automation:
/// - default OFF;
/// - notification permission is requested only from an explicit enable action, after the explanatory UI;
/// - no health value is embedded in notification content;
/// - schedules live in the OS notification center and work while NOOP is not running.
@MainActor
enum DailyReviewNotifications {
    static let enabledKey = "dailyReview.enabled"
    static let morningEnabledKey = "dailyReview.morningEnabled"
    static let journalEnabledKey = "dailyReview.journalEnabled"
    static let splitPreferenceMigrationKey = "dailyReview.splitPreferenceMigrated.v1"
    static let morningMinutesKey = "dailyReview.morningMinutes"
    static let eveningMinutesKey = "dailyReview.eveningMinutes"
    static let completedJournalDaysKey = "dailyReview.completedJournalDays"
    static let scheduledEveningIDsKey = "dailyReview.scheduledEveningIDs"
    private static var scheduleGeneration: UInt64 = 0

    private static let morningRequestID = "daily-review-morning"
    /// Removed after the completion-aware one-shot schedule shipped. Keep cancelling it on upgrades.
    private static let eveningRequestID = "daily-review-evening"
    /// A repeating morning check-in plus two weeks of evening one-shots stays well below iOS's
    /// per-app pending-request ceiling while remaining useful through process death.
    static let journalScheduleHorizonDays = 14
    /// Shared by every wellness notification that must keep detail out of hidden lock-screen previews.
    nonisolated static let privacyCategoryID = "noop.daily-review.private"
    nonisolated static let plannedWorkoutCategoryID = "noop.adaptive.planned-workout.private"
    nonisolated static let keepCurrentPlanActionID = "noop.adaptive.planned-workout.keep"
    nonisolated static let reviewLighterOptionsActionID =
        "noop.adaptive.planned-workout.review"

    static var isEnabled: Bool {
        isMorningEnabled || isJournalEnabled
    }

    static var isMorningEnabled: Bool {
        migrateLegacyPreferencesIfNeeded()
        return UserDefaults.standard.bool(forKey: morningEnabledKey)
    }

    static var isJournalEnabled: Bool {
        migrateLegacyPreferencesIfNeeded()
        return UserDefaults.standard.bool(forKey: journalEnabledKey)
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
        case deferred
        case denied
        case off
    }

    enum RestoreAuthorizationDisposition: Equatable, Sendable {
        case reschedule
        case retainOptIn
        case disable
    }

    struct ReminderSpec: Equatable, Sendable {
        let identifier: String
        let minuteOfDay: Int
        let title: String
        let body: String
        let route: NoopNotificationRoute
    }

    struct DatedReminderSpec: Equatable, Sendable {
        let reminder: ReminderSpec
        let day: String
        let fireDate: Date
    }

    /// Compatibility entry point used by onboarding: the one explicit choice applies to both reminders.
    static func setEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        setPreferences(
            morningEnabled: on,
            journalEnabled: on,
            completion: completion
        )
    }

    static func setMorningEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        setPreferences(
            morningEnabled: on,
            journalEnabled: nil,
            completion: completion
        )
    }

    static func setJournalEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        setPreferences(
            morningEnabled: nil,
            journalEnabled: on,
            completion: completion
        )
    }

    private static func setPreferences(
        morningEnabled: Bool?,
        journalEnabled: Bool?,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)?
    ) {
        migrateLegacyPreferencesIfNeeded()
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let requestedMorning = morningEnabled ?? isMorningEnabled
        let requestedJournal = journalEnabled ?? isJournalEnabled
        let enablesNewPreference =
            (morningEnabled == true && !isMorningEnabled) ||
            (journalEnabled == true && !isJournalEnabled)

        guard enablesNewPreference else {
            persistPreferences(
                morningEnabled: requestedMorning,
                journalEnabled: requestedJournal
            )
            cancelDisabledRequests(
                morningEnabled: requestedMorning,
                journalEnabled: requestedJournal
            )
            if requestedMorning || requestedJournal {
                requestReschedule()
            } else {
                LocalNotificationLifecycle.cancel(identifiers: requestIDs)
                UserDefaults.standard.removeObject(forKey: scheduledEveningIDsKey)
            }
            completion?(
                persistedPreferenceOutcome(
                    morningEnabled: requestedMorning,
                    journalEnabled: requestedJournal
                )
            )
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                await enableAndSchedule(
                    generation: generation,
                    morningEnabled: requestedMorning,
                    journalEnabled: requestedJournal,
                    center: center,
                    completion: completion
                )
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    await enableAndSchedule(
                        generation: generation,
                        morningEnabled: requestedMorning,
                        journalEnabled: requestedJournal,
                        center: center,
                        completion: completion
                    )
                } else {
                    guard generation == scheduleGeneration else { return }
                    recordSuppressedRequests()
                    completion?(.denied)
                }
            default:
                guard generation == scheduleGeneration else { return }
                recordSuppressedRequests()
                completion?(.denied)
            }
        }
    }

    static func setMorningMinutes(_ minutes: Int) {
        UserDefaults.standard.set(clampMinute(minutes), forKey: morningMinutesKey)
        if isMorningEnabled { requestReschedule() }
    }

    static func setEveningMinutes(_ minutes: Int) {
        UserDefaults.standard.set(clampMinute(minutes), forKey: eveningMinutesKey)
        if isJournalEnabled { requestReschedule() }
    }

    /// Keep the evening journal prompt honest. Logging any answer completes that local day; clearing
    /// its final answer makes the still-future prompt eligible again.
    static func setJournalCompleted(_ completed: Bool, day: String) {
        guard isDayKey(day) else { return }
        var days = completedJournalDays
        guard days.contains(day) != completed else { return }
        if completed {
            days.insert(day)
        } else {
            days.remove(day)
        }
        persistCompletedJournalDays(days)
        if isJournalEnabled { requestReschedule() }
    }

    /// Repository reconciliation after launch/restore. Only the bounded schedule window is supplied,
    /// so stale completion keys cannot accumulate forever.
    static func reconcileCompletedJournalDays(_ days: Set<String>, now: Date = Date()) {
        let eligible = Set(journalHorizonDayKeys(now: now))
        let reconciled = days.intersection(eligible)
        guard reconciled != completedJournalDays else { return }
        persistCompletedJournalDays(reconciled)
        if isJournalEnabled { requestReschedule(now: now) }
    }

    static func journalHorizonDayKeys(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let start = calendar.startOfDay(for: now)
        return (-1..<journalScheduleHorizonDays).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
                .map { dayKey($0, calendar: calendar) }
        }
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
            switch restoreAuthorizationDisposition(settings.authorizationStatus) {
            case .reschedule:
                requestReschedule()
            case .retainOptIn:
                cancelTrackedRequestsPreservingOptIn()
                recordSuppressedRequests()
            case .disable:
                persistPreferences(
                    morningEnabled: false,
                    journalEnabled: false
                )
                LocalNotificationLifecycle.cancel(identifiers: requestIDs)
                UserDefaults.standard.removeObject(forKey: scheduledEveningIDsKey)
                recordSuppressedRequests()
            }
        }
    }

    static func restoreAuthorizationDisposition(
        _ status: UNAuthorizationStatus
    ) -> RestoreAuthorizationDisposition {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .reschedule
        case .notDetermined:
            return .retainOptIn
        case .denied:
            return .retainOptIn
        @unknown default:
            return .disable
        }
    }

    static func persistedPreferenceOutcome(
        morningEnabled: Bool,
        journalEnabled: Bool
    ) -> EnableOutcome {
        morningEnabled || journalEnabled ? .deferred : .off
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
                body: String(localized: "Review today’s Effort, then log what shaped your day."),
                route: .journal
            ),
        ]
    }

    static func eveningReminderSpecs(
        now: Date,
        minuteOfDay: Int,
        completedDays: Set<String>,
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> [DatedReminderSpec] {
        let template = reminderSpecs(morning: morningMinutes, evening: minuteOfDay)[1]
        let start = calendar.startOfDay(for: now)
        return (-1..<journalScheduleHorizonDays).compactMap { offset in
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: start),
                  let fireDate = calendar.date(
                    bySettingHour: template.minuteOfDay / 60,
                    minute: template.minuteOfDay % 60,
                    second: 0,
                    of: dayDate
                  ) else { return nil }
            let eligibleFireDate = RoutineNotificationQuietHours.nextEligibleDate(
                fireDate,
                calendar: calendar,
                defaults: defaults
            )
            guard eligibleFireDate > now else { return nil }
            let day = dayKey(dayDate, calendar: calendar)
            guard !completedDays.contains(day) else { return nil }
            return DatedReminderSpec(
                reminder: ReminderSpec(
                    identifier: "\(eveningRequestID)-\(day)",
                    minuteOfDay: localMinuteOfDay(
                        for: eligibleFireDate,
                        calendar: calendar
                    ),
                    title: template.title,
                    body: template.body,
                    route: template.route
                ),
                day: day,
                fireDate: eligibleFireDate
            )
        }
    }

    nonisolated static func clampMinute(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }

    private static var requestIDs: [String] {
        trackedRequestIDs()
    }

    static func trackedRequestIDs(
        defaults: UserDefaults = .standard
    ) -> [String] {
        let stored = defaults.stringArray(forKey: scheduledEveningIDsKey) ?? []
        return [morningRequestID, eveningRequestID] + stored
    }

    static func datedEveningRequestIDs(
        _ identifiers: [String]
    ) -> [String] {
        Array(
            Set(
                identifiers.filter {
                    $0.hasPrefix("\(eveningRequestID)-")
                }
            )
        ).sorted()
    }

    private static func persistTrackedEveningRequestIDs(
        _ identifiers: [String],
        defaults: UserDefaults = .standard
    ) {
        let dated = datedEveningRequestIDs(identifiers)
        if dated.isEmpty {
            defaults.removeObject(forKey: scheduledEveningIDsKey)
        } else {
            defaults.set(dated, forKey: scheduledEveningIDsKey)
        }
    }

    static func cancelTrackedRequestsPreservingOptIn(
        defaults: UserDefaults = .standard,
        cancel: ([String]) -> Void = {
            LocalNotificationLifecycle.cancel(identifiers: $0)
        }
    ) {
        cancel(trackedRequestIDs(defaults: defaults))
        defaults.removeObject(forKey: scheduledEveningIDsKey)
    }

    static func disabledRequestIDs(
        morningEnabled: Bool,
        journalEnabled: Bool,
        storedEveningIDs: [String]
    ) -> [String] {
        var identifiers: [String] = []
        if !morningEnabled {
            identifiers.append(morningRequestID)
        }
        if !journalEnabled {
            identifiers.append(eveningRequestID)
            identifiers.append(contentsOf: storedEveningIDs)
        }
        return Array(Set(identifiers)).sorted()
    }

    private static func cancelDisabledRequests(
        morningEnabled: Bool,
        journalEnabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        let identifiers = disabledRequestIDs(
            morningEnabled: morningEnabled,
            journalEnabled: journalEnabled,
            storedEveningIDs: defaults.stringArray(
                forKey: scheduledEveningIDsKey
            ) ?? []
        )
        if !identifiers.isEmpty {
            LocalNotificationLifecycle.cancel(identifiers: identifiers)
        }
        if !journalEnabled {
            defaults.removeObject(forKey: scheduledEveningIDsKey)
        }
    }

    private static var completedJournalDays: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: completedJournalDaysKey) ?? [])
    }

    private static func persistCompletedJournalDays(_ days: Set<String>) {
        UserDefaults.standard.set(days.sorted(), forKey: completedJournalDaysKey)
    }

    private static func migrateLegacyPreferencesIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: splitPreferenceMigrationKey) else { return }
        let legacyEnabled = defaults.bool(forKey: enabledKey)
        defaults.set(legacyEnabled, forKey: morningEnabledKey)
        defaults.set(legacyEnabled, forKey: journalEnabledKey)
        defaults.set(true, forKey: splitPreferenceMigrationKey)
    }

    private static func persistPreferences(
        morningEnabled: Bool,
        journalEnabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(morningEnabled, forKey: morningEnabledKey)
        defaults.set(journalEnabled, forKey: journalEnabledKey)
        defaults.set(morningEnabled || journalEnabled, forKey: enabledKey)
        defaults.set(true, forKey: splitPreferenceMigrationKey)
    }

    private static func enableAndSchedule(
        generation: UInt64,
        morningEnabled: Bool,
        journalEnabled: Bool,
        center: UNUserNotificationCenter,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)?
    ) async {
        guard generation == scheduleGeneration else { return }
        persistPreferences(
            morningEnabled: morningEnabled,
            journalEnabled: journalEnabled
        )
        registerPrivacyCategory(on: center)
        let result = await reconcileSchedule(
            expectedGeneration: generation,
            client: .system(center: center)
        )
        guard generation == scheduleGeneration else { return }
        let settings = await center.notificationSettings()
        guard generation == scheduleGeneration else { return }
        completion?(
            applyScheduleResult(
                result,
                authorizationStatus: settings.authorizationStatus
            )
        )
    }

    private static func requestReschedule(now: Date = Date()) {
        guard isEnabled else {
            LocalNotificationLifecycle.cancel(identifiers: requestIDs)
            UserDefaults.standard.removeObject(forKey: scheduledEveningIDsKey)
            return
        }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let initialSettings = await center.notificationSettings()
            guard generation == scheduleGeneration else { return }
            switch restoreAuthorizationDisposition(initialSettings.authorizationStatus) {
            case .retainOptIn:
                cancelTrackedRequestsPreservingOptIn()
                recordSuppressedRequests()
                return
            case .disable:
                _ = applyScheduleResult(
                    nil,
                    authorizationStatus: initialSettings.authorizationStatus
                )
                return
            case .reschedule:
                break
            }
            registerPrivacyCategory(on: center)
            let result = await reconcileSchedule(
                now: now,
                expectedGeneration: generation,
                client: .system(center: center)
            )
            guard generation == scheduleGeneration else { return }
            let finalSettings = await center.notificationSettings()
            guard generation == scheduleGeneration else { return }
            _ = applyScheduleResult(
                result,
                authorizationStatus: finalSettings.authorizationStatus
            )
        }
    }

    @discardableResult
    static func applyScheduleResult(
        _ result: LocalNotificationReconciliationResult?,
        authorizationStatus: UNAuthorizationStatus
    ) -> EnableOutcome {
        switch restoreAuthorizationDisposition(authorizationStatus) {
        case .reschedule:
            return applyAuthorizedScheduleResult(result)
        case .retainOptIn:
            cancelTrackedRequestsPreservingOptIn()
            recordSuppressedRequests()
            return .deferred
        case .disable:
            persistPreferences(
                morningEnabled: false,
                journalEnabled: false
            )
            LocalNotificationLifecycle.cancel(identifiers: requestIDs)
            UserDefaults.standard.removeObject(forKey: scheduledEveningIDsKey)
            recordSuppressedRequests()
            return .denied
        }
    }

    /// Authorization and user intent are separate from Notification Center capacity. Once the user has
    /// explicitly opted in and authorization is available, a transient rejection or capacity deferral
    /// must remain retryable rather than silently becoming an opt-out.
    @discardableResult
    static func applyAuthorizedScheduleResult(
        _ result: LocalNotificationReconciliationResult?
    ) -> EnableOutcome {
        return (result?.activeCount ?? 0) > 0 ? .scheduled : .deferred
    }

    @discardableResult
    static func reconcileSchedule(
        now: Date = Date(),
        calendar: Calendar = .current,
        expectedGeneration: UInt64? = nil,
        coordinator: LocalNotificationCapacityCoordinator? = nil,
        client: LocalNotificationCenterClient
    ) async -> LocalNotificationReconciliationResult? {
        let priorIDs = requestIDs
        let requests = notificationRequests(
            now: now,
            calendar: calendar
        )
        // Track both the old and proposed one-shot identifiers before the first
        // Notification Center await. A process death can then leave extra
        // cancellable IDs, but never an untracked reminder that survives opt-out.
        persistTrackedEveningRequestIDs(
            priorIDs + requests.map(\.identifier)
        )
        let result = await LocalNotificationLifecycle.reconcile(
            candidateRequests: requests,
            replacingIdentifiers: Set(
                priorIDs + requests.map(\.identifier)
            ),
            now: now,
            calendar: calendar,
            coordinator: coordinator,
            isStillCurrent: {
                expectedGeneration.map { $0 == scheduleGeneration } ?? true
            },
            client: client
        )
        if let expectedGeneration,
           expectedGeneration != scheduleGeneration {
            return nil
        }
        persistTrackedEveningRequestIDs(result.activeIdentifiers)
        return result
    }

    static func notificationRequests(
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> [UNNotificationRequest] {
        var requests: [UNNotificationRequest] = []
        if isMorningEnabled {
            let morning = reminderSpecs(morning: morningMinutes, evening: eveningMinutes)[0]
            let nominal = calendar.date(
                bySettingHour: morning.minuteOfDay / 60,
                minute: morning.minuteOfDay % 60,
                second: 0,
                of: now
            ) ?? now
            let eligible = RoutineNotificationQuietHours.nextEligibleDate(
                nominal,
                calendar: calendar,
                defaults: defaults
            )
            let eligibleMinute = localMinuteOfDay(for: eligible, calendar: calendar)
            var morningComponents = DateComponents()
            morningComponents.hour = eligibleMinute / 60
            morningComponents.minute = eligibleMinute % 60
            requests.append(
                notificationRequest(
                    morning,
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: morningComponents,
                        repeats: true
                    )
                )
            )
        }

        if isJournalEnabled {
            let eveningSpecs = eveningReminderSpecs(
                now: now,
                minuteOfDay: eveningMinutes,
                completedDays: completedJournalDays,
                calendar: calendar,
                defaults: defaults
            )
            for dated in eveningSpecs {
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dated.fireDate
                )
                requests.append(notificationRequest(
                    dated.reminder,
                    journalDay: dated.day,
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: components,
                        repeats: false
                    )
                ))
            }
        }
        return requests
    }

    static func quietHoursDidChange() {
        if isEnabled { requestReschedule() }
    }

    private static func notificationRequest(
        _ spec: ReminderSpec,
        journalDay: String? = nil,
        trigger: UNNotificationTrigger
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.applyProminence(.ambient)
        content.title = spec.title
        content.body = spec.body
        content.sound = .default
        // The normal copy contains no values or conditions. When the user hides previews, keep even
        // the metric names off the lock screen while retaining a recognizable app-level placeholder.
        content.categoryIdentifier = privacyCategoryID
        content.threadIdentifier = "noop.daily-review"
        var userInfo: [AnyHashable: Any] = [
            NotificationRouteBridge.userInfoKey: spec.route.rawValue
        ]
        if spec.route == .journal, let journalDay, isDayKey(journalDay) {
            userInfo[NotificationRouteBridge.journalDayUserInfoKey] = journalDay
        }
        content.userInfo = userInfo
        return UNNotificationRequest(
            identifier: spec.identifier,
            content: content,
            trigger: trigger
        )
    }

    nonisolated private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    nonisolated private static func isDayKey(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let chars = Array(value)
        return chars[4] == "-" && chars[7] == "-" &&
            chars.enumerated().allSatisfy { index, char in
                index == 4 || index == 7 ? char == "-" : char.isNumber
            }
    }

    nonisolated private static func localMinuteOfDay(
        for date: Date,
        calendar: Calendar
    ) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clampMinute((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
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
        let plannedWorkoutCategory = plannedWorkoutDecisionCategory()
        var merged = existing.filter {
            $0.identifier != privacyCategoryID &&
                $0.identifier != plannedWorkoutCategoryID
        }
        merged.insert(category)
        merged.insert(plannedWorkoutCategory)
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

    static func plannedWorkoutDecisionCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: plannedWorkoutCategoryID,
            actions: [
                UNNotificationAction(
                    identifier: keepCurrentPlanActionID,
                    title: String(
                        localized:
                            "appwide.adaptive_day_guidance.planned_workout.keep_plan"
                    ),
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: reviewLighterOptionsActionID,
                    title: String(
                        localized:
                            "appwide.adaptive_day_guidance.planned_workout.review_options"
                    ),
                    options: [.authenticationRequired, .foreground]
                ),
            ],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "Private NOOP check-in"),
            options: []
        )
    }
}

@MainActor
enum RoutineNotificationQuietHours {
    private static let enabledKey = "notif.quietHoursEnabled"
    private static let startMinutesKey = "notif.quietStartMinutes"
    private static let endMinutesKey = "notif.quietEndMinutes"

    static func contains(
        _ date: Date,
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.bool(forKey: enabledKey) else { return false }
        let start = defaults.object(forKey: startMinutesKey) as? Int ?? 22 * 60
        let end = defaults.object(forKey: endMinutesKey) as? Int ?? 7 * 60
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return HydrationReminders.windowContains(
            minute,
            start: start,
            end: end
        )
    }

    static func nextEnd(
        after date: Date,
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Date? {
        guard contains(date, calendar: calendar, defaults: defaults) else {
            return nil
        }
        let end = defaults.object(forKey: endMinutesKey) as? Int ?? 7 * 60
        return calendar.nextDate(
            after: date,
            matching: DateComponents(
                hour: end / 60,
                minute: end % 60,
                second: 0
            ),
            matchingPolicy: .nextTimePreservingSmallerComponents,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    static func nextEligibleDate(
        _ date: Date,
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Date {
        nextEnd(
            after: date,
            calendar: calendar,
            defaults: defaults
        ) ?? date
    }
}

/// An opt-in recap posted only after a completed wearable sync has materialized a scored night.
///
/// This is distinct from the clock-based morning review reminder above. Delivery follows the data:
/// a banked night may reach the phone later, and the same report-day key can never post twice.
@MainActor
enum MorningRecapNotifications {
    static let enabledKey = "morningRecap.enabled"
    static let lastReportDayKey = "morningRecap.lastReportDay"

    private static let requestID = "morning-recap"
    private static var preferenceGeneration: UInt64 = 0
    private static var deliveryGeneration: UInt64 = 0
    private static var activeReportDay: String?

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

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func shouldNotify(
        enabled: Bool,
        materializedAfterSync: Bool,
        recoveryOrSleepScorePresent: Bool,
        reportDay: String,
        lastReportDay: String?,
        inQuietHours: Bool = false
    ) -> Bool {
        enabled
            && materializedAfterSync
            && recoveryOrSleepScorePresent
            && !reportDay.isEmpty
            && reportDay != lastReportDay
            && !inQuietHours
    }

    static func isInQuietHours(
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        RoutineNotificationQuietHours.contains(
            now,
            calendar: calendar,
            defaults: defaults
        )
    }

    static func copy(
        recoveryPresent: Bool,
        sleepScorePresent: Bool
    ) -> (title: String, body: String)? {
        guard recoveryPresent || sleepScorePresent else { return nil }
        let body = switch (recoveryPresent, sleepScorePresent) {
        case (true, true):
            String(localized: "appwide.morning_recap.body.both")
        case (true, false):
            String(localized: "appwide.morning_recap.body.recovery")
        case (false, true):
            String(localized: "appwide.morning_recap.body.sleep")
        case (false, false):
            preconditionFailure("Guarded above")
        }
        return (
            String(localized: "appwide.morning_recap.title"),
            body
        )
    }

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
            UserDefaults.standard.set(false, forKey: enabledKey)
            clear(client: client)
            completion?(.off)
            return
        }

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

    static func postIfAuthorized(
        reportDay: String,
        recoveryPresent: Bool,
        sleepScorePresent: Bool,
        materializedAfterSync: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        await postIfAuthorized(
            reportDay: reportDay,
            recoveryPresent: recoveryPresent,
            sleepScorePresent: sleepScorePresent,
            materializedAfterSync: materializedAfterSync,
            client: .system,
            now: now,
            calendar: calendar,
            budget: budget
        )
    }

    static func postIfAuthorized(
        reportDay: String,
        recoveryPresent: Bool,
        sleepScorePresent: Bool,
        materializedAfterSync: Bool = true,
        client: NotificationClient,
        now: Date = Date(),
        calendar: Calendar = .current,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        guard let copy = copy(
            recoveryPresent: recoveryPresent,
            sleepScorePresent: sleepScorePresent
        ) else { return }
        let lastReportDay = UserDefaults.standard.string(forKey: lastReportDayKey)
        guard shouldNotify(
            enabled: isEnabled,
            materializedAfterSync: materializedAfterSync,
            recoveryOrSleepScorePresent: recoveryPresent || sleepScorePresent,
            reportDay: reportDay,
            lastReportDay: lastReportDay
        ), activeReportDay != reportDay else { return }
        let deferredUntil = RoutineNotificationQuietHours.nextEnd(
            after: now,
            calendar: calendar
        )

        let generation = deliveryGeneration
        activeReportDay = reportDay
        defer {
            if activeReportDay == reportDay { activeReportDay = nil }
        }

        let status = await client.authorizationStatus()
        guard generation == deliveryGeneration,
              canPost(using: status),
              isEnabled else { return }
        await client.preparePrivateCategory()
        guard generation == deliveryGeneration, isEnabled else { return }
        let lane = PostSyncRoutineNotificationBudget.Lane.morningRecap
        guard budget?.reserve(lane) ?? true else { return }
        var committed = budget == nil
        defer {
            if !committed {
                budget?.release(lane)
            }
        }

        let content = UNMutableNotificationContent()
        content.applyProminence(.ambient)
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.morning-recap"
        content.userInfo = [
            NotificationRouteBridge.userInfoKey: NoopNotificationRoute.sleep.rawValue
        ]

        do {
            let trigger = deferredUntil.map { deliveryDate in
                UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents(
                        [
                            .calendar,
                            .timeZone,
                            .year,
                            .month,
                            .day,
                            .hour,
                            .minute,
                            .second,
                        ],
                        from: deliveryDate
                    ),
                    repeats: false
                )
            }
            try await client.add(
                UNNotificationRequest(
                    identifier: requestID,
                    content: content,
                    trigger: trigger
                )
            )
            guard generation == deliveryGeneration, isEnabled else {
                client.remove([requestID])
                return
            }
            if let budget {
                guard budget.commit(lane) else {
                    client.remove([requestID])
                    return
                }
            }
            committed = true
            UserDefaults.standard.set(reportDay, forKey: lastReportDayKey)
        } catch {
            // `add` can fail after Notification Center observed the request. Retract the stable
            // identifier before releasing the budget so a lower-priority lane cannot double-stack.
            client.remove([requestID])
        }
    }

    static func clear() {
        clear(client: .system)
    }

    static func clear(client: NotificationClient) {
        deliveryGeneration &+= 1
        activeReportDay = nil
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

/// An opt-in, privacy-safe heads-up after a newly synced workout reaches NOOP.
///
/// Delivery is intentionally tied to the post-sync caller rather than workout end time: a wearable
/// may bank the session for hours before the phone receives it. Enabling seeds the current newest
/// workout as the frontier, so old history never produces a surprise notification.
@MainActor
enum PostWorkoutSummaryNotifications {
    static let enabledKey = "postWorkoutSummary.enabled"
    static let lastWorkoutStartKey = "postWorkoutSummary.lastWorkoutStart"
    static let frontierInitializedKey = "postWorkoutSummary.frontierInitialized"

    private static let requestID = "post-workout-summary"
    private static var preferenceGeneration: UInt64 = 0
    private static var deliveryGeneration: UInt64 = 0
    private static var activeWorkoutStart: Int?

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

    struct Copy: Equatable, Sendable {
        let title: String
        let body: String
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var copy: Copy {
        Copy(
            title: String(localized: "Your workout summary is ready"),
            body: String(localized: "Open NOOP to review the workout after your latest sync.")
        )
    }

    static func setEnabled(
        _ enabled: Bool,
        currentNewestWorkoutStart: Int?,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        setEnabled(
            enabled,
            currentNewestWorkoutStart: currentNewestWorkoutStart,
            client: .system,
            completion: completion
        )
    }

    static func setEnabled(
        _ enabled: Bool,
        currentNewestWorkoutStart: Int?,
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

        // Keep the preference false until the OS confirms permission. Capture the frontier before the
        // prompt so a workout that syncs while the sheet is open remains eligible afterward.
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
            if allowed {
                initializeFrontier(currentNewestWorkoutStart)
                UserDefaults.standard.set(true, forKey: enabledKey)
                completion?(.enabled)
            } else {
                UserDefaults.standard.set(false, forKey: enabledKey)
                completion?(.denied)
            }
        }
    }

    /// Pure gate shared by delivery and focused tests.
    static func shouldNotify(
        enabled: Bool,
        frontierInitialized: Bool,
        newestWorkoutStart: Int?,
        lastWorkoutStart: Int
    ) -> Bool {
        enabled
            && frontierInitialized
            && newestWorkoutStart.map { $0 > lastWorkoutStart } == true
    }

    static func postIfAuthorized(
        newestWorkoutStart: Int?,
        now: Date = Date(),
        calendar: Calendar = .current,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        await postIfAuthorized(
            newestWorkoutStart: newestWorkoutStart,
            client: .system,
            now: now,
            calendar: calendar,
            budget: budget
        )
    }

    static func postIfAuthorized(
        newestWorkoutStart: Int?,
        client: NotificationClient,
        now: Date = Date(),
        calendar: Calendar = .current,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        guard isEnabled else {
            clear(client: client)
            return
        }

        // Upgrade safety: an impossible pre-feature state (enabled but no frontier marker) seeds
        // silently instead of treating the entire workout archive as new.
        guard UserDefaults.standard.bool(forKey: frontierInitializedKey) else {
            initializeFrontier(newestWorkoutStart)
            return
        }

        let last = UserDefaults.standard.object(forKey: lastWorkoutStartKey) as? Int ?? 0
        guard shouldNotify(
            enabled: true,
            frontierInitialized: true,
            newestWorkoutStart: newestWorkoutStart,
            lastWorkoutStart: last
        ), let newestWorkoutStart,
           activeWorkoutStart != newestWorkoutStart else { return }
        if RoutineNotificationQuietHours.contains(
            now,
            calendar: calendar
        ) {
            LocalNotificationLifecycle.suppressed(
                identifier: requestID,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return
        }

        let generation = deliveryGeneration
        activeWorkoutStart = newestWorkoutStart
        defer {
            if activeWorkoutStart == newestWorkoutStart {
                activeWorkoutStart = nil
            }
        }

        let status = await client.authorizationStatus()
        guard generation == deliveryGeneration,
              canPost(using: status),
              isEnabled else { return }
        await client.preparePrivateCategory()
        guard generation == deliveryGeneration, isEnabled else { return }
        let lane = PostSyncRoutineNotificationBudget.Lane.postWorkoutSummary
        guard budget?.reserve(lane) ?? true else { return }
        var committed = budget == nil
        defer {
            if !committed {
                budget?.release(lane)
            }
        }

        let text = copy
        let content = UNMutableNotificationContent()
        content.applyProminence(.ambient)
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.post-workout"
        content.userInfo = [
            NotificationRouteBridge.userInfoKey: NoopNotificationRoute.workouts.rawValue
        ]

        do {
            try await client.add(
                UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
            )
            guard generation == deliveryGeneration, isEnabled else {
                client.remove([requestID])
                return
            }
            if let budget {
                guard budget.commit(lane) else {
                    client.remove([requestID])
                    return
                }
            }
            committed = true
            // Advance only after Notification Center accepted the request. A denied or failed post can
            // retry on the next completed sync instead of losing the workout silently.
            advanceFrontier(to: newestWorkoutStart)
        } catch {
            client.remove([requestID])
        }
    }

    static func initializeFrontier(_ newestWorkoutStart: Int?) {
        if let newestWorkoutStart {
            UserDefaults.standard.set(newestWorkoutStart, forKey: lastWorkoutStartKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastWorkoutStartKey)
        }
        UserDefaults.standard.set(true, forKey: frontierInitializedKey)
    }

    static func clear() {
        clear(client: .system)
    }

    static func clear(client: NotificationClient) {
        deliveryGeneration &+= 1
        activeWorkoutStart = nil
        client.remove([requestID])
    }

    private static func advanceFrontier(to workoutStart: Int) {
        let current = UserDefaults.standard.object(forKey: lastWorkoutStartKey) as? Int ?? 0
        if workoutStart > current {
            UserDefaults.standard.set(workoutStart, forKey: lastWorkoutStartKey)
        }
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
        let budget: PostSyncRoutineNotificationBudget?
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

    static func postIfAuthorized(
        startSec: Int,
        endSec: Int,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        await postIfAuthorized(
            startSec: startSec,
            endSec: endSec,
            client: .system,
            budget: budget
        )
    }

    static func postIfAuthorized(
        startSec: Int,
        endSec: Int,
        client: NotificationClient,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        guard PuffinExperiment.autoDetectWorkoutsEnabled, isEnabled else {
            clear(client: client)
            return
        }
        await post(
            kind: .candidate,
            startSec: startSec,
            endSec: endSec,
            client: client,
            budget: budget
        )
    }

    static func postAutoSavedIfAuthorized(
        startSec: Int,
        endSec: Int,
        budget: PostSyncRoutineNotificationBudget? = nil
    ) async {
        guard PuffinExperiment.autoWorkoutMode == .autoSave else { return }
        await post(
            kind: .autoSaved,
            startSec: startSec,
            endSec: endSec,
            client: .system,
            budget: budget
        )
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
        client: NotificationClient,
        budget: PostSyncRoutineNotificationBudget?
    ) async {
        let candidateToken = token(startSec: startSec, endSec: endSec)
        let deliveryToken = kind.rawValue + ":" + candidateToken
        guard shouldDeliver(deliveryToken: deliveryToken, kind: kind,
                            startSec: startSec, defaults: .standard),
              activeDeliveryToken != deliveryToken,
              !deliveryQueue.contains(where: { $0.deliveryToken == deliveryToken }) else { return }
        let lane = PostSyncRoutineNotificationBudget.Lane.autoWorkout
        guard budget?.reserve(lane) ?? true else { return }

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
            client: client,
            budget: budget
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
        let lane = PostSyncRoutineNotificationBudget.Lane.autoWorkout
        var committed = delivery.budget == nil
        defer {
            if !committed {
                delivery.budget?.release(lane)
            }
        }
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
            if let budget = delivery.budget {
                guard budget.commit(lane) else {
                    delivery.client.remove([requestID])
                    return
                }
            }
            committed = true
            remember(deliveryToken: delivery.deliveryToken, defaults: .standard)
        } catch {
            // Keep the token unset so a later completed sync can retry delivery.
            // The daemon can still have accepted a request before reporting an error. Retract the
            // stable identifier before releasing the sync slot; the serialized drain guarantees this
            // cleanup cannot erase a newer queued delivery.
            delivery.client.remove([requestID])
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
        for delivery in deliveryQueue {
            delivery.budget?.release(.autoWorkout)
        }
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
