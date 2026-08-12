import XCTest
@testable import Strand

final class DailyEnergyBreakdownTests: XCTestCase {
    func testCompleteAppleComponentsProduceTotal() {
        let result = DailyEnergyBreakdown.resolve(
            appleActiveKcal: 540,
            appleRestingKcal: 1_680,
            wearableCombinedKcal: 9_999
        )

        XCTAssertEqual(result.coverage, .completeApple)
        XCTAssertEqual(result.activeKcal, 540)
        XCTAssertEqual(result.restingKcal, 1_680)
        XCTAssertEqual(result.totalKcal, 2_220)
        XCTAssertEqual(result.headlineKcal, 2_220)
    }

    func testPartialAppleNeverBorrowsWearableTotal() {
        let activeOnly = DailyEnergyBreakdown.resolve(
            appleActiveKcal: 420,
            appleRestingKcal: nil,
            wearableCombinedKcal: 2_100
        )
        XCTAssertEqual(activeOnly.coverage, .activeOnly)
        XCTAssertEqual(activeOnly.activeKcal, 420)
        XCTAssertNil(activeOnly.restingKcal)
        XCTAssertNil(activeOnly.totalKcal,
                     "a combined wearable estimate cannot fill Apple's missing resting component")
        XCTAssertEqual(activeOnly.headlineKcal, 420)

        let restingOnly = DailyEnergyBreakdown.resolve(
            appleActiveKcal: nil,
            appleRestingKcal: 1_500,
            wearableCombinedKcal: 2_100
        )
        XCTAssertEqual(restingOnly.coverage, .restingOnly)
        XCTAssertNil(restingOnly.activeKcal)
        XCTAssertEqual(restingOnly.restingKcal, 1_500)
        XCTAssertNil(restingOnly.totalKcal)
        XCTAssertEqual(restingOnly.headlineKcal, 1_500)
    }

    func testWearableValueRemainsCombinedWithoutInventedSplit() {
        let result = DailyEnergyBreakdown.resolve(
            appleActiveKcal: nil,
            appleRestingKcal: nil,
            wearableCombinedKcal: 1_940
        )

        XCTAssertEqual(result.coverage, .combinedEstimateOnly)
        XCTAssertNil(result.activeKcal)
        XCTAssertNil(result.restingKcal)
        XCTAssertEqual(result.totalKcal, 1_940)
        XCTAssertEqual(result.headlineKcal, 1_940)
    }

    func testInvalidInputsDoNotBecomeEnergy() {
        let result = DailyEnergyBreakdown.resolve(
            appleActiveKcal: .nan,
            appleRestingKcal: -10,
            wearableCombinedKcal: .infinity
        )

        XCTAssertEqual(result.coverage, .unavailable)
        XCTAssertNil(result.headlineKcal)
    }

    func testTotalSeriesIncludesOnlyPairedDays() {
        let totals = DailyEnergyBreakdown.appleTotalSeries(
            active: [
                ("2026-08-08", 300),
                ("2026-08-09", 400),
                ("2026-08-10", 500),
            ],
            resting: [
                ("2026-08-08", 1_600),
                ("2026-08-10", 1_700),
                ("2026-08-11", 1_710),
            ]
        )

        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].day, "2026-08-08")
        XCTAssertEqual(totals[0].value, 1_900)
        XCTAssertEqual(totals[1].day, "2026-08-10")
        XCTAssertEqual(totals[1].value, 2_200)
    }

    func testRoutingMatchesHeadlineQuantity() {
        let complete = DailyEnergyBreakdown.resolve(
            appleActiveKcal: 400, appleRestingKcal: 1_600, wearableCombinedKcal: nil)
        XCTAssertEqual(MetricCatalog.todayEnergyMetric(for: complete)?.id,
                       "apple-health:total_kcal")

        let active = DailyEnergyBreakdown.resolve(
            appleActiveKcal: 400, appleRestingKcal: nil, wearableCombinedKcal: 2_000)
        XCTAssertEqual(MetricCatalog.todayEnergyMetric(for: active)?.id,
                       "apple-health:active_kcal")

        let combined = DailyEnergyBreakdown.resolve(
            appleActiveKcal: nil, appleRestingKcal: nil, wearableCombinedKcal: 2_000)
        XCTAssertEqual(MetricCatalog.todayEnergyMetric(for: combined)?.id,
                       "my-whoop:energy_kcal")
    }
}
