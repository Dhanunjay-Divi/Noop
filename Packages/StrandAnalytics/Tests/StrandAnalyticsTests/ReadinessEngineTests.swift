import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ReadinessEngineTests: XCTestCase {

    private func d(_ i: Int, hrv: Double?, rhr: Int?, strain: Double?, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2024-03-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: strain, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: resp)
    }

    /// 28 baseline days with gentle variation (so SD > 0), then `today` as day 29.
    private func baseline(todayHrv: Double?, todayRhr: Int?, todayStrain: Double?,
                          todayResp: Double? = nil, baseStrain: Double = 10) -> [DailyMetric] {
        var days: [DailyMetric] = []
        for i in 1...28 {
            days.append(d(i, hrv: i % 2 == 0 ? 62 : 58, rhr: i % 2 == 0 ? 54 : 50,
                          strain: baseStrain, resp: i % 2 == 0 ? 14.5 : 13.5))
        }
        days.append(d(29, hrv: todayHrv, rhr: todayRhr, strain: todayStrain, resp: todayResp))
        return days
    }

    func testInsufficientWhenEmpty() {
        XCTAssertEqual(ReadinessEngine.evaluate(days: []).level, .insufficient)
    }

    func testPrimedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below, load steady.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10))
        XCTAssertEqual(r.level, .primed)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.flag, .good)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .neutral)
        XCTAssertEqual(r.signals.first { $0.key == "hrv" }?.evidence, "72 vs 60 ms")
        XCTAssertEqual(r.signals.first { $0.key == "rhr" }?.evidence, "46 vs 52 bpm")
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.evidence, "7d 10.0 / 28d 10.0")
        XCTAssertEqual(r.summary,
                       "Your measured recovery trends are aligned with your recent baseline.")
        XCTAssertEqual(r.headline, "Aligned")
        XCTAssertEqual(r.asOfDay, "2024-03-29")
        XCTAssertEqual(r.confidence, .solid)
        XCTAssertEqual(r.baselineDays, 28)
        XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("load"))
        XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("train"))
    }

    func testRundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated → two "bad" recovery signals.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 50, todayRhr: 60, todayStrain: 10))
        XCTAssertEqual(r.level, .rundown)
        XCTAssertEqual(r.headline, "Multiple shifts")
        XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("rest today"))
        XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("train"))
        XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("diagnosis"))
    }

    func testRecentLoadSpikeIsDescriptiveOnly() {
        // With no evaluable recovery signals, even an extreme ratio remains context—not readiness.
        var days: [DailyMetric] = []
        for i in 1...21 { days.append(d(i, hrv: 60, rhr: 52, strain: 5)) }
        for i in 22...28 { days.append(d(i, hrv: 60, rhr: 52, strain: 15)) }
        days.append(d(29, hrv: 60, rhr: 52, strain: 15))
        let r = ReadinessEngine.evaluate(days: days)
        XCTAssertEqual(r.signals.first { $0.key == "acwr" }?.flag, .neutral)
        XCTAssertEqual(r.level, .insufficient)
        XCTAssertNotNil(r.acwr)
        XCTAssertGreaterThan(r.acwr!, 1.5)
        let load = r.signals.first { $0.key == "acwr" }
        XCTAssertEqual(load?.label, "Recent-load ratio")
        XCTAssertTrue(load?.detail.contains("7-day mean is") == true)
        XCTAssertFalse(load?.detail.localizedCaseInsensitiveContains("injury") == true)
        XCTAssertFalse(load?.detail.localizedCaseInsensitiveContains("sweet spot") == true)
        XCTAssertFalse(r.summary.localizedCaseInsensitiveContains("train"))
    }

    func testRecentLoadRatioCannotChangeRecoveryDrivenReadiness() {
        let steady = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        var spiking = steady
        // Eight identical row changes also regress the old XOR cache fingerprint, where even changes
        // cancelled and could return the steady result unchanged.
        for index in 21..<spiking.count {
            let row = spiking[index]
            spiking[index] = DailyMetric(
                day: row.day, totalSleepMin: row.totalSleepMin, efficiency: row.efficiency,
                deepMin: row.deepMin, remMin: row.remMin, lightMin: row.lightMin,
                disturbances: row.disturbances, restingHr: row.restingHr, avgHrv: row.avgHrv,
                recovery: row.recovery, strain: 100, exerciseCount: row.exerciseCount,
                spo2Pct: row.spo2Pct, skinTempDevC: row.skinTempDevC, respRateBpm: row.respRateBpm)
        }

        let steadyReadiness = ReadinessEngine.evaluate(days: steady)
        let spikeReadiness = ReadinessEngine.evaluate(days: spiking)
        XCTAssertEqual(steadyReadiness.level, .primed)
        XCTAssertEqual(spikeReadiness.level, steadyReadiness.level)
        XCTAssertEqual(spikeReadiness.headline, steadyReadiness.headline)
        XCTAssertEqual(spikeReadiness.summary, steadyReadiness.summary)
        XCTAssertEqual(spikeReadiness.signals.first { $0.key == "acwr" }?.flag, .neutral)
        XCTAssertGreaterThan(spikeReadiness.acwr ?? 0, steadyReadiness.acwr ?? 0)
    }

    func testTrainingMonotonyCannotDowngradeAlignedRecovery() {
        var days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        // Keep enough non-zero variation for the Foster ratio, but make the recent week deliberately
        // uniform enough to produce the descriptive Training variety watch signal.
        let recent = [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 11.0, 10.0]
        for (offset, strain) in recent.enumerated() {
            let index = 21 + offset
            let row = days[index]
            days[index] = DailyMetric(
                day: row.day, totalSleepMin: row.totalSleepMin, efficiency: row.efficiency,
                deepMin: row.deepMin, remMin: row.remMin, lightMin: row.lightMin,
                disturbances: row.disturbances, restingHr: row.restingHr, avgHrv: row.avgHrv,
                recovery: row.recovery, strain: strain, exerciseCount: row.exerciseCount,
                spo2Pct: row.spo2Pct, skinTempDevC: row.skinTempDevC, respRateBpm: row.respRateBpm)
        }
        let read = ReadinessEngine.evaluate(days: days)
        XCTAssertNotNil(read.signals.first { $0.key == "monotony" })
        XCTAssertEqual(read.level, .primed)
        XCTAssertEqual(read.headline, "Aligned")
    }

    func testRespRateRiseFlags() {
        // Today's respiratory rate is well above the personal baseline (~14), so a shifted signal is present.
        let r = ReadinessEngine.evaluate(days: baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10, todayResp: 18))
        XCTAssertTrue(r.signals.contains { $0.key == "respRate" })
        XCTAssertEqual(r.signals.first { $0.key == "respRate" }?.evidence, "18.0 vs 14.0 rpm")
        XCTAssertFalse(r.signals.first { $0.key == "respRate" }?.detail.localizedCaseInsensitiveContains("sick") == true)
    }

    func testExplicitTodayWithoutMatchingRowIsInsufficient() {
        // Stale historical import: newest row is 2024-03-29, but the device's real calendar day is later.
        // An explicit `today` with no matching row must read INSUFFICIENT — NOT synthesize off the newest
        // stored (stale) row (issue #23/#24).
        let days = baseline(todayHrv: 72, todayRhr: 46, todayStrain: 10)
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, today: "2026-06-08").level, .insufficient)
        let missing = ReadinessEngine.evaluate(days: days, today: "2026-06-08")
        XCTAssertEqual(missing.asOfDay, "2026-06-08")
        XCTAssertEqual(missing.confidence, .calibrating)
        XCTAssertEqual(missing.baselineDays, 0)
        XCTAssertFalse(missing.limitations.isEmpty)
        // The day that IS present still computes (no regression for current data).
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days, today: "2024-03-29").level, .insufficient)
        // The legacy no-`today` path is unchanged — still falls back to the most recent row.
        XCTAssertNotEqual(ReadinessEngine.evaluate(days: days).level, .insufficient)
    }

    func testHistoricalReadinessIgnoresFutureLoadRows() {
        var days = baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10)
        let historical = ReadinessEngine.evaluate(days: days, today: "2024-03-29")
        days.append(DailyMetric(
            day: "2024-03-30", totalSleepMin: nil, efficiency: nil, deepMin: nil,
            remMin: nil, lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: 60,
            recovery: nil, strain: 100, exerciseCount: nil, spo2Pct: nil,
            skinTempDevC: nil, respRateBpm: 14))
        let withFuture = ReadinessEngine.evaluate(days: days, today: "2024-03-29")
        XCTAssertEqual(withFuture.acwr, historical.acwr)
        XCTAssertEqual(withFuture.signals.first { $0.key == "acwr" },
                       historical.signals.first { $0.key == "acwr" })
    }

    func testSparseRowsAcrossMonthsDoNotBecomeTwentyEightDayLoad() {
        var days: [DailyMetric] = []
        for month in 1...12 {
            for day in [1, 15] {
                days.append(DailyMetric(
                    day: String(format: "2024-%02d-%02d", month, day),
                    totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: 60,
                    recovery: nil, strain: 10, exerciseCount: nil, spo2Pct: nil,
                    skinTempDevC: nil, respRateBpm: 14))
            }
        }
        let result = ReadinessEngine.evaluate(days: days, today: "2024-12-15")
        XCTAssertNil(result.acwr)
        XCTAssertFalse(result.signals.contains { $0.key == "acwr" })
    }

    func testTrainingLoadContextRequiresSeparateAdditiveInput() {
        let days = baseline(todayHrv: 60, todayRhr: 52, todayStrain: 10)
        // DailyMetric.strain is populated, but it is nonlinear and must never silently feed ATL/CTL.
        let withoutAdditiveLoad = ReadinessEngine.evaluate(
            days: days, today: "2024-03-29", additiveLoadEntries: []
        )
        XCTAssertNil(withoutAdditiveLoad.trainingLoad)

        let additive = (1...29).map {
            TrainingLoadModel.Entry(day: String(format: "2024-03-%02d", $0), load: 50)
        }
        let withAdditiveLoad = ReadinessEngine.evaluate(
            days: days, today: "2024-03-29", additiveLoadEntries: additive
        )
        XCTAssertEqual(withAdditiveLoad.readiness,
                       ReadinessEngine.evaluate(days: days, today: "2024-03-29"))
        XCTAssertEqual(withAdditiveLoad.trainingLoad?.day, "2024-03-29")
        XCTAssertEqual(withAdditiveLoad.trainingLoad?.atl, 50)
        XCTAssertEqual(withAdditiveLoad.trainingLoad?.ctl, 50)
        XCTAssertEqual(withAdditiveLoad.trainingLoad?.tsb, 0)
    }

    func testSingleRecoverySignalIsExplicitlyBuildingConfidence() {
        var days: [DailyMetric] = []
        for i in 1...15 {
            days.append(d(i, hrv: i.isMultiple(of: 2) ? 62 : 58,
                          rhr: nil, strain: nil, resp: nil))
        }
        days.append(d(16, hrv: 70, rhr: nil, strain: nil, resp: nil))
        let read = ReadinessEngine.evaluate(days: days, today: "2024-03-16")
        XCTAssertEqual(read.confidence, .building)
        XCTAssertEqual(read.baselineDays, 15)
        XCTAssertTrue(read.limitations.contains { $0.contains("one current recovery signal") })
    }

    func testStatsHelpers() {
        XCTAssertEqual(ReadinessEngine.mean([2, 4, 6]), 4)
        XCTAssertEqual(ReadinessEngine.sampleSD([2, 4, 6])!, 2.0, accuracy: 0.0001)
        XCTAssertNil(ReadinessEngine.sampleSD([5]))
        XCTAssertNil(ReadinessEngine.mean([]))
    }
}
