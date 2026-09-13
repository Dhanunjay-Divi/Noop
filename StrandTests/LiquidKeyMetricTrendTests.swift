import XCTest
import WhoopStore
@testable import Strand

private final class TrendsCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checkCount = 0
    private let cancelAfter: Int

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
    }

    var checks: Int {
        lock.withLock { checkCount }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            checkCount += 1
            return checkCount >= cancelAfter
        }
    }
}

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

    func testTrendsSnapshotUsesTodayAnchoredQuarterWithoutChangingMetricValues() throws {
        let days = [
            metric("2026-06-14", hrv: 35, rhr: 55, recovery: 10, strain: 15),
            metric("2026-06-15", hrv: 40, rhr: 53, recovery: 20, strain: 30),
            metric("2026-09-12", hrv: 60, rhr: 48, recovery: 80, strain: 70),
        ]

        let snapshot = try XCTUnwrap(TrendsView.buildSnapshot(
            days: days,
            range: .quarter,
            sleepPerfByDay: [
                "2026-06-14": 65,
                "2026-06-15": 75,
                "2026-09-12": 90,
            ],
            todayKey: "2026-09-12"
        ))

        XCTAssertEqual(snapshot.recovery.points.map(\.value), [20, 80])
        XCTAssertEqual(snapshot.hrv.points.map(\.value), [40, 60])
        XCTAssertEqual(snapshot.rhr.points.map(\.value), [53, 48])
        XCTAssertEqual(snapshot.strain.points.map(\.value), [30, 70])
        XCTAssertEqual(snapshot.rest.points.map(\.value), [75, 90])
        XCTAssertEqual(snapshot.recovery.effective, .quarter)
        XCTAssertFalse(snapshot.recovery.widened)
    }

    func testTrendsSnapshotWidensSparseQuarterToAllHistory() throws {
        let snapshot = try XCTUnwrap(TrendsView.buildSnapshot(
            days: [metric("2025-01-01", recovery: 55)],
            range: .quarter,
            sleepPerfByDay: [:],
            todayKey: "2026-09-12"
        ))

        XCTAssertEqual(snapshot.recovery.points.map(\.value), [55])
        XCTAssertEqual(snapshot.recovery.effective, .all)
        XCTAssertTrue(snapshot.recovery.widened)
    }

    func testTrendsSnapshotStopsWhenCancellationIsRequested() {
        let probe = TrendsCancellationProbe(cancelAfter: 2)
        let days = (0..<2_000).map { index in
            metric(
                String(format: "2026-01-%02d", (index % 28) + 1),
                recovery: Double(index % 100)
            )
        }

        let snapshot = TrendsView.buildSnapshot(
            days: days,
            range: .all,
            sleepPerfByDay: [:],
            todayKey: "2026-09-12",
            shouldCancel: { probe.shouldCancel() }
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(probe.checks, 2)
    }

    private func metric(
        _ day: String,
        hrv: Double? = nil,
        rhr: Int? = nil,
        respiratory: Double? = nil,
        spo2: Double? = nil,
        steps: Int? = nil,
        recovery: Double? = nil,
        strain: Double? = nil
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
            recovery: recovery,
            strain: strain,
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
