import Foundation
import WhoopStore

/// On-device "Readiness" intelligence.
///
/// Synthesizes a handful of established, non-medical sports-science signals from the daily-metrics
/// history into a single readiness read plus the drivers behind it. Everything here is a pure,
/// deterministic function of the rows you pass in — no networking, no strap commands, no state.
///
/// Signals and their references:
/// - **HRV readiness** — z-score of today's HRV against the personal trailing baseline. A lower
///   personal-baseline comparison is surfaced as a shift to recheck, not a clinical explanation.
/// - **Resting-HR drift** — resting HR compared with the wearer's own recent baseline.
/// - **Respiratory-rate drift** — sleeping respiratory rate compared with the wearer's own baseline.
/// - **Recent-load ratio (ACWR)** — a fixed-window 7-day/28-day ratio of recorded daily strain.
///   It is retained as descriptive context and is not Training Stress Balance, an injury predictor,
///   or a universal safe-load prescription. `TrainingLoadModel` separately implements ATL/CTL/TSB
///   for additive load units.
/// - **Training monotony** — mean/SD of recorded daily strain over a week. It is descriptive
///   context only; NOOP does not turn it into an injury or illness prediction.
///
/// Not medical advice. These are approximations from a consumer strap; they describe trends in
/// *your own* data, nothing more.
public enum ReadinessEngine {

    // MARK: Output types

    public enum Level: String, Sendable, Equatable {
        case primed       // measured recovery signals aligned
        case balanced     // nothing notable either way
        case strained     // one meaningful recovery signal down
        case rundown      // several recovery signals down
        case insufficient // not enough history yet
    }

    public enum Flag: String, Sendable, Equatable {
        case good, neutral, watch, bad
    }

    public struct Signal: Sendable, Equatable {
        public let key: String      // "hrv" | "rhr" | "respRate" | "acwr" | "monotony"
        public let label: String    // short human label
        public let evidence: String?
        public let detail: String   // one-line plain-English read
        public let flag: Flag
        public init(key: String, label: String, evidence: String? = nil, detail: String, flag: Flag) {
            self.key = key; self.label = label; self.evidence = evidence
            self.detail = detail; self.flag = flag
        }
    }

    public struct Readiness: Sendable, Equatable {
        public let level: Level
        public let headline: String
        public let summary: String
        public let signals: [Signal]
        /// Seven-day mean / 28-day mean of recorded nonlinear strain (nil with insufficient history).
        public let acwr: Double?
        /// Foster training monotony over the last week (nil if not enough strain history).
        public let monotony: Double?
        /// Calendar day this read describes. nil only for legacy callers that did not select a day.
        public let asOfDay: String?
        /// Certainty of the read, derived from signal count and baseline coverage. It never changes
        /// the readiness level or any underlying score.
        public let confidence: ScoreConfidence
        /// Valid strictly-prior baseline days supporting the thinnest evaluated recovery signal.
        public let baselineDays: Int
        /// Plain-language constraints the UI can disclose beside the read.
        public let limitations: [String]
        public init(level: Level, headline: String, summary: String,
                    signals: [Signal], acwr: Double?, monotony: Double?,
                    asOfDay: String? = nil,
                    confidence: ScoreConfidence = .calibrating,
                    baselineDays: Int = 0,
                    limitations: [String] = []) {
            self.level = level; self.headline = headline; self.summary = summary
            self.signals = signals; self.acwr = acwr; self.monotony = monotony
            self.asOfDay = asOfDay; self.confidence = confidence
            self.baselineDays = baselineDays; self.limitations = limitations
        }
    }

    /// Readiness plus optional additive-load context. The existing daily `strain` field is deliberately
    /// not used for ATL/CTL: it is a bounded nonlinear score, not an additive training impulse.
    public struct Context: Sendable, Equatable {
        public let readiness: Readiness
        public let trainingLoad: TrainingLoadModel.Point?

        public init(readiness: Readiness, trainingLoad: TrainingLoadModel.Point?) {
            self.readiness = readiness
            self.trainingLoad = trainingLoad
        }
    }

    // MARK: Tunables (named so the thresholds are auditable)

    private static let baselineWindow = 30   // days for HRV / RHR / RR baselines
    private static let minBaseline    = 7    // need at least this many baseline nights
    private static let acuteWindow    = 7
    private static let chronicWindow  = 28
    private static let minAcute       = 4    // do not call a sparse one-or-two-day sample a "7-day" load
    private static let minChronic     = 14   // need at least this much strain history for ACWR

    // MARK: Entry point

    /// Evaluate readiness from daily metrics. `days` may be in any order; the most recent day is
    /// treated as "today" unless `today` (a YYYY-MM-DD string) is given.
    public static func evaluate(days: [DailyMetric], today: String? = nil) -> Readiness {
        // v7.0.2 perf (#707): `evaluate` SORTS the entire daily history and walks trailing windows every
        // call, and it is read from a SwiftUI computed property — so a `body` re-evaluation (the iOS twin of
        // a Compose recompose) re-runs the full-history sort on each ~1 Hz live-HR tick. The Today view also
        // memoizes this at the View layer (its `todayInputKey`); this engine-level cache additionally shields
        // every OTHER caller and the first/uncached read. Key = `today` + a fingerprint over ONLY the row
        // fields the synthesis reads (day + avgHrv/restingHr/respRateBpm/strain), so a new sync re-keys but a
        // cosmetic reorder does not. Result is a small `Readiness`; no row arrays are retained.
        let key = ReadinessKey(today: today, rows: Self.rowsFingerprint(days))
        return evaluateCache.value(key) { evaluateUncached(days: days, today: today) }
    }

    /// Evaluate readiness and, only when a caller has a genuine additive load source, expose the
    /// matching ATL/CTL/TSB point. Valid inputs include session-RPE minutes, TRIMP, or MET-minutes in
    /// one consistent unit. Empty input stays absent; daily Effort/strain is never substituted.
    public static func evaluate(days: [DailyMetric], today: String? = nil,
                                additiveLoadEntries: [TrainingLoadModel.Entry],
                                trainingLoadConfiguration: TrainingLoadModel.Configuration = .init()) -> Context {
        let readiness = evaluate(days: days, today: today)
        guard !additiveLoadEntries.isEmpty else {
            return Context(readiness: readiness, trainingLoad: nil)
        }
        let series = TrainingLoadModel.evaluate(entries: additiveLoadEntries,
                                                configuration: trainingLoadConfiguration)
        let load = today.flatMap { selected in series.points.first { $0.day == selected } } ??
            (today == nil ? series.latest : nil)
        return Context(readiness: readiness, trainingLoad: load)
    }

    private struct ReadinessKey: Hashable { let today: String?; let rows: StreamFingerprint }
    private static let evaluateCache = AnalyticsMemoCache<ReadinessKey, Readiness>(capacity: 16)

    /// Fingerprint the readiness-relevant columns of the daily rows without re-sorting or copying them.
    /// Order-independent per-row hash (folded into the checksum), so two identical histories in different
    /// order key the same — `evaluate` sorts internally, so order never changes the result.
    private static func rowsFingerprint(_ days: [DailyMetric]) -> StreamFingerprint {
        var sum: UInt64 = 1469598103934665603
        var minDayHash = 0, maxDayHash = 0
        for (i, d) in days.enumerated() {
            // All folds stay in UInt64 — `Double.bitPattern` is already a UInt64 (its sign bit can exceed
            // Int64.max, so an Int64 round-trip would TRAP), and `Int.bitPattern` reinterprets without loss.
            var h: UInt64 = UInt64(bitPattern: Int64(d.day.hashValue))
            h = (h &* 1099511628211) ^ (d.avgHrv ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.restingHr.map { UInt64(bitPattern: Int64($0)) } ?? .max)
            h = (h &* 1099511628211) ^ (d.respRateBpm ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.strain ?? -1).bitPattern
            // Finalize after the last field, then use wrapping addition as the commutative fold. A raw
            // XOR here cancels an even number of identical strain changes because strain is the final
            // field (`oldBits ^ newBits` is then identical for every changed row), returning stale cache.
            h = (h ^ (h >> 32)) &* 1099511628211
            sum &+= h                                  // commutative fold → order-independent
            let dh = d.day.hashValue
            if i == 0 { minDayHash = dh; maxDayHash = dh } else { minDayHash = min(minDayHash, dh); maxDayHash = max(maxDayHash, dh) }
        }
        return StreamFingerprint(count: days.count, firstTs: minDayHash, lastTs: maxDayHash, checksum: sum)
    }

    private static func evaluateUncached(days: [DailyMetric], today: String?) -> Readiness {
        let sorted = days.sorted { $0.day < $1.day }
        // When an explicit `today` is given (the dashboard passes the device's real local day key), use
        // the row for THAT day and nothing else: a stale historical import has no row for today, so the
        // readiness card reads "insufficient" rather than synthesizing off the newest stored - possibly
        // months-old — row (issue #23/#24). With no `today` (live-strap default callers) fall back to the
        // most recent row exactly as before, so nothing wearing the strap nightly changes.
        let latestRow: DailyMetric?
        if let today { latestRow = sorted.first { $0.day == today } } else { latestRow = sorted.last }
        guard let latest = latestRow else {
            return Readiness(level: .insufficient,
                             headline: "Readiness",
                             summary: "A current daily row and enough prior nights are needed for this read.",
                             signals: [], acwr: nil, monotony: nil,
                             asOfDay: today, confidence: .calibrating, baselineDays: 0,
                             limitations: ["No daily recovery row is available for this date."])
        }
        let history = sorted.filter { $0.day < latest.day }   // everything before today

        // Metadata only: these counts explain the evidence supporting the read but never change score
        // weights or thresholds. Use the SAME trailing columns each signal builder reads.
        let trailing = history.suffix(baselineWindow)
        let baselineCountByKey: [String: Int] = [
            "hrv": trailing.compactMap(\.avgHrv).count,
            "rhr": trailing.compactMap(\.restingHr).count,
            "respRate": trailing.compactMap(\.respRateBpm).count,
        ]

        var signals: [Signal] = []

        // HRV readiness ------------------------------------------------------
        let hrvSignal = zSignal(
            value: latest.avgHrv,
            baseline: history.suffix(baselineWindow).compactMap { $0.avgHrv },
            key: "hrv", label: "HRV",
            unit: "ms",
            decimals: 0,
            higherIsBetter: true,
            goodText: "above your recent baseline",
            neutralText: "in your normal range",
            watchText: "a touch below baseline",
            badText: "below your recent baseline")
        if let s = hrvSignal { signals.append(s) }

        // Resting-HR drift ---------------------------------------------------
        let rhrSignal = zSignal(
            value: latest.restingHr.map(Double.init),
            baseline: history.suffix(baselineWindow).compactMap { $0.restingHr.map(Double.init) },
            key: "rhr", label: "Resting HR",
            unit: "bpm",
            decimals: 0,
            higherIsBetter: false,
            goodText: "at or below baseline",
            neutralText: "in your normal range",
            watchText: "running a little high",
            badText: "elevated compared with your recent baseline")
        if let s = rhrSignal { signals.append(s) }

        // Respiratory-rate drift ---------------------------------------------
        // respRateBpm may be a clean cloud value OR a higher-variance on-device RSA estimate, so gate
        // BOTH the latest value and the baseline mean to the plausible sleeping-RR band (8–25 bpm) and
        // use wider resp-only z thresholds (WATCH 1.5 / BAD 2.0) than HRV/RHR so a single noisy night
        // can't flip RUNDOWN. Mirrors the Kotlin reference (#78) for cross-platform parity.
        if let rr = latest.respRateBpm, SleepStager.respPlausibleRangeBpm.contains(rr) {
            let base = history.suffix(baselineWindow).compactMap { $0.respRateBpm }
            if base.count >= minBaseline, let m = mean(base),
               SleepStager.respPlausibleRangeBpm.contains(m), let sd = sampleSD(base), sd > 0 {
                let z = (rr - m) / sd
                if z >= 2.0 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "higher than your recent baseline; recheck across more nights", flag: .bad))
                } else if z >= 1.5 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "slightly raised vs baseline", flag: .watch))
                }
            }
        }

        // Fixed-window recent-load ratio (ACWR) + monotony ------------------
        var acwr: Double? = nil
        var monotony: Double? = nil
        // Anchor load windows to the selected/latest calendar day. The old `sorted.compactMap` path
        // included rows AFTER an explicitly selected historical day, and `suffix(28)` treated 28 sparse
        // readings spread across months as a 28-day training block. Calendar-bounded, one-value-per-day
        // windows prevent both future leakage and false coverage.
        let loadRows = sorted.filter { $0.day <= latest.day }
        if let acuteSeries = calendarWindowStrains(rows: loadRows, ending: latest.day, days: acuteWindow),
           let chronicSeries = calendarWindowStrains(rows: loadRows, ending: latest.day, days: chronicWindow),
           acuteSeries.count >= minAcute, chronicSeries.count >= minChronic {
            let acute = mean(acuteSeries)!
            let chronic = mean(chronicSeries)!
            if chronic > 0 {
                let ratio = acute / chronic
                acwr = ratio
                signals.append(acwrSignal(ratio, acute: acute, chronic: chronic))
            }
            // Foster monotony over the last week of strain.
            let week = acuteSeries
            if week.count >= 4, let sd = sampleSD(week), sd > 0, let m = mean(week) {
                let mono = m / sd
                monotony = mono
                if mono >= 2.0 {
                    let low = week.min() ?? m
                    let high = week.max() ?? m
                    signals.append(Signal(key: "monotony", label: "Training variety",
                        evidence: "Last \(week.count) recorded days: Effort "
                            + "\(Int(low.rounded()))-\(Int(high.rounded())) "
                            + "(average \(Int(m.rounded())))",
                        detail: "recorded daily Effort stayed in a narrow range", flag: .watch))
                }
            }
        }

        let (level, headline, summary) = synthesize(signals: signals,
                                                    hasHistory: !history.isEmpty || acwr != nil)
        let recoveryKeys = Set(["hrv", "rhr", "respRate"])
        let recoverySignals = signals.filter { recoveryKeys.contains($0.key) }
        let supportingCounts = recoverySignals.compactMap { baselineCountByKey[$0.key] }
        let baselineDays = supportingCounts.min() ?? baselineCountByKey.values.max() ?? 0
        let confidence: ScoreConfidence
        if recoverySignals.isEmpty {
            confidence = .calibrating
        } else if recoverySignals.count >= 2 && baselineDays >= Baselines.minNightsTrust {
            confidence = .solid
        } else {
            confidence = .building
        }
        var limitations: [String] = []
        if recoverySignals.isEmpty {
            limitations.append("No current recovery signal has enough prior variation for comparison.")
        } else if recoverySignals.count == 1 {
            limitations.append("This read is based on one current recovery signal.")
        }
        if !recoverySignals.isEmpty && baselineDays < Baselines.minNightsTrust {
            limitations.append("The personal baseline has \(baselineDays) supporting prior days and is still building.")
        }
        if acwr != nil {
            limitations.append("The recent-load ratio is descriptive and does not affect readiness.")
        }
        return Readiness(level: level, headline: headline, summary: summary,
                         signals: signals, acwr: acwr, monotony: monotony,
                         asOfDay: latest.day, confidence: confidence,
                         baselineDays: baselineDays, limitations: limitations)
    }

    // MARK: Signal builders

    /// Build a z-score signal for a metric where the baseline is the trailing window.
    private static func zSignal(value: Double?, baseline: [Double],
                                key: String, label: String, unit: String, decimals: Int,
                                higherIsBetter: Bool,
                                goodText: String, neutralText: String,
                                watchText: String, badText: String) -> Signal? {
        guard let v = value, baseline.count >= minBaseline,
              let m = mean(baseline), let sd = sampleSD(baseline), sd > 0 else { return nil }
        // Orient z so positive always means "better".
        let z = (higherIsBetter ? (v - m) : (m - v)) / sd
        let flag: Flag
        let text: String
        switch z {
        case 0.5...:        flag = .good;    text = goodText
        case -0.5..<0.5:    flag = .neutral; text = neutralText
        case -1.0 ..< -0.5: flag = .watch;   text = watchText
        default:            flag = .bad;     text = badText
        }
        return Signal(key: key, label: label,
                      evidence: evidence(value: v, baseline: m, unit: unit, decimals: decimals),
                      detail: text, flag: flag)
    }

    private static func acwrSignal(_ ratio: Double, acute: Double, chronic: Double) -> Signal {
        let pct = String(format: "%.2f", ratio)
        let evidence = "7d \(String(format: "%.1f", acute)) / 28d \(String(format: "%.1f", chronic))"
        // This ratio has no validated universal "good", "bad", or injury-risk bands. Keep the legacy
        // Signal/Flag API shape, but always emit `.neutral` and state only the arithmetic relationship.
        // `synthesize` also excludes this key so the number cannot change readiness or prescribe training.
        return Signal(key: "acwr", label: "Recent-load ratio",
                      evidence: evidence,
                      detail: "7-day mean is \(pct)x the 28-day mean of recorded strain",
                      flag: .neutral)
    }

    private static func evidence(value: Double, baseline: Double, unit: String, decimals: Int) -> String {
        "\(format(value, decimals: decimals)) vs \(format(baseline, decimals: decimals)) \(unit)"
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(decimals)f", value)
    }

    /// Values inside an actual calendar window, deduplicated to one daily row. ISO day keys compare
    /// lexicographically, but we parse the anchor once so month/year boundaries are handled correctly.
    private static func calendarWindowStrains(rows: [DailyMetric], ending endDay: String,
                                              days: Int) -> [Double]? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let end = formatter.date(from: endDay),
              let start = formatter.calendar.date(byAdding: .day, value: -(days - 1), to: end) else {
            return nil
        }
        let startDay = formatter.string(from: start)
        var byDay: [String: Double] = [:]
        for row in rows where row.day >= startDay && row.day <= endDay {
            if let strain = row.strain { byDay[row.day] = strain }
        }
        return byDay.keys.sorted().compactMap { byDay[$0] }
    }

    // MARK: Synthesis

    private static func synthesize(signals: [Signal], hasHistory: Bool) -> (Level, String, String) {
        // Training-load context (ratio and monotony) is descriptive only. Readiness is synthesized solely
        // from the measured recovery physiology whose personal baselines are evaluated above. Keeping an
        // allow-list prevents a future context signal from silently changing the wellness verdict.
        let evaluativeKeys = Set(["hrv", "rhr", "respRate"])
        let evaluativeSignals = signals.filter { evaluativeKeys.contains($0.key) }
        guard hasHistory, !evaluativeSignals.isEmpty else {
            return (.insufficient, "Readiness",
                    "A few more nights of data and your readiness read will sharpen.")
        }
        let bad = evaluativeSignals.filter { $0.flag == .bad }
        let watch = evaluativeSignals.filter { $0.flag == .watch }
        let good = evaluativeSignals.filter { $0.flag == .good }
        let recoveryDown = evaluativeSignals.contains {
            ["hrv", "rhr", "respRate"].contains($0.key) && $0.flag == .bad
        }

        if bad.count >= 2 {
            return (.rundown, "Multiple shifts",
                    "Several measured signals shifted from your recent range. Recheck the trend and use how you feel as context.")
        }
        if recoveryDown || bad.count >= 1 {
            return (.strained, "One shift",
                    "One measured signal shifted from your recent range. A single day is a cue to recheck, not a diagnosis or training instruction.")
        }
        if good.count >= 2 && watch.isEmpty {
            return (.primed, "Aligned",
                    "Your measured recovery trends are aligned with your recent baseline.")
        }
        return (.balanced, "Within range",
                "Available measured signals are close to your recent baseline.")
    }

    // MARK: Stats helpers

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n-1). nil for fewer than 2 points.
    static func sampleSD(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
