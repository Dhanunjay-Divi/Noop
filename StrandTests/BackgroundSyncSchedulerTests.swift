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

    func testPrivacySensitiveWakeCanAdvanceButNotDelayMaintenance() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(
            BackgroundSyncPolicy.nextBeginDate(
                afterSuccess: true,
                now: now,
                requestedWake: now.addingTimeInterval(15 * 60)
            ),
            now.addingTimeInterval(15 * 60)
        )
        XCTAssertEqual(
            BackgroundSyncPolicy.nextBeginDate(
                afterSuccess: true,
                now: now,
                requestedWake: now.addingTimeInterval(2 * 60 * 60)
            ),
            now.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            BackgroundSyncPolicy.nextBeginDate(
                afterSuccess: false,
                now: now,
                requestedWake: now.addingTimeInterval(-1)
            ),
            now.addingTimeInterval(60)
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

    func testCompletedMaintenanceDoesNotRequireOptionalBandWork() {
        XCTAssertTrue(BackgroundSyncPolicy.completedMaintenance(
            optionalBandWorkCompleted: true,
            cancelled: false
        ))
        XCTAssertTrue(BackgroundSyncPolicy.completedMaintenance(
            optionalBandWorkCompleted: false,
            cancelled: false
        ))
        XCTAssertFalse(BackgroundSyncPolicy.completedMaintenance(
            optionalBandWorkCompleted: true,
            cancelled: true
        ))
        XCTAssertFalse(BackgroundSyncPolicy.completedMaintenance(
            optionalBandWorkCompleted: false,
            cancelled: true
        ))
    }

    func testStaleSyncReminderRequiresPairingAndExistingAuthorization() {
        XCTAssertTrue(BandSyncStaleReminderPolicy.shouldSchedule(
            hasPairedBand: true,
            notificationsAuthorized: true
        ))
        XCTAssertFalse(BandSyncStaleReminderPolicy.shouldSchedule(
            hasPairedBand: false,
            notificationsAuthorized: true
        ))
        XCTAssertFalse(BandSyncStaleReminderPolicy.shouldSchedule(
            hasPairedBand: true,
            notificationsAuthorized: false
        ))
        XCTAssertEqual(BandSyncStaleReminderPolicy.delay, 2 * 60 * 60)
    }

    func testDurableProgressKeepsCountdownArmedWithoutWaitingForSyncCompletion() {
        XCTAssertTrue(BandSyncStaleReminderPolicy.shouldRefreshAfterDurableProgress(
            appIsActive: false,
            hasPairedBand: true
        ))
        XCTAssertFalse(BandSyncStaleReminderPolicy.shouldRefreshAfterDurableProgress(
            appIsActive: true,
            hasPairedBand: true
        ))
        XCTAssertFalse(BandSyncStaleReminderPolicy.shouldRefreshAfterDurableProgress(
            appIsActive: false,
            hasPairedBand: false
        ))
    }

}
