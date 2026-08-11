import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RRSourceIntegrityTests: XCTestCase {
    func testSchemaCarriesEmissionOrderAndSourceChannel() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "rrInterval")

        XCTAssertTrue(columns.contains("ord"))
        XCTAssertTrue(columns.contains("srcChannel"))
    }

    func testScoringReadPreservesBeatOrderAndExcludesDuplicateSpO2Channel() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "ring", mac: nil, name: nil)
        _ = try await store.insert(
            Streams(rr: [
                RRInterval(ts: 100, rrMs: 910, srcChannel: .greenQuality),
                RRInterval(ts: 100, rrMs: 700, srcChannel: .spo2Ibi),
                RRInterval(ts: 100, rrMs: 850, srcChannel: .ibiAmplitude),
                RRInterval(ts: 101, rrMs: 820, srcChannel: .ibiBare),
            ]),
            deviceId: "ring"
        )

        let scored = try await store.rrIntervals(
            deviceId: "ring", from: 0, to: 1_000, limit: 100
        )

        XCTAssertEqual(scored.map(\.rrMs), [910, 850, 820],
                       "scoring must keep physiological beat order, not sort by rrMs")
        XCTAssertEqual(scored.map(\.srcChannel),
                       [.greenQuality, .ibiAmplitude, .ibiBare])
        XCTAssertFalse(scored.contains { $0.srcChannel == .spo2Ibi })
    }
}
