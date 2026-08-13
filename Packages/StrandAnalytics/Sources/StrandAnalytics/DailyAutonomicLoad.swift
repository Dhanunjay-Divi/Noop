import Foundation

// DailyAutonomicLoad.swift — a causal, provenance-carrying daily autonomic-load proxy.
//
// This is deliberately a small, package-native analytics primitive. Callers adapt their
// persistence model into `Day`; this engine does not import an app/store `DailyMetric`.
//
// The experimental wellness proxy compares a target day's resting heart rate and HRV with
// that person's own recent, STRICTLY PRIOR days:
//
//     zRHR = (target RHR - prior mean RHR) / prior SD RHR
//     zHRV = (prior mean HRV - target HRV) / prior SD HRV
//     value = 3 / (1 + exp(-(zRHR + zHRV)))
//
// A target is never allowed into its own baseline. A historical trend is time-causal in the
// signal-processing sense: each point reads only earlier days, so appending future data cannot
// rewrite an older value. "Causal" here does NOT claim that the score identifies the biological
// or psychological cause of a change.
//
// Honesty gates:
// - each contributing signal needs at least seven valid prior daily values;
// - a zero/near-zero baseline spread makes that signal unusable (we do not squash an empty
//   z-score into a manufactured 1.5);
// - one usable signal is explicitly LIMITED; only two usable signals are RELIABLE;
// - this remains an experimental, non-clinical autonomic-load estimate, not WHOOP score parity,
//   a mental-health assessment, or a diagnosis.

public enum DailyAutonomicLoad {

    /// Daily aggregate supplied by a caller. `day` must be an ISO local-day key (`yyyy-MM-dd`)
    /// so chronological order is also lexical order. Values must be finite and positive to be
    /// treated as observed.
    public struct Day: Equatable, Sendable, Codable {
        public let day: String
        public let restingHeartRate: Double?
        public let hrv: Double?

        public init(day: String, restingHeartRate: Double? = nil, hrv: Double? = nil) {
            self.day = day
            self.restingHeartRate = restingHeartRate
            self.hrv = hrv
        }
    }

    /// Signals that actually contributed a standardized term to the value. A measurement that
    /// exists but lacks enough prior history or baseline spread is omitted and explained through
    /// `limitations`.
    public enum Signal: String, Equatable, Sendable, Codable {
        case restingHeartRate
        case heartRateVariability
    }

    public enum Band: String, Equatable, Sendable, Codable {
        case low
        case moderate
        case high

        public init(value: Double) {
            if value < 1.0 { self = .low }
            else if value < 2.0 { self = .moderate }
            else { self = .high }
        }
    }

    /// Certainty describes input support, not medical certainty.
    public enum Confidence: String, Equatable, Sendable, Codable {
        /// No valid 0–3 value passed the history/spread gates.
        case unavailable
        /// Exactly one autonomic signal had a valid target and usable personal baseline.
        case limited
        /// Both resting HR and HRV had valid targets and usable personal baselines.
        case reliable
    }

    public enum Limitation: String, Equatable, Sendable, Codable {
        case targetSignalsMissing
        case restingHeartRateMissing
        case heartRateVariabilityMissing
        case restingHeartRateHistoryInsufficient
        case heartRateVariabilityHistoryInsufficient
        case restingHeartRateBaselineHasNoSpread
        case heartRateVariabilityBaselineHasNoSpread
        case singleSignalEstimate
        /// A newer requested day had no usable target signal, so `asOf` truthfully remains the
        /// older observed day rather than relabelling that value as current.
        case staleSourceDay
        case experimentalNonClinicalProxy
    }

    public struct Readout: Equatable, Sendable, Codable {
        /// Experimental autonomic load on 0...3, or nil when no signal passed every gate.
        public let value: Double?
        public let band: Band?
        public let confidence: Confidence
        /// The actual observed local day scored. This intentionally remains old for stale data.
        public let asOf: String?
        /// Number of valid prior days supporting the least-covered CONTRIBUTING signal. While
        /// unavailable, this is the best candidate signal's history count for calibration UI.
        public let baselineDays: Int
        /// Stable-order list of signals that actually contributed: resting HR, then HRV.
        public let observedSignals: [Signal]
        public let limitations: [Limitation]

        public init(value: Double?, band: Band?, confidence: Confidence, asOf: String?,
                    baselineDays: Int, observedSignals: [Signal], limitations: [Limitation]) {
            self.value = value
            self.band = band
            self.confidence = confidence
            self.asOf = asOf
            self.baselineDays = baselineDays
            self.observedSignals = observedSignals
            self.limitations = limitations
        }
    }

    /// A rolling calendar window, matching the existing daily stress presentation while making
    /// every point causal instead of sharing one full-history baseline.
    public static let baselineWindowDays = 30
    public static let minimumBaselineDays = 7
    /// Below this population SD, division is not meaningful and the signal is withheld.
    public static let minimumUsableSpread = 0.0001

    /// Latest honest read at or before `asOf`. If the requested/latest row has no valid target
    /// signal, the newest earlier observed row is used and its REAL day remains in `Readout.asOf`;
    /// `.staleSourceDay` makes the fallback explicit.
    ///
    /// Supplying `asOf` also establishes a hard information cutoff: rows after that day are ignored.
    public static func readout(days: [Day], asOf requestedAsOf: String? = nil) -> Readout {
        let normalized = normalize(days)
        let requested = requestedAsOf ?? normalized.last?.day
        guard let requested else { return unavailable(asOf: nil) }

        let eligible = normalized.filter { $0.day <= requested }
        guard let target = eligible.last(where: hasObservation) else {
            return unavailable(asOf: nil)
        }

        let prior = Array(eligible.filter { $0.day < target.day }.suffix(baselineWindowDays))
        var result = evaluate(target: target, prior: prior)
        if target.day < requested {
            var limitations = result.limitations
            limitations.append(.staleSourceDay)
            result = Readout(value: result.value, band: result.band,
                             confidence: result.confidence, asOf: result.asOf,
                             baselineDays: result.baselineDays,
                             observedSignals: result.observedSignals,
                             limitations: limitations)
        }
        return result
    }

    /// Historical readouts in ascending day order. Each observed target day is scored only from
    /// the preceding `baselineWindowDays` rows. This is time-causal: adding later rows cannot alter
    /// any already-returned readout. Cold-start observed days remain present with `value == nil` so
    /// consumers can render the calibration period without fabricating a line.
    public static func causalTrend(days: [Day]) -> [Readout] {
        let normalized = normalize(days)
        var result: [Readout] = []
        result.reserveCapacity(normalized.count)

        for target in normalized where hasObservation(target) {
            let prior = Array(normalized.lazy
                .filter { $0.day < target.day }
                .suffix(baselineWindowDays))
            result.append(evaluate(target: target, prior: prior))
        }
        return result
    }

    /// Plain `trend` spelling for callers that do not need the longer explanatory name. It is the
    /// same causal implementation, not a second/global-baseline path.
    public static func trend(days: [Day]) -> [Readout] {
        causalTrend(days: days)
    }

    // MARK: - Pure scoring

    private struct UsableTerm {
        let signal: Signal
        let z: Double
        let baselineDays: Int
    }

    private static func evaluate(target: Day, prior: [Day]) -> Readout {
        var terms: [UsableTerm] = []
        var limitations: [Limitation] = []
        var candidateHistoryCounts: [Int] = []

        buildTerm(target: valid(target.restingHeartRate),
                  baseline: prior.compactMap { valid($0.restingHeartRate) },
                  signal: .restingHeartRate,
                  missing: .restingHeartRateMissing,
                  insufficient: .restingHeartRateHistoryInsufficient,
                  noSpread: .restingHeartRateBaselineHasNoSpread,
                  direction: 1.0,
                  terms: &terms, limitations: &limitations,
                  candidateHistoryCounts: &candidateHistoryCounts)

        buildTerm(target: valid(target.hrv),
                  baseline: prior.compactMap { valid($0.hrv) },
                  signal: .heartRateVariability,
                  missing: .heartRateVariabilityMissing,
                  insufficient: .heartRateVariabilityHistoryInsufficient,
                  noSpread: .heartRateVariabilityBaselineHasNoSpread,
                  direction: -1.0,
                  terms: &terms, limitations: &limitations,
                  candidateHistoryCounts: &candidateHistoryCounts)

        guard !terms.isEmpty else {
            if valid(target.restingHeartRate) == nil && valid(target.hrv) == nil {
                limitations.insert(.targetSignalsMissing, at: 0)
            }
            limitations.append(.experimentalNonClinicalProxy)
            return Readout(value: nil, band: nil, confidence: .unavailable,
                           asOf: target.day,
                           baselineDays: candidateHistoryCounts.max() ?? 0,
                           observedSignals: [], limitations: limitations)
        }

        if terms.count == 1 { limitations.append(.singleSignalEstimate) }
        limitations.append(.experimentalNonClinicalProxy)

        let raw = terms.reduce(0.0) { $0 + $1.z }
        let value = squash(raw)
        let supportingDays = terms.map(\.baselineDays).min() ?? 0
        return Readout(value: value, band: Band(value: value),
                       confidence: terms.count == 2 ? .reliable : .limited,
                       asOf: target.day, baselineDays: supportingDays,
                       observedSignals: terms.map(\.signal), limitations: limitations)
    }

    /// `direction` is +1 for RHR (higher = more load) and -1 for HRV (lower = more load).
    private static func buildTerm(target: Double?, baseline: [Double], signal: Signal,
                                  missing: Limitation, insufficient: Limitation,
                                  noSpread: Limitation, direction: Double,
                                  terms: inout [UsableTerm], limitations: inout [Limitation],
                                  candidateHistoryCounts: inout [Int]) {
        guard let target else {
            limitations.append(missing)
            return
        }
        candidateHistoryCounts.append(baseline.count)
        guard baseline.count >= minimumBaselineDays else {
            limitations.append(insufficient)
            return
        }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        let variance = baseline.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(baseline.count)
        let spread = variance.squareRoot()
        guard spread.isFinite, spread > minimumUsableSpread else {
            limitations.append(noSpread)
            return
        }

        // RHR: +(target - mean)/SD. HRV: -(target - mean)/SD == (mean - target)/SD.
        let z = direction * (target - mean) / spread
        guard z.isFinite else {
            limitations.append(noSpread)
            return
        }
        terms.append(UsableTerm(signal: signal, z: z, baselineDays: baseline.count))
    }

    /// Explicit experimental 0–3 logistic. Called only after at least one real z term exists.
    static func squash(_ raw: Double) -> Double {
        let value = 3.0 / (1.0 + exp(-raw))
        return min(max(value, 0.0), 3.0)
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func hasObservation(_ day: Day) -> Bool {
        valid(day.restingHeartRate) != nil || valid(day.hrv) != nil
    }

    /// Coalesce duplicate day keys so duplicate persistence rows cannot inflate "baseline days".
    /// A later supplied non-nil valid value wins signal-by-signal, matching incremental sync use.
    private static func normalize(_ days: [Day]) -> [Day] {
        var byDay: [String: Day] = [:]
        for day in days where !day.day.isEmpty {
            if let existing = byDay[day.day] {
                byDay[day.day] = Day(
                    day: day.day,
                    restingHeartRate: valid(day.restingHeartRate) ?? valid(existing.restingHeartRate),
                    hrv: valid(day.hrv) ?? valid(existing.hrv)
                )
            } else {
                byDay[day.day] = Day(day: day.day,
                                     restingHeartRate: valid(day.restingHeartRate),
                                     hrv: valid(day.hrv))
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func unavailable(asOf: String?) -> Readout {
        Readout(value: nil, band: nil, confidence: .unavailable, asOf: asOf,
                baselineDays: 0, observedSignals: [],
                limitations: [.targetSignalsMissing, .experimentalNonClinicalProxy])
    }
}
