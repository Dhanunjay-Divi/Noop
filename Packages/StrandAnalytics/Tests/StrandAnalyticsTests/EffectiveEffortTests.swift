import XCTest
@testable import StrandAnalytics

final class EffectiveEffortTests: XCTestCase {
    func testLiveAheadWinsAndStoredFloorsUnderRead() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 2.3, stored: 0.5), 2.3)
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 0, stored: 38.3), 38.3)
    }

    func testSingleSourceAndNoSourceRemainHonest() {
        XCTAssertEqual(StrainScorer.effectiveEffort(live: nil, stored: 12.5), 12.5)
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 4, stored: nil), 4)
        XCTAssertNil(StrainScorer.effectiveEffort(live: nil, stored: nil))
        XCTAssertEqual(StrainScorer.effectiveEffort(live: 0, stored: 0), 0)
    }
}
