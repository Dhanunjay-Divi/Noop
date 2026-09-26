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

    /// Maximum tolerated absence at either edge of a day, or between adjacent rows, before an all-still
    /// window becomes too sparse to repair a previously persisted whole-day value. This is an integrity
    /// threshold, not a gait detector: current step publication still requires walk/run classification.
    public static let stationaryRepairMaxCoverageGapSeconds = 15 * 60

    public enum ClassificationPolicy: Equatable, Sendable {
        /// Preserve the historical raw-motion estimate when every persisted class is absent.
        case allowLegacyRawMotion

        /// Current counter-capable hardware must provide walk/run evidence. An all-unclassified
        /// window remains observed but ambiguous: it yields no steps and cannot enable motion fallback.
        case requireActivityClass
    }

    public struct Analysis: Equatable, Sendable {
        public enum FilterMode: String, Equatable, Sendable {
            /// No activity-class evidence exists anywhere in the window, so preserve the legacy raw-motion
            /// estimate for older persisted rows.
            case legacyRawMotion

            /// At least one sample has activity-class evidence. Only deltas whose later sample is walk (1)
            /// or run (2) are retained.
            case activityClassFiltered

            /// The production source is expected to classify locomotion, but the complete window is
            /// unclassified. Positive deltas are rejected as unknown rather than counted as steps.
            case activityClassRequiredMissing
        }

        public let filterMode: FilterMode
        public let sampleCount: Int
        public let deltaCount: Int
        public let keptDeltaCount: Int
        public let rejectedStillDeltaCount: Int
        public let rejectedUnknownDeltaCount: Int
        public let rejectedGapDeltaCount: Int
        public let zeroDeltaCount: Int
        /// Positive, in-range ticks before activity-class filtering. This exists only to recognize a
        /// stale value produced by the former raw-motion algorithm; it is never published as current steps.
        public let unfilteredRawTicks: Int
        public let rawTicks: Int

        /// Compatibility value used by existing callers: no retained movement remains missing, not zero.
        public var steps: Int? {
            rawTicks > 0 ? rawTicks : nil
        }

        /// At least one counter row exists in this window. This remains true when every delta was flat,
        /// discontinuous, or rejected as still/unknown, so callers do not confuse explicit counter evidence
        /// with hardware that exposes no counter at all.
        public var counterObserved: Bool {
            sampleCount > 0
        }

        /// Gravity-derived movement is only an honest fallback when the source exposes no counter rows.
        /// A present-but-rejected counter must not be reinterpreted as steps through another motion path.
        public var allowsMotionFallback: Bool {
            !counterObserved
        }

        /// Only retained walk/run evidence is authoritative enough to replace an older estimate.
        /// Still-only or unclassified partial windows suppress new fallbacks but do not prove that the
        /// entire day's previously stored steps were false.
        public var hasAuthoritativeCounterOutcome: Bool { steps != nil }

        /// The exact raw-motion total the former algorithm would have published when every usable positive
        /// delta is explicitly classified as still. Mixed, unknown, discontinuous, classless, singleton,
        /// and flat windows stay ambiguous. Persistence may use this only as a conditional compare-and-clear
        /// value, so unrelated or imported step totals remain untouched.
        public var stationaryOnlyLegacyTicks: Int? {
            guard filterMode == .activityClassFiltered,
                  keptDeltaCount == 0,
                  rejectedStillDeltaCount > 0,
                  rejectedUnknownDeltaCount == 0,
                  rejectedGapDeltaCount == 0,
                  unfilteredRawTicks > 0
            else { return nil }
            return unfilteredRawTicks
        }
    }

    /// Apply the one shared motion-tick calibration used by daily, workout, trace, and stale-value repair
    /// paths. Keeping rounding and the defensive coefficient floor here prevents cross-path drift.
    public static func scaledSteps(rawTicks: Int, ticksPerStep: Double) -> Int? {
        guard rawTicks > 0 else { return nil }
        let scaled = Int((Double(rawTicks) / max(ticksPerStep, 0.5)).rounded())
        return scaled > 0 ? scaled : nil
    }

    /// Return the exact stale raw-motion value that a continuously observed all-still day disproves.
    ///
    /// A short shower/hand-motion burst can reject new steps, but it cannot establish what happened during
    /// the rest of the day. Compare-and-clear therefore becomes eligible only when the same rows analyzed
    /// above cover the civil-day start through `observedThroughTs`, with no large internal gap. The caller
    /// still clears only an exact matching computed value; imported or mismatched totals remain untouched.
    public static func stationaryLegacyRepairSteps(
        analysis: Analysis,
        samples: [StepSample],
        ticksPerStep: Double,
        dayStartTs: Int,
        observedThroughTs: Int,
        maxCoverageGapSeconds: Int = stationaryRepairMaxCoverageGapSeconds
    ) -> Int? {
        guard let legacyTicks = analysis.stationaryOnlyLegacyTicks,
              maxCoverageGapSeconds > 0,
              observedThroughTs >= dayStartTs
        else { return nil }

        let covered = samples
            .filter { $0.ts >= dayStartTs && $0.ts <= observedThroughTs }
            .sorted { $0.ts < $1.ts }
        guard covered.count >= 2,
              covered.count == analysis.sampleCount,
              let first = covered.first,
              let last = covered.last,
              first.ts - dayStartTs <= maxCoverageGapSeconds,
              observedThroughTs - last.ts <= maxCoverageGapSeconds
        else { return nil }

        for index in 1..<covered.count {
            let gap = covered[index].ts - covered[index - 1].ts
            guard gap > 0, gap <= maxCoverageGapSeconds else { return nil }
        }
        return scaledSteps(rawTicks: legacyTicks, ticksPerStep: ticksPerStep)
    }

    /// Pure analysis of a counter window. Deltas remain wrap-aware and the `maxStepDelta` boundary is
    /// applied before activity filtering. A window with no non-nil activity class keeps legacy behavior.
    /// Once any class evidence exists, each in-range positive delta is attributed to its later sample:
    /// walk/run is retained, still is rejected, and nil/unknown classes fail closed.
    public static func analyze(
        _ samples: [StepSample],
        classificationPolicy: ClassificationPolicy = .allowLegacyRawMotion
    ) -> Analysis {
        let sorted = samples.sorted { $0.ts < $1.ts }
        let hasActivityClass = sorted.contains { $0.activityClass != nil }
        let filterMode: Analysis.FilterMode
        if hasActivityClass {
            filterMode = .activityClassFiltered
        } else if classificationPolicy == .requireActivityClass {
            filterMode = .activityClassRequiredMissing
        } else {
            filterMode = .legacyRawMotion
        }

        var rawTicks = 0
        var keptDeltaCount = 0
        var rejectedStillDeltaCount = 0
        var rejectedUnknownDeltaCount = 0
        var rejectedGapDeltaCount = 0
        var zeroDeltaCount = 0
        var unfilteredRawTicks = 0

        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let later = sorted[i]
                let delta = (later.counter - sorted[i - 1].counter) & 0xFFFF
                if delta == 0 {
                    zeroDeltaCount += 1
                } else if delta >= maxStepDelta {
                    rejectedGapDeltaCount += 1
                } else if filterMode == .legacyRawMotion {
                    unfilteredRawTicks += delta
                    rawTicks += delta
                    keptDeltaCount += 1
                } else {
                    unfilteredRawTicks += delta
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
            unfilteredRawTicks: unfilteredRawTicks,
            rawTicks: rawTicks
        )
    }

    /// Compatibility wrapper for the retained raw tick total from `analyze`. Completely unclassified
    /// windows keep the legacy positive-delta sum; classed windows keep only walk/run deltas. Returns `nil`
    /// when no retained movement remains, and leaves `stepTicksPerStep` calibration to the caller.
    public static func stepsInWindow(
        _ samples: [StepSample],
        classificationPolicy: ClassificationPolicy = .allowLegacyRawMotion
    ) -> Int? {
        analyze(samples, classificationPolicy: classificationPolicy).steps
    }
}
