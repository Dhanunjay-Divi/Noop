import Foundation
import UserNotifications
import StrandAnalytics

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

/// The wind-down nudge (#207) — a gentle, NON-critical evening local notification suggesting it's
/// time to start winding down so the user can reach their usual wake time well-rested.
///
/// Cross-platform (macOS + iOS): a sideloaded backgrounded app can't fire a dependable LOUD wake
/// alarm (no critical-alert entitlement), but it CAN post a calm daily reminder. The nudge fires on a
/// repeating calendar trigger at a time DERIVED from the user's earliest wake time minus their usual
/// sleep need minus a short lead. State is its own UserDefaults-backed store so it doesn't couple to
/// the shared BehaviorStore. On-device only; nothing is sent anywhere.
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
            // Clear the single trigger AND any per-day triggers (PR#554) so disabling leaves nothing behind.
            LocalNotificationLifecycle.cancel(
                identifiers: [requestId] + perDayRequestIds
            )
            completion?(.off)
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UserDefaults.standard.set(true, forKey: K.enabled)
                schedule()
                completion?(.scheduled)
            case .notDetermined:
                // First ask — the system dialog appears now (a predictable moment), then we schedule on
                // grant so the FIRST night is covered rather than only after some later re-arm.
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                } else {
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    LocalNotificationLifecycle.suppressed(identifier: requestId)
                    completion?(.denied)
                }
            default:
                // .denied (or any future non-authorized case) — don't fake an enabled toggle. The caller
                // surfaces a "notifications are off" prompt with a jump to Settings.
                UserDefaults.standard.set(false, forKey: K.enabled)
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
        UserDefaults.standard.set(min(max(minutes, 5 * 60), 11 * 60), forKey: K.sleepNeed)
        if isEnabled { schedule() }
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
        let center = UNUserNotificationCenter.current()
        guard isEnabled else {
            LocalNotificationLifecycle.cancel(
                identifiers: [requestId] + perDayRequestIds,
                on: center
            )
            return
        }
        Task { @MainActor in
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                schedule()
            default:
                LocalNotificationLifecycle.suppressed(identifier: requestId)
                break
            }
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

    private static func schedule() {
        let center = UNUserNotificationCenter.current()
        // Clear BOTH the single trigger and any per-day triggers so switching between the two modes (or
        // editing an override) never double-fires or leaves an orphaned reminder.
        LocalNotificationLifecycle.cancel(
            identifiers: [requestId] + perDayRequestIds,
            on: center
        )

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Wind down for tonight")
        content.subtitle = notificationSubtitle()
        content.body = notificationBody()
        content.sound = .default
        content.threadIdentifier = "noop.sleep"
        content.userInfo = [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.sleep.rawValue]

        // PR#554 — with per-day overrides set, fan out to seven weekday-pinned triggers each at that day's
        // own nudge time; with none, keep the single daily trigger (identical to the pre-#554 behaviour).
        if hasPerDayOverrides {
            for weekday in 1...7 {
                let minute = nudgeMinuteOfDay(forWeekday: weekday)
                var comps = DateComponents()
                comps.weekday = weekday   // Calendar weekday 1=Sun…7=Sat → fires weekly on that day
                comps.hour = minute / 60
                comps.minute = minute % 60
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                LocalNotificationLifecycle.schedule(
                    UNNotificationRequest(
                        identifier: "\(requestId)-wd\(weekday)",
                        content: content,
                        trigger: trigger
                    ),
                    on: center
                )
            }
            return
        }

        let minute = nudgeMinuteOfDay()
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        // repeats: true → a daily calendar trigger; survives relaunch (it lives in the notification
        // center, not the process), so the nudge keeps firing each evening without the app running.
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        LocalNotificationLifecycle.schedule(
            UNNotificationRequest(
                identifier: requestId,
                content: content,
                trigger: trigger
            ),
            on: center
        )
    }

    private static func notificationSubtitle() -> String {
        let bedtime = SleepPlanner.wrappedMinute(wakeMinutes - targetSleepMinutes)
        return String(localized: "Start \(clockText(nudgeMinuteOfDay())) · In bed \(clockText(bedtime))")
    }

    private static func notificationBody() -> String {
        let duration = durationText(targetSleepMinutes)
        let context = personalization
        guard context.isCurrent,
              context.historyNights >= SleepPlanner.minimumDebtNights else {
            return String(localized: "Protect your \(duration) sleep target with a calm wind-down.")
        }

        let basis: String
        switch context.source {
        case .wearable:
            basis = String(localized: "recent wearable sleep")
        case .appleHealth:
            basis = String(localized: "recent Apple Health sleep")
        case .mixed:
            basis = String(localized: "recent wearable and Apple Health sleep")
        case .none:
            basis = String(localized: "your sleep target")
        }
        return String(localized: "Based on \(basis) across \(context.historyNights) nights, allow \(duration) for sleep tonight.")
    }

    private static func clockText(_ minute: Int) -> String {
        var components = DateComponents()
        components.hour = minute / 60
        components.minute = minute % 60
        return (Calendar.current.date(from: components) ?? Date())
            .formatted(date: .omitted, time: .shortened)
    }

    private static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return String(localized: "\(hours) hr") }
        return String(localized: "\(hours) hr \(remainder) min")
    }
}
