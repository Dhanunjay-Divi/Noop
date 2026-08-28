import Combine
import XCTest
@testable import Strand

@MainActor
final class HistorySyncProgressTests: XCTestCase {
    func testProgressPublishesFirstTenthAndExactFinalBatch() {
        let live = LiveState()
        live.beginHistorySync(continuing: false)

        live.noteAcknowledgedHistoryBatch()
        XCTAssertEqual(live.syncChunksThisSession, 1)
        for _ in 2...9 { live.noteAcknowledgedHistoryBatch() }
        XCTAssertEqual(live.syncChunksThisSession, 1)

        live.noteAcknowledgedHistoryBatch()
        XCTAssertEqual(live.syncChunksThisSession, 10)
        for _ in 11...13 { live.noteAcknowledgedHistoryBatch() }
        XCTAssertEqual(live.syncChunksThisSession, 10)

        live.finishHistorySyncProgress()
        XCTAssertEqual(live.syncChunksThisSession, 13)
    }

    func testRowsAndDataFrontierAccumulateAcrossContinuationSlices() {
        let live = LiveState()
        live.beginHistorySync(continuing: false, at: 10)
        live.notePersistedHistoryData(rows: 20, oldestUnix: 200, newestUnix: 300, at: 1)
        live.noteAcknowledgedHistoryBatch(at: 11)
        live.finishHistorySyncProgress()

        live.beginHistorySync(continuing: true, at: 20)
        live.notePersistedHistoryData(rows: 7, oldestUnix: 100, newestUnix: 450, at: 2)
        live.noteAcknowledgedHistoryBatch(at: 21)
        live.finishHistorySyncProgress()

        XCTAssertEqual(live.historySyncProgress.batchesReceived, 2)
        XCTAssertEqual(live.historySyncProgress.rowsPersisted, 27)
        XCTAssertEqual(live.historySyncProgress.oldestDataUnix, 100)
        XCTAssertEqual(live.historySyncProgress.newestDataUnix, 450)
        XCTAssertEqual(live.historySyncStartedAt, 10)
        XCTAssertEqual(live.historySyncLastDurableProgressAt, 21)

        live.beginHistorySync(continuing: false, at: 30)
        XCTAssertEqual(live.historySyncProgress, .init())
        XCTAssertEqual(live.historySyncStartedAt, 30)
        XCTAssertNil(live.historySyncLastDurableProgressAt)
    }

    func testEveryDurableCommitEmitsRevisionWithoutWaitingForUiBatchCadence() {
        let live = LiveState()
        var revisions: [UInt64] = []
        var cancellables = Set<AnyCancellable>()
        live.historyDataPublisher
            .sink { revisions.append($0) }
            .store(in: &cancellables)

        live.notePersistedHistoryData(rows: 1, oldestUnix: 100, newestUnix: 100, at: 1)
        live.notePersistedHistoryData(rows: 1, oldestUnix: 101, newestUnix: 101, at: 2)

        XCTAssertEqual(revisions, [1, 2])
        XCTAssertEqual(live.historyDataRevision, 2)
        XCTAssertEqual(live.lastHistoryDataAt, 2)
    }
}

final class HistorySyncDurableProgressPolicyTests: XCTestCase {
    func testOnlyInsertedRowsOrChangedTrimCountAsDurableProgress() {
        XCTAssertTrue(
            HistorySyncDurableProgressPolicy.advances(
                rows: 1, trim: 42, previousTrim: 42
            )
        )
        XCTAssertTrue(
            HistorySyncDurableProgressPolicy.advances(
                rows: 0, trim: 43, previousTrim: 42
            )
        )
        XCTAssertFalse(
            HistorySyncDurableProgressPolicy.advances(
                rows: 0, trim: 42, previousTrim: 42
            )
        )
    }

    func testStartingWaitingAndStalledBoundariesWithoutProgress() {
        XCTAssertEqual(
            HistorySyncDurableProgressPolicy.activity(
                startedAt: 100, lastDurableProgressAt: nil, now: 109
            ),
            .starting
        )
        XCTAssertEqual(
            HistorySyncDurableProgressPolicy.activity(
                startedAt: 100, lastDurableProgressAt: nil, now: 110
            ),
            .waiting
        )
        XCTAssertFalse(
            HistorySyncDurableProgressPolicy.shouldStop(
                startedAt: 100, lastDurableProgressAt: nil, now: 189
            )
        )
        XCTAssertTrue(
            HistorySyncDurableProgressPolicy.shouldStop(
                startedAt: 100, lastDurableProgressAt: nil, now: 190
            )
        )
    }

    func testDurableReceiptRestartsTheDeadline() {
        XCTAssertEqual(
            HistorySyncDurableProgressPolicy.activity(
                startedAt: 100, lastDurableProgressAt: 150, now: 159
            ),
            .advancing
        )
        XCTAssertEqual(
            HistorySyncDurableProgressPolicy.activity(
                startedAt: 100, lastDurableProgressAt: 150, now: 160
            ),
            .waiting
        )
        XCTAssertTrue(
            HistorySyncDurableProgressPolicy.shouldStop(
                startedAt: 100, lastDurableProgressAt: 150, now: 240
            )
        )
    }

    func testClockRollbackNeverProducesAFalseStall() {
        XCTAssertEqual(
            HistorySyncDurableProgressPolicy.activity(
                startedAt: 100, lastDurableProgressAt: 150, now: 120
            ),
            .advancing
        )
    }
}
