import XCTest
@testable import Strand

final class PersistedHistoryRefreshWorkerTests: XCTestCase {
    func testFirstCommitRefreshesQuickly() {
        var schedule = PersistedHistoryRefreshSchedule(
            initialDelay: 0.75,
            quietDelay: 2,
            maximumContinuousDelay: 30
        )

        XCTAssertEqual(schedule.noteCommit(revision: 1, at: 10), 10.75)
        XCTAssertNil(schedule.claimIfDue(at: 10.74))
        XCTAssertEqual(schedule.claimIfDue(at: 10.75), .init(revision: 1))
    }

    func testContinuousCommitsCannotStarveRefresh() {
        var schedule = PersistedHistoryRefreshSchedule(
            initialDelay: 0.75,
            quietDelay: 2,
            maximumContinuousDelay: 30
        )
        _ = schedule.noteCommit(revision: 1, at: 0)
        let first = try! XCTUnwrap(schedule.claimIfDue(at: 0.75))
        XCTAssertEqual(schedule.complete(first, at: 1), nil)

        var deadline: TimeInterval?
        for revision in 2...22 {
            let commitAt = 1 + Double(revision - 1) * 1.4
            deadline = schedule.noteCommit(revision: UInt64(revision), at: commitAt)
        }

        XCTAssertEqual(try! XCTUnwrap(deadline), 31, accuracy: 0.000_001)
        XCTAssertNil(schedule.claimIfDue(at: 30.99))
        XCTAssertEqual(schedule.claimIfDue(at: 31), .init(revision: 22))
    }

    func testQuietEdgeRunsFinalTrailingRevision() {
        var schedule = PersistedHistoryRefreshSchedule(
            initialDelay: 0,
            quietDelay: 2,
            maximumContinuousDelay: 30
        )
        _ = schedule.noteCommit(revision: 1, at: 0)
        let first = try! XCTUnwrap(schedule.claimIfDue(at: 0))
        _ = schedule.noteCommit(revision: 2, at: 0.5)

        XCTAssertEqual(schedule.complete(first, at: 1), 2.5)
        XCTAssertNil(schedule.claimIfDue(at: 2.49))
        XCTAssertEqual(schedule.claimIfDue(at: 2.5), .init(revision: 2))
    }

    func testCommitDuringAnalysisDoesNotStartOverlappingClaim() {
        var schedule = PersistedHistoryRefreshSchedule(
            initialDelay: 0,
            quietDelay: 2,
            maximumContinuousDelay: 30
        )
        _ = schedule.noteCommit(revision: 1, at: 0)
        let first = try! XCTUnwrap(schedule.claimIfDue(at: 0))
        XCTAssertNil(schedule.noteCommit(revision: 2, at: 1))
        XCTAssertNil(schedule.claimIfDue(at: 100))

        XCTAssertEqual(schedule.complete(first, at: 3), 3)
        XCTAssertEqual(schedule.claimIfDue(at: 3), .init(revision: 2))
    }
}
