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
        live.beginHistorySync(continuing: false)
        live.notePersistedHistoryData(rows: 20, oldestUnix: 200, newestUnix: 300, at: 1)
        live.noteAcknowledgedHistoryBatch()
        live.finishHistorySyncProgress()

        live.beginHistorySync(continuing: true)
        live.notePersistedHistoryData(rows: 7, oldestUnix: 100, newestUnix: 450, at: 2)
        live.noteAcknowledgedHistoryBatch()
        live.finishHistorySyncProgress()

        XCTAssertEqual(live.historySyncProgress.batchesReceived, 2)
        XCTAssertEqual(live.historySyncProgress.rowsPersisted, 27)
        XCTAssertEqual(live.historySyncProgress.oldestDataUnix, 100)
        XCTAssertEqual(live.historySyncProgress.newestDataUnix, 450)

        live.beginHistorySync(continuing: false)
        XCTAssertEqual(live.historySyncProgress, .init())
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
