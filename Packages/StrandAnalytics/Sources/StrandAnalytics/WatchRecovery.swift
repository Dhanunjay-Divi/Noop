import Foundation

// WatchRecovery.swift — recovery/Charge from Apple Watch DAILY aggregates.
//
// The honesty-critical piece of "Apple Watch as a device". A WHOOP strap gives us
// dense overnight RR intervals, so RecoveryScorer runs off raw-derived nightly RMSSD.
// The Apple Watch does NOT. It gives a handful of HRV SDNN readings a day plus a
// resting HR, both as daily aggregates. So watch recovery is a genuinely lower-density
// computation.
//
// We do NOT invent a new formula. Recovery is HRV-and-RHR-vs-personal-baseline, and
// because every term is relative to the person's OWN baseline, the metric scale cancels
// out: SDNN-vs-SDNN-baseline behaves like RMSSD-vs-RMSSD-baseline. So we build SDNN and
// RHR baselines through the existing `Baselines` machinery and feed them straight into
// the SAME `RecoveryScorer.recovery(...)` the strap uses. Watch recovery and strap
// recovery therefore land on the same 0-100 scale and read against the same bands.
//
// What we drop vs the strap path: the respiration, sleep-performance and skin-temp terms
// are not supplied here (the watch's daily aggregate doesn't carry them in the same shape),
// so RecoveryScorer renormalises the remaining HRV + RHR weights. The HRV term stays the
// dominant driver either way.
//
// The hard honesty rule: we return nil recovery + `.calibrating` when today's SDNN is
// missing, OR the SDNN baseline isn't usable yet, OR we have fewer than `minBaselineNights`
// nights of history. We NEVER fabricate a number to fill a sparse week. Confidence comes
// straight from the existing `ScoreConfidence.charge(recovery:hrvBaseline:)`, so the watch
// "calibrating → building → solid" arc is the same one the strap uses.
public enum WatchRecovery {

    /// The time-domain statistic represented by an HRV value.
    ///
    /// SDNN and RMSSD are both expressed in milliseconds, but they are not interchangeable
    /// measurements. Keeping the method on every sample prevents a numerically plausible value
    /// from silently entering a baseline built with the other statistic.
    public enum HRVMethod: String, Equatable, Sendable, Codable {
        case sdnn = "SDNN"
        case rmssd = "RMSSD"
    }

    /// Stable identity of an HRV series. A baseline belongs to one source and one method.
    public struct HRVProvenance: Equatable, Hashable, Sendable, Codable {
        public let sourceID: String
        public let method: HRVMethod

        public init(sourceID: String, method: HRVMethod) {
            self.sourceID = sourceID
            self.method = method
        }

        /// Explicit developer-facing label for diagnostics and UI provenance adapters.
        public var label: String {
            "\(sourceID) HRV (\(method.rawValue))"
        }
    }

    /// One HRV value with enough provenance to decide whether it belongs in a baseline.
    public struct HRVSample: Equatable, Sendable {
        public let value: Double
        public let provenance: HRVProvenance

        public init(value: Double, provenance: HRVProvenance) {
            self.value = value
            self.provenance = provenance
        }
    }

    /// Result of a watch-recovery computation: the score (nil while calibrating) and its
    /// confidence tier, plus the exact HRV source and method used.
    public struct Result: Equatable, Sendable {
        /// Recovery in [0, 100], or nil when we can't honestly score yet (calibrating).
        public let recovery: Double?
        /// Per-score confidence, driven by the real SDNN-baseline density (not a hardcoded label).
        public let confidence: ScoreConfidence
        /// The source and method of both today's HRV and its isolated personal baseline.
        public let hrvProvenance: HRVProvenance

        public init(recovery: Double?, confidence: ScoreConfidence,
                    hrvProvenance: HRVProvenance) {
            self.recovery = recovery
            self.confidence = confidence
            self.hrvProvenance = hrvProvenance
        }
    }

    /// Minimum nights of SDNN history before we'll score recovery from the watch. The spec's
    /// honesty stance is to keep recovery "calibrating" for about a week of nights rather than
    /// ship a misleading number off a thin baseline. This sits ABOVE the baseline's own seed
    /// gate (`Baselines.minNightsSeed` = 4) deliberately: a strap user crosses the seed faster
    /// on dense data, but the watch's sparse SDNN deserves a longer warm-up before we trust it.
    public static let minBaselineNights = 7

    /// Compute recovery/Charge from one explicitly identified HRV series + resting HR.
    ///
    /// - Parameters:
    ///   - provenance: source and HRV method this computation is allowed to use.
    ///   - todayHRV: today's HRV reading (ms), including its source and method.
    ///   - todayRHR:  today's resting HR (bpm), or nil to drop the RHR term.
    ///   - hrvHistory: ordered nightly HRV samples (oldest to newest). Samples whose source or
    ///     method differs from `provenance` are excluded before the baseline is built.
    ///   - rhrHistory:  ordered nightly resting-HR values (oldest → newest).
    /// - Returns: a `Result` with recovery in [0,100] and a confidence tier, or nil recovery +
    ///   `.calibrating` when today's matching HRV is missing, the baseline isn't usable, or
    ///   source-and-method-matched history is thin.
    public static func compute(provenance: HRVProvenance,
                               todayHRV: HRVSample?, todayRHR: Int?,
                               hrvHistory: [HRVSample], rhrHistory: [Double]) -> Result {
        // Source isolation is enforced here, not left to caller convention. A source switch or a
        // method switch starts a fresh baseline even though both values happen to use milliseconds.
        let isolatedHistory = hrvHistory.compactMap { sample -> Double? in
            sample.provenance == provenance ? sample.value : nil
        }
        let isolatedToday = todayHRV.flatMap { sample -> Double? in
            sample.provenance == provenance ? sample.value : nil
        }

        // Build both baselines through the production model (Winsorized EWMA + cold-start gating),
        // exactly as the strap path does. SDNN feeds the HRV config; resting HR feeds the RHR config.
        let hrvBase = Baselines.foldHistory(isolatedHistory.map { Optional($0) }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHistory.map { Optional($0) }, cfg: Baselines.restingHRCfg)

        // Confidence is the SAME helper the strap Charge uses, so the calibrating → building → solid
        // arc matches. It reads .calibrating whenever recovery would be nil (no usable HRV baseline),
        // and below it we ALSO nil-out recovery, so the two stay consistent.
        let conf = ScoreConfidence.charge(recovery: isolatedToday, hrvBaseline: hrvBase)

        // Honesty gate: no number unless today's sample has the expected provenance, its isolated
        // baseline is usable, and that exact source/method has at least a week of history.
        guard let hrv = isolatedToday,
              hrvBase.usable,
              isolatedHistory.count >= minBaselineNights else {
            return Result(recovery: nil, confidence: .calibrating,
                          hrvProvenance: provenance)
        }

        // Reuse the canonical Charge engine. Drop the resp / sleep / skin-temp terms (the watch
        // daily aggregate doesn't carry them here) — RecoveryScorer renormalises to HRV + RHR.
        // RHR is optional: when the watch logged no resting HR today we pass the HRV-only path.
        let recovery = RecoveryScorer.recovery(
            hrv: hrv,
            rhr: todayRHR.map(Double.init) ?? rhrBase.baseline,   // missing RHR → at-baseline (z≈0, neutral term)
            resp: nil,
            hrvBaseline: hrvBase,
            rhrBaseline: todayRHR != nil ? rhrBase : nil,          // drop the RHR term entirely if no reading
            respBaseline: nil,
            sleepPerf: nil
        )

        // RecoveryScorer only returns nil on a cold-start HRV baseline, which we already gated above;
        // but stay honest if it ever does — never coerce a nil into a number.
        guard let recovery else {
            return Result(recovery: nil, confidence: .calibrating,
                          hrvProvenance: provenance)
        }
        return Result(recovery: recovery, confidence: conf,
                      hrvProvenance: provenance)
    }
}
