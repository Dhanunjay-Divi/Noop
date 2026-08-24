import XCTest
@testable import StrandAnalytics

final class DailyEffortGuidanceTests: XCTestCase {
    private let range = DailyActionPlanner.EffortRange(lower: 40, upper: 60)

    func testMissingAndInvalidInputsFailClosed() {
        for result in [
            DailyEffortGuidance.evaluate(currentEffort: nil, range: range),
            DailyEffortGuidance.evaluate(currentEffort: .nan, range: range),
            DailyEffortGuidance.evaluate(currentEffort: -1, range: range),
            DailyEffortGuidance.evaluate(currentEffort: 101, range: range),
            DailyEffortGuidance.evaluate(currentEffort: 45, range: nil),
            DailyEffortGuidance.evaluate(
                currentEffort: 45,
                range: .init(lower: 70, upper: 60)
            ),
        ] {
            XCTAssertEqual(result.state, .unavailable)
            XCTAssertNil(result.current)
            XCTAssertNil(result.range)
            XCTAssertNil(result.remainingToLower)
            XCTAssertEqual(result.progress, 0)
        }
    }

    func testBelowRangeReportsRemainingAndCanonicalProgress() {
        let result = DailyEffortGuidance.evaluate(currentEffort: 25, range: range)
        XCTAssertEqual(result.state, .belowRange)
        XCTAssertEqual(result.remainingToLower, 15)
        XCTAssertEqual(result.progress, 0.25)
    }

    func testRangeBoundsAreInclusive() {
        XCTAssertEqual(
            DailyEffortGuidance.evaluate(currentEffort: 40, range: range).state,
            .inRange
        )
        XCTAssertEqual(
            DailyEffortGuidance.evaluate(currentEffort: 60, range: range).state,
            .inRange
        )
    }

    func testAboveRangeIsDescriptiveNotUnavailable() {
        let result = DailyEffortGuidance.evaluate(currentEffort: 72.5, range: range)
        XCTAssertEqual(result.state, .aboveRange)
        XCTAssertEqual(result.current, 72.5)
        XCTAssertEqual(result.remainingToLower, 0)
        XCTAssertEqual(result.progress, 0.725)
    }
}
