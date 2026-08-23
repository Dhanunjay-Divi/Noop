import Foundation
import UserNotifications
import StrandAnalytics
import WhoopProtocol

// MARK: - Shared delivery gate

/// Restart-safe policy shared by event-driven wellness prompts.
///
/// Signal-specific engines decide whether an observation is meaningful. This layer only decides whether
/// a prompt may be delivered now: the evidence must still be fresh, the exact observation must be new,
/// its topic cooldown must have elapsed, the global anti-pileup window must be clear, and routine prompts
/// must be outside quiet hours. It never turns a wellness signal into a diagnosis or emergency.
enum ContextualInterventionKind: String, Codable, CaseIterable, Sendable {
    case stressBreathing
    case caffeineCutoff
    case oxygenTrend
    case bodyTemperatureReview
    case vo2Trend

    var cooldown: TimeInterval {
        switch self {
        case .stressBreathing: return 4 * 60 * 60
        case .caffeineCutoff: return 6 * 60 * 60
        case .oxygenTrend, .bodyTemperatureReview: return 24 * 60 * 60
        case .vo2Trend: return 21 * 24 * 60 * 60
        }
    }
}

struct ContextualInterventionCandidate: Equatable, Sendable {
    let kind: ContextualInterventionKind
    let observedAt: Date
    let maximumAge: TimeInterval
    let fingerprint: String
    let title: String
    let body: String
    let route: NoopNotificationRoute
    var respectsQuietHours = true
}

struct ContextualInterventionState: Codable, Equatable, Sendable {
    struct Delivery: Codable, Equatable, Sendable {
        let at: Date
        let fingerprint: String
    }

    var lastGlobalDelivery: Date?
    var deliveries: [String: Delivery]

    static let empty = ContextualInterventionState(lastGlobalDelivery: nil, deliveries: [:])
}

enum ContextualInterventionDecisionReason: Equatable, Sendable {
    case deliver
    case stale
    case duplicate
    case topicCooldown
    case globalCooldown
    case quietHours
}

struct ContextualInterventionDecision: Equatable, Sendable {
    let shouldDeliver: Bool
    let reason: ContextualInterventionDecisionReason
    let nextState: ContextualInterventionState
}

enum ContextualInterventionPolicy {
    static let globalCooldown: TimeInterval = 30 * 60

    static func evaluate(
        _ candidate: ContextualInterventionCandidate,
        state: ContextualInterventionState,
        now: Date,
        quietHoursEnabled: Bool,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
        calendar: Calendar = .current
    ) -> ContextualInterventionDecision {
        let age = now.timeIntervalSince(candidate.observedAt)
        guard age >= -5 * 60, age <= candidate.maximumAge else {
            return .init(shouldDeliver: false, reason: .stale, nextState: state)
        }

        let key = candidate.kind.rawValue
        if let prior = state.deliveries[key] {
            guard prior.fingerprint != candidate.fingerprint else {
                return .init(shouldDeliver: false, reason: .duplicate, nextState: state)
            }
            guard now.timeIntervalSince(prior.at) >= candidate.kind.cooldown else {
                return .init(shouldDeliver: false, reason: .topicCooldown, nextState: state)
            }
        }

        if let last = state.lastGlobalDelivery,
           now.timeIntervalSince(last) < globalCooldown {
            return .init(shouldDeliver: false, reason: .globalCooldown, nextState: state)
        }

        if candidate.respectsQuietHours, quietHoursEnabled {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if windowContains(
                minute,
                start: quietStartMinutes,
                end: quietEndMinutes
            ) {
                return .init(shouldDeliver: false, reason: .quietHours, nextState: state)
            }
        }

        var next = state
        next.lastGlobalDelivery = now
        next.deliveries[key] = .init(at: now, fingerprint: candidate.fingerprint)
        return .init(shouldDeliver: true, reason: .deliver, nextState: next)
    }

    static func windowContains(_ minute: Int, start: Int, end: Int) -> Bool {
        let day = 24 * 60
        let value = ((minute % day) + day) % day
        let lo = ((start % day) + day) % day
        let hi = ((end % day) + day) % day
        guard lo != hi else { return false }
        return lo < hi ? (value >= lo && value < hi) : (value >= lo || value < hi)
    }
}

/// Notification side effect for immediate contextual prompts. Authorization is requested only from an
/// explicit settings toggle; event handlers merely inspect the current status. State is persisted only
/// after the OS accepted the request, so a denied permission cannot silently consume a fresh observation.
@MainActor
enum ContextualInterventionCenter {
    static let stateKey = "contextualInterventions.deliveryState.v1"
    private static let quietHoursEnabledKey = "notif.quietHoursEnabled"
    private static let quietStartMinutesKey = "notif.quietStartMinutes"
    private static let quietEndMinutesKey = "notif.quietEndMinutes"
    private static var deliveriesInFlight = Set<ContextualInterventionKind>()

    enum EnableOutcome: Equatable, Sendable {
        case enabled
        case denied
        case off
    }

    static func requestAuthorization(
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion?(.enabled)
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                let final = await center.notificationSettings()
                completion?(granted && Self.isAuthorized(final.authorizationStatus) ? .enabled : .denied)
            default:
                completion?(.denied)
            }
        }
    }

    static func post(_ candidate: ContextualInterventionCandidate, now: Date = Date()) {
        guard !deliveriesInFlight.contains(candidate.kind) else { return }
        deliveriesInFlight.insert(candidate.kind)
        Task { @MainActor in
            defer { deliveriesInFlight.remove(candidate.kind) }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard isAuthorized(settings.authorizationStatus) else { return }

            let defaults = UserDefaults.standard
            let current = loadState(defaults: defaults)
            let decision = ContextualInterventionPolicy.evaluate(
                candidate,
                state: current,
                now: now,
                quietHoursEnabled: defaults.bool(forKey: quietHoursEnabledKey),
                quietStartMinutes: defaults.object(forKey: quietStartMinutesKey) as? Int ?? 22 * 60,
                quietEndMinutes: defaults.object(forKey: quietEndMinutesKey) as? Int ?? 7 * 60
            )
            guard decision.shouldDeliver else { return }

            DailyReviewNotifications.registerPrivacyCategory(on: center)
            let content = UNMutableNotificationContent()
            content.title = candidate.title
            content.body = candidate.body
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.contextual.\(candidate.kind.rawValue)"
            content.userInfo = [
                NotificationRouteBridge.userInfoKey: candidate.route.rawValue
            ]
            do {
                try await center.add(
                    UNNotificationRequest(
                        identifier: "contextual-\(candidate.kind.rawValue)",
                        content: content,
                        trigger: nil
                    )
                )
                saveState(decision.nextState, defaults: defaults)
            } catch {
                // A rejected request remains eligible while its evidence is fresh.
            }
        }
    }

    static func loadState(defaults: UserDefaults = .standard) -> ContextualInterventionState {
        guard let data = defaults.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode(ContextualInterventionState.self, from: data)
        else { return .empty }
        return decoded
    }

    static func saveState(
        _ state: ContextualInterventionState,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

enum ContextualInterventionSettings {
    static let vitalReviewEnabledKey = "contextualInterventions.vitalReviewEnabled"
    static let vo2ReviewEnabledKey = "contextualInterventions.vo2ReviewEnabled"

    static var vitalReviewEnabled: Bool {
        UserDefaults.standard.bool(forKey: vitalReviewEnabledKey)
    }

    static var vo2ReviewEnabled: Bool {
        UserDefaults.standard.bool(forKey: vo2ReviewEnabledKey)
    }
}

// MARK: - Fresh vital policies

enum ContextualVitalPolicy {
    static let oxygenReviewThresholdPct = 95.0
    static let oxygenLookbackDays = 3
    static let oxygenSameDayConflictPct = 3.0

    struct OxygenObservation: Equatable, Sendable {
        let day: String
        let value: Double
    }

    /// A single wearable oxygen estimate is too placement-sensitive to interrupt the user. Require two
    /// distinct recent days below the same typical-range boundary already shown by the Health vital tile.
    /// Raw optical ADC values can never enter this path because they are stored separately from `spo2Pct`.
    static func oxygenCandidate(
        sourceRows: [SourcedDailyMetric],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ContextualInterventionCandidate? {
        let today = calendar.startOfDay(for: now)
        var candidatesByDay: [String: [(value: Double, priority: Int)]] = [:]
        for row in sourceRows {
            guard let value = row.metric.spo2Pct,
                  value.isFinite,
                  (70.0...100.0).contains(value),
                  let date = dayDate(row.metric.day, calendar: calendar) else { continue }
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: today
            ).day ?? Int.max
            guard (0...oxygenLookbackDays).contains(age) else { continue }
            candidatesByDay[row.metric.day, default: []].append(
                (value, row.source.vitalPriority)
            )
        }

        var byDay: [String: Double] = [:]
        for (day, candidates) in candidatesByDay {
            guard let low = candidates.map(\.value).min(),
                  let high = candidates.map(\.value).max(),
                  high - low < oxygenSameDayConflictPct,
                  let preferred = candidates.min(by: { $0.priority < $1.priority })
            else { continue }
            byDay[day] = preferred.value
        }

        let observations = byDay
            .map { OxygenObservation(day: $0.key, value: $0.value) }
            .sorted { $0.day < $1.day }
        guard observations.count >= 2 else { return nil }
        let pair = Array(observations.suffix(2))
        guard pair.allSatisfy({ $0.value < oxygenReviewThresholdPct }),
              let firstDate = dayDate(pair[0].day, calendar: calendar),
              let latestDate = dayDate(pair[1].day, calendar: calendar) else { return nil }
        let separation = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: firstDate),
            to: calendar.startOfDay(for: latestDate)
        ).day ?? Int.max
        let latestAge = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latestDate),
            to: today
        ).day ?? Int.max
        guard (1...2).contains(separation), (0...1).contains(latestAge) else { return nil }

        let fingerprint = pair
            .map { "\($0.day):\(Int(($0.value * 10).rounded()))" }
            .joined(separator: "|")
        return ContextualInterventionCandidate(
            kind: .oxygenTrend,
            observedAt: latestDate,
            maximumAge: 3 * 24 * 60 * 60,
            fingerprint: fingerprint,
            title: String(localized: "Wellness readings to review"),
            body: String(localized: "Two recent blood oxygen readings were outside the usual wearable range. Open NOOP to review their source and context."),
            route: .trends
        )
    }

    struct BodyTemperaturePoint: Equatable, Sendable {
        let day: String
        let valueC: Double
        let source: String
        let sourcePriority: Int
    }

    static let bodyTemperaturePlausibleRangeC = 30.0...45.0
    static let bodyTemperatureReviewRangeC = 35.0...38.0
    static let bodyTemperatureSameDayConflictC = 0.8

    /// Explicit absolute body-temperature samples only. Wrist/skin temperature is intentionally absent:
    /// it has different physiology and remains in the corroborated personal-baseline engine.
    static func bodyTemperatureCandidate(
        points: [BodyTemperaturePoint],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ContextualInterventionCandidate? {
        let today = calendar.startOfDay(for: now)
        var candidatesByDay: [String: [BodyTemperaturePoint]] = [:]
        for point in points {
            guard point.valueC.isFinite,
                  bodyTemperaturePlausibleRangeC.contains(point.valueC),
                  let date = dayDate(point.day, calendar: calendar) else { continue }
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: today
            ).day ?? Int.max
            guard (0...1).contains(age) else { continue }
            candidatesByDay[point.day, default: []].append(point)
        }

        let resolved = candidatesByDay.compactMap { day, candidates -> BodyTemperaturePoint? in
            guard let low = candidates.map(\.valueC).min(),
                  let high = candidates.map(\.valueC).max(),
                  high - low < bodyTemperatureSameDayConflictC
            else { return nil }
            return candidates.min { lhs, rhs in
                if lhs.sourcePriority == rhs.sourcePriority {
                    return lhs.source < rhs.source
                }
                return lhs.sourcePriority < rhs.sourcePriority
            }
        }
        guard let latest = resolved.max(by: { $0.day < $1.day }),
              !bodyTemperatureReviewRangeC.contains(latest.valueC),
              let observedAt = dayDate(latest.day, calendar: calendar)
        else { return nil }

        return ContextualInterventionCandidate(
            kind: .bodyTemperatureReview,
            observedAt: observedAt,
            maximumAge: 2 * 24 * 60 * 60,
            fingerprint: "\(latest.day):\(Int((latest.valueC * 10).rounded()))",
            title: String(localized: "Body temperature reading to review"),
            body: String(localized: "A fresh explicit body temperature reading was outside the broad review range. Recheck with a thermometer and consider how you feel; NOOP cannot assess severity."),
            route: .trends
        )
    }

    struct VO2Point: Equatable, Sendable {
        let day: String
        let value: Double
    }

    /// VO2 max is a slow fitness trend, not a real-time alarm. Notify only when a genuinely new point is
    /// fresh and two recent points persist in the same direction against a comparison at least three weeks
    /// older than the first point. One shifted estimate is never enough.
    static func vo2Candidate(
        measured: [VO2Point],
        estimated: [VO2Point],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ContextualInterventionCandidate? {
        let measuredClean = cleanVO2(measured, now: now, calendar: calendar)
        let estimatedClean = cleanVO2(estimated, now: now, calendar: calendar)
        let selected: [VO2Point]
        let sourceToken: String
        if measuredClean.count >= 3 {
            selected = measuredClean
            sourceToken = "measured"
        } else {
            selected = estimatedClean
            sourceToken = "estimated"
        }
        guard selected.count >= 3,
              let latest = selected.last,
              let latestDate = dayDate(latest.day, calendar: calendar) else { return nil }
        let shifted = Array(selected.suffix(2))
        guard let firstShiftDate = dayDate(shifted[0].day, calendar: calendar) else { return nil }
        let persistenceGap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: firstShiftDate),
            to: calendar.startOfDay(for: latestDate)
        ).day ?? Int.max
        guard (1...14).contains(persistenceGap) else { return nil }

        let reference = selected.last { point in
            guard point.day < shifted[0].day,
                  let date = dayDate(point.day, calendar: calendar) else { return false }
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: firstShiftDate)
            ).day ?? 0
            return days >= 21
        }
        guard let reference, reference.value > 0 else { return nil }
        let changes = shifted.map { $0.value - reference.value }
        guard changes.allSatisfy({
            abs($0) >= 3.0 && abs($0) / reference.value >= 0.08
        }), changes[0].sign == changes[1].sign else { return nil }

        return ContextualInterventionCandidate(
            kind: .vo2Trend,
            observedAt: latestDate,
            maximumAge: 8 * 24 * 60 * 60,
            fingerprint: "\(sourceToken):\(latest.day):\(Int((latest.value * 10).rounded()))",
            title: String(localized: "Cardio fitness trend updated"),
            body: String(localized: "A meaningful longer-term VO₂ max change is ready to review. Check the source and trend in NOOP."),
            route: .trends
        )
    }

    private static func cleanVO2(
        _ points: [VO2Point],
        now: Date,
        calendar: Calendar
    ) -> [VO2Point] {
        let today = calendar.startOfDay(for: now)
        var byDay: [String: VO2Point] = [:]
        for point in points {
            guard point.value.isFinite,
                  (10.0...90.0).contains(point.value),
                  let date = dayDate(point.day, calendar: calendar) else { continue }
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: today
            ).day ?? Int.max
            guard age >= 0, age <= 400 else { continue }
            byDay[point.day] = point
        }
        guard let latest = byDay.values.max(by: { $0.day < $1.day }),
              let latestDate = dayDate(latest.day, calendar: calendar) else { return [] }
        let latestAge = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latestDate),
            to: today
        ).day ?? Int.max
        guard latestAge <= 7 else { return [] }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func dayDate(_ day: String, calendar: Calendar) -> Date? {
        let fields = day.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: fields[0],
            month: fields[1],
            day: fields[2]
        ))
    }
}

// MARK: - Caffeine cutoff

enum CaffeineReminderPolicy {
    enum Plan: Equatable, Sendable {
        case none
        case schedule(at: Date)
        case notifyNow(ContextualInterventionCandidate)
    }

    static func plan(
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Plan {
        guard let bedtime = nextBedtime(
            after: now,
            bedtimeMinutes: bedtimeMinutes,
            calendar: calendar
        ) else { return .none }
        let cutoff = bedtime.addingTimeInterval(
            -CaffeineDecay.cutoffLeadHours() * 60 * 60
        )
        let recent = intakes
            .filter { $0.at <= now && $0.at >= now.addingTimeInterval(-24 * 60 * 60) }
            .sorted { $0.at < $1.at }
        guard let latest = recent.last else { return .none }

        if cutoff > now {
            return .schedule(at: cutoff)
        }
        guard latest.at > cutoff else { return .none }
        return .notifyNow(
            ContextualInterventionCandidate(
                kind: .caffeineCutoff,
                observedAt: latest.at,
                maximumAge: 6 * 60 * 60,
                fingerprint: latest.id.uuidString,
                title: String(localized: "Caffeine cutoff"),
                body: String(localized: "A logged intake falls inside your sleep cutoff window. Consider decaf or water from here."),
                route: .sleep
            )
        )
    }

    static func nextBedtime(
        after date: Date,
        bedtimeMinutes: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let minute = DailyReviewNotifications.clampMinute(bedtimeMinutes)
        var components = DateComponents()
        components.hour = minute / 60
        components.minute = minute % 60
        components.second = 0
        return calendar.nextDate(
            after: date.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

@MainActor
enum CaffeineCutoffReminders {
    static let cutoffEnabledKey = "noop.caffeine.cutoffNudge"
    static let bedtimeMinutesKey = "noop.caffeine.bedtimeMinutes"
    static let notificationsEnabledKey = "noop.caffeine.cutoffNotification"
    private static let requestID = "caffeine-cutoff-reminder"

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationsEnabledKey)
    }

    static func setNotificationsEnabled(
        _ on: Bool,
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int,
        completion: (@MainActor @Sendable (ContextualInterventionCenter.EnableOutcome) -> Void)? = nil
    ) {
        guard on else {
            UserDefaults.standard.set(false, forKey: notificationsEnabledKey)
            removeScheduled()
            completion?(.off)
            return
        }
        ContextualInterventionCenter.requestAuthorization { outcome in
            guard outcome == .enabled else {
                UserDefaults.standard.set(false, forKey: notificationsEnabledKey)
                completion?(outcome)
                return
            }
            UserDefaults.standard.set(true, forKey: notificationsEnabledKey)
            reconcile(intakes: intakes, bedtimeMinutes: bedtimeMinutes)
            completion?(.enabled)
        }
    }

    static func reconcile(
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        removeScheduled()
        guard notificationsEnabled,
              UserDefaults.standard.bool(forKey: cutoffEnabledKey) else { return }
        switch CaffeineReminderPolicy.plan(
            intakes: intakes,
            bedtimeMinutes: bedtimeMinutes,
            now: now,
            calendar: calendar
        ) {
        case .none:
            break
        case .notifyNow(let candidate):
            ContextualInterventionCenter.post(candidate, now: now)
        case .schedule(let fireDate):
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                let status = await center.notificationSettings().authorizationStatus
                guard isAuthorized(status), fireDate.timeIntervalSince(now) > 1 else { return }
                DailyReviewNotifications.registerPrivacyCategory(on: center)
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Caffeine cutoff")
                content.body = String(localized: "Your caffeine cutoff window starts now. Consider switching to decaf or water for tonight’s sleep.")
                content.sound = .default
                content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
                content.threadIdentifier = "noop.contextual.caffeine"
                content.userInfo = [
                    NotificationRouteBridge.userInfoKey: NoopNotificationRoute.sleep.rawValue
                ]
                let delay = max(1, fireDate.timeIntervalSince(now))
                try? await center.add(
                    UNNotificationRequest(
                        identifier: requestID,
                        content: content,
                        trigger: UNTimeIntervalNotificationTrigger(
                            timeInterval: delay,
                            repeats: false
                        )
                    )
                )
            }
        }
    }

    static func restoreIfAuthorized(
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int
    ) {
        guard notificationsEnabled else {
            removeScheduled()
            return
        }
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            guard isAuthorized(status) else { return }
            reconcile(intakes: intakes, bedtimeMinutes: bedtimeMinutes)
        }
    }

    static func removeScheduled() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

// MARK: - Timestamp-matched wrist motion

struct TimestampedWristMotionEvidence: Equatable, Sendable {
    let movementG: Double
    let observedAt: Date
    let sampleCount: Int

    func value(relativeTo eventDate: Date, maximumSkew: TimeInterval = 90) -> Double? {
        guard movementG.isFinite,
              abs(eventDate.timeIntervalSince(observedAt)) <= maximumSkew else { return nil }
        return movementG
    }
}

enum StressEvidencePolicy {
    static let maximumPhysiologyAge: TimeInterval = 15
    static let maximumRRBufferGap: TimeInterval = 30

    /// A rolling HRV window may span adjacent live packets, but never a transport gap or a clock jump.
    /// The first packet has no previous receipt and starts a new buffer naturally.
    static func shouldResetRRBuffer(
        previousReceivedAt: Date?,
        currentReceivedAt: Date
    ) -> Bool {
        guard let previousReceivedAt else { return false }
        let gap = currentReceivedAt.timeIntervalSince(previousReceivedAt)
        return gap < 0 || gap > maximumRRBufferGap
    }

    /// Return the contemporaneous wrist movement only when every source-level credibility gate passes.
    /// This runs before `StressOnsetDetector`, so an unencrypted/off-wrist/stale window cannot train its
    /// personal baseline, present an in-app check-in, post a notification, or request a band haptic.
    static func qualifiedMotion(
        now: Date,
        rrReceivedAt: Date?,
        heartRateReceivedAt: Date?,
        motion: TimestampedWristMotionEvidence?,
        connected: Bool,
        bonded: Bool,
        encryptedBond: Bool,
        worn: Bool
    ) -> Double? {
        guard connected, bonded, encryptedBond, worn,
              let rrReceivedAt,
              let heartRateReceivedAt,
              isFresh(rrReceivedAt, now: now),
              isFresh(heartRateReceivedAt, now: now)
        else { return nil }
        return motion?.value(relativeTo: rrReceivedAt)
    }

    private static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= maximumPhysiologyAge
    }
}

enum WristMotionEvidencePolicy {
    static let lookbackSeconds = 120
    static let maximumLatestAgeSeconds = 90
    static let maximumSampleGapSeconds = 10
    static let minimumSamples = 8
    static let minimumSpanSeconds = 10
    static let averagingWindowSeconds = 60

    /// Convert persisted gravity into a short movement estimate only when density and timestamps prove it
    /// overlaps the current physiological window. Sparse historical motion fails closed.
    static func derive(
        gravity: [GravitySample],
        nowSec: Int
    ) -> TimestampedWristMotionEvidence? {
        let rows = gravity
            .filter {
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                    && $0.ts <= nowSec + 5
                    && $0.ts >= nowSec - lookbackSeconds
            }
            .sorted { $0.ts < $1.ts }
        guard rows.count >= minimumSamples,
              let first = rows.first,
              let latest = rows.last,
              (0...maximumLatestAgeSeconds).contains(nowSec - latest.ts),
              latest.ts - first.ts >= minimumSpanSeconds else { return nil }
        guard !zip(rows, rows.dropFirst()).contains(where: {
            $1.ts - $0.ts > maximumSampleGapSeconds
        }) else { return nil }

        let recentStart = latest.ts - averagingWindowSeconds
        let recentRows = rows.filter { $0.ts >= recentStart }
        let intensities = WorkoutDetector.activitySeries(recentRows).dropFirst().map(\.intensity)
        guard !intensities.isEmpty else { return nil }
        let movement = intensities.reduce(0, +) / Double(intensities.count)
        guard movement.isFinite else { return nil }
        return TimestampedWristMotionEvidence(
            movementG: movement,
            observedAt: Date(timeIntervalSince1970: TimeInterval(latest.ts)),
            sampleCount: recentRows.count
        )
    }
}
