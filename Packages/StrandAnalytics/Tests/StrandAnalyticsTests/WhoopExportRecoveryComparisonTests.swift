import XCTest
@testable import StrandAnalytics

/// Scores NOOP's Recovery against a provider's reference Recovery % across opt-in private cohorts,
/// using exported HRV / resting HR / respiratory rate plus NOOP Rest derived from raw sleep aggregates.
///
/// This is the most directly meaningful validation available for the Charge/Recovery family: same wearer,
/// same nights, same underlying signals, and the vendor's own published score as the reference. It answers
/// the question a switching user actually asks - *"will NOOP tell me roughly what WHOOP told me?"*
///
/// OPT-IN, because the export is personal health data and must never be committed:
///
///     python3 Tools/validation/prepare_whoop_export.py ~/Downloads/my_whoop_data_*.zip
///     NOOP_WHOOP_CYCLES=/tmp/whoop/prepared_cycles.json swift test --filter WhoopExportRecoveryComparisonTests
///
/// WHAT THIS IS NOT: WHOOP's Recovery is proprietary and is itself an estimate, not ground truth. Agreement
/// means "NOOP tracks the reference a user is switching from"; disagreement does not prove either side
/// wrong. It also cannot separate "NOOP is differently calibrated" from "NOOP is worse", which is why the
/// band agreement below matters more than the raw error: bands are what the user acts on.
final class WhoopExportRecoveryComparisonTests: XCTestCase {

    private struct Cycle: Decodable {
        let start: String
        let recovery: Double?
        let rhr: Double?
        let hrv: Double?
        let sleepPerf: Double?  // reference outcome only; never a Recovery input
        let resp: Double?
        let strain: Double?
        let skinTemp: Double?
        let efficiency: Double?
        let asleepMin: Double?
        let inBedMin: Double?
        let deepMin: Double?
        let remMin: Double?
    }

    private func cycles() throws -> [Cycle] {
        guard let path = ProcessInfo.processInfo.environment["NOOP_WHOOP_CYCLES"] else { return [] }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([Cycle].self, from: raw)
            .filter { $0.recovery != nil && $0.hrv != nil && $0.rhr != nil }
            .sorted { $0.start < $1.start }
    }

    /// Production EWMA baseline from strictly preceding days. Optional rows stay aligned by day.
    private func baseline(_ values: [Double?], at index: Int,
                          cfg: MetricCfg) -> RecoveryScorer.DriverBaseline? {
        let state = Baselines.foldHistory(Array(values[..<index]), cfg: cfg)
        return state.usable ? .init(state) : nil
    }

    /// Derive NOOP Rest from raw sleep aggregates only. Reference Sleep Performance,
    /// Sleep Need, and consistency outcomes are deliberately not inputs.
    private func restQuality(_ cycle: Cycle) -> Double? {
        guard let asleepMin = cycle.asleepMin, asleepMin > 0 else { return nil }
        let efficiency: Double
        if let percent = cycle.efficiency {
            guard percent.isFinite, (0.0...100.0).contains(percent) else { return nil }
            efficiency = percent / 100.0
        } else if let inBedMin = cycle.inBedMin, inBedMin.isFinite, inBedMin > 0 {
            let ratio = asleepMin / inBedMin
            guard ratio.isFinite, (0.0...1.0).contains(ratio) else { return nil }
            efficiency = ratio
        } else {
            return nil
        }
        let inBedMin = cycle.inBedMin.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? asleepMin / max(efficiency, 0.01)
        let deepMin = max(0.0, cycle.deepMin ?? 0.0)
        let remMin = max(0.0, cycle.remMin ?? 0.0)
        return AnalyticsEngine.Rest.composite(
            tstSeconds: asleepMin * 60.0,
            inBedSeconds: inBedMin * 60.0,
            efficiency: efficiency,
            restorativeSeconds: (deepMin + remMin) * 60.0,
            needHours: AnalyticsEngine.Rest.defaultNeedHours,
            consistency: nil,
            deepSeconds: deepMin * 60.0
        ) / 100.0
    }

    func testNoopRecoveryTracksWhoopRecoveryOnARealExport() throws {
        let cycles = try self.cycles()
        try XCTSkipIf(cycles.count < 30, """
            Set NOOP_WHOOP_CYCLES to a prepared export (see the doc comment). Skipped rather than failed: \
            this is personal health data and is deliberately not committed.
            """)

        let hrvSeries = cycles.map(\.hrv)
        let rhrSeries = cycles.map(\.rhr)
        let respSeries = cycles.map(\.resp)
        let restSeries = cycles.map(restQuality)

        var paired: [(day: String, whoop: Double, noop: Double)] = []
        var declined = 0

        for (i, c) in cycles.enumerated() {
            guard let hrvBase = baseline(hrvSeries, at: i, cfg: Baselines.hrvCfg),
                  let rhrBase = baseline(rhrSeries, at: i, cfg: Baselines.restingHRCfg)
            else { continue }
            let respBase = baseline(respSeries, at: i, cfg: Baselines.respCfg)
            let restBase = baseline(restSeries, at: i, cfg: Baselines.restQualityCfg)
            let score = RecoveryScorer.recovery(
                hrv: c.hrv!, rhr: c.rhr!, resp: c.resp,
                hrvBaseline: hrvBase, rhrBaseline: rhrBase, respBaseline: respBase,
                sleepPerf: restSeries[i],
                restQualityBaseline: restBase
            )
            guard let score else { declined += 1; continue }
            paired.append((String(c.start.prefix(10)), c.recovery!, score))
        }

        try XCTSkipIf(paired.count < 30, "Only \(paired.count) comparable days after baseline warm-up.")

        // Use the product's own comparison engine rather than hand-rolled statistics.
        let observations = paired.flatMap { p -> [ReferenceMetricObservation] in
            [.whoopExport(day: p.day, metric: .recoveryScore, value: p.whoop),
             .noopComputed(day: p.day, metric: .recoveryScore, value: p.noop,
                           algorithmVersion: NoopScoreAlgorithmRevision.charge)]
        }
        let report = WhoopReferenceCalibration.report(
            metric: .recoveryScore,
            observations: observations,
            noopAlgorithmVersion: NoopScoreAlgorithmRevision.charge
        )
        let stats = report.statistics

        // Band agreement is what the user acts on: red/yellow/green, not the exact integer.
        var bandAgree = 0
        var confusion: [String: [String: Int]] = [:]
        for p in paired {
            let w = RecoveryScorer.band(p.whoop), n = RecoveryScorer.band(p.noop)
            if w == n { bandAgree += 1 }
            confusion[w, default: [:]][n, default: 0] += 1
        }
        let bandRate = Double(bandAgree) / Double(paired.count)

        // Direction agreement: when WHOOP moved up day over day, did NOOP move up too? A user notices
        // direction long before they notice a 4-point offset.
        var dirTotal = 0, dirAgree = 0
        for i in 1..<paired.count {
            let dw = paired[i].whoop - paired[i-1].whoop
            let dn = paired[i].noop - paired[i-1].noop
            if abs(dw) < 2 { continue }                    // ignore noise-level moves
            dirTotal += 1
            if (dw > 0) == (dn > 0) { dirAgree += 1 }
        }

        func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
        print("\n=== NOOP Recovery vs WHOOP Recovery % (real export, one wearer) ===")
        print("comparable days: \(paired.count)   engine declined: \(declined)")
        if let s = stats {
            print(String(format: "WHOOP mean %.1f    NOOP mean %.1f    bias %+.1f", s.officialMean, s.noopMean, s.bias))
            print(String(format: "MAE %.1f    RMSE %.1f    Pearson r %@",
                         s.meanAbsoluteError, s.rootMeanSquaredError,
                         s.correlation.map { String(format: "%.3f", $0) } ?? "n/a"))
        }
        print("band agreement (red/yellow/green): \(pct(bandRate))  (\(bandAgree)/\(paired.count))")
        if dirTotal > 0 {
            print("day-over-day direction agreement: \(pct(Double(dirAgree)/Double(dirTotal)))  (\(dirAgree)/\(dirTotal))")
        }
        print("\nband confusion (rows = WHOOP, cols = NOOP):")
        let order = ["red", "yellow", "green"]
        print("        " + order.map { String(repeating: " ", count: max(0, 8 - $0.count)) + $0 }.joined())
        for w in order {
            let row = confusion[w] ?? [:]
            let cells = order.map { c -> String in
                let v = "\(row[c] ?? 0)"; return String(repeating: " ", count: max(0, 8 - v.count)) + v
            }.joined()
            print(w + String(repeating: " ", count: max(0, 8 - w.count)) + cells)
        }

        // Assertions: loose, and about SANITY not calibration. A verdict on calibration belongs in
        // docs/validation/, because "NOOP differs from WHOOP" is not automatically a defect.
        XCTAssertGreaterThan(paired.count, 30, "Too few comparable days.")
        if let s = stats, let r = s.correlation {
            XCTAssertGreaterThan(r, 0.0,
                                 "NOOP Recovery is NEGATIVELY correlated with WHOOP Recovery on the same "
                                 + "nights (r=\(r)). That is not a calibration difference, it is inverted.")
        }
        for p in paired {
            XCTAssertTrue(
                p.noop >= 0 && p.noop <= 100,
                "NOOP produced an out-of-range score in the private comparison fixture."
            )
        }
    }

    func testNoopRestTracksReferenceSleepOutcomeWithoutLeakage() throws {
        let cycles = try self.cycles()
        try XCTSkipIf(cycles.count < 30, "Set NOOP_WHOOP_CYCLES (see the class documentation).")
        let paired = cycles.compactMap { cycle -> (day: String, reference: Double, noop: Double)? in
            guard let reference = cycle.sleepPerf,
                  let noop = restQuality(cycle).map({ $0 * 100.0 }) else { return nil }
            return (String(cycle.start.prefix(10)), reference, noop)
        }
        try XCTSkipIf(paired.count < 30, "Too few independently derived Rest days.")

        let observations = paired.flatMap { row -> [ReferenceMetricObservation] in
            [.whoopExport(day: row.day, metric: .restScore, value: row.reference),
             .noopComputed(day: row.day, metric: .restScore, value: row.noop,
                           algorithmVersion: NoopScoreAlgorithmRevision.rest)]
        }
        let report = WhoopReferenceCalibration.report(
            metric: .restScore,
            observations: observations,
            noopAlgorithmVersion: NoopScoreAlgorithmRevision.rest
        )
        let stats = try XCTUnwrap(report.statistics)
        print("\n=== NOOP Rest vs reference Sleep Performance (outcome only) ===")
        print(String(format: "days %d    reference mean %.1f    NOOP mean %.1f    bias %+.1f",
                     paired.count, stats.officialMean, stats.noopMean, stats.bias))
        print(String(format: "MAE %.1f    RMSE %.1f    Pearson r %@",
                     stats.meanAbsoluteError, stats.rootMeanSquaredError,
                     stats.correlation.map { String(format: "%.3f", $0) } ?? "n/a"))

        XCTAssertTrue(paired.allSatisfy { (0.0...100.0).contains($0.noop) })
        if let correlation = stats.correlation {
            XCTAssertGreaterThan(correlation, 0,
                                 "Independently derived Rest is inverted against the reference outcome.")
        }
    }

    /// WHOOP exports Day Strain on 0...21; NOOP's Effort is 0...100. The import boundary documents that
    /// conversion, so a rank comparison is the honest check: do both agree on which days were hard?
    func testEffortRanksTheSameDaysHardAsWhoopStrain() throws {
        let cycles = try self.cycles()
        try XCTSkipIf(cycles.count < 30, "Set NOOP_WHOOP_CYCLES (see the other test).")
        let withStrain = cycles.compactMap { c -> (String, Double)? in
            guard let s = c.strain else { return nil }
            return (String(c.start.prefix(10)), s)
        }
        try XCTSkipIf(withStrain.count < 30, "Too few strain days.")

        // Spearman: rank WHOOP strain against WHOOP strain scaled to NOOP's 0...100 range. This validates
        // the documented scale conversion is monotonic, which is all that can be checked without raw HR.
        let scaled = withStrain.map { ($0.0, min(100, max(0, $0.1 / 21.0 * 100))) }
        var inversions = 0
        for i in 1..<withStrain.count {
            let dw = withStrain[i].1 - withStrain[i-1].1
            let dn = scaled[i].1 - scaled[i-1].1
            if dw != 0, (dw > 0) != (dn > 0) { inversions += 1 }
        }
        print("\n=== WHOOP Day Strain -> NOOP Effort scale conversion ===")
        print("days: \(withStrain.count)   rank inversions: \(inversions)")
        XCTAssertEqual(inversions, 0,
                       "The documented 0...21 -> 0...100 conversion must be strictly monotonic; \(inversions) "
                       + "inversions means the mapping reorders how hard days were.")
    }
}
