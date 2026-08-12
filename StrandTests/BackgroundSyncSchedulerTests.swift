import XCTest
@testable import Strand

final class BackgroundSyncSchedulerTests: XCTestCase {
    func testSuccessfulWakeUsesConservativeRegularDelay() {
        XCTAssertEqual(BackgroundSyncPolicy.delay(afterSuccess: true), 60 * 60)
    }

    func testFailedOrExpiredWakeRetriesSoonerButNotAggressively() {
        XCTAssertEqual(BackgroundSyncPolicy.delay(afterSuccess: false), 20 * 60)
        XCTAssertGreaterThanOrEqual(
            BackgroundSyncPolicy.delay(afterSuccess: false),
            BackgroundSyncPolicy.duplicateAttemptFloor
        )
    }

    func testDuplicateWakeIsDebounced() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(BackgroundSyncPolicy.shouldStart(now: now, lastAttempt: nil))
        XCTAssertFalse(BackgroundSyncPolicy.shouldStart(
            now: now,
            lastAttempt: now.addingTimeInterval(-BackgroundSyncPolicy.duplicateAttemptFloor + 1)
        ))
        XCTAssertTrue(BackgroundSyncPolicy.shouldStart(
            now: now,
            lastAttempt: now.addingTimeInterval(-BackgroundSyncPolicy.duplicateAttemptFloor)
        ))
    }

}
