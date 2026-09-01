import XCTest
@testable import StrandAnalytics

/// Scores NOOP's Recovery against a provider's reference Recovery % across opt-in private cohorts,
/// using exported HRV / resting HR / respiratory rate plus NOOP Rest derived from exported sleep
/// aggregates.
///
/// This is interoperability/regression evidence for the Charge/Recovery family: same wearer, same nights,
/// shared provider-processed inputs, and the vendor's own score as the reference. It answers whether NOOP
/// moves similarly for a switching user. It is not independent physiological validation.
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
        let day: String
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

    private struct RecoveryPairCandidate {
        let index: Int
        let cycle: Cycle
        let referenceRecovery: Double
        let hrv: Double
        let rhr: Double
    }

    private func decodeCycles(_ raw: Data) throws -> [Cycle] {
        let decoded = try JSONDecoder().decode([Cycle].self, from: raw)
        let duplicateDays = Dictionary(grouping: decoded, by: \.day)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        guard duplicateDays.isEmpty else {
            throw NSError(
                domain: "WhoopExportRecoveryComparisonTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Prepared fixture has ambiguous duplicate wake days: "
                        + duplicateDays.joined(separator: ", ")
                ]
            )
        }
        return decoded.sorted { $0.day < $1.day }
    }

    private func cycles() throws -> [Cycle] {
        guard let path = ProcessInfo.processInfo.environment["NOOP_WHOOP_CYCLES"] else { return [] }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decodeCycles(raw)
    }

    private func recoveryPairCandidates(_ cycles: [Cycle]) -> [RecoveryPairCandidate] {
        cycles.enumerated().compactMap { index, cycle in
            guard let referenceRecovery = cycle.recovery,
                  let hrv = cycle.hrv,
                  let rhr = cycle.rhr else { return nil }
            return RecoveryPairCandidate(
                index: index,
                cycle: cycle,
                referenceRecovery: referenceRecovery,
                hrv: hrv,
                rhr: rhr
            )
        }
    }

    /// Production EWMA baseline from strictly preceding days. Optional rows stay aligned by day.
    private func baseline(_ values: [Double?], at index: Int,
                          cfg: MetricCfg) -> RecoveryScorer.DriverBaseline? {
        let state = Baselines.foldHistory(Array(values[..<index]), cfg: cfg)
        return state.usable ? .init(state) : nil
    }

    /// Derive NOOP Rest without directly reusing the reference Sleep Performance target. The exported
    /// duration, efficiency, and stage aggregates are themselves provider-processed, so this avoids direct
    /// target leakage but is not an independent sensor-level validation.
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

        for candidate in recoveryPairCandidates(cycles) {
            let i = candidate.index
            let c = candidate.cycle
            guard let hrvBase = baseline(hrvSeries, at: i, cfg: Baselines.hrvCfg),
                  let rhrBase = baseline(rhrSeries, at: i, cfg: Baselines.restingHRCfg)
            else { continue }
            let respBase = baseline(respSeries, at: i, cfg: Baselines.respCfg)
            let restBase = baseline(restSeries, at: i, cfg: Baselines.restQualityCfg)
            let score = RecoveryScorer.recovery(
                hrv: candidate.hrv, rhr: candidate.rhr, resp: c.resp,
                hrvBaseline: hrvBase, rhrBaseline: rhrBase, respBaseline: respBase,
                sleepPerf: restSeries[i],
                restQualityBaseline: restBase
            )
            guard let score else { declined += 1; continue }
            paired.append((c.day, candidate.referenceRecovery, score))
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

        // Fixed-fixture regression floors, not population accuracy claims. Every audited cohort clears
        // these with material margin; crossing one means the implementation changed enough to require a
        // new dated verdict rather than silently accepting any positive association.
        XCTAssertGreaterThan(paired.count, 30, "Too few comparable days.")
        if let s = stats, let r = s.correlation {
            XCTAssertGreaterThanOrEqual(
                r,
                0.50,
                "Recovery association fell below the fixed-fixture regression floor (r=\(r)); "
                    + "re-measure and update the dated verdict before changing this threshold."
            )
        }
        XCTAssertGreaterThanOrEqual(
            bandRate,
            0.45,
            "Band agreement fell below the fixed-fixture regression floor."
        )
        if dirTotal > 0 {
            XCTAssertGreaterThanOrEqual(
                Double(dirAgree) / Double(dirTotal),
                0.70,
                "Day-over-day direction agreement fell below the fixed-fixture regression floor."
            )
        }
        for p in paired {
            XCTAssertTrue(
                p.noop >= 0 && p.noop <= 100,
                "NOOP produced an out-of-range score in the private comparison fixture."
            )
        }
    }

    func testMissingReferenceOutcomeRemainsInBaselineHistoryUntilPairing() throws {
        let raw = Data(
            """
            [
              {"day":"2026-01-01","recovery":60,"rhr":60,"hrv":50},
              {"day":"2026-01-02","recovery":null,"rhr":59,"hrv":52},
              {"day":"2026-01-03","recovery":62,"rhr":58,"hrv":54},
              {"day":"2026-01-04","recovery":63,"rhr":57,"hrv":56},
              {"day":"2026-01-05","recovery":64,"rhr":56,"hrv":58}
            ]
            """.utf8
        )
        let cycles = try decodeCycles(raw)
        let candidates = recoveryPairCandidates(cycles)

        XCTAssertEqual(cycles.count, 5)
        XCTAssertNil(cycles[1].recovery)
        XCTAssertEqual(candidates.map(\.index), [0, 2, 3, 4])

        let finalIndex = try XCTUnwrap(candidates.last?.index)
        let hrvSeries = cycles.map(\.hrv)
        let rhrSeries = cycles.map(\.rhr)
        let hrvHistory = Baselines.foldHistory(
            Array(hrvSeries[..<finalIndex]), cfg: Baselines.hrvCfg)
        let rhrHistory = Baselines.foldHistory(
            Array(rhrSeries[..<finalIndex]), cfg: Baselines.restingHRCfg)
        XCTAssertEqual(hrvHistory.nValid, 4)
        XCTAssertEqual(rhrHistory.nValid, 4)
        XCTAssertNotNil(baseline(hrvSeries, at: finalIndex, cfg: Baselines.hrvCfg))
        XCTAssertNotNil(baseline(rhrSeries, at: finalIndex, cfg: Baselines.restingHRCfg))

        let prematurelyFiltered = candidates.map(\.cycle)
        XCTAssertNil(
            baseline(
                prematurelyFiltered.map(\.hrv),
                at: prematurelyFiltered.count - 1,
                cfg: Baselines.hrvCfg
            ),
            "filtering on reference Recovery before folding would discard a valid physiology night"
        )
        XCTAssertNil(
            baseline(
                prematurelyFiltered.map(\.rhr),
                at: prematurelyFiltered.count - 1,
                cfg: Baselines.restingHRCfg
            )
        )
    }

    func testDuplicateWakeDaysAreRejected() {
        let raw = Data(
            """
            [
              {"day":"2026-01-01","recovery":60,"rhr":60,"hrv":50},
              {"day":"2026-01-01","recovery":62,"rhr":58,"hrv":54}
            ]
            """.utf8
        )
        XCTAssertThrowsError(try decodeCycles(raw)) { error in
            XCTAssertTrue(error.localizedDescription.contains("2026-01-01"))
        }
    }

    func testNoopRestAssociatesWithReferenceOutcomeWithoutDirectTargetReuse() throws {
        let cycles = try self.cycles()
        try XCTSkipIf(cycles.count < 30, "Set NOOP_WHOOP_CYCLES (see the class documentation).")
        let paired = cycles.compactMap { cycle -> (day: String, reference: Double, noop: Double)? in
            guard let reference = cycle.sleepPerf,
                  let noop = restQuality(cycle).map({ $0 * 100.0 }) else { return nil }
            return (cycle.day, reference, noop)
        }
        try XCTSkipIf(paired.count < 30, "Too few comparable Rest days.")

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
        print("\n=== NOOP Rest vs reference Sleep Performance (no direct target reuse) ===")
        print(String(format: "days %d    reference mean %.1f    NOOP mean %.1f    bias %+.1f",
                     paired.count, stats.officialMean, stats.noopMean, stats.bias))
        print(String(format: "MAE %.1f    RMSE %.1f    Pearson r %@",
                     stats.meanAbsoluteError, stats.rootMeanSquaredError,
                     stats.correlation.map { String(format: "%.3f", $0) } ?? "n/a"))

        XCTAssertTrue(paired.allSatisfy { (0.0...100.0).contains($0.noop) })
        if let correlation = stats.correlation {
            XCTAssertGreaterThanOrEqual(
                correlation,
                0.50,
                "Rest association fell below the fixed-fixture regression floor; exported stages and "
                    + "efficiency are provider-processed, so re-measure before revising this contract."
            )
        }
    }
}
