import GRDB
import XCTest
@testable import WhoopStore

final class ManagedSyncDocumentsTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)

    func testJournalInsertUpdateDeleteRetainsDurableRevisions() async throws {
        let store = try await WhoopStore.inMemory()
        try await insertJournal(into: store, notes: "first")

        let insertedRows = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        let inserted = try XCTUnwrap(insertedRows.first)
        XCTAssertEqual(inserted.tableName, "journal")
        XCTAssertEqual(inserted.documentKind, "journal")
        XCTAssertEqual(inserted.generation, 1)
        XCTAssertEqual(inserted.baseRevision, 0)
        XCTAssertFalse(inserted.deleted)
        XCTAssertEqual(
            try payloadRecord(inserted)["notes"] as? String,
            "first"
        )

        try await acknowledge(inserted, revision: 1, store: store)
        let afterInsert = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        XCTAssertTrue(afterInsert.isEmpty)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE journal SET notes = 'second'
                    WHERE deviceId = 'strap' AND day = '2026-09-04'
                      AND question = 'late_caffeine'
                    """
            )
        }
        let updatedRows = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        let updated = try XCTUnwrap(updatedRows.first)
        XCTAssertEqual(updated.generation, 2)
        XCTAssertEqual(updated.baseRevision, 1)
        XCTAssertEqual(
            try payloadRecord(updated)["notes"] as? String,
            "second"
        )
        try await acknowledge(updated, revision: 2, store: store)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    DELETE FROM journal
                    WHERE deviceId = 'strap' AND day = '2026-09-04'
                      AND question = 'late_caffeine'
                    """
            )
        }
        let deletedRows = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        let deleted = try XCTUnwrap(deletedRows.first)
        XCTAssertEqual(deleted.generation, 3)
        XCTAssertEqual(deleted.baseRevision, 2)
        XCTAssertTrue(deleted.deleted)
        XCTAssertNil(deleted.payloadJSON)
    }

    func testRemoteJournalApplyAndDeleteDoNotEchoIntoOutbox() async throws {
        let source = try await WhoopStore.inMemory()
        try await insertJournal(into: source, notes: "remote")
        let sourcePending = try await source.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 1
        )
        let candidate = try XCTUnwrap(sourcePending.first)
        let payload = try XCTUnwrap(candidate.payloadJSON)

        let destination = try await WhoopStore.inMemory()
        let documentID = "11111111-1111-5111-8111-111111111111"
        let digest = String(repeating: "b", count: 64)
        let applied = try await destination.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "journal",
            documentID: documentID,
            revision: 1,
            contentSHA256: digest,
            payloadJSON: payload,
            deleted: false,
            appliedAtMs: 1_000
        )
        XCTAssertTrue(applied.applied)
        XCTAssertEqual(applied.changedRows, 1)

        let restored = try await destination.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT answeredYes, notes FROM journal
                    WHERE deviceId = 'strap' AND day = '2026-09-04'
                      AND question = 'late_caffeine'
                    """
            )
        }
        XCTAssertEqual(restored?["answeredYes"] as Bool?, true)
        XCTAssertEqual(restored?["notes"] as String?, "remote")
        let afterRestore = try await destination.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        XCTAssertTrue(afterRestore.isEmpty)

        let removed = try await destination.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "journal",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "c", count: 64),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 2_000
        )
        XCTAssertEqual(removed.changedRows, 1)
        let count = try await destination.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal") ?? -1
        }
        XCTAssertEqual(count, 0)
        let afterDelete = try await destination.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testV56SeedsExistingHydrationRowsAndInstallsDurableTriggers() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v55-hydration-entry")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hydrationEntry
                        (id, deviceId, day, amountML, loggedAt)
                    VALUES (?, 'hydration', '2026-09-11', 237, 1789142400)
                    """,
                arguments: ["11111111-2222-4333-8444-555555555555"]
            )
        }

        try migrator.migrate(queue)

        let seeded = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT documentKind, generation, operation
                    FROM managedDocumentDirty
                    WHERE tableName = 'hydrationEntry'
                    """
            )
        }
        XCTAssertEqual(seeded?["documentKind"] as String?, "hydration")
        XCTAssertEqual(seeded?["generation"] as Int64?, 1)
        XCTAssertEqual(seeded?["operation"] as String?, "upsert")

        let triggerNames = try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'trigger'
                      AND name LIKE 'managed_document_hydrationEntry_%'
                    ORDER BY name
                    """
            )
        }
        XCTAssertEqual(
            triggerNames,
            [
                "managed_document_hydrationEntry_delete",
                "managed_document_hydrationEntry_insert",
                "managed_document_hydrationEntry_update",
            ]
        )

        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE hydrationEntry SET amountML = 500
                    WHERE id = ?
                    """,
                arguments: ["11111111-2222-4333-8444-555555555555"]
            )
        }
        let updatedGeneration = try queue.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                    SELECT generation FROM managedDocumentDirty
                    WHERE tableName = 'hydrationEntry'
                    """
            )
        }
        XCTAssertEqual(updatedGeneration, 2)
    }

    func testHydrationDocumentsRoundTripEntriesProjectionAndTombstoneWithoutEcho() async throws {
        let source = try await WhoopStore.inMemory()
        let destination = try await WhoopStore.inMemory()
        let day = "2026-09-11"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let documentID = "99999999-8888-5777-8666-555555555555"

        let insertedEntry = HydrationLogEntry(
            id: entryID,
            day: day,
            amountML: 237,
            loggedAt: 1_789_142_400
        )
        try await source.replaceHydrationLogEntries(
            [insertedEntry],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let insertedCandidate = try await hydrationCandidate(in: source)
        let inserted = try XCTUnwrap(insertedCandidate)
        XCTAssertEqual(inserted.documentKind, "hydration")
        XCTAssertEqual(try payloadRecord(inserted)["amountML"] as? Int64, 237)
        try await acknowledge(
            inserted,
            revision: 1,
            documentID: documentID,
            store: source
        )

        let insertedApply = try await destination.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: inserted.documentKind,
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "1", count: 64),
            payloadJSON: inserted.payloadJSON,
            deleted: false,
            appliedAtMs: 1_000
        )
        XCTAssertEqual(insertedApply.changedRows, 1)
        let insertedEntries = try await destination.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertEqual(
            insertedEntries,
            [insertedEntry]
        )
        let insertedMetric = try await hydrationMetric(
            in: destination,
            day: day
        )
        XCTAssertEqual(
            insertedMetric,
            237
        )

        let updatedEntry = HydrationLogEntry(
            id: entryID,
            day: day,
            amountML: 500,
            loggedAt: 1_789_142_460
        )
        try await source.replaceHydrationLogEntries(
            [updatedEntry],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let updatedCandidate = try await hydrationCandidate(in: source)
        let updated = try XCTUnwrap(updatedCandidate)
        try await acknowledge(
            updated,
            revision: 2,
            documentID: documentID,
            store: source
        )
        _ = try await destination.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: updated.documentKind,
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "2", count: 64),
            payloadJSON: updated.payloadJSON,
            deleted: false,
            appliedAtMs: 2_000
        )
        let updatedEntries = try await destination.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertEqual(
            updatedEntries,
            [updatedEntry]
        )
        let updatedMetric = try await hydrationMetric(
            in: destination,
            day: day
        )
        XCTAssertEqual(
            updatedMetric,
            500
        )

        try await source.replaceHydrationLogEntries(
            [],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let deletedCandidate = try await hydrationCandidate(in: source)
        let deleted = try XCTUnwrap(deletedCandidate)
        XCTAssertTrue(deleted.deleted)
        let deletedApply = try await destination.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: deleted.documentKind,
            documentID: documentID,
            revision: 3,
            contentSHA256: String(repeating: "3", count: 64),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 3_000
        )
        XCTAssertEqual(deletedApply.changedRows, 1)
        let deletedEntries = try await destination.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        XCTAssertTrue(deletedEntries.isEmpty)
        let deletedMetric = try await hydrationMetric(
            in: destination,
            day: day
        )
        XCTAssertEqual(
            deletedMetric,
            0
        )
        let destinationPending = try await destination.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        XCTAssertTrue(destinationPending.isEmpty)
        let dirtyWindows = try await destination.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM managedDirtyWindow"
            ) ?? -1
        }
        XCTAssertEqual(dirtyWindows, 0)
    }

    func testPreferencesStageAndRemoteApplyShareOneRevisionedDocument() async throws {
        let store = try await WhoopStore.inMemory()
        let first = Data(#"{"settings.schemaVersion":4,"units.system":"metric"}"#.utf8)
        try await store.stageManagedPreferences(first, updatedAtMs: 1_000)
        try await store.stageManagedPreferences(first, updatedAtMs: 2_000)

        let preferenceRows = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        let pending = try XCTUnwrap(preferenceRows.first)
        XCTAssertEqual(pending.tableName, "preferences")
        XCTAssertEqual(pending.localKey, "global")
        XCTAssertEqual(pending.generation, 1)
        XCTAssertEqual(pending.payloadJSON, first)

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "preferences",
            documentID: "22222222-2222-5222-8222-222222222222",
            revision: 1,
            contentSHA256: String(repeating: "d", count: 64),
            payloadJSON: first,
            deleted: false,
            appliedAtMs: 3_000
        )
        let afterApply = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        )
        XCTAssertTrue(afterApply.isEmpty)
    }

    private func insertJournal(
        into store: WhoopStore,
        notes: String
    ) async throws {
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO journal (
                        deviceId, day, question, answeredYes, notes, numericValue
                    ) VALUES (
                        'strap', '2026-09-04', 'late_caffeine', 1, ?, 2.5
                    )
                    """,
                arguments: [notes]
            )
        }
    }

    private func payloadRecord(
        _ candidate: ManagedLocalDocumentCandidate
    ) throws -> [String: Any] {
        let payload = try XCTUnwrap(candidate.payloadJSON)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        return try XCTUnwrap(root["record"] as? [String: Any])
    }

    private func hydrationCandidate(
        in store: WhoopStore
    ) async throws -> ManagedLocalDocumentCandidate? {
        try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            limit: 10
        ).first {
            $0.tableName == "hydrationEntry"
        }
    }

    private func hydrationMetric(
        in store: WhoopStore,
        day: String
    ) async throws -> Double? {
        try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: day,
            to: day
        ).first?.value
    }

    private func acknowledge(
        _ candidate: ManagedLocalDocumentCandidate,
        revision: Int64,
        documentID: String = UUID().uuidString.lowercased(),
        store: WhoopStore
    ) async throws {
        try await store.acknowledgeManagedDocument(
            accountScopeHash: scope,
            candidate: candidate,
            documentID: documentID,
            remoteRevision: revision,
            remoteContentSHA256: String(repeating: "e", count: 64),
            acknowledgedAtMs: revision * 1_000
        )
    }
}
