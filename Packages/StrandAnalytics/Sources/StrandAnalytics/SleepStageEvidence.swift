import Foundation

// SleepStageEvidence.swift — whether a night's REM and deep minutes are measurements or guesses.
//
// WHY THIS EXISTS
// `SleepStager` always returns four classes ("wake" | "light" | "deep" | "rem"), so every night looks
// equally well-measured. It is not. Validated against expert polysomnography (n=6 subjects, 5,720
// epochs, full coverage; see docs/validation/MULTI-DATASET-VERDICTS.md):
//
//   4-class agreement    46.8%   against the 65-73% ceiling the stager's own header cites
//   sleep/wake           71.8%   usable
//   REM recall            3.7%   NOT usable
//   deep recall           6.9%   NOT usable
//   dominant error        706 of 1,392 REM epochs (51%) classified as WAKE
//
// The cause is inputs, not arithmetic. That corpus carried motion and heart rate only, with no R-R
// intervals and no respiration, and the stager's Stage-1 features require both: the deep rule reads
// parasympathetic tone from R-R, and the REM rule reads respiratory irregularity. Deprived of them the
// classifier still emits four labels, and roughly half of REM lands in wake.
//
// WHAT THIS DOES ABOUT IT
// It does NOT change staging. Two things were rejected deliberately:
//
//   * Collapsing REM and deep into "light" when R-R is absent. That trades one fabrication for another,
//     because it asserts the epoch WAS light sleep. It also silently inflates light minutes.
//   * Re-tuning the classifier to score better without R-R. The measurement is missing; no coefficient
//     recovers information that was never captured.
//
// Instead this reports provenance, which is the repository's existing convention: a value NOOP cannot
// measure resolves to nil and renders as an em-dash, never as a number and never as zero. Sleep/wake and
// total sleep time remain trustworthy at 71.8% and stay reportable; REM and deep are withheld.
//
// The honest framing for a user is that NOOP knows how long they slept and does not know how much of it
// was REM, rather than a confident REM figure that is wrong roughly half the time.

/// Whether a night had the physiological inputs REM and deep discrimination require.
public enum SleepStageEvidence: String, Equatable, Sendable, Codable {
    /// R-R intervals present in usable quantity. Four-class staging is reportable.
    case cardiacResolved
    /// Motion and heart rate only. Sleep/wake and duration are reportable; REM and deep are NOT.
    case motionOnly

    /// True when REM and deep minutes may be presented to the user as measurements.
    public var remDeepReportable: Bool { self == .cardiacResolved }
}

/// Sleep totals carrying their own provenance, so a caller cannot read REM without seeing whether it
/// was measured.
public struct AttributedSleepTotals: Equatable, Sendable {
    public let totalSleepMin: Double
    public let efficiency: Double
    public let lightMin: Double
    public let evidence: SleepStageEvidence

    /// Deep minutes, or nil when the night lacked the R-R needed to discriminate deep.
    public let deepMin: Double?
    /// REM minutes, or nil when the night lacked the R-R needed to discriminate REM.
    public let remMin: Double?

    public init(totalSleepMin: Double,
                efficiency: Double,
                lightMin: Double,
                deepMin: Double?,
                remMin: Double?,
                evidence: SleepStageEvidence) {
        self.totalSleepMin = totalSleepMin
        self.efficiency = efficiency
        self.lightMin = lightMin
        self.deepMin = deepMin
        self.remMin = remMin
        self.evidence = evidence
    }
}

public enum SleepStageEvidenceGate {

    /// Minimum R-R intervals across a session before four-class staging is trusted.
    ///
    /// `HRVAnalyzer` already refuses to compute RMSSD below 20 intervals, and the stager consumes R-R in
    /// 5-minute windows. A night carrying only a handful of intervals has R-R present in a technical sense
    /// while supplying no usable parasympathetic signal, so the bar is deliberately well above 20 rather
    /// than at "non-empty". This is a judgement, not a validated threshold, and is pinned by a test so
    /// changing it is a decision rather than a drift.
    public static let minimumIntervalsForStaging = 120

    /// Classify the evidence available for one session.
    public static func evidence(rrIntervalCount: Int, respSampleCount: Int = 0) -> SleepStageEvidence {
        guard rrIntervalCount >= minimumIntervalsForStaging else { return .motionOnly }
        return .cardiacResolved
    }

    /// Attach provenance to a night's totals, withholding REM and deep when they were not measured.
    ///
    /// Light minutes are deliberately still reported under `.motionOnly`: sleep/wake separation validated
    /// at 71.8%, so "asleep and not otherwise resolved" is a defensible statement where "REM" is not.
    public static func attribute(totalSleepMin: Double,
                                 efficiency: Double,
                                 lightMin: Double,
                                 deepMin: Double,
                                 remMin: Double,
                                 evidence: SleepStageEvidence) -> AttributedSleepTotals {
        let reportable = evidence.remDeepReportable
        return AttributedSleepTotals(
            totalSleepMin: totalSleepMin,
            efficiency: efficiency,
            // Under motion-only evidence the epochs the classifier called deep or REM are still sleep, they
            // are simply unresolved. Folding them into light would assert a stage that was not measured, so
            // light reports only what was actually labelled light and the remainder is accounted for by
            // totalSleepMin exceeding the sum of the resolved stages.
            lightMin: lightMin,
            deepMin: reportable ? deepMin : nil,
            remMin: reportable ? remMin : nil,
            evidence: evidence
        )
    }
}
