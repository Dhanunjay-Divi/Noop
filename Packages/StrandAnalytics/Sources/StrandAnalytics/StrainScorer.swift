import Foundation
import WhoopProtocol

// StrainScorer.swift — cardiovascular load on a 0–100 logarithmic strain ("Effort") scale.
//
// Ported from server/ingest/app/analysis/strain.py. INDEPENDENT implementation of
// published exercise-physiology methods (WHOOP-*like*, not a reproduction of the
// proprietary algorithm; not medical advice).
//
// Scale note: the metric was historically 0–21 (WHOOP's Strain axis); the
// "Charge / Effort / Rest" redesign rescales the OUTPUT to 0–100 by raising
// `maxStrain` 21.0 → 100.0 only. The denominator D = 7201 is unchanged, so the log
// curve and its saturation point (TRIMP 7200 ≈ max) are preserved — a max Effort day
// stays as rare as a 21.0 day used to be. Internal metric key stays `strain`.
//
// Pipeline:
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
//   2. Per-sample intensity as %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
//   3. TRIMP accumulated over the window:
//        a. Edwards 5-zone summation (default): sample contributes its zone weight
//           (1..5 at 50/60/70/80/90 %HRR cut-offs) × duration.
//        b. Banister exponential: sample contributes duration × x × 0.64 × e^(b·x).
//   4. Logarithmic compression onto [0, 100]:
//        strain = 100 × ln(TRIMP + 1) / ln(D),  D = STRAIN_DENOMINATOR.
//
// References: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
// (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax = 208 − 0.7×age).

public enum StrainScorer {

    // MARK: - Constants (strain.py)

    /// Minimum HR readings before computing strain on a DENSE stream (≈10 min at 1 Hz).
    public static let minReadings: Int = 600
    /// Sparse-stream acceptance (#482/#480): a low-cadence strap — the WHOOP 5/MG sends live
    /// standard HR only ~every 30 s — would need ~5 h of continuous wear to reach `minReadings`,
    /// so Effort sat un-scored (nil → the gauge showed a stale prior-day value) for most of the day.
    /// Also accept once the HR series SPANS at least `minSpanSeconds` of wall-clock with a small
    /// sample floor. This never fabricates load: TRIMP still integrates honestly over whatever HR is
    /// there, so a genuine low-HR day scores 0 either way — it just lets the live gauge reflect TODAY
    /// instead of yesterday. A dense 1 Hz stream is unaffected (it clears `minReadings` first).
    public static let minSparseReadings: Int = 20
    /// Wall-clock coverage (seconds) that qualifies a sparse stream. 600 s = 10 min, matching the
    /// dense gate's ≈10 min of 600 × 1 Hz samples, so both cadences trust the number at the same age.
    public static let minSpanSeconds: Int = 600
    /// Top of the strain ("Effort") scale. Rescaled 21.0 → 100.0 for the
    /// Charge/Effort/Rest redesign; only the output scale changes, the curve does not.
    public static let maxStrain: Double = 100.0

    /// Logarithmic-map denominator D. Chosen so the Edwards daily ceiling
    /// (top zone weight 5 sustained 24 h = 7200) maps to exactly maxStrain:
    /// D = 7200 + 1 = 7201 makes ln(7201)/ln(7201) = 1.
    public static let strainDenominator: Double = 7201.0
    static var lnStrainDenominator: Double { log(strainDenominator) }

    /// Fallback per-sample duration (minutes) — 1 s at 1 Hz.
    static let fallbackSampleMin: Double = 1.0 / 60.0

    public static let defaultAge: Int = 30
    public static let defaultRestingHR: Double = 60

    /// Minimum HR samples before the observed high-percentile HRmax is trusted.
    public static let hrmaxMinSamples: Int = 600
    /// Upper percentile for the observed-HRmax estimate.
    public static let hrmaxPercentile: Double = 99.5

    /// Banister coefficients.
    public static let banisterScale: Double = 0.64
    public static let banisterBMen: Double = 1.92
    public static let banisterBWomen: Double = 1.67

    /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
    static let edwardsZones: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    /// TRIMP accumulation method.
    public enum Method: Sendable, Hashable { case edwards, banister }

    // MARK: - HRmax helpers

    /// Tanaka (2001): HRmax = 208 − 0.7 × age (gender-independent).
    public static func tanakaHRmax(age: Double) -> Double { 208.0 - 0.7 * age }

    /// Classic 220 − age. Last-resort fallback only.
    public static func defaultMaxHR(age: Int = defaultAge) -> Int { 220 - age }

    /// Linear-interpolated percentile of an already-sorted sequence (numpy-style).
    static func percentile(_ sortedValues: [Double], _ pct: Double) -> Double {
        let n = sortedValues.count
        if n == 0 { return 0 }
        if n == 1 { return sortedValues[0] }
        let position = (pct / 100.0) * Double(n - 1)
        let lower = Int(position)
        let upper = min(lower + 1, n - 1)
        let frac = position - Double(lower)
        return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower])
    }

    /// Estimate a personalized HRmax from a trailing HR series.
    /// Returns (hrmax bpm, source) where source ∈ {"observed", "tanaka", "unknown"}.
    public static func estimateHRmax(_ hrHistory: [Double], age: Double?) -> (Double, String) {
        let n = hrHistory.count
        let tanaka = age.map { tanakaHRmax(age: $0) }

        if n >= hrmaxMinSamples {
            let observed = percentile(hrHistory.sorted(), hrmaxPercentile)
            guard let t = tanaka else { return (observed, "observed") }
            return observed >= t ? (observed, "observed") : (t, "tanaka")
        }
        if let t = tanaka { return (t, "tanaka") }
        return (0.0, "unknown")
    }

    // MARK: - Karvonen %HRR and Edwards zone weight

    /// Karvonen %HRR, clamped [0, 100].
    static func pctHRR(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Double {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        if pct < 0 { return 0 }
        if pct > 100 { return 100 }
        return pct
    }

    /// Edwards 5-zone weight (0–5) from %HRR (unclamped; extremes agree with
    /// the clamped path at both ends).
    static func zoneWeight(_ bpm: Double, restingHR: Double, hrReserve: Double) -> Int {
        let pct = (bpm - restingHR) / hrReserve * 100.0
        for (threshold, weight) in edwardsZones where pct >= threshold { return weight }
        return 0
    }

    // MARK: - TRIMP accumulation

    /// Longest span (minutes) a single reading may be credited with. A wear or connection dropout
    /// leaves a gap with no data in it; without a ceiling the last reading before the gap would be
    /// credited with the whole hole, so one high-HR sample could invent hours of effort. Two minutes
    /// is four times the sparsest expected WHOOP 5/MG cadence (~30 s), so real samples are preserved.
    public static let maxSampleGapMin: Double = 2.0

    /// Resolve the one Effort value every Today read-out must show. Today's live recompute can lead a
    /// stale daily row, but it can also under-read sparse HR; Effort accrues, so never drop below the
    /// value already stored for the day. Past days pass `nil` for `live`.
    public static func effectiveEffort(live: Double?, stored: Double?) -> Double? {
        guard let live else { return stored }
        guard let stored else { return live }
        return Swift.max(live, stored)
    }

    /// Infer per-sample duration (minutes) from the first two timestamps. Falls
    /// back to 1 s when fewer than two samples or coincident timestamps.
    ///
    /// Production TRIMP uses `sampleDurationsMinutes`; this helper remains so the uniform-cadence
    /// regression can compare the new integration against the previously shipped formula.
    static func sampleDurationMinutes(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return fallbackSampleMin }
        // Convert before subtraction so adversarial Int64 endpoints cannot overflow.
        let deltaS = abs(Double(hr[1].ts) - Double(hr[0].ts))
        return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
    }

    /// Give every sample its own adjacent interval. Each reading covers the gap to its successor,
    /// capped at `maxSampleGapMin`; the final reading reuses the preceding real cadence because it has
    /// no successor. Coincident timestamps retain the historical one-second fallback.
    ///
    /// A single duration inferred from the first pair is incorrect for NOOP's mixed live (~1 s),
    /// banked (~30 s), and dropout-prone streams. Per-interval integration also keeps a workout window
    /// comparable with the day containing it even when the two windows begin at different cadences.
    static func sampleDurationsMinutes(_ hr: [HRSample]) -> [Double] {
        if hr.isEmpty { return [] }
        if hr.count == 1 { return [fallbackSampleMin] }

        var durations: [Double] = []
        durations.reserveCapacity(hr.count)
        for index in 0..<(hr.count - 1) {
            // Convert before subtraction so adversarial Int64 endpoints cannot overflow.
            let deltaS = abs(Double(hr[index + 1].ts) - Double(hr[index].ts))
            let minutes = deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin
            durations.append(min(minutes, maxSampleGapMin))
        }
        durations.append(durations[durations.count - 1])
        return durations
    }

    /// Seconds represented by genuinely adjacent samples. Gaps beyond the hold ceiling are treated as
    /// missing, not as observed coverage. This prevents a handful of isolated readings spread across
    /// hours from satisfying the ten-minute quality gate.
    static func observedCoverageSeconds(_ hr: [HRSample]) -> Double {
        guard hr.count >= 2 else { return 0 }
        let maximumGapSeconds = maxSampleGapMin * 60
        return zip(hr, hr.dropFirst()).reduce(0.0) { total, pair in
            let gap = Double(pair.1.ts) - Double(pair.0.ts)
            guard gap > 0, gap <= maximumGapSeconds else { return total }
            return total + gap
        }
    }

    static func edwardsTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                             durations: [Double]) -> Double {
        let pairedCount = min(hr.count, durations.count)
        guard pairedCount > 0 else { return 0 }
        var accumulated = 0.0
        for index in 0..<pairedCount {
            accumulated += Double(zoneWeight(Double(hr[index].bpm),
                                             restingHR: restingHR,
                                             hrReserve: hrReserve)) * durations[index]
        }
        return accumulated
    }

    static func banisterTRIMP(_ hr: [HRSample], restingHR: Double, hrReserve: Double,
                              durations: [Double], b: Double) -> Double {
        let pairedCount = min(hr.count, durations.count)
        guard pairedCount > 0 else { return 0 }
        var acc = 0.0
        for index in 0..<pairedCount {
            let x = pctHRR(Double(hr[index].bpm), restingHR: restingHR, hrReserve: hrReserve) / 100.0
            if x > 0 { acc += durations[index] * x * banisterScale * exp(b * x) }
        }
        return acc
    }

    // MARK: - Logarithmic map

    /// Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
    /// TRIMP ≤ 0 → 0.
    public static func trimpToStrain(_ trimp: Double, denominator: Double = strainDenominator) -> Double {
        if trimp <= 0 { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        return (value * 100).rounded() / 100
    }

    // MARK: - Denominator calibration

    /// Calibrate D from (TRIMP, reference_strain) pairs via the through-origin
    /// least-squares line: ln(D) = maxStrain × Σ(x²) / Σ(xy), x = ln(TRIMP+1).
    /// (reference_strain pairs must be on the same 0–maxStrain axis as the output.)
    /// Throws when fewer than 2 usable pairs (TRIMP>0, strain>0) or degenerate.
    public static func fitStrainDenominator(_ pairs: [(trimp: Double, strain: Double)]) throws -> Double {
        let usable = pairs.filter { $0.trimp > 0 && $0.strain > 0 }
        guard usable.count >= 2 else { throw StrainError.tooFewPairs }
        var sumXX = 0.0, sumXY = 0.0
        for (trimp, strain) in usable {
            let x = log(trimp + 1.0)
            sumXX += x * x
            sumXY += x * strain
        }
        guard sumXY > 0 && sumXX > 0 else { throw StrainError.degenerate }
        return exp(maxStrain * sumXX / sumXY)
    }

    public enum StrainError: Error, Equatable, Sendable {
        case tooFewPairs
        case degenerate
    }

    // MARK: - Public API

    /// Cardiovascular strain / "Effort" (0–100) from an HR series. APPROXIMATE.
    ///
    /// Returns nil when there isn't yet enough data to trust the number — fewer than
    /// `minReadings` samples AND less than `minSpanSeconds` of HR coverage (the sparse-strap
    /// path, #482) — or when maxHR ≤ restingHR (invalid HRR).
    ///
    /// - Parameters:
    ///   - hr: time-ordered `[HRSample]`.
    ///   - maxHR: HRmax (bpm). Defaults to 220 − defaultAge when nil.
    ///   - restingHR: resting HR (bpm) for the HRR denominator (default 60).
    ///   - method: `.edwards` (default) or `.banister`.
    ///   - sex: "male"/"female" — selects the Banister coefficient (ignored by Edwards).
    ///   - denominator: log-map D (default STRAIN_DENOMINATOR).
    public static func strain(_ hr: [HRSample],
                              maxHR: Double? = nil,
                              restingHR: Double = defaultRestingHR,
                              method: Method = .edwards,
                              sex: String = "male",
                              denominator: Double = strainDenominator) -> Double? {
        // v7.0.2 perf (#707): TRIMP integrates over the day's HR stream; called once per day in the post-sync
        // scoring loop AND from the Today view (which re-reads on each live-HR tick). Memoize on the HR
        // fingerprint + every scalar that steers the score, so an identical re-request is a lookup. The
        // result is a single `Double?`; the HR array is not retained.
        let key = StrainKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            maxHR: maxHR, restingHR: restingHR, method: method,
            sexF: sex.lowercased().hasPrefix("f"), denom: denominator)
        return strainCache.value(key) {
            strainUncached(hr, maxHR: maxHR, restingHR: restingHR, method: method, sex: sex, denominator: denominator)
        }
    }

    /// Workout-bounded Effort using an explicit per-sample duration vector. The general public scorer
    /// keeps its inferred-tail behavior for day/live callers; imported workouts instead pass their one
    /// half-open `[start, end)` vector so TRIMP cannot extend beyond the workout boundary.
    static func strain(_ hr: [HRSample],
                       durationsMinutes: [Double],
                       maxHR: Double? = nil,
                       restingHR: Double = defaultRestingHR,
                       method: Method = .edwards,
                       sex: String = "male",
                       denominator: Double = strainDenominator) -> Double? {
        guard durationsMinutes.count == hr.count else { return nil }
        let coverageSeconds = durationsMinutes.reduce(0.0) { total, duration in
            guard duration.isFinite, duration > 0 else { return total }
            return total + duration * 60.0
        }
        let effMax = maxHR ?? Double(defaultMaxHR())
        let enoughData = hr.count >= minSparseReadings
            && coverageSeconds >= Double(minSpanSeconds - 1)
        guard enoughData, effMax > restingHR else { return nil }

        let hrReserve = effMax - restingHR
        let trimp: Double
        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            trimp = banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                  durations: durationsMinutes, b: b)
        case .edwards:
            trimp = edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                 durations: durationsMinutes)
        }
        return trimpToStrain(trimp, denominator: denominator)
    }

    /// Key folds `sex` to the single bit the recipe reads (`hasPrefix("f")`) so "female"/"f"/"F" all hit.
    private struct StrainKey: Hashable {
        let hr: StreamFingerprint
        let maxHR: Double?; let restingHR: Double; let method: Method
        let sexF: Bool; let denom: Double
    }
    private static let strainCache = AnalyticsMemoCache<StrainKey, Double?>(capacity: 48)

    private static func strainUncached(_ hr: [HRSample], maxHR: Double?, restingHR: Double,
                                       method: Method, sex: String, denominator: Double) -> Double? {
        let effMax = maxHR ?? Double(defaultMaxHR())
        // Dense and sparse streams both need roughly ten minutes of genuinely adjacent coverage.
        // A count/span-only gate lets isolated hourly readings masquerade as continuous wear.
        let enoughData = hr.count >= minSparseReadings
            && observedCoverageSeconds(hr) >= Double(minSpanSeconds - 1)
        if !enoughData || effMax <= restingHR { return nil }

        let durations = sampleDurationsMinutes(hr)
        let hrReserve = effMax - restingHR

        let trimp: Double
        switch method {
        case .banister:
            let b = sex.lowercased().hasPrefix("f") ? banisterBWomen : banisterBMen
            trimp = banisterTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                  durations: durations, b: b)
        case .edwards:
            trimp = edwardsTRIMP(hr, restingHR: restingHR, hrReserve: hrReserve,
                                 durations: durations)
        }
        return trimpToStrain(trimp, denominator: denominator)
    }
}
