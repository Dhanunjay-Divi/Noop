import XCTest
@testable import NoopRemoteSync

final class ManagedChunkPayloadTests: XCTestCase {
    func testManagedTimestampAcceptsServerWholeSecondsAndFractionalSeconds() {
        XCTAssertEqual(
            ManagedTimestamp.milliseconds(iso8601: "1970-01-01T00:00:00Z"),
            0
        )
        XCTAssertEqual(
            ManagedTimestamp.milliseconds(iso8601: "1970-01-01T00:00:00.123Z"),
            123
        )
        XCTAssertEqual(
            ManagedTimestamp.milliseconds(iso8601: "1970-01-01T00:00:01+00:00"),
            1_000
        )
    }

    func testAccountScopedInstallationIdentityMatchesCrossPlatformVector() throws {
        let first = try ManagedAccountIdentifier.installationID(
            baseInstallationID: "installation",
            accountScopeHash: String(repeating: "a", count: 64)
        )
        let second = try ManagedAccountIdentifier.installationID(
            baseInstallationID: "installation",
            accountScopeHash: String(repeating: "b", count: 64)
        )

        XCTAssertEqual(first, "8aef8f93-975e-5622-b49d-589684e87197")
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(
            try ManagedAccountIdentifier.installationID(
                baseInstallationID: "installation",
                accountScopeHash: "not-a-scope"
            )
        )
    }

    func testCanonicalChunkIsStableAndManifestBound() throws {
        let sourceID = UUID(uuidString: "fe5d19f4-b8ea-4c97-9c3f-e6532f083883")!
        let stream = ManagedChunkStreamPayload(
            streamKey: "heart_rate",
            columns: ["event_at_ms", "bpm", "quality", "provenance"],
            rows: [
                [.integer(1_788_436_800_000), .integer(68), .null, .string("sensor")],
                [.integer(1_788_436_801_000), .integer(69), .null, .string("sensor")],
            ]
        )

        let first = try XCTUnwrap(
            ManagedPreparedChunk.prepare(
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                eventStartMs: 1_788_436_800_000,
                eventEndMs: 1_788_440_399_999,
                streams: [stream]
            )
        )
        let second = try XCTUnwrap(
            ManagedPreparedChunk.prepare(
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                eventStartMs: 1_788_436_800_000,
                eventEndMs: 1_788_440_399_999,
                streams: [stream]
            )
        )

        XCTAssertEqual(first.payload.chunkID, second.payload.chunkID)
        XCTAssertEqual(first.uncompressed, second.uncompressed)
        XCTAssertEqual(first.manifests.first?.sampleCount, 2)
        XCTAssertEqual(first.manifests.first?.streamKey, "heart_rate")
        XCTAssertEqual(first.uncompressedSHA256.count, 64)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first.uncompressed) as? [String: Any]
        )
        XCTAssertEqual(object["data_class"] as? String, "essential_timeseries")
        XCTAssertEqual(object["chunk_id"] as? String, first.payload.chunkID.uuidString.lowercased())
    }

    func testContentChangeCreatesNewChunkIdentity() throws {
        let sourceID = UUID(uuidString: "fe5d19f4-b8ea-4c97-9c3f-e6532f083883")!
        func prepare(bpm: Int64) throws -> ManagedPreparedChunk {
            try XCTUnwrap(
                ManagedPreparedChunk.prepare(
                    sourceID: sourceID,
                    dataClass: "essential_timeseries",
                    eventStartMs: 1_788_436_800_000,
                    eventEndMs: 1_788_440_399_999,
                    streams: [
                        ManagedChunkStreamPayload(
                            streamKey: "heart_rate",
                            columns: ["event_at_ms", "bpm", "quality", "provenance"],
                            rows: [[
                                .integer(1_788_436_800_000),
                                .integer(bpm),
                                .null,
                                .string("sensor"),
                            ]]
                        ),
                    ]
                )
            )
        }

        XCTAssertNotEqual(
            try prepare(bpm: 68).payload.chunkID,
            try prepare(bpm: 69).payload.chunkID
        )
    }

    func testEmptySnapshotIsCanonicalAndManifestHasNoEventWindow() throws {
        let prepared = try XCTUnwrap(
            ManagedPreparedChunk.prepare(
                sourceID: UUID(uuidString: "fe5d19f4-b8ea-4c97-9c3f-e6532f083883")!,
                dataClass: "essential_timeseries",
                eventStartMs: 1_788_436_800_000,
                eventEndMs: 1_788_440_399_999,
                streams: [
                    ManagedChunkStreamPayload(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: []
                    ),
                ]
            )
        )

        XCTAssertEqual(prepared.manifests.first?.sampleCount, 0)
        XCTAssertNil(prepared.manifests.first?.firstEventAt)
        XCTAssertNil(prepared.manifests.first?.lastEventAt)
        let decoded = try JSONDecoder().decode(
            ManagedChunkPayload.self,
            from: prepared.uncompressed
        )
        XCTAssertEqual(decoded, prepared.payload)
    }

    func testRejectsRowsOutsideReservedWindow() {
        XCTAssertThrowsError(
            try ManagedPreparedChunk.prepare(
                sourceID: UUID(),
                dataClass: "essential_timeseries",
                eventStartMs: 1_000,
                eventEndMs: 2_000,
                streams: [
                    ManagedChunkStreamPayload(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: [[.integer(2_001), .integer(68), .null, .string("sensor")]]
                    ),
                ]
            )
        )
    }
}
