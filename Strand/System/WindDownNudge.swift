import Foundation
import UserNotifications
import StrandAnalytics
import WhoopStore

enum ReminderSleepSource: String, Equatable, Sendable { case wearable, appleHealth, mixed, none }

struct ReminderSleepObservation: Equatable, Sendable {
    let day: String
    let minutes: Double
    let source: ReminderSleepSource
}

struct ReminderSleepContext: Equatable, Sendable {
    let recoveryMinutes: Int
    let historyNights: Int
    let latestDay: String?
    let source: ReminderSleepSource
    let isCurrent: Bool
    static let unavailable = Self(recoveryMinutes: 0, historyNights: 0, latestDay: nil,
                                  source: .none, isCurrent: false)
}

enum ReminderDataPolicy {
    static let lookbackDays = 14
    static let maximumLatestAgeDays = 2

    static func sleepContext(observations: [ReminderSleepObservation], targetMinutes: Int,
                             goalMode: SleepGoalMode, now: Date = Date(),
                             calendar: Calendar = .current) -> ReminderSleepContext {
        let today = calendar.startOfDay(for: now)
        guard let oldest = calendar.date(byAdding: .day, value: -(lookbackDays - 1), to: today) else {
            return .unavailable
        }
        let eligible = observations.compactMap { item -> (ReminderSleepObservation, Date)? in
            let fields = item.day.split(separator: "-").compactMap { Int($0) }
            guard fields.count == 3, item.minutes.isFinite, (120.0...900.0).contains(item.minutes),
                  item.source == .wearable || item.source == .appleHealth,
                  let date = calendar.date(from: DateComponents(
                    year: fields[0], month: fields[1], day: fields[2]
                  )).map({ calendar.startOfDay(for: $0) }),
                  date >= oldest, date <= today else { return nil }
            return (item, date)
        }
        var byDay: [String: (ReminderSleepObservation, Date)] = [:]
        for candidate in eligible.sorted(by: {
            if $0.0.day != $1.0.day { return $0.0.day < $1.0.day }
            return $0.0.source == .wearable && $1.0.source != .wearable
        }) where byDay[candidate.0.day] == nil {
            byDay[candidate.0.day] = candidate
        }
        let selected = byDay.values.sorted { $0.1 < $1.1 }
        guard let latest = selected.last else { return .unavailable }
        let age = calendar.dateComponents([.day], from: latest.1, to: today).day ?? Int.max
        guard (0...maximumLatestAgeDays).contains(age) else {
            return .init(recoveryMinutes: 0, historyNights: 0, latestDay: latest.0.day,
                         source: .none, isCurrent: false)
        }
        let ledger = SleepDebt.ledger(
            series: selected.map { (day: $0.0.day, totalSleepMin: Optional($0.0.minutes)) },
            needHours: Double(targetMinutes) / 60,
            window: lookbackDays
        )
        let recovery = SleepPlanner.plan(
            wakeMinute: 0, sleepTargetMinutes: targetMinutes, windDownLeadMinutes: 0,
            debtBalanceMinutes: ledger.balanceMin, historyNights: ledger.nightCount,
            goalMode: goalMode
        ).recoveryMinutes
        let sources = Set(selected.map(\.0.source))
        return .init(recoveryMinutes: recovery, historyNights: ledger.nightCount,
                     latestDay: latest.0.day,
                     source: sources.count > 1 ? .mixed : (sources.first ?? .none),
                     isCurrent: true)
    }
}

struct WindDownNotificationCopy: Equatable, Sendable {
    let title: String
    let body: String
}

/// Conservative, best-effort evidence that the user is already asleep when a wind-down reminder is
/// pending. Only a fresh, locally computed, stage-rich session can suppress a reminder. Missing,
/// imported-summary, sparse, edited, malformed, stale, or future evidence deliberately fails open.
enum WindDownSleepStatePolicy {
    static let maximumSessionAge: TimeInterval = 18 * 60 * 60
    static let maximumObservationLag: TimeInterval = 30 * 60
    static let maximumObservationLead: TimeInterval = 5 * 60
    private static let asleepStages = Set(["light", "deep", "rem"])
    private static let knownStages = asleepStages.union(["wake", "awake"])

    struct Evidence: Equatable, Sendable {
        let sessionStart: Int
        let observedThrough: Int
        let lastStage: String
    }

    static func evidence(from session: CachedSleepSession) -> Evidence? {
        guard !session.userEdited,
              session.gravitySparse == false,
              let json = session.stagesJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([StageSegment].self, from: data),
              !segments.isEmpty else { return nil }

        var previousEnd = Int.min
        var observedThrough = Int.min
        var lastStage: String?
        for segment in segments {
            let stage = segment.stage.lowercased()
            guard segment.end > segment.start,
                  segment.start >= session.effectiveStartTs - 60,
                  segment.end <= session.endTs + 60,
                  segment.start >= previousEnd,
                  knownStages.contains(stage) else { return nil }
            previousEnd = segment.end
            observedThrough = segment.end
            lastStage = stage
        }
        guard observedThrough > session.effectiveStartTs,
              let lastStage else { return nil }
        return Evidence(
            sessionStart: session.effectiveStartTs,
            observedThrough: observedThrough,
            lastStage: lastStage
        )
    }

    static func activeSleepEvidence(
        sessions: [CachedSleepSession],
        now: Date = Date()
    ) -> Evidence? {
        let nowSeconds = Int(now.timeIntervalSince1970)
        return sessions.compactMap(evidence(from:))
            .filter {
                asleepStages.contains($0.lastStage)
                    && $0.sessionStart <= nowSeconds
                    && nowSeconds - $0.sessionStart <= Int(maximumSessionAge)
                    && $0.observedThrough <= nowSeconds + Int(maximumObservationLead)
                    && nowSeconds - $0.observedThrough <= Int(maximumObservationLag)
            }
            .max { $0.observedThrough < $1.observedThrough }
    }

    static func shouldSuppress(
        sessions: [CachedSleepSession],
        now: Date = Date()
    ) -> Bool {
        activeSleepEvidence(sessions: sessions, now: now) != nil
    }
}

struct ScheduledWindDownReminder: Codable, Equatable, Sendable {
    let identifier: String
    let fireTimestamp: Int
    let dayKey: String

    var fireDate: Date {
        Date(timeIntervalSince1970: TimeInterval(fireTimestamp))
    }
}

/// The wind-down nudge (#207) — a gentle, NON-critical evening local notification suggesting it's
/// time to start winding down so the user can reach their usual wake time well-rested.
///
/// Cross-platform (macOS + iOS): a sideloaded backgrounded app can't fire a dependable LOUD wake
/// alarm (no critical-alert entitlement), but it CAN post a calm daily reminder. The nudge fires on a
/// bounded set of dated calendar triggers at a time DERIVED from the user's earliest wake time minus
/// their usual sleep need minus a short lead. Dated triggers allow fresh local sleep evidence to remove
/// only the current night while later reminders remain intact. State is its own UserDefaults-backed
/// store so it doesn't couple to the shared BehaviorStore. On-device only; nothing is sent anywhere.
@MainActor
enum WindDownNudge {

    private static let requestId = "wind-down-nudge"

    // MARK: - Persisted settings (own keys; default OFF, opt-in like every automation)

    private enum K {
        static let enabled = "windDown.enabled"
        static let sleepNeed = "windDown.sleepNeedMinutes"   // default 8h
        static let goalMode = "windDown.goalMode"
        static let recovery = "windDown.recoveryMinutes"     // planner-derived, default 0m
        static let lead = "windDown.leadMinutes"             // default 30m
        static let wake = "windDown.wakeMinutes"             // earliest wake, minutes since midnight
        static let personalizationSource = "windDown.personalizationSource"
        static let personalizationNights = "windDown.personalizationNights"
        static let personalizationLatestDay = "windDown.personalizationLatestDay"
        static let personalizationCurrent = "windDown.personalizationCurrent"
        static let scheduledReminders = "windDown.scheduledReminders.v2"
        static let sleepSuppressedDays = "windDown.sleepSuppressedDays.v1"
        // PR#554 (MumiZed) — per-day wake overrides. A JSON map of {weekday(1=Sun…7=Sat): wakeMinutes}.
        // Empty / no entry for a day = that day uses the default `wakeMinutes`, so the feature is purely
        // additive (no override → exactly the old single-time behaviour).
        static let perDayWake = "windDown.perDayWakeMinutes"
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    static var sleepNeedMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.sleepNeed) as? Int ?? 8 * 60
        return min(max(v, 5 * 60), 11 * 60)
    }

    static var hasExplicitSleepNeed: Bool {
        UserDefaults.standard.object(forKey: K.sleepNeed) != nil
    }

    static var goalMode: SleepGoalMode {
        guard let raw = UserDefaults.standard.string(forKey: K.goalMode),
              let mode = SleepGoalMode(rawValue: raw) else { return .balance }
        return mode
    }

    /// A bounded extra opportunity from the recent sleep-balance ledger. This is a planner output,
    /// not a second user target: 0–60 minutes, refreshed when the Sleep Planner sees new history.
    static var recoveryMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.recovery) as? Int ?? 0
        return min(max(v, 0), 60)
    }

    static var targetSleepMinutes: Int { sleepNeedMinutes + recoveryMinutes }

    static var leadMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.lead) as? Int ?? 30
        return min(max(v, 0), 120)
    }

    static var wakeMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.wake) as? Int ?? 7 * 60   // 07:00
        return min(max(v, 0), 24 * 60 - 1)
    }

    static var personalization: ReminderSleepContext {
        let defaults = UserDefaults.standard
        let source = defaults.string(forKey: K.personalizationSource)
            .flatMap(ReminderSleepSource.init(rawValue:)) ?? .none
        return ReminderSleepContext(
            recoveryMinutes: recoveryMinutes,
            historyNights: max(0, defaults.integer(forKey: K.personalizationNights)),
            latestDay: defaults.string(forKey: K.personalizationLatestDay),
            source: source,
            isCurrent: defaults.bool(forKey: K.personalizationCurrent)
        )
    }

    // MARK: - Per-day wake overrides (PR#554)

    /// The stored per-weekday wake overrides — {weekday(1=Sun…7=Sat): wakeMinutes}. Empty when the user
    /// hasn't set any (the common case), so every day falls back to the single `wakeMinutes`. Values are
    /// clamped to a valid minute-of-day on read so a corrupt blob can't schedule at a nonsense time.
    static var perDayWakeOverrides: [Int: Int] {
        guard let data = UserDefaults.standard.data(forKey: K.perDayWake),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in raw {
            guard let day = Int(k), (1...7).contains(day) else { continue }
            out[day] = min(max(v, 0), 24 * 60 - 1)
        }
        return out
    }

    /// The wake time used for a given Calendar weekday (1=Sun…7=Sat) — the per-day override if set, else the
    /// default `wakeMinutes`. The single source of truth both the schedule and the UI read, so they agree.
    static func wakeMinutes(forWeekday weekday: Int) -> Int {
        perDayWakeOverrides[weekday] ?? wakeMinutes
    }

    /// Whether ANY per-day override is set — drives whether scheduling fans out to 7 per-weekday triggers
    /// (overrides present) or keeps the single daily trigger (none).
    static var hasPerDayOverrides: Bool { !perDayWakeOverrides.isEmpty }

    #if DEBUG
    /// Seeds the real persisted planner state before `SmartAlarmView` initializes. UI tests use this
    /// instead of tapping the final switch through the floating navigation overlay.
    static func applyDemoLaunchArgumentsIfNeeded(
        arguments: [String] = CommandLine.arguments,
        defaults: UserDefaults = .standard
    ) {
        guard arguments.contains("--demo-sleep-per-day") else { return }
        let value = min(max(wakeMinutes, 0), 24 * 60 - 1)
        guard let data = try? JSONEncoder().encode(["1": value]) else { return }
        defaults.set(data, forKey: K.perDayWake)
    }
    #endif

    /// Set or clear a single weekday's wake override (pass nil to clear → that day reverts to the default),
    /// rescheduling if enabled. Clamps the minute-of-day so a bad value can't be stored.
    static func setWakeOverride(weekday: Int, minutes: Int?) {
        guard (1...7).contains(weekday) else { return }
        var map = perDayWakeOverrides
        if let m = minutes {
            map[weekday] = min(max(m, 0), 24 * 60 - 1)
        } else {
            map.removeValue(forKey: weekday)
        }
        let encodable = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: K.perDayWake)
        }
        if isEnabled { schedule() }
    }

    /// The nudge minute-of-day for a given weekday — that day's wake (override or default) minus sleep need
    /// minus lead, wrapped into [0, 1440). Pure; mirrors `nudgeMinuteOfDay()` per-day. (PR#554)
    static func nudgeMinuteOfDay(forWeekday weekday: Int) -> Int {
        let raw = wakeMinutes(forWeekday: weekday) - targetSleepMinutes - leadMinutes
        let day = 24 * 60
        return ((raw % day) + day) % day
    }

    // MARK: - Public API

    /// The result of enabling the nudge - lets the UI react instead of silently persisting an "on" toggle
    /// that can never fire. `.denied` means the OS won't deliver (permission off), so the caller should
    /// revert the switch and point the user at Settings.
    enum EnableOutcome: Sendable { case scheduled, denied, off }

    /// Enable/disable and (re)schedule. Enabling gates on notification authorization FIRST — mirroring the
    /// smart-alarm backup path in `AppModel.scheduleSmartAlarmBackupNotification`: if undetermined it asks
    /// once and schedules on grant; if already denied it reports back rather than persisting a dead toggle.
    ///
    /// Why this matters: the old version called `requestAuthorization` with an empty completion and then
    /// scheduled unconditionally. `requestAuthorization` only shows the system dialog when the status is
    /// `.notDetermined`; once a user (or a prior sideload install with the same bundle id) has denied, the
    /// dialog never returns and the app silently scheduled reminders the OS would never deliver — with
    /// nothing in the UI to explain it. Now denial surfaces.
    ///
    /// `completion` always runs on the main actor (the settings/authorization callbacks fire off-main).
    static func setEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            cancelAllScheduledReminders()
            completion?(.off)
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UserDefaults.standard.set(true, forKey: K.enabled)
                clearSleepSuppressedDays()
                schedule()
                completion?(.scheduled)
            case .notDetermined:
                // First ask — the system dialog appears now (a predictable moment), then we schedule on
                // grant so the FIRST night is covered rather than only after some later re-arm.
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    clearSleepSuppressedDays()
                    schedule()
                    completion?(.scheduled)
                } else {
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    cancelAllScheduledReminders(on: center)
                    LocalNotificationLifecycle.suppressed(identifier: requestId)
                    completion?(.denied)
                }
            default:
                // .denied (or any future non-authorized case) — don't fake an enabled toggle. The caller
                // surfaces a "notifications are off" prompt with a jump to Settings.
                UserDefaults.standard.set(false, forKey: K.enabled)
                cancelAllScheduledReminders(on: center)
                LocalNotificationLifecycle.suppressed(identifier: requestId)
                completion?(.denied)
            }
        }
    }

    /// Update the earliest wake time the nudge is derived from, rescheduling if enabled.
    static func setWakeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.wake)
        if isEnabled { schedule() }
    }

    /// Update the user's explicit baseline target. The planner may add a bounded recovery buffer,
    /// but never silently changes this value.
    static func setSleepNeedMinutes(_ minutes: Int) {
        let next = min(max(minutes, 5 * 60), 11 * 60)
        let prior = sleepNeedMinutes
        let wasExplicit = hasExplicitSleepNeed
        UserDefaults.standard.set(next, forKey: K.sleepNeed)
        if isEnabled { schedule() }
        if !wasExplicit || next != prior {
            ContextualInterventionInputs.notifyChanged()
        }
    }

    static func setGoalMode(_ mode: SleepGoalMode) {
        guard mode != goalMode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: K.goalMode)
    }

    static func setLeadMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 120), forKey: K.lead)
        if isEnabled { schedule() }
    }

    /// Persist the planner's bounded recovery addition so a notification already scheduled in the
    /// OS remains aligned with the plan after NOOP closes.
    static func setRecoveryMinutes(_ minutes: Int) {
        let next = min(max(minutes, 0), 60)
        guard next != recoveryMinutes else { return }
        UserDefaults.standard.set(next, forKey: K.recovery)
        if isEnabled { schedule() }
    }

    /// Refresh adaptive sleep opportunity from source-labelled repository rows. A wearable owns a day
    /// it observed; Apple Health fills only missing days. Stale or insufficient history clears any old
    /// recovery addition so taking the band off can never turn yesterday's estimate into a standing fact.
    static func refreshPersonalization(
        from rows: [SourcedDailyMetric],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let observations = rows.compactMap { row -> ReminderSleepObservation? in
            guard let minutes = row.metric.totalSleepMin else { return nil }
            let source: ReminderSleepSource
            switch row.source {
            case .whoopImport, .noopComputed:
                source = .wearable
            case .appleHealth:
                source = .appleHealth
            case .localCache:
                return nil
            }
            return ReminderSleepObservation(
                day: row.metric.day,
                minutes: minutes,
                source: source
            )
        }
        let context = ReminderDataPolicy.sleepContext(
            observations: observations,
            targetMinutes: sleepNeedMinutes,
            goalMode: goalMode,
            now: now,
            calendar: calendar
        )
        let defaults = UserDefaults.standard
        let changed = context != personalization
        defaults.set(context.recoveryMinutes, forKey: K.recovery)
        defaults.set(context.historyNights, forKey: K.personalizationNights)
        defaults.set(context.source.rawValue, forKey: K.personalizationSource)
        defaults.set(context.isCurrent, forKey: K.personalizationCurrent)
        if let latest = context.latestDay {
            defaults.set(latest, forKey: K.personalizationLatestDay)
        } else {
            defaults.removeObject(forKey: K.personalizationLatestDay)
        }
        if changed, isEnabled { schedule() }
    }

    /// Repair or remove the OS schedule from persisted state without requesting permission. This runs
    /// on normal shell appearance and after a cold backup restore, so a restored OFF value cannot leave
    /// an older target-device reminder behind and a restored ON value becomes live only when the user
    /// has already authorized notifications.
    static func restoreScheduleIfAuthorized() {
        Task { @MainActor in
            await renewScheduleIfAuthorized()
        }
    }

    /// Direct async repair used by the iOS background-maintenance lane. Unlike the foreground wrapper,
    /// this does not launch detached work that could outlive the finite BGAppRefreshTask.
    static func renewScheduleIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        guard isEnabled else {
            cancelAllScheduledReminders(on: center)
            return
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            schedule()
        default:
            LocalNotificationLifecycle.suppressed(identifier: requestId)
        }
    }

    /// The minute-of-day the nudge fires: wake − sleepNeed − lead, wrapped into [0, 1440).
    static func nudgeMinuteOfDay() -> Int {
        let raw = wakeMinutes - targetSleepMinutes - leadMinutes
        let day = 24 * 60
        return ((raw % day) + day) % day
    }

    // MARK: - Scheduling

    /// Per-weekday request ids — cleared alongside the single id so toggling overrides on/off never leaves
    /// a stale trigger behind.
    private static var perDayRequestIds: [String] { (1...7).map { "\(requestId)-wd\($0)" } }
    private static let suppressionLookAhead: TimeInterval = 12 * 60 * 60
    private static let renewalBufferDays = 21

    private static var storedScheduledReminders: [ScheduledWindDownReminder] {
        guard let data = UserDefaults.standard.data(forKey: K.scheduledReminders),
              let reminders = try? JSONDecoder().decode([ScheduledWindDownReminder].self, from: data)
        else { return [] }
        return reminders
    }

    private static var sleepSuppressedDayKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: K.sleepSuppressedDays) ?? [])
    }

    private static func storeScheduledReminders(_ reminders: [ScheduledWindDownReminder]) {
        if reminders.isEmpty {
            UserDefaults.standard.removeObject(forKey: K.scheduledReminders)
            return
        }
        guard let data = try? JSONEncoder().encode(reminders) else { return }
        UserDefaults.standard.set(data, forKey: K.scheduledReminders)
    }

    private static func storeSleepSuppressedDayKeys(_ keys: Set<String>) {
        let bounded = Array(keys.sorted().suffix(32))
        if bounded.isEmpty {
            UserDefaults.standard.removeObject(forKey: K.sleepSuppressedDays)
        } else {
            UserDefaults.standard.set(bounded, forKey: K.sleepSuppressedDays)
        }
    }

    private static func clearSleepSuppressedDays() {
        UserDefaults.standard.removeObject(forKey: K.sleepSuppressedDays)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func fireDate(
        on day: Date,
        minuteOfDay: Int,
        calendar: Calendar
    ) -> Date? {
        guard let date = calendar.date(
            bySettingHour: minuteOfDay / 60,
            minute: minuteOfDay % 60,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ), calendar.isDate(date, inSameDayAs: day) else { return nil }
        return date
    }

    /// Builds a bounded set of strictly future one-shot requests. Dated requests let fresh local sleep
    /// evidence remove only the current sleep-window reminder instead of destroying every later night.
    static func reminderSchedule(
        now: Date = Date(),
        horizonDays: Int = 28,
        calendar: Calendar = .current,
        excludedDayKeys: Set<String> = []
    ) -> [ScheduledWindDownReminder] {
        let targetCount = min(max(horizonDays, 1), 28)
        let startDay = calendar.startOfDay(for: now)
        var reminders: [ScheduledWindDownReminder] = []
        var offset = 0
        while reminders.count < targetCount, offset < targetCount + 32 {
            defer { offset += 1 }
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            let minute = nudgeMinuteOfDay(forWeekday: weekday)
            guard let fireDate = fireDate(on: day, minuteOfDay: minute, calendar: calendar),
                  fireDate > now else { continue }
            let key = dayKey(for: fireDate, calendar: calendar)
            guard !excludedDayKeys.contains(key) else { continue }
            reminders.append(
                ScheduledWindDownReminder(
                    identifier: "\(requestId)-\(key)",
                    fireTimestamp: Int(fireDate.timeIntervalSince1970),
                    dayKey: key
                )
            )
        }
        return reminders
    }

    /// Requests maintenance while a large dated-reminder buffer still remains. iOS may defer app
    /// refresh, so the 28-day schedule leaves three weeks after this first renewal opportunity.
    static func renewalWakeDate(
        scheduledReminders: [ScheduledWindDownReminder],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard let finalReminder = scheduledReminders.max(by: {
            $0.fireTimestamp < $1.fireTimestamp
        }), let preferred = calendar.date(
            byAdding: .day,
            value: -renewalBufferDays,
            to: finalReminder.fireDate
        ) else { return nil }
        return max(preferred, now.addingTimeInterval(60))
    }

    /// Selects only reminders in the active sleep window. The upper bound prevents evidence observed
    /// after midnight from suppressing the following evening's reminder.
    static func remindersToSuppress(
        sessions: [CachedSleepSession],
        scheduledReminders: [ScheduledWindDownReminder],
        now: Date = Date()
    ) -> [ScheduledWindDownReminder] {
        guard let evidence = WindDownSleepStatePolicy.activeSleepEvidence(
            sessions: sessions,
            now: now
        ) else { return [] }
        let lower = evidence.sessionStart
        let upper = Int(now.addingTimeInterval(suppressionLookAhead).timeIntervalSince1970)
        return scheduledReminders.filter {
            $0.fireTimestamp >= lower && $0.fireTimestamp <= upper
        }
    }

    /// Remove a current-night reminder when fresh local stage evidence says the user is already asleep.
    /// Future dated reminders remain scheduled, and the suppressed local day survives a schedule repair
    /// so foregrounding the app cannot immediately re-add the same reminder.
    static func suppressIfAlreadyAsleep(
        sessions: [CachedSleepSession],
        now: Date = Date(),
        on center: UNUserNotificationCenter = .current()
    ) {
        guard isEnabled else { return }
        let scheduled = storedScheduledReminders
        let selected = remindersToSuppress(
            sessions: sessions,
            scheduledReminders: scheduled,
            now: now
        )
        guard !selected.isEmpty else { return }

        let identifiers = selected.map(\.identifier)
        var suppressedDays = sleepSuppressedDayKeys
        suppressedDays.formUnion(selected.map(\.dayKey))
        storeSleepSuppressedDayKeys(suppressedDays)
        storeScheduledReminders(
            scheduled.filter { !identifiers.contains($0.identifier) }
        )
        for identifier in identifiers {
            LocalNotificationLifecycle.suppressed(
                identifier: identifier,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
        }
        LocalNotificationLifecycle.cancel(
            identifiers: identifiers,
            presented: true,
            on: center
        )
    }

    static var notificationCopy: WindDownNotificationCopy {
        WindDownNotificationCopy(
            title: String(localized: "Wind down for tonight"),
            body: String(localized: "Your planned bedtime is coming up. Start settling down when it works for you.")
        )
    }

    static func notificationContent() -> UNMutableNotificationContent {
        let copy = notificationCopy
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.sleep"
        content.userInfo = [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.sleep.rawValue]
        return content
    }

    private static func cancelAllScheduledReminders(
        on center: UNUserNotificationCenter = .current()
    ) {
        let identifiers = [requestId] + perDayRequestIds
            + storedScheduledReminders.map(\.identifier)
        LocalNotificationLifecycle.cancel(
            identifiers: Array(Set(identifiers)),
            presented: true,
            on: center
        )
        storeScheduledReminders([])
    }

    private static func schedule(
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let center = UNUserNotificationCenter.current()
        cancelAllScheduledReminders(on: center)
        DailyReviewNotifications.registerPrivacyCategory(on: center)

        let content = notificationContent()
        let reminders = reminderSchedule(
            now: now,
            calendar: calendar,
            excludedDayKeys: sleepSuppressedDayKeys
        )
        storeScheduledReminders(reminders)
        for reminder in reminders {
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            )
            components.second = 0
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
            LocalNotificationLifecycle.schedule(
                UNNotificationRequest(
                    identifier: reminder.identifier,
                    content: content,
                    trigger: trigger
                ),
                on: center
            )
        }
        #if os(iOS)
        if let renewal = renewalWakeDate(
            scheduledReminders: reminders,
            now: now,
            calendar: calendar
        ) {
            BackgroundSyncScheduler.requestWake(noLaterThan: renewal, now: now)
        }
        #endif
    }
}
