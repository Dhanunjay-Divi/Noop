import Foundation

/// Describes where today's measured Effort sits relative to an evidence-gated personal range.
///
/// This is presentation state, not a training prescription. Invalid or missing inputs fail closed so
/// callers never turn a guessed score or range into guidance.
public enum DailyEffortGuidance {
    public enum State: String, Equatable, Sendable, Codable {
        case unavailable
        case belowRange
        case inRange
        case aboveRange
    }

    public struct Result: Equatable, Sendable {
        public let state: State
        public let current: Double?
        public let range: DailyActionPlanner.EffortRange?
        public let remainingToLower: Double?
        /// Current Effort normalized to NOOP's canonical 0...100 axis.
        public let progress: Double

        public init(
            state: State,
            current: Double?,
            range: DailyActionPlanner.EffortRange?,
            remainingToLower: Double?,
            progress: Double
        ) {
            self.state = state
            self.current = current
            self.range = range
            self.remainingToLower = remainingToLower
            self.progress = progress
        }
    }

    public static func evaluate(
        currentEffort: Double?,
        range: DailyActionPlanner.EffortRange?
    ) -> Result {
        guard let currentEffort,
              currentEffort.isFinite,
              (0...100).contains(currentEffort),
              let range,
              (0...100).contains(range.lower),
              (0...100).contains(range.upper),
              range.lower <= range.upper else {
            return Result(
                state: .unavailable,
                current: nil,
                range: nil,
                remainingToLower: nil,
                progress: 0
            )
        }

        let state: State
        if currentEffort < Double(range.lower) {
            state = .belowRange
        } else if currentEffort <= Double(range.upper) {
            state = .inRange
        } else {
            state = .aboveRange
        }

        return Result(
            state: state,
            current: currentEffort,
            range: range,
            remainingToLower: max(0, Double(range.lower) - currentEffort),
            progress: currentEffort / 100
        )
    }
}
