import Foundation

/// A conservative, explainable daily planning contract.
///
/// The planner does not turn a wearable score into permission to train. A numeric range is shown only
/// when a same-day self-check is answered "as usual", at least two baseline-relative recovery signals
/// support a solid readiness read, and the user has enough prior scored Effort days to describe their
/// own normal range. "Primed" never raises the range; readiness is a confidence gate, not a load bonus.
public enum DailyActionPlanner {
    public enum CheckIn: String, Equatable, Sendable, Codable {
        case unanswered
        case asUsual
        case belowUsual
        case painOrUnwell
    }

    public enum Availability: String, Equatable, Sendable, Codable {
        case ready
        case checkInNeeded
        case calibrating
        case recoveryShift
        case stop
    }

    public enum Action: String, Equatable, Sendable, Codable {
        case completeCheckIn
        case keepSleepWindow
        case protectExtraSleep
        case chooseEasyDay
        case stopAndAssess
    }

    public enum EvidenceSource: String, Equatable, Sendable, Codable {
        case selfCheck
        case readinessBaseline
        case personalEffortHistory
        case sleepPlan
    }

    public struct EffortDay: Equatable, Sendable {
        public let day: String
        public let effort: Double?

        public init(day: String, effort: Double?) {
            self.day = day
            self.effort = effort
        }
    }

    public struct SleepDay: Equatable, Sendable {
        public let day: String
        public let minutes: Double?
        public let observedAtSec: Int?
        public let observedSessionDurationMinutes: Double?

        public init(
            day: String,
            minutes: Double?,
            observedAtSec: Int? = nil,
            observedSessionDurationMinutes: Double? = nil
        ) {
            self.day = day
            self.minutes = minutes
            self.observedAtSec = observedAtSec
            self.observedSessionDurationMinutes = observedSessionDurationMinutes
        }
    }

    public struct PlannedWorkout: Equatable, Sendable {
        public let day: String
        public let startSec: Int
        public let endSec: Int

        public init(day: String, startSec: Int, endSec: Int) {
            self.day = day
            self.startSec = startSec
            self.endSec = endSec
        }
    }

    public enum WorkoutAdjustmentReason: String, Equatable, Sendable, Codable {
        case sleepDeficit
        case recoveryShift
        case sleepAndRecovery
    }

    public enum SleepReference: String, Equatable, Sendable, Codable {
        case personalUsual
        case explicitTarget
    }

    public struct WorkoutAdjustment: Equatable, Sendable {
        public let startSec: Int
        public let durationMinutes: Int
        public let reason: WorkoutAdjustmentReason
        public let measuredSleepMinutes: Int?
        public let referenceSleepMinutes: Int?
        public let sleepDeficitMinutes: Int?
        public let sleepReference: SleepReference?
        public let confidence: ScoreConfidence

        public init(
            startSec: Int,
            durationMinutes: Int,
            reason: WorkoutAdjustmentReason,
            measuredSleepMinutes: Int?,
            referenceSleepMinutes: Int?,
            sleepDeficitMinutes: Int?,
            sleepReference: SleepReference?,
            confidence: ScoreConfidence
        ) {
            self.startSec = startSec
            self.durationMinutes = durationMinutes
            self.reason = reason
            self.measuredSleepMinutes = measuredSleepMinutes
            self.referenceSleepMinutes = referenceSleepMinutes
            self.sleepDeficitMinutes = sleepDeficitMinutes
            self.sleepReference = sleepReference
            self.confidence = confidence
        }
    }

    public struct EffortRange: Equatable, Sendable {
        public let lower: Int
        public let upper: Int

        public init(lower: Int, upper: Int) {
            self.lower = lower
            self.upper = upper
        }
    }

    public struct Evidence: Equatable, Sendable {
        public let source: EvidenceSource
        public let detail: String

        public init(source: EvidenceSource, detail: String) {
            self.source = source
            self.detail = detail
        }
    }

    public struct Plan: Equatable, Sendable {
        public let day: String
        public let availability: Availability
        /// Personal planning range on NOOP's canonical 0–100 Effort scale.
        public let target: EffortRange?
        public let confidence: ScoreConfidence
        public let action: Action
        public let evidence: [Evidence]
        public let limitations: [String]
        public let workoutAdjustment: WorkoutAdjustment?

        public init(
            day: String,
            availability: Availability,
            target: EffortRange?,
            confidence: ScoreConfidence,
            action: Action,
            evidence: [Evidence],
            limitations: [String],
            workoutAdjustment: WorkoutAdjustment? = nil
        ) {
            self.day = day
            self.availability = availability
            self.target = target
            self.confidence = confidence
            self.action = action
            self.evidence = evidence
            self.limitations = limitations
            self.workoutAdjustment = workoutAdjustment
        }
    }

    public static let historyWindowDays = 28
    public static let minimumEffortDays = 7
    public static let solidEffortDays = 14
    public static let extraSleepActionThresholdMinutes = 30
    public static let sleepHistoryWindowDays = 21
    public static let minimumUsualSleepNights = 5
    public static let solidUsualSleepNights = 7
    public static let workoutSleepDeficitThresholdMinutes = 45
    public static let currentSleepMaximumAgeSeconds = 30 * 60 * 60
    public static let minimumMatchedSleepSessionMinutes = 3 * 60
    public static let maximumMatchedSleepSessionMinutes = 14 * 60
    public static let aggregateSessionRoundingToleranceMinutes = 15
    public static let maximumSessionExcessMinutes = 3 * 60
    public static let minimumPlannedWorkoutMinutes = 10
    public static let maximumPlannedWorkoutMinutes = 6 * 60
    // A same-civil-day workout can be up to 25 elapsed hours away across a DST fall-back day.
    public static let maximumPlannedWorkoutLeadSeconds = 25 * 60 * 60

    private static let planningLimitation =
        "This is a personal planning range, not a safety limit, diagnosis, or medical clearance."

    /// Associate a daily asleep-minute aggregate with one fresh session without accepting a short nap as
    /// proof that an unrelated aggregate is current. Missing, stale, or implausibly different evidence
    /// fails closed; callers remain responsible for same-day/source selection.
    public static func matchedSleepObservationEndSec(
        aggregateMinutes: Double?,
        sessionDurationMinutes: Double?,
        sessionEndSec: Int?,
        nowSec: Int,
        maximumAgeSeconds: Int = currentSleepMaximumAgeSeconds
    ) -> Int? {
        guard let aggregateMinutes,
              aggregateMinutes.isFinite,
              (120...900).contains(aggregateMinutes),
              let sessionDurationMinutes,
              sessionDurationMinutes.isFinite,
              sessionDurationMinutes >= Double(minimumMatchedSleepSessionMinutes),
              sessionDurationMinutes <= Double(maximumMatchedSleepSessionMinutes),
              let sessionEndSec,
              (-5 * 60...maximumAgeSeconds).contains(nowSec - sessionEndSec),
              aggregateMinutes <= sessionDurationMinutes
                  + Double(aggregateSessionRoundingToleranceMinutes),
              sessionDurationMinutes <= aggregateMinutes
                  + Double(maximumSessionExcessMinutes)
        else { return nil }
        return sessionEndSec
    }

    public static func plan(
        today: String,
        readiness: ReadinessEngine.Readiness,
        checkIn: CheckIn,
        recentEffort: [EffortDay],
        sleepRecoveryMinutes: Int = 0,
        sleepConfidence: ScoreConfidence = .calibrating,
        recentSleep: [SleepDay] = [],
        sleepTargetMinutes: Int = 8 * 60,
        sleepTargetIsExplicit: Bool = false,
        plannedWorkout: PlannedWorkout? = nil,
        nowSec: Int = Int(Date().timeIntervalSince1970)
    ) -> Plan {
        let selfEvidence = Evidence(source: .selfCheck, detail: checkIn.rawValue)
        let plannedAdjustment = workoutAdjustment(
            today: today,
            nowSec: nowSec,
            readiness: readiness,
            recentSleep: recentSleep,
            sleepTargetMinutes: sleepTargetMinutes,
            sleepTargetIsExplicit: sleepTargetIsExplicit,
            plannedWorkout: plannedWorkout
        )

        if checkIn == .painOrUnwell {
            return Plan(
                day: today,
                availability: .stop,
                target: nil,
                confidence: .calibrating,
                action: .stopAndAssess,
                evidence: [selfEvidence],
                limitations: [planningLimitation, "A symptom or pain check-in always overrides wearable data."]
            )
        }

        if checkIn == .unanswered {
            return Plan(
                day: today,
                availability: .checkInNeeded,
                target: nil,
                confidence: .calibrating,
                action: .completeCheckIn,
                evidence: [],
                limitations: [planningLimitation, "A same-day self-check is required before showing a range."],
                workoutAdjustment: plannedAdjustment
            )
        }

        if checkIn == .belowUsual {
            return Plan(
                day: today,
                availability: .recoveryShift,
                target: nil,
                confidence: .calibrating,
                action: .chooseEasyDay,
                evidence: [selfEvidence],
                limitations: [planningLimitation, "How you feel takes priority over an aligned wearable read."],
                workoutAdjustment: plannedAdjustment
            )
        }

        guard readiness.asOfDay == today else {
            return Plan(
                day: today,
                availability: .calibrating,
                target: nil,
                confidence: .calibrating,
                action: .keepSleepWindow,
                evidence: [selfEvidence],
                limitations: [planningLimitation, "No current readiness read is available for this date."],
                workoutAdjustment: plannedAdjustment
            )
        }

        let recoverySignals = readiness.signals.filter {
            $0.key == "hrv" || $0.key == "rhr" || $0.key == "respRate"
        }
        let readinessEvidence = Evidence(
            source: .readinessBaseline,
            detail: "\(recoverySignals.count) current signals, \(readiness.baselineDays) prior days"
        )

        if readiness.level == .strained || readiness.level == .rundown {
            return Plan(
                day: today,
                availability: .recoveryShift,
                target: nil,
                confidence: readiness.confidence,
                action: .chooseEasyDay,
                evidence: [selfEvidence, readinessEvidence],
                limitations: [planningLimitation, "A measured recovery shift withholds the range; it does not diagnose a cause."],
                workoutAdjustment: plannedAdjustment
            )
        }

        guard readiness.confidence == .solid,
              readiness.level == .balanced || readiness.level == .primed else {
            return Plan(
                day: today,
                availability: .calibrating,
                target: nil,
                confidence: readiness.confidence,
                action: .keepSleepWindow,
                evidence: [selfEvidence, readinessEvidence],
                limitations: [planningLimitation, "At least two current signals and a trusted personal baseline are required."],
                workoutAdjustment: plannedAdjustment
            )
        }

        let values = effortValues(in: recentEffort, before: today)
        let effortEvidence = Evidence(
            source: .personalEffortHistory,
            detail: "\(values.count) scored days in the prior \(historyWindowDays) days"
        )
        guard values.count >= minimumEffortDays, let target = planningRange(values) else {
            return Plan(
                day: today,
                availability: .calibrating,
                target: nil,
                confidence: .calibrating,
                action: .keepSleepWindow,
                evidence: [selfEvidence, readinessEvidence, effortEvidence],
                limitations: [planningLimitation, "At least \(minimumEffortDays) prior scored Effort days are required."],
                workoutAdjustment: plannedAdjustment
            )
        }

        let boundedSleepRecovery = min(60, max(0, sleepRecoveryMinutes))
        let hasSupportedExtraSleep =
            boundedSleepRecovery >= extraSleepActionThresholdMinutes && sleepConfidence != .calibrating
        var evidence = [selfEvidence, readinessEvidence, effortEvidence]
        if hasSupportedExtraSleep {
            evidence.append(Evidence(
                source: .sleepPlan,
                detail: "\(boundedSleepRecovery) min recovery addition"
            ))
        }

        return Plan(
            day: today,
            availability: .ready,
            target: target,
            confidence: values.count >= solidEffortDays ? .solid : .building,
            action: hasSupportedExtraSleep ? .protectExtraSleep : .keepSleepWindow,
            evidence: evidence,
            limitations: [
                planningLimitation,
                "Aligned readiness never raises the range above the user's recent normal Effort."
            ],
            workoutAdjustment: plannedAdjustment
        )
    }

    static func workoutAdjustment(
        today: String,
        nowSec: Int,
        readiness: ReadinessEngine.Readiness,
        recentSleep: [SleepDay],
        sleepTargetMinutes: Int,
        sleepTargetIsExplicit: Bool,
        plannedWorkout: PlannedWorkout?
    ) -> WorkoutAdjustment? {
        guard let workout = plannedWorkout,
              workout.day == today,
              workout.startSec > nowSec,
              workout.startSec - nowSec <= maximumPlannedWorkoutLeadSeconds,
              workout.endSec > workout.startSec else { return nil }

        let durationMinutes = (workout.endSec - workout.startSec) / 60
        guard (minimumPlannedWorkoutMinutes...maximumPlannedWorkoutMinutes)
            .contains(durationMinutes) else { return nil }

        let sleep = sleepContext(
            days: recentSleep,
            today: today,
            nowSec: nowSec,
            sleepTargetMinutes: sleepTargetMinutes,
            sleepTargetIsExplicit: sleepTargetIsExplicit
        )
        let recoveryShift =
            readiness.asOfDay == today
            && readiness.confidence != .calibrating
            && (readiness.level == .strained || readiness.level == .rundown)
        guard sleep != nil || recoveryShift else { return nil }

        let reason: WorkoutAdjustmentReason
        switch (sleep != nil, recoveryShift) {
        case (true, true): reason = .sleepAndRecovery
        case (true, false): reason = .sleepDeficit
        case (false, true): reason = .recoveryShift
        case (false, false): return nil
        }

        let confidence: ScoreConfidence = {
            guard let sleep else {
                return readiness.confidence == .solid ? .solid : .building
            }
            guard recoveryShift else { return sleep.confidence }
            return sleep.confidence == .solid && readiness.confidence == .solid
                ? .solid
                : .building
        }()

        return WorkoutAdjustment(
            startSec: workout.startSec,
            durationMinutes: durationMinutes,
            reason: reason,
            measuredSleepMinutes: sleep?.measuredMinutes,
            referenceSleepMinutes: sleep?.referenceMinutes,
            sleepDeficitMinutes: sleep?.deficitMinutes,
            sleepReference: sleep?.reference,
            confidence: confidence
        )
    }

    private struct SleepContext {
        let measuredMinutes: Int
        let referenceMinutes: Int
        let deficitMinutes: Int
        let reference: SleepReference
        let confidence: ScoreConfidence
    }

    private static func sleepContext(
        days: [SleepDay],
        today: String,
        nowSec: Int,
        sleepTargetMinutes: Int,
        sleepTargetIsExplicit: Bool
    ) -> SleepContext? {
        let grouped = validSleepByDay(days, through: today)
        let currentValues = days.compactMap { row -> Double? in
            guard row.day == today,
                  let minutes = row.minutes,
                  matchedSleepObservationEndSec(
                      aggregateMinutes: minutes,
                      sessionDurationMinutes: row.observedSessionDurationMinutes,
                      sessionEndSec: row.observedAtSec,
                      nowSec: nowSec
                  ) != nil else { return nil }
            return minutes
        }
        guard !currentValues.isEmpty else { return nil }
        let current = currentValues.reduce(0, +) / Double(currentValues.count)

        let prior = grouped
            .filter { $0.key < today }
            .keys
            .sorted()
            .suffix(sleepHistoryWindowDays)
            .compactMap { grouped[$0] }
        let reference: Double
        let source: SleepReference
        let confidence: ScoreConfidence
        if prior.count >= minimumUsualSleepNights {
            reference = quantile(prior.sorted(), 0.5)
            source = .personalUsual
            confidence = prior.count >= solidUsualSleepNights ? .solid : .building
        } else {
            guard sleepTargetIsExplicit else { return nil }
            reference = Double(min(max(sleepTargetMinutes, 5 * 60), 11 * 60))
            source = .explicitTarget
            confidence = .building
        }
        let deficit = Int((reference - current).rounded())
        guard deficit >= workoutSleepDeficitThresholdMinutes else { return nil }
        return SleepContext(
            measuredMinutes: Int(current.rounded()),
            referenceMinutes: Int(reference.rounded()),
            deficitMinutes: deficit,
            reference: source,
            confidence: confidence
        )
    }

    private static func validSleepByDay(
        _ days: [SleepDay],
        through today: String
    ) -> [String: Double] {
        let formatter = isoFormatter()
        guard let end = formatter.date(from: today),
              formatter.string(from: end) == today,
              let start = formatter.calendar.date(
                byAdding: .day,
                value: -sleepHistoryWindowDays,
                to: end
              ) else { return [:] }
        let startDay = formatter.string(from: start)
        var grouped: [String: [Double]] = [:]
        for row in days where row.day >= startDay && row.day <= today {
            guard let parsed = formatter.date(from: row.day),
                  formatter.string(from: parsed) == row.day,
                  let minutes = row.minutes,
                  minutes.isFinite,
                  (120...900).contains(minutes) else { continue }
            grouped[row.day, default: []].append(minutes)
        }
        return grouped.mapValues { values in
            values.reduce(0, +) / Double(values.count)
        }
    }

    /// One deterministic value per prior calendar day in [today-28, today-1]. Duplicate rows are
    /// averaged so input ordering cannot change the plan. Invalid dates and out-of-scale values are ignored.
    static func effortValues(in days: [EffortDay], before today: String) -> [Double] {
        let formatter = isoFormatter()
        guard let end = formatter.date(from: today),
              formatter.string(from: end) == today,
              let start = formatter.calendar.date(byAdding: .day, value: -historyWindowDays, to: end) else {
            return []
        }
        let startDay = formatter.string(from: start)
        var grouped: [String: [Double]] = [:]
        for row in days where row.day >= startDay && row.day < today {
            guard let parsed = formatter.date(from: row.day),
                  formatter.string(from: parsed) == row.day,
                  let effort = row.effort,
                  effort.isFinite,
                  (0...100).contains(effort) else { continue }
            grouped[row.day, default: []].append(effort)
        }
        return grouped.keys.sorted().compactMap { day in
            guard let values = grouped[day], !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    static func planningRange(_ values: [Double]) -> EffortRange? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        var lower = Int(floor(quantile(sorted, 0.25) / 5.0) * 5.0)
        var upper = Int(ceil(quantile(sorted, 0.75) / 5.0) * 5.0)
        if upper - lower < 10 {
            let center = quantile(sorted, 0.5)
            lower = Int(floor((center - 5.0) / 5.0) * 5.0)
            upper = Int(ceil((center + 5.0) / 5.0) * 5.0)
        }
        lower = min(100, max(0, lower))
        upper = min(100, max(0, upper))
        if upper - lower < 10 {
            if lower == 0 {
                upper = min(100, lower + 10)
            } else if upper == 100 {
                lower = max(0, upper - 10)
            } else {
                upper = min(100, lower + 10)
            }
        }
        return EffortRange(lower: lower, upper: upper)
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = min(1, max(0, q)) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    private static func isoFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
