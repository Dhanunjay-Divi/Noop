import Foundation
import WhoopProtocol

/// Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
/// total (`AnalyticsEngine.analyzeDay`) and any windowed total (a manual workout's `[start, end]`, #398).
///
/// `step_motion_counter@57` is a CUMULATIVE u16 running counter: it climbs while you move, holds flat when
/// still, and wraps at 65536. The number of motion ticks over a set of time-ordered records is the SUM of
/// WRAP-AWARE increments of that counter — `delta = (cur - prev) & 0xFFFF` — with a per-user
/// `stepTicksPerStep` calibration applied by the caller AFTERWARDS (this returns the raw pre-calibration
/// tick total, so the two callers can never disagree on the counter math). The raw total is an ESTIMATE
/// (@57 counts motion ticks, not validated steps), not cloud/clinical parity.
///
/// Kept in lockstep with the Kotlin twin `StepsCounter`.
public enum StepsCounter {
    /// The largest wrap-aware increment treated as real motion between two adjacent 1 Hz records. A delta
    /// at/above this is a big time-gap / disconnect boundary between sync sessions (or a firmware reboot,
    /// byte-indistinguishable from a u16 wrap), NOT real steps — dropped so gaps don't inflate the total.
    /// Real 1 Hz motion never ticks this fast between adjacent records. (#132/#276/#316)
    public static let maxStepDelta = 512

    public struct Analysis: Equatable, Sendable {
        public enum FilterMode: String, Equatable, Sendable {
            /// No activity-class evidence exists anywhere in the window, so preserve the legacy raw-motion
            /// estimate for older persisted rows.
            case legacyRawMotion

            /// At least one sample has activity-class evidence. Only deltas whose later sample is walk (1)
            /// or run (2) are retained.
            case activityClassFiltered
        }

        public let filterMode: FilterMode
        public let sampleCount: Int
        public let deltaCount: Int
        public let keptDeltaCount: Int
        public let rejectedStillDeltaCount: Int
        public let rejectedUnknownDeltaCount: Int
        public let rejectedGapDeltaCount: Int
        public let zeroDeltaCount: Int
        public let rawTicks: Int

        /// Compatibility value used by existing callers: no retained movement remains missing, not zero.
        public var steps: Int? {
            rawTicks > 0 ? rawTicks : nil
        }
    }

    /// Pure analysis of a counter window. Deltas remain wrap-aware and the `maxStepDelta` boundary is
    /// applied before activity filtering. A window with no non-nil activity class keeps legacy behavior.
    /// Once any class evidence exists, each in-range positive delta is attributed to its later sample:
    /// walk/run is retained, still is rejected, and nil/unknown classes fail closed.
    public static func analyze(_ samples: [StepSample]) -> Analysis {
        let sorted = samples.sorted { $0.ts < $1.ts }
        let filterMode: Analysis.FilterMode = sorted.contains { $0.activityClass != nil }
            ? .activityClassFiltered
            : .legacyRawMotion

        var rawTicks = 0
        var keptDeltaCount = 0
        var rejectedStillDeltaCount = 0
        var rejectedUnknownDeltaCount = 0
        var rejectedGapDeltaCount = 0
        var zeroDeltaCount = 0

        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let later = sorted[i]
                let delta = (later.counter - sorted[i - 1].counter) & 0xFFFF
                if delta == 0 {
                    zeroDeltaCount += 1
                } else if delta >= maxStepDelta {
                    rejectedGapDeltaCount += 1
                } else if filterMode == .legacyRawMotion {
                    rawTicks += delta
                    keptDeltaCount += 1
                } else {
                    switch later.activityClass {
                    case 1, 2:
                        rawTicks += delta
                        keptDeltaCount += 1
                    case 0:
                        rejectedStillDeltaCount += 1
                    default:
                        rejectedUnknownDeltaCount += 1
                    }
                }
            }
        }

        return Analysis(
            filterMode: filterMode,
            sampleCount: sorted.count,
            deltaCount: Swift.max(sorted.count - 1, 0),
            keptDeltaCount: keptDeltaCount,
            rejectedStillDeltaCount: rejectedStillDeltaCount,
            rejectedUnknownDeltaCount: rejectedUnknownDeltaCount,
            rejectedGapDeltaCount: rejectedGapDeltaCount,
            zeroDeltaCount: zeroDeltaCount,
            rawTicks: rawTicks
        )
    }

    /// Compatibility wrapper for the retained raw tick total from `analyze`. Completely unclassified
    /// windows keep the legacy positive-delta sum; classed windows keep only walk/run deltas. Returns `nil`
    /// when no retained movement remains, and leaves `stepTicksPerStep` calibration to the caller.
    public static func stepsInWindow(_ samples: [StepSample]) -> Int? {
        analyze(samples).steps
    }
}
