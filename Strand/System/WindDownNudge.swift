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

struct WindDownNotificationPlan: Equatable, Sendable {
    let windDownMinuteOfDay: Int
    let bedtimeMinuteOfDay: Int
}

struct DatedWindDownPlan: Equatable, Sendable {
    let windDownTimestamp: Int
    let bedtimeTimestamp: Int
    let wakeTimestamp: Int
    let wakeWeekday: Int

    var windDownDate: Date {
        Date(timeIntervalSince1970: TimeInterval(windDownTimestamp))
    }

    var bedtimeDate: Date {
        Date(timeIntervalSince1970: TimeInterval(bedtimeTimestamp))
    }

    var wakeDate: Date {
        Date(timeIntervalSince1970: TimeInterval(wakeTimestamp))
    }
}

enum WindDownNotificationAuthorization: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
}

enum WindDownScheduleFailure: String, Equatable, Sendable {
    case authorizationRevoked
    case capacityLimited
    case noFuturePlan
    case notificationCenterRejected
}

enum WindDownScheduleResult: Equatable, Sendable {
    case scheduled(count: Int)
    case failed(WindDownScheduleFailure)
}

struct WindDownRetryPolicy: Equatable, Sendable {
    let maximumAttempts: Int
    let delayNanoseconds: UInt64

    static let production = WindDownRetryPolicy(
        maximumAttempts: 2,
        delayNanoseconds: 150_000_000
    )

    init(maximumAttempts: Int, delayNanoseconds: UInt64) {
        self.maximumAttempts = max(1, min(maximumAttempts, 3))
        self.delayNanoseconds = min(delayNanoseconds, 1_000_000_000)
    }
}

@MainActor
protocol WindDownNotificationClient: AnyObject {
    func authorization() async -> WindDownNotificationAuthorization
    func requestAuthorization() async -> Bool
    func registerPrivacyCategory()
    func add(_ request: UNNotificationRequest) async throws
    func reconcile(
        requests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingIdentifiers: Set<String>,
        now: Date,
        calendar: Calendar
    ) async -> LocalNotificationReconciliationResult
    func cancel(identifiers: [String])
}

extension WindDownNotificationClient {
    func reconcile(
        requests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingIdentifiers: Set<String>,
        now: Date,
        calendar: Calendar
    ) async -> LocalNotificationReconciliationResult {
        _ = replacingIdentifiers
        _ = preservingIdentifiers
        _ = now
        _ = calendar
        var accepted: [String] = []
        var failed: [String] = []
        for request in requests {
            do {
                try await add(request)
                accepted.append(request.identifier)
            } catch {
                failed.append(request.identifier)
                break
            }
        }
        return LocalNotificationReconciliationResult(
            acceptedIdentifiers: accepted,
            capacityLimitedIdentifiers: [],
            failedIdentifiers: failed,
            removedIdentifiers: []
        )
    }
}

@MainActor
final class SystemWindDownNotificationClient: WindDownNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorization() async -> WindDownNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func registerPrivacyCategory() {
        DailyReviewNotifications.registerPrivacyCategory(on: center)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await LocalNotificationLifecycle.schedule(request, on: center)
    }

    func reconcile(
        requests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingIdentifiers: Set<String>,
        now: Date,
        calendar: Calendar
    ) async -> LocalNotificationReconciliationResult {
        await LocalNotificationLifecycle.reconcile(
            candidateRequests: requests,
            replacingIdentifiers: replacingIdentifiers,
            preservingExistingIdentifiers: preservingIdentifiers,
            now: now,
            calendar: calendar,
            on: center
        )
    }

    func cancel(identifiers: [String]) {
        LocalNotificationLifecycle.cancel(
            identifiers: identifiers,
            presented: true,
            on: center
        )
    }
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
    let bedtimeTimestamp: Int
    let wakeTimestamp: Int
    let dayKey: String
    let wakeDayKey: String
    let wakeWeekday: Int
    let usesContextualCopy: Bool

    var fireDate: Date {
        Date(timeIntervalSince1970: TimeInterval(fireTimestamp))
    }

    var bedtimeDate: Date {
        Date(timeIntervalSince1970: TimeInterval(bedtimeTimestamp))
    }

    var wakeDate: Date {
        Date(timeIntervalSince1970: TimeInterval(wakeTimestamp))
    }

    init(
        identifier: String,
        fireTimestamp: Int,
        bedtimeTimestamp: Int,
        wakeTimestamp: Int,
        dayKey: String,
        wakeDayKey: String,
        wakeWeekday: Int,
        usesContextualCopy: Bool
    ) {
        self.identifier = identifier
        self.fireTimestamp = fireTimestamp
        self.bedtimeTimestamp = bedtimeTimestamp
        self.wakeTimestamp = wakeTimestamp
        self.dayKey = dayKey
        self.wakeDayKey = wakeDayKey
        self.wakeWeekday = wakeWeekday
        self.usesContextualCopy = usesContextualCopy
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case fireTimestamp
        case bedtimeTimestamp
        case wakeTimestamp
        case dayKey
        case wakeDayKey
        case wakeWeekday
        case usesContextualCopy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        fireTimestamp = try container.decode(Int.self, forKey: .fireTimestamp)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        bedtimeTimestamp = try container.decodeIfPresent(
            Int.self,
            forKey: .bedtimeTimestamp
        ) ?? fireTimestamp
        wakeTimestamp = try container.decodeIfPresent(
            Int.self,
            forKey: .wakeTimestamp
        ) ?? bedtimeTimestamp
        wakeDayKey = try container.decodeIfPresent(
            String.self,
            forKey: .wakeDayKey
        ) ?? dayKey
        wakeWeekday = try container.decodeIfPresent(
            Int.self,
            forKey: .wakeWeekday
        ) ?? 0
        usesContextualCopy = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesContextualCopy
        ) ?? false
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
    static let stateDidChange = Notification.Name("noop.windDownNudge.stateDidChange")

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
        rescheduleIfEnabled()
    }

    /// The nudge minute-of-day for a given weekday — that day's wake (override or default) minus sleep need
    /// minus lead, wrapped into [0, 1440). Pure; mirrors `nudgeMinuteOfDay()` per-day. (PR#554)
    static func nudgeMinuteOfDay(forWeekday weekday: Int) -> Int {
        notificationPlan(forWeekday: weekday).windDownMinuteOfDay
    }

    /// The planned bedtime for a weekday, derived from that day's wake target and current sleep
    /// opportunity. This is planner context, not a promise or a measured sleep event.
    static func bedtimeMinuteOfDay(forWeekday weekday: Int) -> Int {
        notificationPlan(forWeekday: weekday).bedtimeMinuteOfDay
    }

    static func notificationPlan(forWeekday weekday: Int) -> WindDownNotificationPlan {
        notificationPlan(wakeMinutes: wakeMinutes(forWeekday: weekday))
    }

    private static func notificationPlan(wakeMinutes: Int) -> WindDownNotificationPlan {
        let bedtime = normalizedMinuteOfDay(
            wakeMinutes - targetSleepMinutes
        )
        return WindDownNotificationPlan(
            windDownMinuteOfDay: normalizedMinuteOfDay(bedtime - leadMinutes),
            bedtimeMinuteOfDay: bedtime
        )
    }

    // MARK: - Public API

    /// The result of enabling the nudge - lets the UI react instead of silently persisting an "on" toggle
    /// that can never fire. `.denied` means the OS won't deliver (permission off), so the caller should
    /// revert the switch and point the user at Settings.
    enum EnableOutcome: Equatable, Sendable {
        case scheduled
        case denied
        case failed(WindDownScheduleFailure)
        case off
    }

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
        stateMutation &+= 1
        let mutation = stateMutation
        Task { @MainActor in
            let outcome = await applyEnabledState(
                on,
                client: SystemWindDownNotificationClient(),
                expectedMutation: mutation
            )
            guard isCurrentStateMutation(mutation) else { return }
            completion?(outcome)
        }
    }

    static func applyEnabledState(
        _ on: Bool,
        client: WindDownNotificationClient,
        retryPolicy: WindDownRetryPolicy = .production,
        now: Date = Date(),
        calendar: Calendar = .current,
        expectedMutation: UInt64? = nil
    ) async -> EnableOutcome {
        await performSchedulingOperation(superseded: .off) { generation in
            await applyEnabledState(
                on,
                client: client,
                retryPolicy: retryPolicy,
                now: now,
                calendar: calendar,
                expectedMutation: expectedMutation,
                ownerGeneration: generation
            )
        }
    }

    private static func applyEnabledState(
        _ on: Bool,
        client: WindDownNotificationClient,
        retryPolicy: WindDownRetryPolicy,
        now: Date,
        calendar: Calendar,
        expectedMutation: UInt64?,
        ownerGeneration: UInt64
    ) async -> EnableOutcome {
        guard isSchedulingOwner(ownerGeneration) else { return .off }
        guard isCurrentStateMutation(expectedMutation) else { return .off }
        guard on else {
            persistEnabled(false)
            cancelAllScheduledReminders(using: client)
            return .off
        }

        let authorization = await client.authorization()
        guard isSchedulingOwner(ownerGeneration),
              isCurrentStateMutation(expectedMutation) else { return .off }
        let authorized: Bool
        switch authorization {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await client.requestAuthorization()
        case .denied:
            authorized = false
        }
        guard isSchedulingOwner(ownerGeneration),
              isCurrentStateMutation(expectedMutation) else { return .off }
        guard authorized else {
            persistEnabled(false)
            cancelAllScheduledReminders(using: client)
            LocalNotificationLifecycle.suppressed(
                identifier: requestId,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return .denied
        }

        clearSleepSuppressedDays()
        let result = await schedule(
            using: client,
            retryPolicy: retryPolicy,
            now: now,
            calendar: calendar,
            ownerGeneration: ownerGeneration
        )
        guard let result,
              isSchedulingOwner(ownerGeneration),
              isCurrentStateMutation(expectedMutation) else { return .off }
        switch result {
        case .scheduled:
            guard await client.authorization() == .authorized else {
                guard isSchedulingOwner(ownerGeneration),
                      isCurrentStateMutation(expectedMutation) else { return .off }
                persistEnabled(false)
                cancelAllScheduledReminders(using: client)
                LocalNotificationLifecycle.suppressed(
                    identifier: requestId,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
                return .failed(.authorizationRevoked)
            }
            guard isSchedulingOwner(ownerGeneration),
                  isCurrentStateMutation(expectedMutation) else { return .off }
            persistEnabled(true)
            return .scheduled
        case .failed(let failure):
            if storedScheduledReminders.isEmpty {
                persistEnabled(false)
                cancelAllScheduledReminders(using: client)
            } else {
                persistEnabled(true)
            }
            return .failed(failure)
        }
    }

    /// Update the earliest wake time the nudge is derived from, rescheduling if enabled.
    static func setWakeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.wake)
        rescheduleIfEnabled()
    }

    /// Update the user's explicit baseline target. The planner may add a bounded recovery buffer,
    /// but never silently changes this value.
    static func setSleepNeedMinutes(_ minutes: Int) {
        let next = min(max(minutes, 5 * 60), 11 * 60)
        let prior = sleepNeedMinutes
        let wasExplicit = hasExplicitSleepNeed
        UserDefaults.standard.set(next, forKey: K.sleepNeed)
        rescheduleIfEnabled()
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
        rescheduleIfEnabled()
    }

    /// Persist the planner's bounded recovery addition so a notification already scheduled in the
    /// OS remains aligned with the plan after NOOP closes.
    static func setRecoveryMinutes(_ minutes: Int) {
        let next = min(max(minutes, 0), 60)
        guard next != recoveryMinutes else { return }
        UserDefaults.standard.set(next, forKey: K.recovery)
        rescheduleIfEnabled()
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
        if changed { rescheduleIfEnabled() }
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
        _ = await reconcileScheduleIfAuthorized(
            client: SystemWindDownNotificationClient()
        )
    }

    @discardableResult
    static func reconcileScheduleIfAuthorized(
        client: WindDownNotificationClient,
        retryPolicy: WindDownRetryPolicy = .production,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> WindDownScheduleResult? {
        await performSchedulingOperation(superseded: nil) { generation in
            await reconcileScheduleIfAuthorized(
                client: client,
                retryPolicy: retryPolicy,
                now: now,
                calendar: calendar,
                ownerGeneration: generation
            )
        }
    }

    private static func reconcileScheduleIfAuthorized(
        client: WindDownNotificationClient,
        retryPolicy: WindDownRetryPolicy,
        now: Date,
        calendar: Calendar,
        ownerGeneration: UInt64
    ) async -> WindDownScheduleResult? {
        guard isSchedulingOwner(ownerGeneration),
              isLatestSchedulingIntent(ownerGeneration) else { return nil }
        guard isEnabled else {
            cancelAllScheduledReminders(using: client)
            return nil
        }
        guard await client.authorization() == .authorized else {
            guard isSchedulingOwner(ownerGeneration) else { return nil }
            persistEnabled(false)
            cancelAllScheduledReminders(using: client)
            LocalNotificationLifecycle.suppressed(
                identifier: requestId,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return .failed(.authorizationRevoked)
        }

        let result = await schedule(
            using: client,
            retryPolicy: retryPolicy,
            now: now,
            calendar: calendar,
            ownerGeneration: ownerGeneration
        )
        guard let result,
              isSchedulingOwner(ownerGeneration),
              isLatestSchedulingIntent(ownerGeneration),
              isEnabled else { return nil }
        if case .scheduled = result,
           await client.authorization() != .authorized {
            guard isSchedulingOwner(ownerGeneration),
                  isLatestSchedulingIntent(ownerGeneration) else { return nil }
            persistEnabled(false)
            cancelAllScheduledReminders(using: client)
            LocalNotificationLifecycle.suppressed(
                identifier: requestId,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return .failed(.authorizationRevoked)
        }
        if case .failed = result, storedScheduledReminders.isEmpty {
            persistEnabled(false)
            cancelAllScheduledReminders(using: client)
        }
        return result
    }

    /// The minute-of-day the nudge fires: wake − sleepNeed − lead, wrapped into [0, 1440).
    static func nudgeMinuteOfDay() -> Int {
        notificationPlan(wakeMinutes: wakeMinutes).windDownMinuteOfDay
    }

    // MARK: - Scheduling

    /// Per-weekday request ids — cleared alongside the single id so toggling overrides on/off never leaves
    /// a stale trigger behind.
    private static var perDayRequestIds: [String] { (1...7).map { "\(requestId)-wd\($0)" } }
    private static let suppressionLookAhead: TimeInterval = 12 * 60 * 60
    private static let renewalBufferDays = 21
    private static let contextualCopyHorizonDays = 7
    private static var stateMutation: UInt64 = 0
    private static var schedulingGeneration: UInt64 = 0
    private static var activeSchedulingGeneration: UInt64?
    private static var schedulingTail: Task<Void, Never>?

    private static func isCurrentStateMutation(_ mutation: UInt64?) -> Bool {
        mutation.map { $0 == stateMutation } ?? true
    }

    private static func isSchedulingOwner(_ generation: UInt64) -> Bool {
        activeSchedulingGeneration == generation
    }

    private static func isLatestSchedulingIntent(_ generation: UInt64) -> Bool {
        schedulingGeneration == generation
    }

    /// One MainActor-owned lane serializes every enable, restore, and settings-driven rebuild.
    /// Requests queued behind an active rebuild are coalesced by generation before they can touch
    /// Notification Center or persisted state. The active owner finishes one coherent transaction.
    /// Repairs publish state only when still latest; explicit toggles are separately generation-gated
    /// by `stateMutation`, so a redundant restore cannot overturn a user state transition.
    private static func performSchedulingOperation<Result: Sendable>(
        superseded: Result,
        operation: @escaping @MainActor (UInt64) async -> Result
    ) async -> Result {
        schedulingGeneration &+= 1
        let generation = schedulingGeneration
        let prior = schedulingTail
        let operationTask = Task<Result, Never> { @MainActor in
            await prior?.value
            guard generation == schedulingGeneration else {
                return superseded
            }
            activeSchedulingGeneration = generation
            let result = await operation(generation)
            if activeSchedulingGeneration == generation {
                activeSchedulingGeneration = nil
            }
            return result
        }
        schedulingTail = Task { @MainActor in
            _ = await operationTask.value
            if generation == schedulingGeneration {
                schedulingTail = nil
            }
        }
        return await operationTask.value
    }

    private static func persistEnabled(_ enabled: Bool) {
        let changed = isEnabled != enabled
        UserDefaults.standard.set(enabled, forKey: K.enabled)
        if changed {
            NotificationCenter.default.post(name: stateDidChange, object: nil)
        }
    }

    private static func rescheduleIfEnabled() {
        guard isEnabled else { return }
        Task { @MainActor in
            _ = await reconcileScheduleIfAuthorized(
                client: SystemWindDownNotificationClient()
            )
        }
    }

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

    /// Foundation's explicit next-time-preserving/first-overlap policy and java.time's
    /// `LocalDateTime.atZone` share the behavior NOOP needs here: a DST gap moves forward by the size
    /// of the gap while preserving minutes, and a repeated local time uses the earlier offset. Both
    /// clients resolve the wake instant first, then subtract exact durations from that same instant.
    static func datedPlan(
        forWakeDay wakeDay: Date,
        wakeMinutes: Int,
        targetSleepMinutes: Int,
        leadMinutes: Int,
        calendar: Calendar
    ) -> DatedWindDownPlan? {
        let safeWake = min(max(wakeMinutes, 0), 24 * 60 - 1)
        let startOfWakeDay = calendar.startOfDay(for: wakeDay)
        var wakeComponents = DateComponents()
        wakeComponents.timeZone = calendar.timeZone
        wakeComponents.hour = safeWake / 60
        wakeComponents.minute = safeWake % 60
        wakeComponents.second = 0
        guard let wakeDate = calendar.nextDate(
            after: startOfWakeDay.addingTimeInterval(-1),
            matching: wakeComponents,
            matchingPolicy: .nextTimePreservingSmallerComponents,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else { return nil }

        let bedtimeDate = wakeDate.addingTimeInterval(
            -TimeInterval(max(0, targetSleepMinutes) * 60)
        )
        let windDownDate = bedtimeDate.addingTimeInterval(
            -TimeInterval(max(0, leadMinutes) * 60)
        )
        return DatedWindDownPlan(
            windDownTimestamp: Int(windDownDate.timeIntervalSince1970),
            bedtimeTimestamp: Int(bedtimeDate.timeIntervalSince1970),
            wakeTimestamp: Int(wakeDate.timeIntervalSince1970),
            wakeWeekday: calendar.component(.weekday, from: wakeDate)
        )
    }

    static func nextDatedPlan(
        defaultWakeMinutes: Int? = nil,
        wakeOverrides: [Int: Int]? = nil,
        targetSleepMinutes: Int? = nil,
        leadMinutes: Int? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DatedWindDownPlan? {
        let resolvedDefaultWake = defaultWakeMinutes ?? Self.wakeMinutes
        let resolvedOverrides = wakeOverrides ?? perDayWakeOverrides
        let resolvedTarget = targetSleepMinutes ?? Self.targetSleepMinutes
        let resolvedLead = leadMinutes ?? Self.leadMinutes
        let startWakeDay = calendar.startOfDay(for: now)
        for offset in 0..<10 {
            guard let wakeDay = calendar.date(
                byAdding: .day,
                value: offset,
                to: startWakeDay
            ) else { continue }
            let weekday = calendar.component(.weekday, from: wakeDay)
            guard let plan = datedPlan(
                forWakeDay: wakeDay,
                wakeMinutes: resolvedOverrides[weekday] ?? resolvedDefaultWake,
                targetSleepMinutes: resolvedTarget,
                leadMinutes: resolvedLead,
                calendar: calendar
            ), plan.windDownDate > now else { continue }
            return plan
        }
        return nil
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
        let startWakeDay = calendar.startOfDay(for: now)
        var reminders: [ScheduledWindDownReminder] = []
        var offset = 0
        while reminders.count < targetCount, offset < targetCount + 32 {
            defer { offset += 1 }
            guard let wakeDay = calendar.date(
                byAdding: .day,
                value: offset,
                to: startWakeDay
            ) else {
                continue
            }
            let wakeWeekday = calendar.component(.weekday, from: wakeDay)
            guard let plan = datedPlan(
                forWakeDay: wakeDay,
                wakeMinutes: wakeMinutes(forWeekday: wakeWeekday),
                targetSleepMinutes: targetSleepMinutes,
                leadMinutes: leadMinutes,
                calendar: calendar
            ), plan.windDownDate > now else { continue }
            let fireKey = dayKey(for: plan.windDownDate, calendar: calendar)
            let wakeKey = dayKey(for: plan.wakeDate, calendar: calendar)
            guard !excludedDayKeys.contains(fireKey) else { continue }
            reminders.append(
                ScheduledWindDownReminder(
                    identifier: "\(requestId)-wake-\(wakeKey)",
                    fireTimestamp: plan.windDownTimestamp,
                    bedtimeTimestamp: plan.bedtimeTimestamp,
                    wakeTimestamp: plan.wakeTimestamp,
                    dayKey: fireKey,
                    wakeDayKey: wakeKey,
                    wakeWeekday: plan.wakeWeekday,
                    usesContextualCopy: offset < contextualCopyHorizonDays
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

    private static func normalizedMinuteOfDay(_ minutes: Int) -> Int {
        let day = 24 * 60
        return ((minutes % day) + day) % day
    }

    private static func localizedTime(
        minuteOfDay: Int,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            year: 2001,
            month: 1,
            day: 1,
            hour: minuteOfDay / 60,
            minute: minuteOfDay % 60
        )) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func localizedTime(
        date: Date,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func notificationCopy(
        forWeekday weekday: Int,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> WindDownNotificationCopy {
        let plan = notificationPlan(forWeekday: weekday)
        let windDown = localizedTime(
            minuteOfDay: plan.windDownMinuteOfDay,
            locale: locale,
            timeZone: timeZone
        )
        let bedtime = localizedTime(
            minuteOfDay: plan.bedtimeMinuteOfDay,
            locale: locale,
            timeZone: timeZone
        )
        let template = String(
            localized: "Plan: wind down at %1$@; bedtime at %2$@, if that works for you.",
            locale: locale
        )
        return WindDownNotificationCopy(
            title: String(localized: "Wind down for tonight", locale: locale),
            body: String(
                format: template,
                locale: locale,
                arguments: [windDown, bedtime]
            )
        )
    }

    static func notificationCopy(
        for reminder: ScheduledWindDownReminder,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> WindDownNotificationCopy {
        guard reminder.usesContextualCopy else {
            return WindDownNotificationCopy(
                title: String(localized: "Wind down for tonight", locale: locale),
                body: String(
                    localized: "Your planned bedtime is coming up. Start settling down when it works for you.",
                    locale: locale
                )
            )
        }
        let windDown = localizedTime(
            date: reminder.fireDate,
            locale: locale,
            calendar: calendar
        )
        let bedtime = localizedTime(
            date: reminder.bedtimeDate,
            locale: locale,
            calendar: calendar
        )
        let template = String(
            localized: "Plan: wind down at %1$@; bedtime at %2$@, if that works for you.",
            locale: locale
        )
        return WindDownNotificationCopy(
            title: String(localized: "Wind down for tonight", locale: locale),
            body: String(
                format: template,
                locale: locale,
                arguments: [windDown, bedtime]
            )
        )
    }

    static func notificationContent(
        for reminder: ScheduledWindDownReminder,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> UNMutableNotificationContent {
        let copy = notificationCopy(
            for: reminder,
            calendar: calendar,
            locale: locale
        )
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.sleep"
        content.userInfo = [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.sleep.rawValue]
        return content
    }

    private static func scheduledIdentifiers(
        including reminders: [ScheduledWindDownReminder]
    ) -> [String] {
        let identifiers = [requestId] + perDayRequestIds
            + reminders.map(\.identifier)
        return Array(Set(identifiers))
    }

    private static func stagedReminders(
        _ reminders: [ScheduledWindDownReminder],
        transactionID: UUID = UUID()
    ) -> [ScheduledWindDownReminder] {
        let suffix = transactionID.uuidString.lowercased()
        return reminders.map {
            ScheduledWindDownReminder(
                identifier: "\($0.identifier)-schedule-\(suffix)",
                fireTimestamp: $0.fireTimestamp,
                bedtimeTimestamp: $0.bedtimeTimestamp,
                wakeTimestamp: $0.wakeTimestamp,
                dayKey: $0.dayKey,
                wakeDayKey: $0.wakeDayKey,
                wakeWeekday: $0.wakeWeekday,
                usesContextualCopy: $0.usesContextualCopy
            )
        }
    }

    private static func cancelAllScheduledReminders(
        using client: WindDownNotificationClient
    ) {
        client.cancel(
            identifiers: scheduledIdentifiers(
                including: storedScheduledReminders
            )
        )
        storeScheduledReminders([])
    }

    static func notificationRequests(
        for reminders: [ScheduledWindDownReminder],
        calendar: Calendar
    ) -> [UNNotificationRequest] {
        reminders.map { reminder in
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: reminder.fireDate
            )
            components.second = 0
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
            return UNNotificationRequest(
                identifier: reminder.identifier,
                content: notificationContent(
                    for: reminder,
                    calendar: calendar
                ),
                trigger: trigger
            )
        }
    }

    private static func schedule(
        using client: WindDownNotificationClient,
        retryPolicy: WindDownRetryPolicy = .production,
        now: Date = Date(),
        calendar: Calendar = .current,
        ownerGeneration: UInt64
    ) async -> WindDownScheduleResult? {
        guard isSchedulingOwner(ownerGeneration) else { return nil }
        let priorReminders = storedScheduledReminders
        let plannedReminders = reminderSchedule(
            now: now,
            calendar: calendar,
            excludedDayKeys: sleepSuppressedDayKeys
        )
        guard !plannedReminders.isEmpty else {
            guard isSchedulingOwner(ownerGeneration),
                  isLatestSchedulingIntent(ownerGeneration) else { return nil }
            client.cancel(
                identifiers: scheduledIdentifiers(including: priorReminders)
            )
            storeScheduledReminders([])
            return .failed(.noFuturePlan)
        }

        let reminders = stagedReminders(plannedReminders)
        let requests = notificationRequests(for: reminders, calendar: calendar)
        let candidateIdentifiers = requests.map(\.identifier)
        let priorIdentifiers = priorReminders.map(\.identifier)
        guard isSchedulingOwner(ownerGeneration) else { return nil }
        client.registerPrivacyCategory()

        for attempt in 1...retryPolicy.maximumAttempts {
            guard isSchedulingOwner(ownerGeneration) else { return nil }
            let reconciliation = await client.reconcile(
                requests: requests,
                replacingIdentifiers: Set(candidateIdentifiers),
                preservingIdentifiers: Set(priorIdentifiers),
                now: now,
                calendar: calendar
            )
            guard isSchedulingOwner(ownerGeneration),
                  isLatestSchedulingIntent(ownerGeneration) else {
                client.cancel(
                    identifiers: reconciliation.acceptedIdentifiers
                )
                return nil
            }
            if !reconciliation.capacityLimitedIdentifiers.isEmpty {
                client.cancel(
                    identifiers: reconciliation.acceptedIdentifiers
                )
                return .failed(.capacityLimited)
            }
            if reconciliation.failedIdentifiers.isEmpty {
                let accepted = Set(reconciliation.acceptedIdentifiers)
                let acceptedReminders = reminders.filter {
                    accepted.contains($0.identifier)
                }
                guard acceptedReminders.count == reminders.count else {
                    client.cancel(identifiers: candidateIdentifiers)
                    return .failed(.notificationCenterRejected)
                }
                if !priorIdentifiers.isEmpty {
                    client.cancel(identifiers: priorIdentifiers)
                }
                storeScheduledReminders(acceptedReminders)
                #if os(iOS)
                if let renewal = renewalWakeDate(
                    scheduledReminders: acceptedReminders,
                    now: now,
                    calendar: calendar
                ) {
                    BackgroundSyncScheduler.requestWake(
                        noLaterThan: renewal,
                        now: now
                    )
                }
                #endif
                return .scheduled(count: acceptedReminders.count)
            }

            client.cancel(identifiers: reconciliation.acceptedIdentifiers)
            guard attempt < retryPolicy.maximumAttempts else {
                return .failed(.notificationCenterRejected)
            }
            if retryPolicy.delayNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: retryPolicy.delayNanoseconds
                )
            }
        }
        return .failed(.notificationCenterRejected)
    }
}
