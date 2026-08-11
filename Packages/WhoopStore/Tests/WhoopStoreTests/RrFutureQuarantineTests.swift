import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Future-stamped R-R beats are retained for recovery but excluded from scoring.
final class RrFutureQuarantineTests: XCTestCase {
    func testV31AddsTsSuspectAndKeepsThePrimaryKey() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("tsSuspect"), "rrInterval missing v31 tsSuspect column")
        let pk = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(pk, ["deviceId", "ts", "rrMs", "seq"],
                       "tsSuspect must not enter the primary key")
    }

    func testFutureBeatsAreQuarantinedExcludedFromScoringAndKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        let now = 1_700_000_000
        let rows = [
            RRInterval(ts: now - 20, rrMs: 800),
            RRInterval(ts: now - 10, rrMs: 810),
            RRInterval(ts: now + 86_400, rrMs: 820),
            RRInterval(ts: now + 315_360_000, rrMs: 830),
        ]
        _ = try await store.insert(Streams(rr: rows), deviceId: "ring")

        try await store.markFutureRrSuspectForTest(nowSeconds: now)

        let onDisk = try await store.rrSuspectRowsForTest(deviceId: "ring")
        XCTAssertEqual(onDisk.count, 4, "quarantine marks rows instead of deleting them")
        XCTAssertEqual(onDisk.filter { $0.tsSuspect == 1 }.map(\.ts),
                       [now + 86_400, now + 315_360_000])
        XCTAssertNil(onDisk.first(where: { $0.ts == now - 20 })?.tsSuspect)

        let scored = try await store.rrIntervals(deviceId: "ring", from: 0,
                                                 to: now + 400_000_000, limit: 1_000)
        XCTAssertEqual(scored.map(\.rrMs), [800, 810])
    }
}
