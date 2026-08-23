import XCTest
@testable import Strand

final class SafetySOSGestureTests: XCTestCase {
    func testFourRapidEventsTriggerOnlyOnFourth() {
        var accumulator = SafetySOSGestureAccumulator()

        XCTAssertEqual(
            accumulator.record(eventUptime: 10, requiredEvents: 4),
            .progress(1)
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 12, requiredEvents: 4),
            .progress(2)
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 14, requiredEvents: 4),
            .progress(3)
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 16, requiredEvents: 4),
            .triggered
        )
    }

    func testLongGapStartsANewSequence() {
        var accumulator = SafetySOSGestureAccumulator()

        XCTAssertEqual(
            accumulator.record(eventUptime: 10, requiredEvents: 3),
            .progress(1)
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 11, requiredEvents: 3),
            .progress(2)
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 20, requiredEvents: 3),
            .progress(1)
        )
    }

    func testTriggerResetsAccumulator() {
        var accumulator = SafetySOSGestureAccumulator()
        _ = accumulator.record(eventUptime: 1, requiredEvents: 3)
        _ = accumulator.record(eventUptime: 2, requiredEvents: 3)
        XCTAssertEqual(
            accumulator.record(eventUptime: 3, requiredEvents: 3),
            .triggered
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 4, requiredEvents: 3),
            .progress(1)
        )
    }

    func testRequiredCountIsClampedToSupportedHardwarePolicy() {
        var low = SafetySOSGestureAccumulator()
        _ = low.record(eventUptime: 1, requiredEvents: 1)
        _ = low.record(eventUptime: 2, requiredEvents: 1)
        XCTAssertEqual(
            low.record(eventUptime: 3, requiredEvents: 1),
            .triggered
        )

        var high = SafetySOSGestureAccumulator()
        _ = high.record(eventUptime: 1, requiredEvents: 8)
        _ = high.record(eventUptime: 2, requiredEvents: 8)
        _ = high.record(eventUptime: 3, requiredEvents: 8)
        XCTAssertEqual(
            high.record(eventUptime: 4, requiredEvents: 8),
            .triggered
        )
    }

    func testInvalidClockInputClearsProgress() {
        var accumulator = SafetySOSGestureAccumulator()
        _ = accumulator.record(eventUptime: 1, requiredEvents: 3)

        XCTAssertEqual(
            accumulator.record(eventUptime: .nan, requiredEvents: 3),
            .progress(0)
        )
        XCTAssertEqual(
            accumulator.record(eventUptime: 2, requiredEvents: 3),
            .progress(1)
        )
    }
}
