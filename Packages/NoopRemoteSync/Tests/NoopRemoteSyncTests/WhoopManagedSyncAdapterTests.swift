import GRDB
import XCTest
@testable import NoopRemoteSync
@testable import WhoopStore

final class WhoopManagedSyncAdapterTests: XCTestCase {
    private let sourceID = UUID(uuidString: "c8c2260b-0069-413d-a8c5-9f6e248405db")!
    private let eventMs: Int64 = 1_788_393_600_000
    private let accountScopeHash = String(repeating: "d", count: 64)

    func testCanonicalChunkAppliesToIsolatedCloudSource() async throws {
        let store = try await managedStore()
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
        let store = try await managedStore()
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
        let store = try await managedStore()
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
        let store = try await managedStore()
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

    func testServerReadableOutboxSkipsEarlierEncryptedRowsAndRestoresWithoutEcho() async throws {
        let source = try await managedStore()
        try await source.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO journal (
                    deviceId, day, question, answeredYes, notes, numericValue
                ) VALUES (
                    'strap', '2026-09-04', 'late_caffeine', 1, 'after lunch', 2.5
                )
                """)
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'strap', 1)
                """)
            try db.execute(sql: """
                UPDATE managedDocumentDirty
                SET updatedAtMs = CASE tableName
                    WHEN 'journal' THEN 1
                    WHEN 'dayOwnership' THEN 2
                    ELSE updatedAtMs
                END
                """)
        }
        let sourceAdapter = try WhoopManagedDocumentAdapter(
            store: source,
            accountScopeHash: accountScopeHash
        )
        let pendingDocuments = try await sourceAdapter.pendingDocuments(limit: 1)
        let pending = try XCTUnwrap(pendingDocuments.first)
        XCTAssertEqual(pending.mutation.documentKind, .dayOwnership)
        XCTAssertEqual(pending.mutation.contentMode, "server_readable")
        XCTAssertEqual(pending.mutation.baseRevision, 0)
        let encryptedBeforeAcknowledge = try await source.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertEqual(encryptedBeforeAcknowledge.map(\.tableName), ["journal"])

        let remote = try remoteDocument(for: pending.mutation)
        try await sourceAdapter.acknowledge(pending, remote: remote)
        let remaining = try await sourceAdapter.pendingDocuments(limit: 10)
        XCTAssertTrue(remaining.isEmpty)
        let encryptedAfterAcknowledge = try await source.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertEqual(encryptedAfterAcknowledge, encryptedBeforeAcknowledge)

        let destination = try await managedStore()
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
                    SELECT deviceId, locked FROM dayOwnership
                    WHERE day = '2026-09-11'
                    """
            )
        }
        XCTAssertEqual(restored?["deviceId"] as String?, "strap")
        XCTAssertEqual(restored?["locked"] as Bool?, true)
        let destinationPending = try await destinationAdapter.pendingDocuments(
            limit: 10
        )
        XCTAssertTrue(destinationPending.isEmpty)
    }

    func testEncryptedDocumentFailsClosedBeforeLaterServerReadableDocument() async throws {
        let store = try await managedStore()
        let adapter = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash
        )
        let applier = WhoopManagedRestoreApplier(
            store: store,
            documentRestore: adapter
        )
        let journalID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-5111-8111-111111111111")
        )
        let encrypted = encryptedDocument(
            kind: .journal,
            documentID: journalID,
            revision: 1
        )
        do {
            try await applier.apply(
                document: encrypted,
                change: documentChange(encrypted, sequence: 1)
            )
            XCTFail("Expected unavailable client decryption to stop restore")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidConfiguration)
        }

        let ownership = try dayOwnershipDocument()
        try await applier.apply(
            document: ownership,
            change: documentChange(ownership, sequence: 2)
        )
        let restored = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT deviceId, locked FROM dayOwnership
                    WHERE day = '2026-09-11'
                    """
            )
        }
        XCTAssertEqual(restored?["deviceId"] as String?, "remote-band")
        XCTAssertEqual(restored?["locked"] as Bool?, true)
        let stateCount = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM managedDocumentState"
            )
        }
        XCTAssertEqual(stateCount, 1)
    }

    func testEncryptedRestoreFailsClosedOnMalformedMetadataAndSensitivePlaintext() async throws {
        let store = try await managedStore()
        let adapter = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash
        )
        let applier = WhoopManagedRestoreApplier(
            store: store,
            documentRestore: adapter
        )
        let encrypted = encryptedDocument(
            kind: .journal,
            documentID: try XCTUnwrap(
                UUID(uuidString: "33333333-3333-5333-8333-333333333333")
            ),
            revision: 1
        )

        do {
            try await applier.apply(
                document: encrypted,
                change: documentChange(
                    encrypted,
                    metadataContentMode: "server_readable"
                )
            )
            XCTFail("Expected mismatched encrypted metadata to fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }

        let plaintextPayload: [String: ManagedDocumentJSONValue] = [
            "secret": .string("not-server-readable"),
        ]
        let plaintextSensitive = ManagedDocument(
            documentKind: .journal,
            documentID: encrypted.documentID,
            revision: 1,
            originInstallationID: "ios-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: try canonicalDigest(plaintextPayload),
            payloadJSON: plaintextPayload,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-11T15:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
        do {
            try await applier.apply(
                document: plaintextSensitive,
                change: documentChange(plaintextSensitive)
            )
            XCTFail("Expected plaintext sensitive document to fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testEncryptedHydrationStopsRestoreWhilePlaintextHydrationIsRejected() async throws {
        let store = try await managedStore()
        try await store.replaceHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: "11111111-2222-4333-8444-555555555555",
                    day: "2026-09-11",
                    amountML: 237,
                    loggedAt: 1_789_142_400
                ),
            ],
            deviceId: "hydration",
            day: "2026-09-11",
            metricKey: "hydration"
        )
        let encryptedCandidates = try await store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 1
        )
        let candidate = try XCTUnwrap(encryptedCandidates.first)
        let adapter = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash
        )
        let emitted = try await adapter.pendingDocuments(limit: 10)
        XCTAssertTrue(emitted.isEmpty)

        let encrypted = try remoteDocument(
            for: candidate,
            kind: .hydration,
            contentMode: "client_encrypted"
        )
        do {
            try await adapter.apply(
                document: encrypted,
                change: documentChange(encrypted)
            )
            XCTFail("Expected unavailable client decryption to stop restore")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidConfiguration)
        }

        let plaintext = try remoteDocument(
            for: candidate,
            kind: .hydration,
            contentMode: "server_readable"
        )
        do {
            try await adapter.apply(
                document: plaintext,
                change: documentChange(plaintext)
            )
            XCTFail("Expected plaintext hydration restore to fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }

        let retained = try await store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertEqual(retained, [candidate])
    }

    func testRemoteConflictMapsToManagedStorageConflict() async throws {
        let source = try await managedStore()
        try await source.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'source', 1)
                """)
        }
        let sourceAdapter = try WhoopManagedDocumentAdapter(
            store: source,
            accountScopeHash: accountScopeHash
        )
        let pendingDocuments = try await sourceAdapter.pendingDocuments(limit: 1)
        let pending = try XCTUnwrap(pendingDocuments.first)
        let firstRemote = try remoteDocument(for: pending.mutation)

        let destination = try await managedStore()
        let destinationAdapter = try WhoopManagedDocumentAdapter(
            store: destination,
            accountScopeHash: accountScopeHash
        )
        try await destinationAdapter.apply(
            document: firstRemote,
            change: documentChange(firstRemote)
        )
        try await destination.registryWriter.write { db in
            try db.execute(sql: """
                UPDATE dayOwnership SET deviceId = 'local'
                WHERE day = '2026-09-11'
                """)
        }

        let remotePayload = dayOwnershipPayload(deviceID: "remote")
        let secondRemote = ManagedDocument(
            documentKind: .dayOwnership,
            documentID: firstRemote.documentID,
            revision: 2,
            originInstallationID: "other-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: try canonicalDigest(remotePayload),
            payloadJSON: remotePayload,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-11T16:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
        do {
            try await destinationAdapter.apply(
                document: secondRemote,
                change: documentChange(secondRemote)
            )
            XCTFail("Expected local generation conflict")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .conflict)
        }

        let retained = try await destination.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT owner.deviceId, state.remoteRevision,
                           state.acknowledgedGeneration
                    FROM dayOwnership AS owner
                    JOIN managedDocumentState AS state
                      ON state.tableName = 'dayOwnership'
                     AND state.documentId = ?
                    WHERE owner.day = '2026-09-11'
                    """,
                arguments: [firstRemote.documentID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(retained?["deviceId"] as String?, "local")
        XCTAssertEqual(retained?["remoteRevision"] as Int64?, 1)
        XCTAssertEqual(retained?["acknowledgedGeneration"] as Int64?, 0)
    }

    func testMatchingUnknownOwnershipTombstoneRebasesPendingMutation() async throws {
        let store = try await managedStore()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'local', 1)
                """)
        }
        let adapter = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash
        )
        let beforeCandidates = try await adapter.pendingDocuments(limit: 10)
        let pendingBefore = try XCTUnwrap(beforeCandidates.first)
        XCTAssertEqual(pendingBefore.mutation.baseRevision, 0)

        let tombstone = dayOwnershipTombstone(
            documentID: pendingBefore.mutation.documentID,
            revision: 4
        )
        try await adapter.apply(
            document: tombstone,
            change: documentChange(tombstone)
        )
        try await adapter.apply(
            document: tombstone,
            change: documentChange(tombstone)
        )
        let newerTombstone = dayOwnershipTombstone(
            documentID: pendingBefore.mutation.documentID,
            revision: 7
        )
        try await adapter.apply(
            document: newerTombstone,
            change: documentChange(newerTombstone)
        )

        let afterCandidates = try await adapter.pendingDocuments(limit: 10)
        let pendingAfter = try XCTUnwrap(afterCandidates.first)
        XCTAssertEqual(
            pendingAfter.localIdentifier,
            pendingBefore.localIdentifier
        )
        XCTAssertEqual(pendingAfter.generation, pendingBefore.generation)
        XCTAssertEqual(
            pendingAfter.mutation.documentID,
            pendingBefore.mutation.documentID
        )
        XCTAssertEqual(
            pendingAfter.mutation.payloadJSON,
            pendingBefore.mutation.payloadJSON
        )
        XCTAssertEqual(
            pendingAfter.mutation.contentSHA256,
            pendingBefore.mutation.contentSHA256
        )
        XCTAssertEqual(pendingAfter.mutation.baseRevision, 7)
        XCTAssertEqual(
            try remoteDocument(for: pendingAfter.mutation).revision,
            8
        )
    }

    func testUnknownOwnershipTombstoneDoesNotBlockUnrelatedLocalOwnership() async throws {
        let store = try await managedStore()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'local', 1)
                """)
        }
        let adapter = try WhoopManagedDocumentAdapter(
            store: store,
            accountScopeHash: accountScopeHash
        )
        let pendingBefore = try await adapter.pendingDocuments(limit: 10)
        XCTAssertEqual(pendingBefore.count, 1)

        let documentID = try XCTUnwrap(
            UUID(uuidString: "99999999-8888-5777-8666-555555555555")
        )
        let tombstone = dayOwnershipTombstone(
            documentID: documentID,
            revision: 1
        )

        try await adapter.apply(
            document: tombstone,
            change: documentChange(tombstone)
        )

        let pendingAfter = try await adapter.pendingDocuments(limit: 10)
        XCTAssertEqual(pendingAfter, pendingBefore)
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

    private func remoteDocument(
        for candidate: ManagedLocalDocumentCandidate,
        kind: ManagedDocumentKind,
        contentMode: String
    ) throws -> ManagedDocument {
        let payloadData = try XCTUnwrap(candidate.payloadJSON)
        let payload = try JSONDecoder().decode(
            [String: ManagedDocumentJSONValue].self,
            from: payloadData
        )
        let documentID = ManagedDocumentStableIdentifier.uuid(
            documentKind: kind.rawValue,
            tableName: candidate.tableName,
            keyJSON: candidate.keyJSON
        )
        if contentMode == "client_encrypted" {
            let ciphertext = Data("opaque-test-ciphertext".utf8)
            return ManagedDocument(
                documentKind: kind,
                documentID: documentID,
                revision: 1,
                originInstallationID: "ios-installation",
                contentMode: contentMode,
                clientKeyID: UUID(
                    uuidString: "11111111-2222-4333-8444-555555555555"
                ),
                contentSHA256: ManagedDigest.sha256(ciphertext),
                payloadJSON: nil,
                payloadCiphertextBase64: ciphertext.base64EncodedString(),
                updatedAt: "2026-09-11T15:00:00.000Z",
                deletedAt: nil,
                duplicate: false
            )
        }
        return ManagedDocument(
            documentKind: kind,
            documentID: documentID,
            revision: 1,
            originInstallationID: "ios-installation",
            contentMode: contentMode,
            clientKeyID: nil,
            contentSHA256: try canonicalDigest(payload),
            payloadJSON: payload,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-11T15:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
    }

    private func dayOwnershipTombstone(
        documentID: UUID,
        revision: Int64
    ) -> ManagedDocument {
        let digest = ManagedDigest.sha256(
            Data(
                (
                    "deleted:day_ownership:"
                        + "\(documentID.uuidString.lowercased()):\(revision)"
                ).utf8
            )
        )
        return ManagedDocument(
            documentKind: .dayOwnership,
            documentID: documentID,
            revision: revision,
            originInstallationID: "other-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: digest,
            payloadJSON: nil,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-11T16:00:00.000Z",
            deletedAt: "2026-09-11T16:00:00.000Z",
            duplicate: false
        )
    }

    private func managedStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountScopeHash,
            updatedAtMs: 1
        )
        return store
    }

    private func dayOwnershipPayload(
        deviceID: String
    ) -> [String: ManagedDocumentJSONValue] {
        [
            "schema_version": .integer(1),
            "table": .string("dayOwnership"),
            "key": .object([
                "day": .string("2026-09-11"),
            ]),
            "record": .object([
                "day": .string("2026-09-11"),
                "deviceId": .string(deviceID),
                "locked": .integer(1),
            ]),
        ]
    }

    private func dayOwnershipDocument() throws -> ManagedDocument {
        let payload = dayOwnershipPayload(deviceID: "remote-band")
        let key: [String: ManagedDocumentJSONValue] = [
            "day": .string("2026-09-11"),
        ]
        return ManagedDocument(
            documentKind: .dayOwnership,
            documentID: ManagedDocumentStableIdentifier.uuid(
                documentKind: ManagedDocumentKind.dayOwnership.rawValue,
                tableName: "dayOwnership",
                keyJSON: try canonicalData(key)
            ),
            revision: 1,
            originInstallationID: "ios-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: try canonicalDigest(payload),
            payloadJSON: payload,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-11T15:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
    }

    private func encryptedDocument(
        kind: ManagedDocumentKind,
        documentID: UUID,
        revision: Int64,
        deleted: Bool = false
    ) -> ManagedDocument {
        let updatedAt = "2026-09-11T15:00:00.000Z"
        if deleted {
            let digest = ManagedDigest.sha256(
                Data(
                    (
                        "deleted:\(kind.rawValue):"
                            + "\(documentID.uuidString.lowercased()):\(revision)"
                    ).utf8
                )
            )
            return ManagedDocument(
                documentKind: kind,
                documentID: documentID,
                revision: revision,
                originInstallationID: "ios-installation",
                contentMode: "client_encrypted",
                clientKeyID: nil,
                contentSHA256: digest,
                payloadJSON: nil,
                payloadCiphertextBase64: nil,
                updatedAt: updatedAt,
                deletedAt: updatedAt,
                duplicate: false
            )
        }

        let ciphertext = Data(
            "noop-encrypted-\(kind.rawValue)-payload".utf8
        )
        return ManagedDocument(
            documentKind: kind,
            documentID: documentID,
            revision: revision,
            originInstallationID: "ios-installation",
            contentMode: "client_encrypted",
            clientKeyID: UUID(
                uuidString: "44444444-4444-5444-8444-444444444444"
            ),
            contentSHA256: ManagedDigest.sha256(ciphertext),
            payloadJSON: nil,
            payloadCiphertextBase64: ciphertext.base64EncodedString(),
            updatedAt: updatedAt,
            deletedAt: nil,
            duplicate: false
        )
    }

    private func canonicalDigest(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> String {
        ManagedDigest.sha256(try canonicalData(payload))
    }

    private func canonicalData(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private func documentChange(
        _ document: ManagedDocument,
        sequence: Int64 = 1,
        metadataContentMode: String? = nil
    ) -> ManagedChangeFeed.Change {
        ManagedChangeFeed.Change(
            sequence: sequence,
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
                contentMode: metadataContentMode ?? document.contentMode,
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
