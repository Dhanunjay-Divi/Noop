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

        public init(
            day: String,
            availability: Availability,
            target: EffortRange?,
            confidence: ScoreConfidence,
            action: Action,
            evidence: [Evidence],
            limitations: [String]
        ) {
            self.day = day
            self.availability = availability
            self.target = target
            self.confidence = confidence
            self.action = action
            self.evidence = evidence
            self.limitations = limitations
        }
    }

    public static let historyWindowDays = 28
    public static let minimumEffortDays = 7
    public static let solidEffortDays = 14
    public static let extraSleepActionThresholdMinutes = 30

    private static let planningLimitation =
        "This is a personal planning range, not a safety limit, diagnosis, or medical clearance."

    public static func plan(
        today: String,
        readiness: ReadinessEngine.Readiness,
        checkIn: CheckIn,
        recentEffort: [EffortDay],
        sleepRecoveryMinutes: Int = 0,
        sleepConfidence: ScoreConfidence = .calibrating
    ) -> Plan {
        let selfEvidence = Evidence(source: .selfCheck, detail: checkIn.rawValue)

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
                limitations: [planningLimitation, "A same-day self-check is required before showing a range."]
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
                limitations: [planningLimitation, "How you feel takes priority over an aligned wearable read."]
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
                limitations: [planningLimitation, "No current readiness read is available for this date."]
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
                limitations: [planningLimitation, "A measured recovery shift withholds the range; it does not diagnose a cause."]
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
                limitations: [planningLimitation, "At least two current signals and a trusted personal baseline are required."]
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
                limitations: [planningLimitation, "At least \(minimumEffortDays) prior scored Effort days are required."]
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
            ]
        )
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
