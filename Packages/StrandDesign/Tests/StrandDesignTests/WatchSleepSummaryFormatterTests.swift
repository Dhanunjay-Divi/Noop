import XCTest
@testable import StrandDesign

final class WatchSleepSummaryFormatterTests: XCTestCase {
    private func summary(
        totalSleepMinutes: Double?,
        efficiency: Double?
    ) -> String {
        WatchSleepSummaryFormatter.format(
            totalSleepMinutes: totalSleepMinutes,
            efficiency: efficiency,
            durationText: { "\($0)h \($1)m" },
            efficiencyText: { "\($0)% sleep efficiency" }
        )
    }

    func testLabelsEfficiencySeparatelyFromSleepScoreOnMacOS() {
        XCTAssertEqual(
            summary(totalSleepMinutes: 432, efficiency: 0.91),
            "7h 12m · 91% sleep efficiency"
        )
    }

    func testAcceptsPercentStyleEfficiencyAndIndependentMissingValues() {
        XCTAssertEqual(
            summary(totalSleepMinutes: nil, efficiency: 88),
            "88% sleep efficiency"
        )
        XCTAssertEqual(
            summary(totalSleepMinutes: 400, efficiency: nil),
            "6h 40m"
        )
        XCTAssertEqual(
            summary(totalSleepMinutes: nil, efficiency: nil),
            ""
        )
    }
}
