import Foundation
import WhoopProtocol

// ScoreConfidence.swift — per-score certainty tier for Charge / Effort / Rest.
//
// Each daily score rides a confidence tier so a sparse 5/MG day (or a cold-start
// baseline) reads truthfully instead of faking a number. Surfaced as a small
// label/dot under each score; the score itself stays nil-honest where it can't
// compute at all.
//
// Tiers (ordered lowest → highest):
//   .calibrating — the baseline/seed isn't usable yet, or the core input window is
//                  absent (no HR window for Effort, no in-bed data for Rest, HRV
//                  baseline not yet usable for Charge). The number, if shown, is a
//                  placeholder.
//   .building    — usable but thin: enough to compute, but the baseline is still
//                  provisional or the inputs are partial (e.g. a day backed mostly by
//                  PPG-derived HR, or a short baseline history).
//   .solid       — full inputs present and the baseline is trusted.
//
// Kept deliberately small and dependency-free so the Kotlin mirror is byte-identical.
public enum ScoreConfidence: String, Equatable, Sendable, Codable {
    case calibrating
    case building
    case solid

    // These keys are durable storage contracts shared with Android. Never rename an existing key.
    public static let sleepPerformanceSeriesKey = "sleep_performance"
    public static let restConfidenceSeriesKey = "rest_confidence"
    public static let restEvidenceSeriesKey = "rest_evidence_flags"
    public static let managedRestSeriesKeys: Set<String> = [
        sleepPerformanceSeriesKey,
        restConfidenceSeriesKey,
        restEvidenceSeriesKey,
    ]
    /// Customer-facing series that expose a detailed stage classification rather than sleep duration.
    /// Locally computed values for these keys must pass the exact-session publication policy below.
    public static let detailedSleepStageSeriesKeys: Set<String> = [
        "sleep_deep_min", "deep_min",
        "sleep_rem_min", "rem_min",
        "sleep_light_min", "core_min",
        "sleep_awake_min", "awake_min",
        "restorative_min", "restorative_pct",
    ]

    public static func isDetailedSleepStageSeriesKey(_ key: String) -> Bool {
        detailedSleepStageSeriesKeys.contains(key)
    }

    /// Stable numeric projection used only for the local `rest_confidence` metric series.
    public var persistedValue: Double {
        switch self {
        case .calibrating: return 0
        case .building: return 1
        case .solid: return 2
        }
    }

    public init?(persistedValue: Double?) {
        guard let persistedValue, persistedValue.isFinite else { return nil }
        switch persistedValue {
        case 0: self = .calibrating
        case 1: self = .building
        case 2: self = .solid
        default: return nil
        }
    }

    /// Why a Rest read did not earn the highest input-confidence tier. These are evidence limits,
    /// not diagnoses, and never alter the Rest score itself.
    public enum RestLimitation: String, Equatable, Sendable, Codable {
        case noSession
        case noStagedSleep
        case motionUnavailable
        case sparseMotion
        case missingRREvidence
        case missingRespirationEvidence
        case implausibleStageMix
    }

    /// Rest certainty plus the concrete evidence limits behind it. `confidence` is byte-identical
    /// to `rest(...)`; the richer shape only lets presentation explain an existing downgrade.
    public struct RestAssessment: Equatable, Sendable {
        public let confidence: ScoreConfidence
        public let limitations: [RestLimitation]

        public init(confidence: ScoreConfidence, limitations: [RestLimitation]) {
            self.confidence = confidence
            self.limitations = limitations
        }
    }

    /// Independently persisted evidence behind a Rest confidence tier. The bit positions are a durable,
    /// cross-platform storage contract; unknown or internally inconsistent masks are rejected so a newer
    /// writer cannot be misread by an older UI.
    public struct RestEvidenceFlags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let sessionPresent = Self(rawValue: 1 << 0)
        public static let stagedSleepPresent = Self(rawValue: 1 << 1)
        public static let motionAvailable = Self(rawValue: 1 << 2)
        public static let sparseMotion = Self(rawValue: 1 << 3)
        public static let rrEvidencePresent = Self(rawValue: 1 << 4)
        public static let respirationEvidencePresent = Self(rawValue: 1 << 5)
        public static let implausibleStageMix = Self(rawValue: 1 << 6)

        private static let knownMask: UInt8 =
            sessionPresent.rawValue
            | stagedSleepPresent.rawValue
            | motionAvailable.rawValue
            | sparseMotion.rawValue
            | rrEvidencePresent.rawValue
            | respirationEvidencePresent.rawValue
            | implausibleStageMix.rawValue

        public var persistedValue: Double { Double(rawValue) }

        public init?(persistedValue: Double?) {
            guard let persistedValue,
                  persistedValue.isFinite,
                  persistedValue >= 0,
                  persistedValue <= Double(UInt8.max),
                  persistedValue.rounded(.towardZero) == persistedValue else { return nil }
            let rawValue = UInt8(persistedValue)
            guard rawValue & ~Self.knownMask == 0 else { return nil }
            let flags = Self(rawValue: rawValue)
            guard !flags.contains(.stagedSleepPresent) || flags.contains(.sessionPresent),
                  !flags.contains(.sparseMotion) || flags.contains(.motionAvailable),
                  !flags.contains(.implausibleStageMix)
                    || flags.isSuperset(of: [.sessionPresent, .stagedSleepPresent]) else { return nil }
            self = flags
        }
    }

    /// Raw, main-night-scoped cardiorespiratory evidence retained across the user-edit recompute seam.
    public struct RestRawEvidence: Equatable, Sendable {
        public let hasRREvidence: Bool
        public let hasRespirationEvidence: Bool
        public let mainSessionStarts: Set<Int>
        private let countsBySessionStart: [Int: AnalyticsEngine.RestEvidenceCounts]

        public init(hasRREvidence: Bool, hasRespirationEvidence: Bool,
                    mainSessionStarts: Set<Int> = []) {
            self.hasRREvidence = hasRREvidence
            self.hasRespirationEvidence = hasRespirationEvidence
            self.mainSessionStarts = mainSessionStarts
            self.countsBySessionStart = [:]
        }

        fileprivate init(mainSessionStarts: Set<Int>,
                         countsBySessionStart: [Int: AnalyticsEngine.RestEvidenceCounts]) {
            let counts = mainSessionStarts.reduce(AnalyticsEngine.RestEvidenceCounts.zero) {
                $0 + (countsBySessionStart[$1] ?? .zero)
            }
            let resolved = counts.resolved
            self.hasRREvidence = resolved.hasRREvidence
            self.hasRespirationEvidence = resolved.hasRespirationEvidence
            self.mainSessionStarts = mainSessionStarts
            self.countsBySessionStart = countsBySessionStart
        }

        /// Resolve evidence for the final main-night group after user edits. A legacy/manually-created
        /// value has no per-session counts, so it may preserve its original selection but cannot lend
        /// evidence to a different block.
        public func selecting(mainSessionStarts: Set<Int>) -> RestRawEvidence {
            guard !countsBySessionStart.isEmpty else {
                guard mainSessionStarts == self.mainSessionStarts else {
                    return RestRawEvidence(
                        hasRREvidence: false,
                        hasRespirationEvidence: false,
                        mainSessionStarts: mainSessionStarts)
                }
                return self
            }
            return RestRawEvidence(
                mainSessionStarts: mainSessionStarts,
                countsBySessionStart: countsBySessionStart)
        }
    }

    // MARK: - Derivations (one per score; mirror the Android helpers exactly)

    /// Charge (recovery) confidence.
    /// - calibrating: no score (HRV baseline not usable / cold-start) → the number is absent.
    /// - solid:       a score exists AND the HRV baseline is fully trusted.
    /// - building:    a score exists but the HRV baseline is only provisional.
    public static func charge(recovery: Double?, hrvBaseline: BaselineState?) -> ScoreConfidence {
        guard recovery != nil, let b = hrvBaseline, b.usable else { return .calibrating }
        return b.trusted ? .solid : .building
    }

    /// Effort (strain) confidence.
    /// - calibrating: no score (no usable HR window) → absent.
    /// - solid:       a score exists AND the HR window is dense (≥ solidReadings samples).
    /// - building:    a score exists but the HR window is thin (PPG-backed / short day).
    public static let solidEffortReadings: Int = 3600  // ~1 h at 1 Hz of HR coverage
    public static func effort(strain: Double?, hrSampleCount: Int) -> ScoreConfidence {
        guard strain != nil else { return .calibrating }
        return hrSampleCount >= solidEffortReadings ? .solid : .building
    }

    /// Rest (sleep) confidence.
    /// - calibrating: no in-bed data (no matched session) → absent.
    /// - solid:       a session exists AND every Rest component had real input
    ///                (staged sleep present so restorative + efficiency are real).
    /// - building:    a session exists but stages/inputs are partial.
    public static func rest(hasSession: Bool, hasStagedSleep: Bool) -> ScoreConfidence {
        guard hasSession else { return .calibrating }
        return hasStagedSleep ? .solid : .building
    }

    // MARK: - H9 stage low-confidence (restorative-share floor on a high-efficiency night)

    /// Restorative (deep+REM) share of asleep time below which staging is treated as LOW-CONFIDENCE on an
    /// otherwise high-efficiency night. A genuine well-structured adult night sits ~40–50% deep+REM; a near-
    /// zero restorative share on a night that ALSO scored high efficiency (lots of "asleep") is far more
    /// likely a staging miss (the EEG-free classifier's weakest link is light/deep/REM separation) than a
    /// real night with no deep or REM — so we flag the LOW CONFIDENCE rather than fake stages or tank Rest.
    /// ~10% is well below the healthy band yet above true edge cases. (#H9)
    public static let restorativeLowConfidenceShare: Double = 0.10

    /// Efficiency above which the restorative-share floor applies. A low-efficiency (fragmented) night
    /// legitimately carries less deep/REM, so the floor would false-positive there; we only flag the
    /// suspicious case — high efficiency (lots of measured sleep) but implausibly little restorative.
    public static let highEfficiencyThreshold: Double = 0.85

    /// Rest confidence WITH the H9 stage-quality check and evidence-availability guards. Starts from
    /// `rest(hasSession:hasStagedSleep:)`, then DOWNGRADES a `.solid` tier to `.building` (low-confidence)
    /// when ANY of these apply:
    ///  - the night was staged on SPARSE gravity (`gravitySparse`) — a WHOOP 4.0 synced/offload night banks
    ///    motion coarsely, too sparse to reliably stage sleep (#345), so a confident 85–100 Rest is unearned
    ///    however the engine filled the stages. This catches the case H9 MISSES: a sparse night whose staging
    ///    manufactures HIGH efficiency AND HIGH restorative reads SOLID under H9 alone (the #319 signature),
    ///    yet the underlying data can't support it; OR
    ///  - R-R or respiration evidence was unavailable, leaving the staged night without one of the
    ///    cardiorespiratory lanes used to distinguish deep and REM; OR
    ///  - the night is high-efficiency yet its restorative (deep+REM) share is below
    ///    `restorativeLowConfidenceShare` — a likely staging miss (#H9).
    /// `asleepSeconds`/`restorativeSeconds` are the night's totals; efficiency is asleep/in-bed in [0,1].
    /// `.calibrating`/`.building` from the base call are returned unchanged. Confidence-only — never changes
    /// the Rest score or invents stages. Engine output only; the UI surfaces the tier later. (#H9, #345)
    public static func rest(hasSession: Bool, hasStagedSleep: Bool,
                            asleepSeconds: Double, restorativeSeconds: Double,
                            efficiency: Double, gravitySparse: Bool = false,
                            hasRREvidence: Bool = true,
                            hasRespirationEvidence: Bool = true) -> ScoreConfidence {
        let base = rest(hasSession: hasSession, hasStagedSleep: hasStagedSleep)
        if base != .solid { return base }
        if gravitySparse { return .building }   // #345: sparse-motion staging can't earn a SOLID Rest
        if !hasRREvidence || !hasRespirationEvidence { return .building }
        if asleepSeconds <= 0 { return base }
        let restorativeShare = restorativeSeconds / asleepSeconds
        if efficiency >= highEfficiencyThreshold && restorativeShare < restorativeLowConfidenceShare {
            return .building   // high-efficiency night with near-zero deep+REM → low-confidence staging (#H9)
        }
        return base
    }

    /// Explainable companion to `rest(...)`. It delegates tier calculation to the canonical helper,
    /// then reports only the gates that actually constrained this night's evidence. Score inputs and
    /// weights remain untouched.
    public static func restAssessment(hasSession: Bool, hasStagedSleep: Bool,
                                      asleepSeconds: Double, restorativeSeconds: Double,
                                      efficiency: Double, gravitySparse: Bool = false,
                                      motionUnavailable: Bool = false,
                                      hasRREvidence: Bool = true,
                                      hasRespirationEvidence: Bool = true) -> RestAssessment {
        restAssessment(evidence: restEvidenceFlags(
            hasSession: hasSession,
            hasStagedSleep: hasStagedSleep,
            asleepSeconds: asleepSeconds,
            restorativeSeconds: restorativeSeconds,
            efficiency: efficiency,
            motionAvailable: !motionUnavailable,
            gravitySparse: gravitySparse,
            hasRREvidence: hasRREvidence,
            hasRespirationEvidence: hasRespirationEvidence))
    }

    /// Build the durable evidence record after all user-edited sleep aggregates have been applied.
    public static func restEvidenceFlags(hasSession: Bool, hasStagedSleep: Bool,
                                         asleepSeconds: Double, restorativeSeconds: Double,
                                         efficiency: Double, motionAvailable: Bool,
                                         gravitySparse: Bool,
                                         hasRREvidence: Bool,
                                         hasRespirationEvidence: Bool) -> RestEvidenceFlags {
        var evidence: RestEvidenceFlags = []
        if hasSession { evidence.insert(.sessionPresent) }
        if hasSession && hasStagedSleep { evidence.insert(.stagedSleepPresent) }
        if motionAvailable { evidence.insert(.motionAvailable) }
        if motionAvailable && gravitySparse { evidence.insert(.sparseMotion) }
        if hasRREvidence { evidence.insert(.rrEvidencePresent) }
        if hasRespirationEvidence { evidence.insert(.respirationEvidencePresent) }
        if hasSession, hasStagedSleep, asleepSeconds > 0,
           efficiency >= highEfficiencyThreshold,
           restorativeSeconds / asleepSeconds < restorativeLowConfidenceShare {
            evidence.insert(.implausibleStageMix)
        }
        return evidence
    }

    /// Decode a persisted evidence record into both the tier and its independent limitations.
    public static func restAssessment(evidence: RestEvidenceFlags) -> RestAssessment {
        let hasSession = evidence.contains(.sessionPresent)
        let hasStagedSleep = evidence.contains(.stagedSleepPresent)
        let motionAvailable = evidence.contains(.motionAvailable)
        let gravitySparse = evidence.contains(.sparseMotion)
        let hasRREvidence = evidence.contains(.rrEvidencePresent)
        let hasRespirationEvidence = evidence.contains(.respirationEvidencePresent)
        let implausibleStageMix = evidence.contains(.implausibleStageMix)

        let confidence: ScoreConfidence
        if !hasSession {
            confidence = .calibrating
        } else if !hasStagedSleep {
            confidence = .building
        } else if !motionAvailable || gravitySparse || !hasRREvidence
                    || !hasRespirationEvidence || implausibleStageMix {
            confidence = .building
        } else {
            confidence = .solid
        }
        var limitations: [RestLimitation] = []
        if !hasSession {
            limitations.append(.noSession)
        } else if !hasStagedSleep {
            limitations.append(.noStagedSleep)
        }
        if !motionAvailable {
            limitations.append(.motionUnavailable)
        } else if gravitySparse {
            limitations.append(.sparseMotion)
        }
        if !hasRREvidence {
            limitations.append(.missingRREvidence)
        }
        if !hasRespirationEvidence {
            limitations.append(.missingRespirationEvidence)
        }
        if implausibleStageMix {
            limitations.append(.implausibleStageMix)
        }
        return RestAssessment(confidence: confidence, limitations: limitations)
    }

    /// Whether exact-session R-R coverage is sufficient to publish a locally computed stage split.
    /// Counts are nullable at the persistence boundary so legacy, imported, manually reshaped, and
    /// partially restored rows fail closed. Invalid counts also fail closed instead of being clamped.
    public static func hasSustainedRREvidence(
        eligibleWindowCount: Int?,
        validRRWindowCount: Int?
    ) -> Bool {
        guard let eligibleWindowCount,
              let validRRWindowCount,
              eligibleWindowCount > 0,
              validRRWindowCount >= 0,
              validRRWindowCount <= eligibleWindowCount else { return false }
        return AnalyticsEngine.hasSustainedRestEvidence(
            validWindowCount: validRRWindowCount,
            eligibleWindowCount: eligibleWindowCount)
    }

    /// Raw exact-session counts stored beside a local stage payload. The persistence layer keeps these
    /// counts rather than a thresholded boolean so a bridged main-night group can be re-evaluated after
    /// edits without retaining or replaying the underlying beat intervals.
    public struct DetailedStageRREvidenceCounts: Equatable, Sendable {
        public let eligibleWindowCount: Int
        public let validRRWindowCount: Int

        public init(eligibleWindowCount: Int, validRRWindowCount: Int) {
            self.eligibleWindowCount = eligibleWindowCount
            self.validRRWindowCount = validRRWindowCount
        }
    }

    /// Evaluate one exact staged session with the classifier's canonical five-minute R-R pipeline.
    public static func detailedStageRREvidenceCounts(
        session: SleepSession,
        rr: [RRInterval]
    ) -> DetailedStageRREvidenceCounts {
        let counts = AnalyticsEngine.mainSleepEvidenceCounts(
            mainGroup: [session],
            rr: rr,
            resp: [])
        return DetailedStageRREvidenceCounts(
            eligibleWindowCount: counts.eligibleWindows,
            validRRWindowCount: counts.validRRWindows)
    }

    /// Session indices whose detailed stages may leave raw storage.
    ///
    /// Callers pass one exact source and one local wake day at a time. The currently selected
    /// main-night group's persisted per-session counts are summed and evaluated with the classifier's
    /// canonical sustained-coverage rule. Missing evidence on any selected fragment fails the whole
    /// group closed. Imported classifiers retain their own disclosed provenance.
    public static func publishableDetailedSleepStageSessionIndices(
        blocks: [SleepStageTotals.NightBlock],
        rrEligibleWindowCounts: [Int?],
        rrValidWindowCounts: [Int?],
        independentlyStagedImport: Bool,
        offsetSec: Int,
        habitualMidsleepSec: Int?
    ) -> Set<Int> {
        if independentlyStagedImport { return Set(blocks.indices) }
        guard blocks.count == rrEligibleWindowCounts.count,
              blocks.count == rrValidWindowCounts.count,
              let mainIndices = SleepStageTotals.mainNightGroupIndices(
            blocks,
            offsetSec: offsetSec,
            habitualMidsleepSec: habitualMidsleepSec
        ), !mainIndices.isEmpty else { return [] }

        var eligibleTotal = 0
        var validTotal = 0
        for index in mainIndices {
            let block = blocks[index]
            let (duration, durationOverflow) =
                block.end.subtractingReportingOverflow(block.start)
            guard let eligible = rrEligibleWindowCounts[index],
                  let valid = rrValidWindowCounts[index],
                  !durationOverflow,
                  duration > 0,
                  eligible == duration / AnalyticsEngine.restEvidenceWindowSeconds,
                  eligible > 0,
                  valid >= 0,
                  valid <= eligible else { return [] }
            let (nextEligible, eligibleOverflow) = eligibleTotal.addingReportingOverflow(eligible)
            let (nextValid, validOverflow) = validTotal.addingReportingOverflow(valid)
            guard !eligibleOverflow, !validOverflow else { return [] }
            eligibleTotal = nextEligible
            validTotal = nextValid
        }
        guard hasSustainedRREvidence(
            eligibleWindowCount: eligibleTotal,
            validRRWindowCount: validTotal
        ) else { return [] }
        return Set(mainIndices)
    }

    /// Capture the same sustained five-minute evidence verdict `AnalyticsEngine` used for this main night.
    /// Keeping this wrapper here exposes only the stable booleans needed by persistence; formulas remain in
    /// the existing canonical evaluator.
    public static func restRawEvidence(sessions: [SleepSession],
                                       rr: [RRInterval],
                                       resp: [RespSample],
                                       offsetSec: Int,
                                       habitualMidsleepSec: Int?) -> RestRawEvidence {
        let indices = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) },
            offsetSec: offsetSec,
            habitualMidsleepSec: habitualMidsleepSec) ?? []
        let mainSessionStarts = Set(indices.map { sessions[$0].start })
        var countsBySessionStart: [Int: AnalyticsEngine.RestEvidenceCounts] = [:]
        for session in sessions {
            countsBySessionStart[session.start] = AnalyticsEngine.mainSleepEvidenceCounts(
                mainGroup: [session], rr: rr, resp: resp)
        }
        return RestRawEvidence(
            mainSessionStarts: mainSessionStarts,
            countsBySessionStart: countsBySessionStart)
    }
}
