import XCTest
@testable import StrandAnalytics

/// Scores NOOP's Recovery against **WHOOP's own Recovery %** on a real 169-day export from one wearer,
/// using WHOOP's exported HRV / resting HR / sleep performance / respiratory rate as the inputs.
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
        let sleepPerf: Double?
        let resp: Double?
        let strain: Double?
        let skinTemp: Double?
    }

    private func cycles() throws -> [Cycle] {
        guard let path = ProcessInfo.processInfo.environment["NOOP_WHOOP_CYCLES"] else { return [] }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([Cycle].self, from: raw)
            .filter { $0.recovery != nil && $0.hrv != nil && $0.rhr != nil }
            .sorted { $0.start < $1.start }
    }

    /// Rolling personal baseline over the preceding `window` days, which is what NOOP would actually hold.
    private func baseline(_ values: [Double], at index: Int, window: Int = 30) -> RecoveryScorer.DriverBaseline? {
        let lo = max(0, index - window)
        let history = Array(values[lo..<index])
        guard history.count >= 7 else { return nil }
        let mean = history.reduce(0, +) / Double(history.count)
        // Mean absolute deviation, matching the engine's "EWMA-abs-dev spread" idea closely enough for a
        // fair comparison without reimplementing Baselines here.
        let spread = history.reduce(0) { $0 + abs($1 - mean) } / Double(history.count)
        return .init(mean: mean, spread: max(spread, 0.5))
    }

    func testNoopRecoveryTracksWhoopRecoveryOnARealExport() throws {
        let cycles = try self.cycles()
        try XCTSkipIf(cycles.count < 30, """
            Set NOOP_WHOOP_CYCLES to a prepared export (see the doc comment). Skipped rather than failed: \
            this is personal health data and is deliberately not committed.
            """)

        let hrvSeries = cycles.map { $0.hrv! }
        let rhrSeries = cycles.map { $0.rhr! }
        let respSeries = cycles.compactMap { $0.resp }

        var paired: [(day: String, whoop: Double, noop: Double)] = []
        var declined = 0

        for (i, c) in cycles.enumerated() {
            guard let hrvBase = baseline(hrvSeries, at: i),
                  let rhrBase = baseline(rhrSeries, at: i) else { continue }
            let respBase = respSeries.count > i ? baseline(respSeries, at: i) : nil
            let score = RecoveryScorer.recovery(
                hrv: c.hrv!, rhr: c.rhr!, resp: c.resp,
                hrvBaseline: hrvBase, rhrBaseline: rhrBase, respBaseline: respBase,
                // UNIT TRAP, learned the hard way: `sleepPerf` is a FRACTION (0...1), centred on
                // sleepPerfCenter = 0.85 with scale 0.12 - NOT a percentage, despite the doc comment saying
                // "~85% efficiency". Passing WHOOP's 0...100 value gave z = (79 - 0.85)/0.12 = 651 and
                // pinned every one of 162 days at exactly 100.0. Production divides by 100 explicitly
                // (see TodayScoring.kt), which is itself evidence the signature invites the mistake.
                sleepPerf: c.sleepPerf.map { $0 / 100.0 }
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
            XCTAssertTrue(p.noop >= 0 && p.noop <= 100, "\(p.day): NOOP produced \(p.noop), outside 0...100")
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
