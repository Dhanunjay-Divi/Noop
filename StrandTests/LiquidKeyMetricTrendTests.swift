import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class LiquidKeyMetricTrendTests: XCTestCase {
    func testTrendWindowIsChronologicalAndAnchoredToSelectedDay() {
        let days = [
            metric("2026-08-08", hrv: 38),
            metric("2026-08-09", hrv: 40),
            metric("2026-08-18", hrv: 42),
            metric("2026-08-22", hrv: 44),
            metric("2026-08-23", hrv: 99),
        ]

        let trends = LiquidTodayView.keyMetricTrendSeries(
            days: days,
            restSeries: [],
            stepEstimates: [],
            appleRows: [],
            endingAt: "2026-08-22"
        )

        XCTAssertEqual(trends[.hrv], [40, 42, 44])
    }

    func testStepsUseDisplayedPerDaySourcePrecedence() {
        let days = [
            metric("2026-08-20", steps: 2_000),
            metric("2026-08-21", steps: 3_000),
        ]
        let estimates = [
            (day: "2026-08-20", value: 1_000.0),
            (day: "2026-08-21", value: 1_500.0),
            (day: "2026-08-22", value: 1_800.0),
        ]
        let apple = [
            appleDay("2026-08-21", steps: 4_000),
            appleDay("2026-08-22", steps: 5_000),
        ]

        let trends = LiquidTodayView.keyMetricTrendSeries(
            days: days,
            restSeries: [],
            stepEstimates: estimates,
            appleRows: apple,
            endingAt: "2026-08-22"
        )

        XCTAssertEqual(trends[.steps], [2_000, 4_000, 5_000])
    }

    func testSleepAndVitalsKeepOnlyRealFinitePoints() {
        let days = [
            metric("2026-08-20", rhr: 54, respiratory: 14.2, spo2: 97),
            metric("2026-08-21", rhr: nil, respiratory: 14.4, spo2: nil),
            metric("2026-08-22", rhr: 52, respiratory: nil, spo2: 98),
        ]
        let rest = [
            (day: "2026-08-20", value: 71.0),
            (day: "2026-08-21", value: .nan),
            (day: "2026-08-22", value: 84.0),
        ]

        let trends = LiquidTodayView.keyMetricTrendSeries(
            days: days,
            restSeries: rest,
            stepEstimates: [],
            appleRows: [],
            endingAt: "2026-08-22"
        )

        XCTAssertEqual(trends[.rest], [71, 84])
        XCTAssertEqual(trends[.restingHr], [54, 52])
        XCTAssertEqual(trends[.respiratory], [14.2, 14.4])
        XCTAssertEqual(trends[.bloodOxygen], [97, 98])
    }

    func testResolvedBloodOxygenFillsBandDaysWithoutCalibratedPercentages() {
        let days = [
            metric("2026-08-20", spo2: nil),
            metric("2026-08-21", spo2: nil),
        ]
        let resolved = [
            (day: "2026-08-20", value: 96.2),
            (day: "2026-08-21", value: 97.1),
            (day: "2026-08-21", value: .infinity),
            (day: "2026-08-21", value: 12_000),
        ]

        let trends = LiquidTodayView.keyMetricTrendSeries(
            days: days,
            restSeries: [],
            stepEstimates: [],
            appleRows: [],
            endingAt: "2026-08-21",
            resolvedSpo2: resolved
        )

        XCTAssertEqual(trends[.bloodOxygen], [96.2, 97.1])
    }

    func testDirectionDescribesMovementWithoutAssigningGoodOrBadMeaning() {
        XCTAssertEqual(LiquidTodayView.keyMetricTrendDirection([52, 54]), .up)
        XCTAssertEqual(LiquidTodayView.keyMetricTrendDirection([54, 52]), .down)
        XCTAssertEqual(LiquidTodayView.keyMetricTrendDirection([98, 98]), .steady)
        XCTAssertNil(LiquidTodayView.keyMetricTrendDirection([.nan, 52]))
    }

    private func metric(
        _ day: String,
        hrv: Double? = nil,
        rhr: Int? = nil,
        respiratory: Double? = nil,
        spo2: Double? = nil,
        steps: Int? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: rhr,
            avgHrv: hrv,
            recovery: nil,
            strain: nil,
            exerciseCount: nil,
            spo2Pct: spo2,
            respRateBpm: respiratory,
            steps: steps
        )
    }

    private func appleDay(_ day: String, steps: Int?, weightKg: Double? = nil) -> AppleDaily {
        AppleDaily(
            day: day,
            steps: steps,
            activeKcal: nil,
            basalKcal: nil,
            vo2max: nil,
            avgHr: nil,
            maxHr: nil,
            walkingHr: nil,
            weightKg: weightKg
        )
    }
}
