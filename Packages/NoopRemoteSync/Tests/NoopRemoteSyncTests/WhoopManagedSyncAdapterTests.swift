import GRDB
import XCTest
@testable import NoopRemoteSync
@testable import WhoopStore

final class WhoopManagedSyncAdapterTests: XCTestCase {
    private let sourceID = UUID(uuidString: "c8c2260b-0069-413d-a8c5-9f6e248405db")!
    private let eventMs: Int64 = 1_788_393_600_000
    private let accountScopeHash = String(repeating: "d", count: 64)

    func testCanonicalChunkAppliesToIsolatedCloudSource() async throws {
        let store = try await WhoopStore.inMemory()
        let prepared = try XCTUnwrap(try makePreparedChunk(bpm: 68))
        let change = makeChange(for: prepared)

        try await WhoopManagedRestoreApplier(store: store).apply(
            chunk: prepared.payload,
            change: change
        )

        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT deviceId, bpm FROM hrSample"
            )
        }
        XCTAssertEqual(
            row?["deviceId"] as String?,
            "noop-plus-\(sourceID.uuidString.lowercased())"
        )
        XCTAssertEqual(row?["bpm"] as Int?, 68)
    }

    func testPayloadWhoseContentDoesNotMatchChunkIdentityIsRejected() async throws {
        let store = try await WhoopStore.inMemory()
        let prepared = try XCTUnwrap(try makePreparedChunk(bpm: 68))
        let changedStream = ManagedChunkStreamPayload(
            streamKey: "heart_rate",
            columns: ["event_at_ms", "bpm", "quality", "provenance"],
            rows: [[
                .integer(eventMs), .integer(69), .null, .string("sensor"),
            ]]
        )
        let tampered = ManagedChunkPayload(
            chunkID: prepared.payload.chunkID,
            sourceID: sourceID,
            dataClass: "essential_timeseries",
            eventStartMs: eventMs,
            eventEndMs: eventMs,
            streams: [changedStream]
        )

        do {
            try await WhoopManagedRestoreApplier(store: store).apply(
                chunk: tampered,
                change: makeChange(for: prepared)
            )
            XCTFail("Expected deterministic identity mismatch")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }

        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedSyncSource")
        }
        XCTAssertEqual(count, 0)
    }

    func testDocumentFailsClosedWithoutDocumentRestorer() async throws {
        let store = try await WhoopStore.inMemory()
        let documentID = UUID()
        let digest = String(repeating: "b", count: 64)
        let updatedAt = "2026-09-03T00:00:00.000Z"
        let document = ManagedDocument(
            documentKind: .preferences,
            documentID: documentID,
            revision: 1,
            originInstallationID: "ios-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: digest,
            payloadJSON: ["units": .string("metric")],
            payloadCiphertextBase64: nil,
            updatedAt: updatedAt,
            deletedAt: nil,
            duplicate: false
        )
        let change = ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: "document",
            resourceID: documentID,
            operation: "upsert",
            contentSHA256: digest,
            dataClass: nil,
            eventStart: nil,
            eventEnd: nil,
            chunk: nil,
            document: ManagedChangeFeed.Change.Document(
                documentKind: .preferences,
                documentID: documentID,
                revision: 1,
                contentMode: "server_readable",
                clientKeyID: nil,
                updatedAt: updatedAt,
                deletedAt: nil
            )
        )

        do {
            try await WhoopManagedRestoreApplier(store: store).apply(
                document: document,
                change: change
            )
            XCTFail("Expected missing document restorer to fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testDocumentUsesServerOperationVocabulary() async throws {
        let store = try await WhoopStore.inMemory()
        let restorer = DocumentRestoreSpy()
        let documentID = UUID()
        let digest = String(repeating: "c", count: 64)
        let updatedAt = "2026-09-03T00:00:00.000Z"
        let deletedAt = "2026-09-03T00:01:00.000Z"
        let applier = WhoopManagedRestoreApplier(
            store: store,
            documentRestore: restorer
        )

        for (sequence, operation, deletion) in [
            (Int64(1), "upsert", Optional<String>.none),
            (Int64(2), "tombstone", Optional(deletedAt)),
        ] {
            let document = ManagedDocument(
                documentKind: .preferences,
                documentID: documentID,
                revision: sequence,
                originInstallationID: "ios-installation",
                contentMode: "server_readable",
                clientKeyID: nil,
                contentSHA256: digest,
                payloadJSON: deletion == nil ? ["units": .string("metric")] : nil,
                payloadCiphertextBase64: nil,
                updatedAt: updatedAt,
                deletedAt: deletion,
                duplicate: false
            )
            let change = ManagedChangeFeed.Change(
                sequence: sequence,
                resourceKind: "document",
                resourceID: documentID,
                operation: operation,
                contentSHA256: digest,
                dataClass: "user_documents",
                eventStart: nil,
                eventEnd: nil,
                chunk: nil,
                document: ManagedChangeFeed.Change.Document(
                    documentKind: .preferences,
                    documentID: documentID,
                    revision: sequence,
                    contentMode: "server_readable",
                    clientKeyID: nil,
                    updatedAt: updatedAt,
                    deletedAt: deletion
                )
            )

            try await applier.apply(document: document, change: change)
        }

        let operations = await restorer.operations()
        XCTAssertEqual(operations, ["upsert", "tombstone"])
    }

    func testJournalDocumentOutboxAndRestoreRoundTrip() async throws {
        let source = try await WhoopStore.inMemory()
        try await source.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO journal (
                    deviceId, day, question, answeredYes, notes, numericValue
                ) VALUES (
                    'strap', '2026-09-04', 'late_caffeine', 1, 'after lunch', 2.5
                )
                """)
        }
        let sourceAdapter = try WhoopManagedDocumentAdapter(
            store: source,
            accountScopeHash: accountScopeHash
        )
        let pendingDocuments = try await sourceAdapter.pendingDocuments(limit: 10)
        let pending = try XCTUnwrap(pendingDocuments.first)
        XCTAssertEqual(pending.mutation.documentKind, .journal)
        XCTAssertEqual(
            pending.mutation.documentID.uuidString.lowercased(),
            "a2810672-1c29-5e68-9ddd-45e8c3164500"
        )
        XCTAssertEqual(pending.mutation.baseRevision, 0)
        let remote = try remoteDocument(for: pending.mutation)
        try await sourceAdapter.acknowledge(pending, remote: remote)
        let remaining = try await sourceAdapter.pendingDocuments(limit: 10)
        XCTAssertTrue(remaining.isEmpty)

        let destination = try await WhoopStore.inMemory()
        let destinationAdapter = try WhoopManagedDocumentAdapter(
            store: destination,
            accountScopeHash: accountScopeHash
        )
        try await WhoopManagedRestoreApplier(
            store: destination,
            documentRestore: destinationAdapter
        ).apply(
            document: remote,
            change: documentChange(remote)
        )

        let restored = try await destination.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT answeredYes, notes, numericValue FROM journal
                    WHERE deviceId = 'strap' AND day = '2026-09-04'
                      AND question = 'late_caffeine'
                    """
            )
        }
        XCTAssertEqual(restored?["answeredYes"] as Bool?, true)
        XCTAssertEqual(restored?["notes"] as String?, "after lunch")
        XCTAssertEqual(restored?["numericValue"] as Double?, 2.5)
        let destinationPending = try await destinationAdapter.pendingDocuments(
            limit: 10
        )
        XCTAssertTrue(destinationPending.isEmpty)
    }

    func testPreferencesRestoreAppliesOnlyBackupWhitelist() async throws {
        let source = try await WhoopStore.inMemory()
        let payload = Data(
            #"{"profile.age":34,"settings.schemaVersion":4,"units.system":"metric"}"#.utf8
        )
        try await source.stageManagedPreferences(payload, updatedAtMs: eventMs)
        let sourceAdapter = try WhoopManagedDocumentAdapter(
            store: source,
            accountScopeHash: accountScopeHash
        )
        let pendingDocuments = try await sourceAdapter.pendingDocuments(limit: 1)
        let pending = try XCTUnwrap(pendingDocuments.first)
        let remote = try remoteDocument(for: pending.mutation)

        let suite = "WhoopManagedSyncAdapterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = try await WhoopStore.inMemory()
        let destinationAdapter = try WhoopManagedDocumentAdapter(
            store: destination,
            accountScopeHash: accountScopeHash,
            preferencesDefaults: defaults
        )
        try await destinationAdapter.apply(
            document: remote,
            change: documentChange(remote)
        )

        XCTAssertEqual(defaults.integer(forKey: "profile.age"), 34)
        XCTAssertEqual(defaults.string(forKey: "units.system"), "metric")
        XCTAssertNil(defaults.object(forKey: "managedCloud.automatic.v1"))
        let destinationPending = try await destinationAdapter.pendingDocuments(
            limit: 10
        )
        XCTAssertTrue(destinationPending.isEmpty)
    }

    private func makePreparedChunk(bpm: Int64) throws -> ManagedPreparedChunk? {
        try ManagedPreparedChunk.prepare(
            sourceID: sourceID,
            dataClass: "essential_timeseries",
            eventStartMs: eventMs,
            eventEndMs: eventMs,
            streams: [
                ManagedChunkStreamPayload(
                    streamKey: "heart_rate",
                    columns: ["event_at_ms", "bpm", "quality", "provenance"],
                    rows: [[
                        .integer(eventMs), .integer(bpm), .null, .string("sensor"),
                    ]]
                ),
            ]
        )
    }

    private func makeChange(
        for prepared: ManagedPreparedChunk
    ) -> ManagedChangeFeed.Change {
        ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: "chunk",
            resourceID: prepared.payload.chunkID,
            operation: "available",
            contentSHA256: String(repeating: "a", count: 64),
            dataClass: prepared.payload.dataClass,
            eventStart: ManagedTimestamp.iso8601(
                milliseconds: prepared.payload.eventStartMs
            ),
            eventEnd: ManagedTimestamp.iso8601(
                milliseconds: prepared.payload.eventEndMs
            ),
            chunk: ManagedChangeFeed.Change.Chunk(
                chunkID: prepared.payload.chunkID,
                sourceID: prepared.payload.sourceID,
                schemaVersion: prepared.payload.schemaVersion,
                contentMode: "server_readable",
                state: "available",
                compression: "none",
                contentType: "application/vnd.noop.chunk+json",
                expectedCompressedBytes: prepared.uncompressed.count,
                expectedUncompressedBytes: prepared.uncompressed.count,
                objectGeneration: 1,
                expiresAt: nil
            ),
            document: nil
        )
    }

    private func remoteDocument(
        for mutation: ManagedDocumentMutation
    ) throws -> ManagedDocument {
        let digest = try XCTUnwrap(mutation.contentSHA256)
        return ManagedDocument(
            documentKind: mutation.documentKind,
            documentID: mutation.documentID,
            revision: mutation.baseRevision + 1,
            originInstallationID: "ios-installation",
            contentMode: mutation.contentMode,
            clientKeyID: mutation.clientKeyID,
            contentSHA256: digest,
            payloadJSON: mutation.payloadJSON,
            payloadCiphertextBase64: mutation.payloadCiphertextBase64,
            updatedAt: mutation.updatedAt,
            deletedAt: nil,
            duplicate: false
        )
    }

    private func documentChange(
        _ document: ManagedDocument
    ) -> ManagedChangeFeed.Change {
        ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: "document",
            resourceID: document.documentID,
            operation: document.deletedAt == nil ? "upsert" : "tombstone",
            contentSHA256: document.contentSHA256,
            dataClass: "user_documents",
            eventStart: nil,
            eventEnd: nil,
            chunk: nil,
            document: ManagedChangeFeed.Change.Document(
                documentKind: document.documentKind,
                documentID: document.documentID,
                revision: document.revision,
                contentMode: document.contentMode,
                clientKeyID: document.clientKeyID,
                updatedAt: document.updatedAt,
                deletedAt: document.deletedAt
            )
        )
    }
}

private actor DocumentRestoreSpy: WhoopManagedDocumentRestoring {
    private var restoredOperations: [String] = []

    func apply(
        document _: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {
        restoredOperations.append(change.operation)
    }

    func operations() -> [String] {
        restoredOperations
    }
}
