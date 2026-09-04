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

    private func acknowledge(
        _ candidate: ManagedLocalDocumentCandidate,
        revision: Int64,
        store: WhoopStore
    ) async throws {
        try await store.acknowledgeManagedDocument(
            accountScopeHash: scope,
            candidate: candidate,
            documentID: UUID().uuidString.lowercased(),
            remoteRevision: revision,
            remoteContentSHA256: String(repeating: "e", count: 64),
            acknowledgedAtMs: revision * 1_000
        )
    }
}
