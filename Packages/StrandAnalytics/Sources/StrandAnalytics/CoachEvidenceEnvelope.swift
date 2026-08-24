import Foundation

/// Typed, bounded grounding for AI coaching. The rendered block keeps observations, planning cues,
/// missing evidence, and nutrition logs separate so a model is not invited to turn a wellness estimate
/// into clearance or to invent diet facts.
public enum CoachEvidenceEnvelope {
    public struct MetricObservation: Equatable, Sendable {
        public let day: String
        public let value: Double?

        public init(day: String, value: Double?) {
            self.day = day
            self.value = value
        }
    }

    public struct MetricCoverage: Equatable, Sendable {
        public let label: String
        public let observedDays: Int
        public let windowDays: Int
        public let latestDay: String?

        public init(label: String, observedDays: Int, windowDays: Int, latestDay: String?) {
            let boundedWindow = max(1, windowDays)
            self.label = label
            self.observedDays = min(max(0, observedDays), boundedWindow)
            self.windowDays = boundedWindow
            self.latestDay = latestDay.flatMap { validDay($0) ? $0 : nil }
        }
    }

    public enum NutritionSourceMix: String, Equatable, Sendable {
        case manual
        case imported
        case mixed
    }

    public struct NutritionEvidence: Equatable, Sendable {
        public let observedDays: Int
        public let windowDays: Int
        public let latestDay: String
        public let caloriesKcal: Double?
        public let proteinG: Double?
        public let carbsG: Double?
        public let fatG: Double?
        public let sourceMix: NutritionSourceMix
        public let explicitGoal: String?

        public init(
            observedDays: Int,
            windowDays: Int,
            latestDay: String,
            caloriesKcal: Double?,
            proteinG: Double?,
            carbsG: Double?,
            fatG: Double?,
            sourceMix: NutritionSourceMix,
            explicitGoal: String? = nil
        ) {
            let boundedWindow = max(1, windowDays)
            self.observedDays = min(max(0, observedDays), boundedWindow)
            self.windowDays = boundedWindow
            self.latestDay = Self.validDay(latestDay) ? latestDay : "unknown"
            self.caloriesKcal = Self.valid(caloriesKcal)
            self.proteinG = Self.valid(proteinG)
            self.carbsG = Self.valid(carbsG)
            self.fatG = Self.valid(fatG)
            self.sourceMix = sourceMix
            self.explicitGoal = explicitGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }

        private static func validDay(_ value: String) -> Bool {
            CoachEvidenceEnvelope.validDay(value)
        }
    }

    public enum NutritionAvailability: Equatable, Sendable {
        case unavailable
        case noEntries
        case observed(NutritionEvidence)
    }

    public struct Input: Equatable, Sendable {
        public let day: String
        public let plan: DailyActionPlanner.Plan
        public let currentEffort: Double?
        public let coverage: [MetricCoverage]
        public let nutrition: NutritionAvailability

        public init(
            day: String,
            plan: DailyActionPlanner.Plan,
            currentEffort: Double?,
            coverage: [MetricCoverage],
            nutrition: NutritionAvailability
        ) {
            self.day = day
            self.plan = plan
            self.currentEffort = currentEffort
            self.coverage = coverage
            self.nutrition = nutrition
        }
    }

    /// Counts distinct, finite observation days inside an inclusive calendar window ending on
    /// `through`. Duplicate rows and rows outside the window cannot inflate the stated coverage.
    public static func metricCoverage(
        label: String,
        through day: String,
        windowDays: Int,
        observations: [MetricObservation]
    ) -> MetricCoverage {
        let boundedWindow = max(1, windowDays)
        guard let end = parseDay(day),
              let start = dayCalendar.date(
                byAdding: .day,
                value: 1 - boundedWindow,
                to: end
              ) else {
            return .init(
                label: label,
                observedDays: 0,
                windowDays: boundedWindow,
                latestDay: nil
            )
        }

        let observed = Set(observations.compactMap { observation -> String? in
            guard let value = observation.value,
                  value.isFinite,
                  let date = parseDay(observation.day),
                  date >= start,
                  date <= end else { return nil }
            return observation.day
        })
        return .init(
            label: label,
            observedDays: observed.count,
            windowDays: boundedWindow,
            latestDay: observed.max()
        )
    }

    public static func render(_ input: Input) -> String {
        let guidance = DailyEffortGuidance.evaluate(
            currentEffort: input.currentEffort,
            range: input.plan.target
        )
        var lines = [
            "COACH EVIDENCE ENVELOPE:",
            "OBSERVED FACTS:",
        ]

        if let current = guidance.current {
            lines.append("- Current Effort for \(input.day): \(oneDecimal(current)) / 100.")
        } else {
            lines.append("- Current Effort for \(input.day): unavailable.")
        }
        for row in input.coverage where row.observedDays > 0 {
            let latest = row.latestDay.map { ", latest \($0)" } ?? ""
            lines.append(
                "- \(row.label) coverage: \(row.observedDays)/\(row.windowDays) stored days\(latest)."
            )
        }

        lines.append("PLANNING CUE:")
        lines.append(
            "- Daily plan state: \(input.plan.availability.rawValue); confidence "
                + "\(input.plan.confidence.rawValue); suggested action \(input.plan.action.rawValue)."
        )
        if let range = input.plan.target {
            lines.append(
                "- Personal Effort range: \(range.lower)-\(range.upper) / 100; progress state "
                    + "\(guidance.state.rawValue). This is a planning cue, not clearance or a limit."
            )
        } else {
            lines.append(
                "- No personal Effort range is available. Do not invent one or infer permission to train."
            )
        }
        if !input.plan.evidence.isEmpty {
            let evidence = input.plan.evidence
                .map { "\($0.source.rawValue): \($0.detail)" }
                .joined(separator: "; ")
            lines.append("- Planner evidence: \(evidence).")
        }

        lines.append("NUTRITION LOG EVIDENCE:")
        switch input.nutrition {
        case .observed(let nutrition) where nutrition.observedDays > 0:
            lines.append(
                "- Logged on \(nutrition.observedDays)/\(nutrition.windowDays) days; latest "
                    + "\(nutrition.latestDay); source mix \(nutrition.sourceMix.rawValue)."
            )
            let values: [String] = [
                nutrition.caloriesKcal.map { "calories \(oneDecimal($0)) kcal" },
                nutrition.proteinG.map { "protein \(oneDecimal($0)) g" },
                nutrition.carbsG.map { "carbs \(oneDecimal($0)) g" },
                nutrition.fatG.map { "fat \(oneDecimal($0)) g" },
            ].compactMap { $0 }
            lines.append(
                values.isEmpty
                    ? "- The latest logged day has no numeric nutrient totals."
                    : "- Latest logged totals: \(values.joined(separator: ", "))."
            )
            if let goal = nutrition.explicitGoal, !goal.isEmpty {
                lines.append("- User-stated nutrition goal (quoted data): \"\(safeUserText(goal))\"")
            } else {
                lines.append("- No explicit nutrition goal is recorded.")
            }
        case .noEntries, .observed:
            lines.append(
                "- No nutrition entries are available in the review window. Do not infer intake."
            )
            lines.append("- No explicit nutrition goal is recorded.")
        case .unavailable:
            lines.append(
                "- Nutrition log availability is unknown because the local read did not complete. "
                    + "Do not describe this as an empty log or infer intake."
            )
            lines.append("- Nutrition goal availability is also unknown.")
        }

        lines += [
            "EVIDENCE LIMITS:",
            "- Missing values are unknown, not zero. Do not invent values, causes, targets, or trends.",
            "- Wearable scores and ranges are wellness estimates, not diagnosis, treatment, safety limits, or training clearance.",
            "- Logged food may be incomplete. Give personalized diet changes only from explicit logged intake plus a user-stated goal, and state coverage.",
            "- Do not recommend medication changes or diagnose deficiency. Do not prescribe supplements; refer individualized clinical nutrition questions to a qualified professional.",
            "- Label personal correlations as associations, not causes.",
        ]
        return lines.joined(separator: "\n")
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static let dayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func parseDay(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = dayCalendar.date(from: DateComponents(
                calendar: dayCalendar,
                timeZone: dayCalendar.timeZone,
                year: year,
                month: month,
                day: day
              )) else { return nil }
        let components = dayCalendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year,
              components.month == month,
              components.day == day else { return nil }
        return date
    }

    private static func validDay(_ value: String) -> Bool {
        parseDay(value) != nil
    }

    private static func safeUserText(_ value: String) -> String {
        value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .replacingOccurrences(of: "\"", with: "'")
            .prefix(500)
            .description
    }
}
