import XCTest
import OuraProtocol
@testable import WhoopStore

final class OuraSleepSessionMappingTests: XCTestCase {
    func testStagesMergeButErasedPageGapDoesNot() throws {
        let t0 = 1_700_000_000
        let first = (0..<10).map { (ts: t0 + $0 * 30, stage: OuraSleepStage.deep) }
        // t0+300 and t0+330 intentionally absent: an erased page remains a gap.
        let second = (0..<10).map { (ts: t0 + 360 + $0 * 30, stage: OuraSleepStage.light) }
        let codes = first + second

        let session = try XCTUnwrap(OuraSleepSessionMapping.session(fromCodes: codes))
        XCTAssertEqual(session.startTs, t0)
        XCTAssertEqual(session.endTs, t0 + 660)
        XCTAssertNil(session.efficiency, "efficiency is unknown when erased epochs leave an internal gap")
        XCTAssertEqual(session.stagesJSON,
                       "[{\"start\":\(t0),\"end\":\(t0 + 300),\"stage\":\"deep\",\"source\":\"oura\"}," +
                       "{\"start\":\(t0 + 360),\"end\":\(t0 + 660),\"stage\":\"light\",\"source\":\"oura\"}]")
        XCTAssertTrue(OuraSleepSessionMapping.hasOuraProvenance(session))
    }

    func testEmptyInputCreatesNoSession() {
        XCTAssertNil(OuraSleepSessionMapping.session(fromCodes: []))
    }

    func testAllAwakeFragmentIsNotPromotedToSleepSession() {
        XCTAssertNil(OuraSleepSessionMapping.session(fromCodes: [
            (1_000, .awake), (1_030, .awake),
        ]))
    }

    func testCompleteCoverageComputesEfficiency() throws {
        let codes = (0..<20).map { index in
            (1_000 + index * 30, index < 16 ? OuraSleepStage.deep : OuraSleepStage.awake)
        }
        let session = try XCTUnwrap(OuraSleepSessionMapping.session(fromCodes: codes))
        XCTAssertEqual(session.efficiency ?? -1, 0.8, accuracy: 1e-9)
    }

    func testShortMostlyAsleepFragmentIsNotPromoted() {
        let codes = (0..<10).map { (1_000 + $0 * 30, OuraSleepStage.light) }
        XCTAssertNil(OuraSleepSessionMapping.session(fromCodes: codes))
    }

    func testReconstructedPhaseEventsSurviveStoreNaturalKey() async throws {
        let phases = [
            OuraSleepPhase(ringTimestamp: 10, index: 0, stage: .deep),
            OuraSleepPhase(ringTimestamp: 10, index: 1, stage: .light),
            OuraSleepPhase(ringTimestamp: 10, index: 2, stage: .rem),
            OuraSleepPhase(ringTimestamp: 10, index: 3, stage: .awake),
        ]
        let burst = OuraHypnogramBurst(records: [
            OuraHypnogramRecord(ringTimestamp: 10, phases: phases),
        ])
        let laid = burst.codesWithTimes(endUnixSeconds: 10_000)

        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "oura-test", mac: nil, name: "Oura")
        for code in laid {
            let streams = OuraStreamMapping.streams(from: [.sleepPhase(code.phase)], at: code.ts)
            _ = try await store.insert(streams, deviceId: "oura-test")
        }

        let events = try await store.events(deviceId: "oura-test", from: 0, to: 20_000, limit: 100)
        XCTAssertEqual(events.count, 4,
                       "the event PK is (deviceId, ts, kind), so every phase needs its reconstructed ts")
        XCTAssertEqual(events.map(\.ts), [9_880, 9_910, 9_940, 9_970])
        XCTAssertEqual(events.map { $0.payload["phase"] }, [.int(0), .int(1), .int(2), .int(3)])
    }
}
