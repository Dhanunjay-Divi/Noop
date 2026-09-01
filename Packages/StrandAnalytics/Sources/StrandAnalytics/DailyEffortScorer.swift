import Foundation
import WhoopProtocol

/// Resolves one daily Effort value from cardiovascular load and low-intensity movement.
///
/// Edwards TRIMP intentionally contributes nothing below 50% heart-rate reserve. That is useful for
/// workout load, but it makes an otherwise active walking day read as zero. This kernel adds a
/// conservative movement floor without adding it to cardiovascular load:
///
/// - measured/calibrated steps are converted to walking minutes at 100 steps/minute;
/// - each walking minute receives one quarter of Edwards zone 1's weight;
/// - the resulting low-intensity TRIMP uses the same logarithmic 0...100 map as cardiovascular Effort;
/// - the final score is `max(cardio, movement)`, so workout steps are not counted twice.
///
/// When a step counter is unavailable, dense-enough wrist gravity can provide a conservative fallback.
/// Missing movement leaves the cardiovascular score byte-identical. This is an approximate activity-load
/// model, not a reproduction of any proprietary wearable score.
public enum DailyEffortScorer {
    /// Common cadence reference for purposeful walking.
    public static let walkingCadenceStepsPerMinute: Double = 100
    /// Sub-zone movement gets one quarter of the lowest Edwards zone weight.
    public static let lightMovementWeight: Double = 0.25
    /// Sustained walking is approximately 0.2...0.4 g on the existing NOOP wrist-motion feature.
    public static let walkingMotionThresholdG: Double = 0.15
    /// Do not infer activity across a telemetry hole longer than two minutes.
    public static let maximumMotionEvidenceGapSeconds: Double = 120
    /// One motion observation may represent at most one minute of activity.
    public static let maximumCreditedMotionSeconds: Double = 60

    /// Resolve daily Effort. A real movement score may stand alone when HR coverage is insufficient.
    public static func score(
        cardioEffort: Double?,
        steps: Int?,
        gravity: [GravitySample] = []
    ) -> Double? {
        guard let movement = movementEffort(steps: steps, gravity: gravity) else {
            return cardioEffort
        }
        guard let cardioEffort else { return movement }
        return max(cardioEffort, movement)
    }

    /// Prefer calibrated steps; fall back to measured wrist movement only when steps are unavailable.
    public static func movementEffort(
        steps: Int?,
        gravity: [GravitySample] = []
    ) -> Double? {
        if let steps, steps > 0 {
            return movementEffort(steps: steps)
        }
        guard let minutes = activeMotionMinutes(gravity), minutes > 0 else { return nil }
        return movementEffort(minutes: minutes)
    }

    /// Low-intensity movement floor from a measured/calibrated daily step total.
    public static func movementEffort(steps: Int) -> Double? {
        guard steps > 0 else { return nil }
        return movementEffort(minutes: Double(steps) / walkingCadenceStepsPerMinute)
    }

    /// Walking-level minutes represented by adjacent gravity records, or nil without usable evidence.
    public static func activeMotionMinutes(_ gravity: [GravitySample]) -> Double? {
        let rows = gravity
            .filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
            .sorted { $0.ts < $1.ts }
        guard rows.count >= 2 else { return nil }

        var activeSeconds = 0.0
        for index in 1..<rows.count {
            let previous = rows[index - 1]
            let current = rows[index]
            let gap = Double(current.ts) - Double(previous.ts)
            guard gap > 0, gap <= maximumMotionEvidenceGapSeconds else { continue }

            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let dz = current.z - previous.z
            let intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            if intensity >= walkingMotionThresholdG {
                activeSeconds += min(gap, maximumCreditedMotionSeconds)
            }
        }
        return activeSeconds > 0 ? activeSeconds / 60 : nil
    }

    private static func movementEffort(minutes: Double) -> Double? {
        guard minutes.isFinite, minutes > 0 else { return nil }
        let lowIntensityTRIMP = minutes * lightMovementWeight
        return min(
            StrainScorer.maxStrain,
            StrainScorer.trimpToStrain(lowIntensityTRIMP)
        )
    }
}
