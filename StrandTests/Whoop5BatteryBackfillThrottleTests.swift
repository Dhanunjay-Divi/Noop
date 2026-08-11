import XCTest
@testable import Strand

@MainActor
final class Whoop5BatteryBackfillThrottleTests: XCTestCase {
    func testFirstBatteryReadAlwaysPolls() {
        XCTAssertTrue(BLEManager.shouldPollWhoop5Battery(lastReadAt: nil))
    }

    func testBatteryReadThrottleBoundary() {
        let now = Date()
        XCTAssertFalse(BLEManager.shouldPollWhoop5Battery(lastReadAt: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(BLEManager.shouldPollWhoop5Battery(lastReadAt: now.addingTimeInterval(-60), now: now))
        XCTAssertEqual(BLEManager.whoop5BatteryReadMinIntervalSeconds, 60)
    }

    func testKnownEmptyHistoryStretchesButNeverShortens() {
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: 900, lowSeconds: 2700, historyEmpty: true),
            2700)
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: 900, lowSeconds: 300, historyEmpty: true),
            900)
        XCTAssertEqual(
            BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: 900, lowSeconds: 2700, historyEmpty: false),
            900)
    }
}
