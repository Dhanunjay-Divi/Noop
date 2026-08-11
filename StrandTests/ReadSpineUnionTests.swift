import XCTest
import WhoopStore
@testable import Strand

final class ReadSpineUnionTests: XCTestCase {
    private func metric(_ day: String,
                        totalSleepMin: Double? = nil, efficiency: Double? = nil,
                        deepMin: Double? = nil, remMin: Double? = nil, lightMin: Double? = nil,
                        disturbances: Int? = nil, restingHr: Int? = nil, avgHrv: Double? = nil,
                        recovery: Double? = nil, strain: Double? = nil, steps: Int? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency,
                    deepMin: deepMin, remMin: remMin, lightMin: lightMin,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv,
                    recovery: recovery, strain: strain, exerciseCount: nil, steps: steps)
    }

    func testHollowWinnerKeepsOtherStrapColumns() {
        let active = metric("2026-07-29", steps: 10_775)
        let other = metric("2026-07-29", totalSleepMin: 435, efficiency: 91,
                           deepMin: 96, remMin: 110, lightMin: 229,
                           restingHr: 64, avgHrv: 37.06, recovery: 93.2, strain: 8.4)

        let merged = Repository.coalesceDay(active, other)

        XCTAssertEqual(merged.steps, 10_775)
        XCTAssertEqual(merged.totalSleepMin, 435)
        XCTAssertEqual(merged.deepMin, 96)
        XCTAssertEqual(merged.recovery, 93.2)
        XCTAssertEqual(merged.restingHr, 64)
        XCTAssertEqual(merged.avgHrv ?? 0, 37.06, accuracy: 1e-9)
    }

    func testMeasuredZeroIsNotTreatedAsMissing() {
        let active = metric("2026-07-29", avgHrv: 0, strain: 0, steps: 0)
        let filler = metric("2026-07-29", avgHrv: 42, strain: 14.7, steps: 9_120)
        let merged = Repository.coalesceDay(active, filler)

        XCTAssertEqual(merged.steps, 0)
        XCTAssertEqual(merged.strain, 0)
        XCTAssertEqual(merged.avgHrv, 0)
    }

    func testSleepBlockIsNeverAssembledAcrossTwoDevices() {
        let active = metric("2026-07-29", totalSleepMin: 402)
        let filler = metric("2026-07-29", totalSleepMin: 435,
                            deepMin: 96, remMin: 110, lightMin: 229)
        let merged = Repository.coalesceDay(active, filler)

        XCTAssertEqual(merged.totalSleepMin, 402)
        XCTAssertNil(merged.deepMin)
        XCTAssertNil(merged.remMin)
        XCTAssertNil(merged.lightMin)
    }
}
