import Foundation

enum ActionableWellnessPolicy {
    static let breathingDurationSeconds = 60
    static let movementDurationSeconds = 120

    static func elapsedSeconds(
        startedAtUptime: TimeInterval,
        nowUptime: TimeInterval
    ) -> Int {
        Int(max(0, nowUptime - startedAtUptime).rounded(.down))
    }

    static func shouldCompleteBreathingSession(
        isOneMinuteSession: Bool,
        elapsedSeconds: Int
    ) -> Bool {
        isOneMinuteSession &&
            elapsedSeconds >= breathingDurationSeconds
    }

    static func movementRemainingSeconds(afterTick remainingSeconds: Int) -> Int {
        max(0, remainingSeconds - 1)
    }

    static func movementRemainingSeconds(
        startedAtUptime: TimeInterval,
        nowUptime: TimeInterval
    ) -> Int {
        max(
            0,
            movementDurationSeconds - elapsedSeconds(
                startedAtUptime: startedAtUptime,
                nowUptime: nowUptime
            )
        )
    }

    static func movementProgress(remainingSeconds: Int) -> Double {
        let boundedRemaining = min(
            max(remainingSeconds, 0),
            movementDurationSeconds
        )
        return Double(movementDurationSeconds - boundedRemaining) /
            Double(movementDurationSeconds)
    }
}
