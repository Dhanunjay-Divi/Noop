import XCTest
@testable import Strand

final class CompactDailyMetricStatusTests: XCTestCase {
    func testSleepStatusUsesShortScoreBands() {
        XCTAssertEqual(CompactDailyMetricStatus.sleep(score: 59.9), .needMoreRest)
        XCTAssertEqual(CompactDailyMetricStatus.sleep(score: 60), .steady)
        XCTAssertEqual(CompactDailyMetricStatus.sleep(score: 79.9), .steady)
        XCTAssertEqual(CompactDailyMetricStatus.sleep(score: 80), .wellRested)
        XCTAssertNil(CompactDailyMetricStatus.sleep(score: .nan))
    }

    func testEffortStatusUsesCanonicalHundredPointScale() {
        XCTAssertEqual(CompactDailyMetricStatus.effort(score: 29.9), .light)
        XCTAssertEqual(CompactDailyMetricStatus.effort(score: 30), .moderate)
        XCTAssertEqual(CompactDailyMetricStatus.effort(score: 69.9), .moderate)
        XCTAssertEqual(CompactDailyMetricStatus.effort(score: 70), .high)
        XCTAssertNil(CompactDailyMetricStatus.effort(score: .infinity))
    }
}
