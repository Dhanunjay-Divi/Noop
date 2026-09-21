import CryptoKit
import GRDB
import XCTest
@testable import WhoopStore

final class ManagedSyncDocumentsTests: XCTestCase {
    private struct ManagedStateSnapshot: Equatable {
        let acknowledgedGeneration: Int64
        let remoteRevision: Int64
        let remoteContentSHA256: String
        let updatedAtMs: Int64
    }

    private let scope = String(repeating: "a", count: 64)

    func testManagedDocumentContentModesMatchStorageMapBoundary() {
        let clientEncryptedTables = Set(
            WhoopStore.managedDocumentTableSpecs
                .filter { $0.contentMode == .clientEncrypted }
                .map(\.tableName)
        )
        XCTAssertEqual(
            clientEncryptedTables,
            Set([
                "coachMemory",
                "coachMessage",
                "hydrationEntry",
                "journal",
                "labMarker",
                "nutritionCatalogItem",
                "nutritionEntry",
                "strengthExercise",
                "strengthRoutine",
                "strengthRoutineExercise",
                "strengthSession",
                "strengthSet",
            ])
        )
        XCTAssertEqual(
            Set(
                WhoopStore.managedDocumentTableSpecs
                    .filter { $0.contentMode == .serverReadable }
                    .map(\.tableName)
            ),
            Set(["dayOwnership"])
        )
        XCTAssertEqual(
            WhoopStore.managedPreferencesContentMode,
            .clientEncrypted
        )
    }

    func testPendingModeFilterRunsBeforeLimitWithoutClearingEncryptedRows() async throws {
        let store = try await managedStore()
        try await insertJournal(into: store, notes: "private")
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dayOwnership (day, deviceId, locked)
                    VALUES ('2026-09-11', 'strap', 1)
                    """
            )
            try db.execute(
                sql: """
                    UPDATE managedDocumentDirty
                    SET updatedAtMs = CASE tableName
                        WHEN 'journal' THEN 1
                        WHEN 'dayOwnership' THEN 2
                        ELSE updatedAtMs
                    END
                    """
            )
        }

        let serverReadable = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 1
        )
        XCTAssertEqual(serverReadable.map(\.tableName), ["dayOwnership"])
        XCTAssertEqual(serverReadable.first?.contentMode, .serverReadable)

        let clientEncrypted = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 1
        )
        XCTAssertEqual(clientEncrypted.map(\.tableName), ["journal"])
        XCTAssertEqual(clientEncrypted.first?.contentMode, .clientEncrypted)

        let retainedDirtyRows = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM managedDocumentDirty
                    WHERE tableName IN ('journal', 'dayOwnership')
                    """
            ) ?? -1
        }
        XCTAssertEqual(retainedDirtyRows, 2)
    }

    func testJournalInsertUpdateDeleteRetainsDurableRevisions() async throws {
        let store = try await managedStore()
        try await insertJournal(into: store, notes: "first")

        let insertedRows = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
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
            contentMode: .clientEncrypted,
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
            contentMode: .clientEncrypted,
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
            contentMode: .clientEncrypted,
            limit: 10
        )
        let deleted = try XCTUnwrap(deletedRows.first)
        XCTAssertEqual(deleted.generation, 3)
        XCTAssertEqual(deleted.baseRevision, 2)
        XCTAssertTrue(deleted.deleted)
        XCTAssertNil(deleted.payloadJSON)
    }

    func testRemoteJournalApplyAndDeleteDoNotEchoIntoOutbox() async throws {
        let source = try await managedStore()
        try await insertJournal(into: source, notes: "remote")
        let sourcePending = try await source.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 1
        )
        let candidate = try XCTUnwrap(sourcePending.first)
        let payload = try XCTUnwrap(candidate.payloadJSON)

        let destination = try await managedStore()
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
            contentMode: .clientEncrypted,
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
            contentMode: .clientEncrypted,
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

        try migrator.migrate(
            queue,
            upTo: "v56-managed-hydration-document"
        )

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

    func testV59QuarantinesLegacyDirtyRowsWithoutGuessingAnAccount() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(
            queue,
            upTo: "v58-analysis-dirty-bounds-repair"
        )
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-12', 'legacy-band', 0)
                """)
        }

        try migrator.migrate(queue)

        let quarantine = try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT profile.localProfileId, profile.accountScopeHash,
                       dirty.localProfileId AS dirtyProfileId
                FROM managedLocalProfile AS profile
                JOIN managedDocumentDirty AS dirty
                  ON dirty.tableName = 'dayOwnership'
                WHERE profile.bindingId = 1
                """)
        }
        XCTAssertNotNil(quarantine)
        XCTAssertNil(quarantine?["accountScopeHash"] as String?)
        XCTAssertEqual(
            quarantine?["localProfileId"] as String?,
            quarantine?["dirtyProfileId"] as String?
        )
        XCTAssertNotEqual(
            quarantine?["dirtyProfileId"] as String?,
            scope
        )

        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE managedLocalProfile
                    SET localProfileId = ?,
                        accountScopeHash = ?,
                        updatedAtMs = 2
                    WHERE bindingId = 1
                    """,
                arguments: [scope, scope]
            )
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-13', 'current-band', 0)
                """)
        }
        let profiles = try queue.read { db in
            try Set(
                String.fetchAll(
                    db,
                    sql: """
                        SELECT localProfileId
                        FROM managedDocumentDirty
                        WHERE tableName = 'dayOwnership'
                        """
                )
            )
        }
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(profiles.contains(scope))
    }

    func testV61RecreatesDirtyGenerationAboveRetainedAcknowledgement() throws {
        let accountA = scope
        let accountB = String(repeating: "b", count: 64)
        let day = "2026-09-12"
        let digest = String(repeating: "c", count: 64)
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(
            queue,
            upTo: "v60-managed-change-feed-capability"
        )

        let localKey = try queue.write { db -> String in
            try db.execute(
                sql: """
                    UPDATE managedLocalProfile
                    SET localProfileId = ?,
                        accountScopeHash = ?,
                        updatedAtMs = 1
                    WHERE bindingId = 1
                    """,
                arguments: [accountA, accountA]
            )
            try db.execute(
                sql: """
                    INSERT INTO dayOwnership (day, deviceId, locked)
                    VALUES (?, 'band-a', 0)
                    """,
                arguments: [day]
            )
            let key = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: """
                        SELECT localKey
                        FROM managedDocumentDirty
                        WHERE localProfileId = ?
                          AND tableName = 'dayOwnership'
                        """,
                    arguments: [accountA]
                )
            )
            try db.execute(
                sql: """
                    INSERT INTO managedDocumentState (
                        accountScopeHash, tableName, localKey, documentKind,
                        documentId, keyJSON, acknowledgedGeneration, remoteRevision,
                        remoteContentSHA256, updatedAtMs
                    ) VALUES (
                        ?, 'dayOwnership', ?, 'day_ownership',
                        '11111111-1111-5111-8111-111111111111',
                        '{"day":"2026-09-12"}', 7, 11, ?, 13
                    )
                    """,
                arguments: [accountA, key, digest]
            )
            try db.execute(
                sql: """
                    UPDATE managedLocalProfile
                    SET localProfileId = ?,
                        accountScopeHash = ?,
                        updatedAtMs = 2
                    WHERE bindingId = 1
                    """,
                arguments: [accountB, accountB]
            )
            try db.execute(
                sql: """
                    UPDATE dayOwnership
                    SET deviceId = 'band-b'
                    WHERE day = ?
                    """,
                arguments: [day]
            )
            return key
        }

        let quarantined = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT localProfileId, generation
                    FROM managedDocumentDirty
                    WHERE tableName = 'dayOwnership'
                      AND localKey = ?
                    """,
                arguments: [localKey]
            )
        }
        XCTAssertEqual(quarantined?["localProfileId"] as String?, accountB)
        XCTAssertEqual(quarantined?["generation"] as Int64?, 1)

        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                    UPDATE managedLocalProfile
                    SET localProfileId = ?,
                        accountScopeHash = ?,
                        updatedAtMs = 3
                    WHERE bindingId = 1
                    """,
                arguments: [accountA, accountA]
            )
            try db.execute(
                sql: """
                    UPDATE dayOwnership
                    SET deviceId = 'band-a-edited'
                    WHERE day = ?
                    """,
                arguments: [day]
            )
        }

        let result = try queue.read { db -> (
            dirty: Row?,
            eligible: Int,
            count: Int
        ) in
            let dirty = try Row.fetchOne(
                db,
                sql: """
                    SELECT dirty.localProfileId, dirty.generation,
                           state.acknowledgedGeneration, state.remoteRevision,
                           state.remoteContentSHA256, state.updatedAtMs
                    FROM managedDocumentDirty AS dirty
                    JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE dirty.tableName = 'dayOwnership'
                      AND dirty.localKey = ?
                    """,
                arguments: [accountA, localKey]
            )
            let eligible = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM managedDocumentDirty AS dirty
                    LEFT JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE dirty.localProfileId = ?
                      AND dirty.tableName = 'dayOwnership'
                      AND dirty.localKey = ?
                      AND dirty.generation >
                          COALESCE(state.acknowledgedGeneration, 0)
                    """,
                arguments: [accountA, accountA, localKey]
            ) ?? -1
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM managedDocumentDirty
                    WHERE tableName = 'dayOwnership'
                      AND localKey = ?
                    """,
                arguments: [localKey]
            ) ?? -1
            return (dirty, eligible, count)
        }
        XCTAssertEqual(result.dirty?["localProfileId"] as String?, accountA)
        XCTAssertEqual(result.dirty?["generation"] as Int64?, 8)
        XCTAssertEqual(
            result.dirty?["acknowledgedGeneration"] as Int64?,
            7
        )
        XCTAssertEqual(result.dirty?["remoteRevision"] as Int64?, 11)
        XCTAssertEqual(
            result.dirty?["remoteContentSHA256"] as String?,
            digest
        )
        XCTAssertEqual(result.dirty?["updatedAtMs"] as Int64?, 13)
        XCTAssertEqual(result.eligible, 1)
        XCTAssertEqual(result.count, 1)
    }

    func testAccountSwitchInvalidatesOnlyChangedPriorUploadIntent() async throws {
        let accountA = String(repeating: "a", count: 64)
        let accountB = String(repeating: "b", count: 64)
        let store = try await managedStore(accountScopeHash: accountA)

        try await insertDayOwnership(
            into: store,
            day: "2026-09-12",
            deviceID: "band-a"
        )
        let initialA = try await store.pendingManagedDocuments(
            accountScopeHash: accountA,
            contentMode: .serverReadable,
            limit: 10
        )
        let originalA = try XCTUnwrap(initialA.first)
        try await insertDayOwnership(
            into: store,
            day: "2026-09-13",
            deviceID: "band-a"
        )
        let expandedA = try await store.pendingManagedDocuments(
            accountScopeHash: accountA,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertEqual(expandedA.count, 2)

        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountB,
            updatedAtMs: 2
        )
        let initialB = try await store.pendingManagedDocuments(
            accountScopeHash: accountB,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertTrue(initialB.isEmpty)
        try await updateDayOwnership(
            in: store,
            day: "2026-09-12",
            deviceID: "band-b"
        )
        let changedB = try await store.pendingManagedDocuments(
            accountScopeHash: accountB,
            contentMode: .serverReadable,
            limit: 10
        )
        let pendingB = try XCTUnwrap(changedB.first)
        XCTAssertEqual(pendingB.localKey, originalA.localKey)

        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountA,
            updatedAtMs: 3
        )
        let remainingA = try await store.pendingManagedDocuments(
            accountScopeHash: accountA,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertEqual(remainingA.count, 1)
        XCTAssertNotEqual(remainingA.first?.localKey, originalA.localKey)
        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountB,
            updatedAtMs: 4
        )
        let restoredB = try await store.pendingManagedDocuments(
            accountScopeHash: accountB,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertEqual(restoredB.map(\.localKey), [pendingB.localKey])
    }

    func testSignedOutMutationIsNotAdoptedByNextAccount() async throws {
        let accountA = String(repeating: "a", count: 64)
        let accountB = String(repeating: "b", count: 64)
        let store = try await managedStore(accountScopeHash: accountA)
        try await insertDayOwnership(
            into: store,
            day: "2026-09-12",
            deviceID: "band-a"
        )
        let pendingA = try await store.pendingManagedDocuments(
            accountScopeHash: accountA,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertEqual(pendingA.count, 1)

        try await store.releaseManagedDocumentProfile(updatedAtMs: 2)
        try await updateDayOwnership(
            in: store,
            day: "2026-09-12",
            deviceID: "signed-out-band"
        )
        let dirtyCount = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM managedDocumentDirty"
            ) ?? -1
        }
        XCTAssertEqual(dirtyCount, 0)

        do {
            _ = try await store.pendingManagedDocuments(
                accountScopeHash: accountA,
                contentMode: .serverReadable,
                limit: 10
            )
            XCTFail("A stale adapter scope must not reclaim a released profile.")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .invalidState
            )
        }
        let released = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT localProfileId, accountScopeHash
                    FROM managedLocalProfile
                    WHERE bindingId = 1
                    """
            )
        }
        XCTAssertNil(released?["accountScopeHash"] as String?)
        XCTAssertNotEqual(released?["localProfileId"] as String?, accountA)

        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountB,
            updatedAtMs: 3
        )
        let adoptedByB = try await store.pendingManagedDocuments(
            accountScopeHash: accountB,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertTrue(adoptedByB.isEmpty)
        try await updateDayOwnership(
            in: store,
            day: "2026-09-12",
            deviceID: "band-b"
        )
        let changedByB = try await store.pendingManagedDocuments(
            accountScopeHash: accountB,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertEqual(changedByB.count, 1)
    }

    func testHydrationDocumentsRoundTripEntriesProjectionAndTombstoneWithoutEcho() async throws {
        let source = try await managedStore()
        let destination = try await managedStore()
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
            contentMode: .clientEncrypted,
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

    func testManagedHydrationLegacyDispositionRequiresDeletionAndIsProfileScoped() async throws {
        let accountB = String(repeating: "b", count: 64)
        let store = try await managedStore()
        let day = "2026-09-11"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let documentID = "99999999-8888-5777-8666-555555555555"
        try await store.replaceHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: entryID,
                    day: day,
                    amountML: 237,
                    loggedAt: 1_789_142_400
                ),
            ],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let pendingCandidate = try await hydrationCandidate(in: store)
        let candidate = try XCTUnwrap(pendingCandidate)
        try await acknowledge(
            candidate,
            revision: 1,
            documentID: documentID,
            store: store
        )
        let acknowledgedDisposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [entryID]
            )
        XCTAssertEqual(
            acknowledgedDisposition,
            .deferForProfileConflict
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE managedDocumentState
                    SET isDeleted = NULL
                    WHERE accountScopeHash = ?
                      AND tableName = 'hydrationEntry'
                """,
                arguments: [self.scope]
            )
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO managedDocumentApplyGuard (guardId)
                    VALUES (1)
                    """
            )
            defer {
                try? db.execute(
                    sql: "DELETE FROM managedDocumentApplyGuard WHERE guardId = 1"
                )
            }
            try db.execute(
                sql: "DELETE FROM hydrationEntry WHERE id = ?",
                arguments: [entryID]
            )
        }
        let upgradedUnknownDisposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [entryID]
            )
        XCTAssertEqual(
            upgradedUnknownDisposition,
            .deferForMixedDeletionState
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE managedDocumentState
                    SET isDeleted = 0
                    WHERE accountScopeHash = ?
                      AND tableName = 'hydrationEntry'
                    """,
                arguments: [self.scope]
            )
        }
        let knownNonDeleteDisposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [entryID]
            )
        XCTAssertEqual(
            knownNonDeleteDisposition,
            .deferForProfileConflict
        )
        do {
            _ = try await store.managedHydrationLegacyDisposition(
                entryIDs: ["not-a-uuid"]
            )
            XCTFail("malformed hydration identifiers must fail closed")
        } catch {
            // Expected.
        }
        var oversizedIDs: [String] = []
        oversizedIDs.reserveCapacity(
            WhoopStore.hydrationLegacyMaximumEntryCount + 1
        )
        for index in 0...WhoopStore.hydrationLegacyMaximumEntryCount {
            oversizedIDs.append(
                UUID(
                    uuid: (
                        0, 0, 0, 0, 0, 0, 0x40, 0,
                        0x80, 0, 0, 0,
                        UInt8((index >> 24) & 0xff),
                        UInt8((index >> 16) & 0xff),
                        UInt8((index >> 8) & 0xff),
                        UInt8(index & 0xff)
                    )
                ).uuidString
            )
        }
        do {
            _ = try await store.managedHydrationLegacyDisposition(
                entryIDs: oversizedIDs
            )
            XCTFail("oversized hydration evidence must fail closed")
        } catch {
            // Expected.
        }
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "2", count: 64),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 2_000
        )

        let deletedDisposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [entryID]
            )
        XCTAssertEqual(deletedDisposition, .retire)
        let mixedDisposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [
                    entryID,
                    "22222222-3333-4444-8555-666666666666",
                ]
            )
        XCTAssertEqual(mixedDisposition, .deferForMixedDeletionState)

        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountB,
            updatedAtMs: 3_000
        )
        let otherProfileDisposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [entryID]
            )
        XCTAssertEqual(
            otherProfileDisposition,
            .deferForProfileConflict
        )
    }

    func testUnboundProfileCanAdoptOwnerlessLegacyHydration() async throws {
        let store = try await WhoopStore.inMemory()
        let disposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: ["11111111-2222-4333-8444-555555555555"]
            )

        XCTAssertEqual(disposition, .migrate)
    }

    func testLegacyHydrationAdoptionRetiresEitherOwnedRepresentation() async throws {
        let day = "2026-09-13"
        let legacyID = "11111111-2222-4333-8444-555555555555"
        let aggregateID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let legacy = HydrationLogEntry(
            id: legacyID,
            day: day,
            amountML: 500,
            loggedAt: 1_789_315_200
        )

        let legacyDeletedStore = try await managedStore()
        try await seedLocalHydrationDeleteEvidence(
            entryID: legacyID,
            in: legacyDeletedStore
        )
        let legacyDeletedDisposition =
            try await legacyDeletedStore.adoptLegacyHydrationLogEntries(
                [legacy],
                alternativeRetirementEntryIDs: [aggregateID],
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
        XCTAssertEqual(legacyDeletedDisposition, .retire)

        let aggregateDeletedStore = try await managedStore()
        try await seedLocalHydrationDeleteEvidence(
            entryID: aggregateID,
            in: aggregateDeletedStore
        )
        let aggregateDeletedDisposition =
            try await aggregateDeletedStore.adoptLegacyHydrationLogEntries(
                [legacy],
                alternativeRetirementEntryIDs: [aggregateID],
                deviceId: "hydration",
                day: day,
                metricKey: "hydration"
            )
        XCTAssertEqual(aggregateDeletedDisposition, .retire)
    }

    func testLegacyHydrationAlternativeRetirementDefersAcrossProfiles() async throws {
        let store = try await managedStore()
        let day = "2026-09-13"
        let legacyID = "11111111-2222-4333-8444-555555555555"
        let aggregateID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try await seedLocalHydrationDeleteEvidence(
            entryID: legacyID,
            in: store
        )
        try await store.activateManagedDocumentProfile(
            accountScopeHash: String(repeating: "b", count: 64),
            updatedAtMs: 2
        )

        let disposition = try await store.adoptLegacyHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: legacyID,
                    day: day,
                    amountML: 500,
                    loggedAt: 1_789_315_200
                ),
            ],
            alternativeRetirementEntryIDs: [aggregateID],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForProfileConflict)
    }

    func testLegacyHydrationResolutionDefersForBoundProfileWithoutWriting() async throws {
        let store = try await managedStore()
        let day = "2026-09-12"
        let legacy = HydrationLogEntry(
            id: "11111111-2222-4333-8444-555555555555",
            day: day,
            amountML: 500,
            loggedAt: 1_789_228_800
        )
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "hydration", value: 737)],
            deviceId: "hydration"
        )

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: [legacy],
            replacementEntries: [legacy],
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForProfileConflict)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(metric, 737)
    }

    func testLegacyHydrationResolutionHonorsLegacyTombstoneWithoutWriting() async throws {
        let store = try await managedStore()
        let day = "2026-09-12"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let documentID = "99999999-8888-5777-8666-555555555555"
        let legacy = HydrationLogEntry(
            id: entryID,
            day: day,
            amountML: 500,
            loggedAt: 1_789_228_800
        )
        _ = try await store.replaceHydrationLogEntries(
            [legacy],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let pendingUpsert = try await hydrationCandidate(in: store)
        let upsertCandidate = try XCTUnwrap(pendingUpsert)
        try await acknowledge(
            upsertCandidate,
            revision: 1,
            documentID: documentID,
            store: store
        )
        _ = try await store.replaceHydrationLogEntries(
            [],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let pendingDelete = try await hydrationCandidate(in: store)
        let deleteCandidate = try XCTUnwrap(pendingDelete)
        XCTAssertTrue(deleteCandidate.deleted)
        try await acknowledge(
            deleteCandidate,
            revision: 2,
            documentID: documentID,
            store: store
        )
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "hydration", value: 737)],
            deviceId: "hydration"
        )

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: [legacy],
            replacementEntries: [legacy],
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .retire)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(metric, 737)
    }

    func testLegacyHydrationResolutionHonorsReplacementOnlyTombstone() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-09-12"
        let replacementID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try await seedLocalHydrationDeleteEvidence(
            entryID: replacementID,
            in: store
        )
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "hydration", value: 737)],
            deviceId: "hydration"
        )
        let legacy = HydrationLogEntry(
            id: "11111111-2222-4333-8444-555555555555",
            day: day,
            amountML: 500,
            loggedAt: 1_789_228_800
        )
        let aggregate = HydrationLogEntry(
            id: replacementID,
            day: day,
            amountML: 737,
            loggedAt: 1_789_228_800
        )

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: [legacy],
            replacementEntries: [aggregate],
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .retire)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(metric, 737)
    }

    func testLegacyHydrationResolutionDefersMixedDeletionStateWithoutWriting() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-09-12"
        let deletedID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try await seedLocalHydrationDeleteEvidence(
            entryID: deletedID,
            in: store
        )
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "hydration", value: 737)],
            deviceId: "hydration"
        )
        let legacy = [
            HydrationLogEntry(
                id: deletedID,
                day: day,
                amountML: 250,
                loggedAt: 1_789_228_800
            ),
            HydrationLogEntry(
                id: "11111111-2222-4333-8444-555555555555",
                day: day,
                amountML: 250,
                loggedAt: 1_789_228_860
            ),
        ]

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: legacy,
            replacementEntries: legacy,
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForMixedDeletionState)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertEqual(metric, 737)
    }

    func testLegacyHydrationAdoptionRetryRechecksBoundProfile() async throws {
        let store = try await managedStore()
        let day = "2026-09-14"
        let legacy = HydrationLogEntry(
            id: "11111111-2222-4333-8444-555555555555",
            day: day,
            amountML: 500,
            loggedAt: 1_789_401_600
        )
        try await store.seedHydrationPersistenceForTesting(
            [legacy],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration",
            totalML: 500,
            suppressManagedDocumentDirtyForTesting: true
        )

        let disposition = try await store.adoptLegacyHydrationLogEntries(
            [legacy],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForProfileConflict)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(persisted, [legacy])
        XCTAssertEqual(metric, 500)
    }

    func testLegacyHydrationAdoptionRetryHonorsTombstone() async throws {
        let store = try await managedStore()
        let day = "2026-09-14"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let legacy = HydrationLogEntry(
            id: entryID,
            day: day,
            amountML: 500,
            loggedAt: 1_789_401_600
        )
        try await seedLocalHydrationDeleteEvidence(
            entryID: entryID,
            in: store
        )
        try await store.seedHydrationPersistenceForTesting(
            [legacy],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration",
            totalML: 500,
            suppressManagedDocumentDirtyForTesting: true
        )

        let disposition = try await store.adoptLegacyHydrationLogEntries(
            [legacy],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .retire)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(persisted, [legacy])
        XCTAssertEqual(metric, 500)
    }

    func testLegacyHydrationAdoptionRetryDefersMixedDeletionState() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-09-14"
        let deletedID = "11111111-2222-4333-8444-555555555555"
        let legacy = [
            HydrationLogEntry(
                id: deletedID,
                day: day,
                amountML: 250,
                loggedAt: 1_789_401_600
            ),
            HydrationLogEntry(
                id: "22222222-3333-4444-8555-666666666666",
                day: day,
                amountML: 250,
                loggedAt: 1_789_401_660
            ),
        ]
        try await seedLocalHydrationDeleteEvidence(
            entryID: deletedID,
            in: store
        )
        try await store.seedHydrationPersistenceForTesting(
            legacy,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration",
            totalML: 500,
            suppressManagedDocumentDirtyForTesting: true
        )

        let disposition = try await store.adoptLegacyHydrationLogEntries(
            legacy,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForMixedDeletionState)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(persisted, legacy)
        XCTAssertEqual(metric, 500)
    }

    func testLegacyHydrationResolutionRetryRechecksBoundProfile() async throws {
        let store = try await managedStore()
        let day = "2026-09-15"
        let legacy = HydrationLogEntry(
            id: "11111111-2222-4333-8444-555555555555",
            day: day,
            amountML: 500,
            loggedAt: 1_789_488_000
        )
        let replacement = HydrationLogEntry(
            id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            day: day,
            amountML: 737,
            loggedAt: 1_789_488_000
        )
        try await store.seedHydrationPersistenceForTesting(
            [replacement],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration",
            totalML: 737,
            suppressManagedDocumentDirtyForTesting: true
        )

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: [legacy],
            replacementEntries: [replacement],
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForProfileConflict)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(persisted, [replacement])
        XCTAssertEqual(metric, 737)
    }

    func testLegacyHydrationResolutionRetryHonorsTombstone() async throws {
        let store = try await managedStore()
        let day = "2026-09-15"
        let legacyID = "11111111-2222-4333-8444-555555555555"
        let replacementID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let legacy = HydrationLogEntry(
            id: legacyID,
            day: day,
            amountML: 500,
            loggedAt: 1_789_488_000
        )
        let replacement = HydrationLogEntry(
            id: replacementID,
            day: day,
            amountML: 737,
            loggedAt: 1_789_488_000
        )
        try await seedLocalHydrationDeleteEvidence(
            entryID: legacyID,
            in: store
        )
        try await store.seedHydrationPersistenceForTesting(
            [replacement],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration",
            totalML: 737,
            suppressManagedDocumentDirtyForTesting: true
        )

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: [legacy],
            replacementEntries: [replacement],
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .retire)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(persisted, [replacement])
        XCTAssertEqual(metric, 737)
    }

    func testLegacyHydrationResolutionRetryDefersMixedDeletionState() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-09-15"
        let deletedID = "11111111-2222-4333-8444-555555555555"
        let legacy = [
            HydrationLogEntry(
                id: deletedID,
                day: day,
                amountML: 250,
                loggedAt: 1_789_488_000
            ),
            HydrationLogEntry(
                id: "22222222-3333-4444-8555-666666666666",
                day: day,
                amountML: 250,
                loggedAt: 1_789_488_060
            ),
        ]
        try await seedLocalHydrationDeleteEvidence(
            entryID: deletedID,
            in: store
        )
        try await store.seedHydrationPersistenceForTesting(
            legacy,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration",
            totalML: 500,
            suppressManagedDocumentDirtyForTesting: true
        )

        let disposition = try await store.resolveLegacyHydrationLogEntries(
            legacyEntries: legacy,
            replacementEntries: legacy,
            expectedScalarML: 737,
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )

        XCTAssertEqual(disposition, .deferForMixedDeletionState)
        let persisted = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let metric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(persisted, legacy)
        XCTAssertEqual(metric, 500)
    }

    func testUppercaseHydrationTombstoneStillRetiresCanonicalLegacyID() async throws {
        let store = try await managedStore()
        let day = "2026-09-11"
        let uppercaseID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let canonicalID = uppercaseID.lowercased()
        let documentID = "99999999-8888-5777-8666-555555555555"
        try await store.replaceHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: uppercaseID,
                    day: day,
                    amountML: 237,
                    loggedAt: 1_789_142_400
                ),
            ],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let pending = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        let candidate = try XCTUnwrap(
            pending.first(where: { $0.documentKind == "hydration" })
        )
        try await acknowledge(
            candidate,
            revision: 1,
            documentID: documentID,
            store: store
        )
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "2", count: 64),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 2_000
        )

        let disposition =
            try await store.managedHydrationLegacyDisposition(
                entryIDs: [canonicalID]
            )

        XCTAssertEqual(disposition, .retire)
    }

    func testStaleAcknowledgementCannotOverwriteNewerDeleteProof() async throws {
        let store = try await managedStore()
        let day = "2026-09-11"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let documentID = "99999999-8888-5777-8666-555555555555"
        try await store.replaceHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: entryID,
                    day: day,
                    amountML: 237,
                    loggedAt: 1_789_142_400
                ),
            ],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let firstPending = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        let staleUpsert = try XCTUnwrap(
            firstPending.first(where: { $0.documentKind == "hydration" })
        )
        try await store.acknowledgeManagedDocument(
            accountScopeHash: scope,
            candidate: staleUpsert,
            documentID: documentID,
            remoteRevision: 1,
            remoteContentSHA256: String(repeating: "1", count: 64),
            acknowledgedAtMs: 1_000
        )
        _ = try await store.replaceHydrationLogEntries(
            [],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let secondPending = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        let currentDelete = try XCTUnwrap(
            secondPending.first(where: { $0.documentKind == "hydration" })
        )
        XCTAssertGreaterThan(currentDelete.generation, staleUpsert.generation)
        try await store.acknowledgeManagedDocument(
            accountScopeHash: scope,
            candidate: currentDelete,
            documentID: documentID,
            remoteRevision: 2,
            remoteContentSHA256: String(repeating: "2", count: 64),
            acknowledgedAtMs: 2_000
        )
        try await store.acknowledgeManagedDocument(
            accountScopeHash: scope,
            candidate: staleUpsert,
            documentID: documentID,
            remoteRevision: 1,
            remoteContentSHA256: String(repeating: "1", count: 64),
            acknowledgedAtMs: 3_000
        )

        let state = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT acknowledgedGeneration, remoteRevision,
                           remoteContentSHA256, isDeleted
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND tableName = 'hydrationEntry'
                    """,
                arguments: [self.scope]
            )
        }
        XCTAssertEqual(
            state?["acknowledgedGeneration"] as Int64?,
            currentDelete.generation
        )
        XCTAssertEqual(state?["remoteRevision"] as Int64?, 2)
        XCTAssertEqual(
            state?["remoteContentSHA256"] as String?,
            String(repeating: "2", count: 64)
        )
        XCTAssertEqual(state?["isDeleted"] as Bool?, true)
    }

    func testV61TombstoneReplayUpgradesUnknownDeletionState() async throws {
        let path =
            NSTemporaryDirectory()
            + "managed-hydration-v61-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entryID = "11111111-2222-4333-8444-555555555555"
        let documentID = "99999999-8888-5777-8666-555555555555"
        let revision: Int64 = 2
        let digest = tombstoneDigest(
            documentKind: "hydration",
            documentID: documentID,
            revision: revision
        )
        do {
            let queue = try DatabaseQueue(path: path)
            let migrator = WhoopStore.makeMigrator()
            try migrator.migrate(
                queue,
                upTo: "v61-managed-document-generation-floor"
            )
            try await queue.write { db in
                let localKey = try XCTUnwrap(
                    String.fetchOne(
                        db,
                        sql: "SELECT hex(CAST(? AS BLOB))",
                        arguments: [entryID]
                    )
                )
                try db.execute(
                    sql: """
                        UPDATE managedLocalProfile
                        SET localProfileId = ?,
                            accountScopeHash = ?,
                            updatedAtMs = 1
                        WHERE bindingId = 1
                        """,
                    arguments: [self.scope, self.scope]
                )
                try db.execute(
                    sql: """
                        INSERT INTO managedDocumentState (
                            accountScopeHash, tableName, localKey, documentKind,
                            documentId, keyJSON, acknowledgedGeneration,
                            remoteRevision, remoteContentSHA256, updatedAtMs
                        ) VALUES (
                            ?, 'hydrationEntry', ?, 'hydration', ?,
                            ?, 1, ?, ?, 1
                        )
                        """,
                    arguments: [
                        self.scope,
                        localKey,
                        documentID,
                        #"{"id":"11111111-2222-4333-8444-555555555555"}"#,
                        revision,
                        digest,
                    ]
                )
            }
        }

        let store = try await WhoopStore(path: path)
        let replay = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: revision,
            contentSHA256: digest,
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 2_000
        )
        let isDeleted = try await store.registryWriter.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT isDeleted
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND tableName = 'hydrationEntry'
                    """,
                arguments: [self.scope]
            )
        }

        XCTAssertEqual(
            replay,
            ManagedDocumentApplyResult(changedRows: 0, applied: true)
        )
        XCTAssertEqual(isDeleted, true)
    }

    func testRemoteHydrationMergedDayLimitIsAtomic() async throws {
        let store = try await managedStore()
        let day = "2026-09-11"
        let firstDocumentID = "99999999-8888-5777-8666-555555555555"
        let secondDocumentID = "88888888-7777-5666-8555-444444444444"
        let rejectedDocumentID = "77777777-6666-5555-8444-333333333333"
        let firstEntry = HydrationLogEntry(
            id: "11111111-2222-4333-8444-555555555555",
            day: day,
            amountML: 6_000,
            loggedAt: 1_789_142_400
        )
        let secondEntry = HydrationLogEntry(
            id: "22222222-3333-4444-8555-666666666666",
            day: day,
            amountML: 4_000,
            loggedAt: 1_789_142_460
        )

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: firstDocumentID,
            revision: 1,
            contentSHA256: String(repeating: "1", count: 64),
            payloadJSON: hydrationPayload(
                id: firstEntry.id,
                day: day,
                amountML: String(firstEntry.amountML),
                loggedAt: String(firstEntry.loggedAt)
            ),
            deleted: false,
            appliedAtMs: 1_000
        )
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: secondDocumentID,
            revision: 1,
            contentSHA256: String(repeating: "2", count: 64),
            payloadJSON: hydrationPayload(
                id: secondEntry.id,
                day: day,
                amountML: String(secondEntry.amountML),
                loggedAt: String(secondEntry.loggedAt)
            ),
            deleted: false,
            appliedAtMs: 2_000
        )

        let firstStateBefore = try await hydrationState(
            in: store,
            documentID: firstDocumentID
        )
        let secondStateBefore = try await hydrationState(
            in: store,
            documentID: secondDocumentID
        )
        let boundaryMetric = try await hydrationMetric(in: store, day: day)
        XCTAssertEqual(boundaryMetric, 10_000)

        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: scope,
                documentKind: "hydration",
                documentID: rejectedDocumentID,
                revision: 1,
                contentSHA256: String(repeating: "3", count: 64),
                payloadJSON: hydrationPayload(
                    id: "33333333-4444-4555-8666-777777777777",
                    day: day,
                    amountML: "1",
                    loggedAt: "1789142520"
                ),
                deleted: false,
                appliedAtMs: 3_000
            )
            XCTFail("Expected the merged hydration day to exceed its limit")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .invalidState
            )
        }

        let retainedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let retainedMetric = try await hydrationMetric(in: store, day: day)
        let firstStateAfter = try await hydrationState(
            in: store,
            documentID: firstDocumentID
        )
        let secondStateAfter = try await hydrationState(
            in: store,
            documentID: secondDocumentID
        )
        let rejectedState = try await hydrationState(
            in: store,
            documentID: rejectedDocumentID
        )
        XCTAssertEqual(retainedEntries, [firstEntry, secondEntry])
        XCTAssertEqual(retainedMetric, 10_000)
        XCTAssertEqual(firstStateAfter, firstStateBefore)
        XCTAssertEqual(secondStateAfter, secondStateBefore)
        XCTAssertNil(rejectedState)
    }

    func testRemoteHydrationUpsertPreservesUnacknowledgedLocalGeneration() async throws {
        let store = try await managedStore()
        let documentID = "99999999-8888-5777-8666-555555555555"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let day = "2026-09-11"
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "1", count: 64),
            payloadJSON: hydrationPayload(
                id: entryID,
                day: day,
                amountML: "237",
                loggedAt: "1789142400"
            ),
            deleted: false,
            appliedAtMs: 1_000
        )
        try await store.replaceHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: entryID,
                    day: day,
                    amountML: 500,
                    loggedAt: 1_789_142_460
                ),
            ],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let localCandidateBefore = try await hydrationCandidate(in: store)
        let localBefore = try XCTUnwrap(localCandidateBefore)
        let stateBefore = try await hydrationState(
            in: store,
            documentID: documentID
        )

        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: scope,
                documentKind: "hydration",
                documentID: documentID,
                revision: 2,
                contentSHA256: String(repeating: "2", count: 64),
                payloadJSON: hydrationPayload(
                    id: entryID,
                    day: day,
                    amountML: "750",
                    loggedAt: "1789142520"
                ),
                deleted: false,
                appliedAtMs: 2_000
            )
            XCTFail("Expected the unacknowledged local generation to win")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .unacknowledgedLocalGeneration
            )
        }

        let retainedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let retainedMetric = try await hydrationMetric(in: store, day: day)
        let localAfter = try await hydrationCandidate(in: store)
        let stateAfter = try await hydrationState(
            in: store,
            documentID: documentID
        )
        XCTAssertEqual(
            retainedEntries,
            [
                HydrationLogEntry(
                    id: entryID,
                    day: day,
                    amountML: 500,
                    loggedAt: 1_789_142_460
                ),
            ]
        )
        XCTAssertEqual(retainedMetric, 500)
        XCTAssertEqual(localAfter, localBefore)
        XCTAssertEqual(stateAfter, stateBefore)
    }

    func testRemoteManagedDocumentIgnoresStaleUpsertWithoutRegressingState() async throws {
        let store = try await managedStore()
        let documentID = "99999999-8888-5777-8666-555555555555"
        let newerDigest = String(repeating: "2", count: 64)
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 2,
            contentSHA256: newerDigest,
            payloadJSON: hydrationPayload(amountML: "500"),
            deleted: false,
            appliedAtMs: 2_000
        )
        let stateBefore = try await hydrationState(
            in: store,
            documentID: documentID
        )

        let stale = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "1", count: 64),
            payloadJSON: hydrationPayload(amountML: "237"),
            deleted: false,
            appliedAtMs: 3_000
        )

        let entries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: "2026-09-11"
        )
        let stateAfter = try await hydrationState(
            in: store,
            documentID: documentID
        )
        XCTAssertEqual(
            stale,
            ManagedDocumentApplyResult(changedRows: 0, applied: true)
        )
        XCTAssertEqual(entries.map(\.amountML), [500])
        XCTAssertEqual(stateAfter, stateBefore)
    }

    func testRemoteManagedDocumentIgnoresStaleTombstoneWithoutDeletingNewerRow() async throws {
        let store = try await managedStore()
        let documentID = "99999999-8888-5777-8666-555555555555"
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "2", count: 64),
            payloadJSON: hydrationPayload(amountML: "500"),
            deleted: false,
            appliedAtMs: 2_000
        )
        let stateBefore = try await hydrationState(
            in: store,
            documentID: documentID
        )

        let stale = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 1,
            contentSHA256: tombstoneDigest(
                documentKind: "hydration",
                documentID: documentID,
                revision: 1
            ),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 3_000
        )

        let entries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: "2026-09-11"
        )
        let stateAfter = try await hydrationState(
            in: store,
            documentID: documentID
        )
        XCTAssertEqual(
            stale,
            ManagedDocumentApplyResult(changedRows: 0, applied: true)
        )
        XCTAssertEqual(entries.map(\.amountML), [500])
        XCTAssertEqual(stateAfter, stateBefore)
    }

    func testRemoteManagedDocumentIgnoresStaleUpsertAfterNewerTombstone() async throws {
        let store = try await managedStore()
        let documentID = "99999999-8888-5777-8666-555555555555"
        let upsertDigest = String(repeating: "1", count: 64)
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 1,
            contentSHA256: upsertDigest,
            payloadJSON: hydrationPayload(amountML: "237"),
            deleted: false,
            appliedAtMs: 1_000
        )
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 2,
            contentSHA256: tombstoneDigest(
                documentKind: "hydration",
                documentID: documentID,
                revision: 2
            ),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 2_000
        )
        let stateBefore = try await hydrationState(
            in: store,
            documentID: documentID
        )

        let stale = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 1,
            contentSHA256: upsertDigest,
            payloadJSON: hydrationPayload(amountML: "237"),
            deleted: false,
            appliedAtMs: 3_000
        )

        let entries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: "2026-09-11"
        )
        let stateAfter = try await hydrationState(
            in: store,
            documentID: documentID
        )
        XCTAssertEqual(
            stale,
            ManagedDocumentApplyResult(changedRows: 0, applied: true)
        )
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(stateAfter, stateBefore)
    }

    func testRemoteManagedDocumentRejectsDivergentEqualRevisionAtomically() async throws {
        let store = try await managedStore()
        let documentID = "99999999-8888-5777-8666-555555555555"
        let acceptedDigest = String(repeating: "2", count: 64)
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 2,
            contentSHA256: acceptedDigest,
            payloadJSON: hydrationPayload(amountML: "500"),
            deleted: false,
            appliedAtMs: 2_000
        )
        let stateBefore = try await hydrationState(
            in: store,
            documentID: documentID
        )

        for conflict in [
            (
                digest: String(repeating: "3", count: 64),
                payload: hydrationPayload(amountML: "600") as Data?
            ),
            (digest: acceptedDigest, payload: nil),
        ] {
            do {
                _ = try await store.applyManagedDocument(
                    accountScopeHash: scope,
                    documentKind: "hydration",
                    documentID: documentID,
                    revision: 2,
                    contentSHA256: conflict.digest,
                    payloadJSON: conflict.payload,
                    deleted: conflict.payload == nil,
                    appliedAtMs: 3_000
                )
                XCTFail("Expected an equal-revision conflict")
            } catch {
                XCTAssertEqual(
                    error as? ManagedDocumentStoreError,
                    .invalidState
                )
            }
        }

        let entries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: "2026-09-11"
        )
        let stateAfter = try await hydrationState(
            in: store,
            documentID: documentID
        )
        XCTAssertEqual(entries.map(\.amountML), [500])
        XCTAssertEqual(stateAfter, stateBefore)
    }

    func testRemoteManagedPreferencesIgnoreStaleRevision() async throws {
        let store = try await managedStore()
        let documentID = "22222222-2222-5222-8222-222222222222"
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "preferences",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "2", count: 64),
            payloadJSON: Data(#"{"units.system":"metric"}"#.utf8),
            deleted: false,
            appliedAtMs: 2_000
        )

        let stale = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "preferences",
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "1", count: 64),
            payloadJSON: Data(#"{"units.system":"imperial"}"#.utf8),
            deleted: false,
            appliedAtMs: 3_000
        )
        let state = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT remoteRevision, remoteContentSHA256, updatedAtMs
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND tableName = 'preferences'
                      AND localKey = 'global'
                    """,
                arguments: [self.scope]
            )
        }

        XCTAssertEqual(
            stale,
            ManagedDocumentApplyResult(changedRows: 0, applied: true)
        )
        XCTAssertEqual(state?["remoteRevision"] as Int64?, 2)
        XCTAssertEqual(
            state?["remoteContentSHA256"] as String?,
            String(repeating: "2", count: 64)
        )
        XCTAssertEqual(state?["updatedAtMs"] as Int64?, 2_000)
    }

    func testRemoteHydrationTombstonePreservesUnacknowledgedLocalGeneration() async throws {
        let store = try await managedStore()
        let documentID = "99999999-8888-5777-8666-555555555555"
        let entryID = "11111111-2222-4333-8444-555555555555"
        let day = "2026-09-11"
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "hydration",
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "1", count: 64),
            payloadJSON: hydrationPayload(
                id: entryID,
                day: day,
                amountML: "237",
                loggedAt: "1789142400"
            ),
            deleted: false,
            appliedAtMs: 1_000
        )
        try await store.replaceHydrationLogEntries(
            [
                HydrationLogEntry(
                    id: entryID,
                    day: day,
                    amountML: 500,
                    loggedAt: 1_789_142_460
                ),
            ],
            deviceId: "hydration",
            day: day,
            metricKey: "hydration"
        )
        let localCandidateBefore = try await hydrationCandidate(in: store)
        let localBefore = try XCTUnwrap(localCandidateBefore)
        let stateBefore = try await hydrationState(
            in: store,
            documentID: documentID
        )

        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: scope,
                documentKind: "hydration",
                documentID: documentID,
                revision: 2,
                contentSHA256: String(repeating: "2", count: 64),
                payloadJSON: nil,
                deleted: true,
                appliedAtMs: 2_000
            )
            XCTFail("Expected the unacknowledged local generation to win")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .unacknowledgedLocalGeneration
            )
        }

        let retainedEntries = try await store.hydrationLogEntries(
            deviceId: "hydration",
            day: day
        )
        let retainedMetric = try await hydrationMetric(in: store, day: day)
        let localAfter = try await hydrationCandidate(in: store)
        let stateAfter = try await hydrationState(
            in: store,
            documentID: documentID
        )
        XCTAssertEqual(retainedEntries.map(\.amountML), [500])
        XCTAssertEqual(retainedMetric, 500)
        XCTAssertEqual(localAfter, localBefore)
        XCTAssertEqual(stateAfter, stateBefore)
    }

    func testUnknownRemoteTombstoneMatchingPendingLocalRebasesRevision() async throws {
        let store = try await managedStore()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'local-strap', 1)
                """)
        }
        let pendingBefore = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        let localBefore = try XCTUnwrap(pendingBefore.first)
        let documentID = ManagedDocumentStableIdentifier.uuid(
            documentKind: localBefore.documentKind,
            tableName: localBefore.tableName,
            keyJSON: localBefore.keyJSON
        ).uuidString.lowercased()
        let firstDigest = tombstoneDigest(
            documentKind: localBefore.documentKind,
            documentID: documentID,
            revision: 4
        )

        let result = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: localBefore.documentKind,
            documentID: documentID,
            revision: 4,
            contentSHA256: firstDigest,
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 2_000
        )
        let replay = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: localBefore.documentKind,
            documentID: documentID,
            revision: 4,
            contentSHA256: firstDigest,
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 3_000
        )
        let newerDigest = tombstoneDigest(
            documentKind: localBefore.documentKind,
            documentID: documentID,
            revision: 7
        )
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: localBefore.documentKind,
            documentID: documentID,
            revision: 7,
            contentSHA256: newerDigest,
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 4_000
        )

        let pendingAfter = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        let localAfter = try XCTUnwrap(pendingAfter.first)
        let state = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT acknowledgedGeneration, remoteRevision,
                           remoteContentSHA256
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND tableName = 'dayOwnership'
                      AND localKey = ?
                    """,
                arguments: [self.scope, localBefore.localKey]
            )
        }

        XCTAssertEqual(
            result,
            ManagedDocumentApplyResult(changedRows: 0, applied: true)
        )
        XCTAssertEqual(replay, result)
        XCTAssertEqual(localAfter.tableName, localBefore.tableName)
        XCTAssertEqual(localAfter.documentKind, localBefore.documentKind)
        XCTAssertEqual(localAfter.contentMode, localBefore.contentMode)
        XCTAssertEqual(localAfter.localKey, localBefore.localKey)
        XCTAssertEqual(localAfter.keyJSON, localBefore.keyJSON)
        XCTAssertEqual(localAfter.generation, localBefore.generation)
        XCTAssertEqual(localAfter.updatedAtMs, localBefore.updatedAtMs)
        XCTAssertEqual(localAfter.payloadJSON, localBefore.payloadJSON)
        XCTAssertEqual(localBefore.baseRevision, 0)
        XCTAssertEqual(localAfter.baseRevision, 7)
        XCTAssertEqual(state?["acknowledgedGeneration"] as Int64?, 0)
        XCTAssertEqual(state?["remoteRevision"] as Int64?, 7)
        XCTAssertEqual(
            state?["remoteContentSHA256"] as String?,
            newerDigest
        )
    }

    func testMatchingTombstoneResolvesPreAcknowledgementDayOwnershipDelete() async throws {
        let store = try await managedStore()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'target', 1)
                """)
        }
        let initialCandidates = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        let initial = try XCTUnwrap(initialCandidates.first)
        let documentID = ManagedDocumentStableIdentifier.uuid(
            documentKind: initial.documentKind,
            tableName: initial.tableName,
            keyJSON: initial.keyJSON
        ).uuidString.lowercased()
        try await store.registryWriter.write { db in
            try db.execute(
                sql: "DELETE FROM dayOwnership WHERE day = '2026-09-11'"
            )
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-12', 'unrelated', 1)
                """)
        }
        let unrelatedBefore = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        let digest = tombstoneDigest(
            documentKind: initial.documentKind,
            documentID: documentID,
            revision: 3
        )

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: initial.documentKind,
            documentID: documentID,
            revision: 3,
            contentSHA256: digest,
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 3_000
        )

        let unrelatedAfter = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        let resolved = try await store.registryWriter.read { db in
            try Row.fetchOne(db, sql: """
                SELECT dirty.generation, dirty.operation,
                       state.acknowledgedGeneration, state.remoteRevision
                FROM managedDocumentDirty AS dirty
                JOIN managedDocumentState AS state
                  ON state.tableName = dirty.tableName
                 AND state.localKey = dirty.localKey
                WHERE dirty.tableName = 'dayOwnership'
                  AND dirty.localKey = ?
                """, arguments: [initial.localKey])
        }
        XCTAssertEqual(unrelatedAfter, unrelatedBefore)
        XCTAssertEqual(resolved?["operation"] as String?, "delete")
        XCTAssertEqual(resolved?["generation"] as Int64?, 2)
        XCTAssertEqual(resolved?["acknowledgedGeneration"] as Int64?, 2)
        XCTAssertEqual(resolved?["remoteRevision"] as Int64?, 3)
    }

    func testUnknownRemoteTombstoneIsNoOpWithUnrelatedPendingLocalKind() async throws {
        let store = try await managedStore()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-09-11', 'local-strap', 1)
                """)
        }
        let localBefore = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )

        let result = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: "99999999-8888-5777-8666-555555555555",
            revision: 1,
            contentSHA256: String(repeating: "3", count: 64),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 1_000
        )

        let localAfter = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        let stateCount = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM managedDocumentState"
            ) ?? -1
        }
        XCTAssertEqual(result, ManagedDocumentApplyResult(changedRows: 0, applied: true))
        XCTAssertEqual(localAfter, localBefore)
        XCTAssertEqual(stateCount, 0)
    }

    func testRemoteDayOwnershipAcceptsBooleanAndExactBinaryInteger() async throws {
        let store = try await managedStore()
        let documentID = "77777777-8888-5999-8aaa-bbbbbbbbbbbb"

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "4", count: 64),
            payloadJSON: dayOwnershipPayload(locked: "true"),
            deleted: false,
            appliedAtMs: 1_000
        )
        let first = try await dayOwnership(in: store, day: "2026-09-11")
        XCTAssertEqual(first?.deviceID, "strap")
        XCTAssertEqual(first?.locked, 1)

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "5", count: 64),
            payloadJSON: dayOwnershipPayload(locked: "0"),
            deleted: false,
            appliedAtMs: 2_000
        )
        let second = try await dayOwnership(in: store, day: "2026-09-11")
        XCTAssertEqual(second?.deviceID, "strap")
        XCTAssertEqual(second?.locked, 0)
    }

    func testRemoteDayOwnershipInvalidatesExactDayOnlyWhenValueChanges() async throws {
        let store = try await managedStore()
        let documentID = "77777777-8888-5999-8aaa-bbbbbbbbbbbb"
        let day = "2026-09-11"
        let utcDayStart = Int64(try XCTUnwrap(
            ISO8601DateFormatter().date(from: "\(day)T00:00:00Z")
        ).timeIntervalSince1970)
        let maximumOffset =
            AnalysisOwnershipInvalidation.maximumSupportedTimeZoneOffsetSeconds
        let expectedRange = (utcDayStart - maximumOffset)...(
            utcDayStart + 86_400 + maximumOffset - 1
        )
        let originalPayload = dayOwnershipPayload(day: day, locked: "0")

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 1,
            contentSHA256: String(repeating: "4", count: 64),
            payloadJSON: originalPayload,
            deleted: false,
            appliedAtMs: 1_000
        )
        var claim = try await ownershipClaim(in: store)
        XCTAssertEqual(claim.generation, 1)
        XCTAssertEqual(claim.affectedTimeRange, expectedRange)

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 2,
            contentSHA256: String(repeating: "5", count: 64),
            payloadJSON: originalPayload,
            deleted: false,
            appliedAtMs: 2_000
        )
        claim = try await ownershipClaim(in: store)
        XCTAssertEqual(claim.generation, 1)
        XCTAssertEqual(claim.affectedTimeRange, expectedRange)

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 3,
            contentSHA256: String(repeating: "6", count: 64),
            payloadJSON: dayOwnershipPayload(day: day, locked: "1"),
            deleted: false,
            appliedAtMs: 3_000
        )
        claim = try await ownershipClaim(in: store)
        XCTAssertEqual(claim.generation, 2)
        XCTAssertEqual(claim.affectedTimeRange, expectedRange)

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 4,
            contentSHA256: tombstoneDigest(
                documentKind: "day_ownership",
                documentID: documentID,
                revision: 4
            ),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 4_000
        )
        claim = try await ownershipClaim(in: store)
        XCTAssertEqual(claim.generation, 3)
        XCTAssertEqual(claim.affectedTimeRange, expectedRange)

        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "day_ownership",
            documentID: documentID,
            revision: 5,
            contentSHA256: tombstoneDigest(
                documentKind: "day_ownership",
                documentID: documentID,
                revision: 5
            ),
            payloadJSON: nil,
            deleted: true,
            appliedAtMs: 5_000
        )
        claim = try await ownershipClaim(in: store)
        XCTAssertEqual(claim.generation, 3)
        XCTAssertEqual(claim.affectedTimeRange, expectedRange)
    }

    func testRemoteDayOwnershipRejectsInvalidDomainAndKeyValues() async throws {
        let oversizedDeviceID = String(repeating: "x", count: 257)
        let oversizedMultibyteDeviceID = String(
            repeating: "\u{00E9}",
            count: 129
        )
        let cases: [(name: String, payload: Data)] = [
            (
                "invalid calendar day",
                dayOwnershipPayload(day: "2026-02-30")
            ),
            (
                "mismatched key",
                dayOwnershipPayload(keyDay: "2026-09-10")
            ),
            (
                "extra key",
                dayOwnershipPayload(includeExtraKey: true)
            ),
            (
                "empty device identifier",
                dayOwnershipPayload(deviceID: "")
            ),
            (
                "blank device identifier",
                dayOwnershipPayload(deviceID: "   ")
            ),
            (
                "leading whitespace in device identifier",
                dayOwnershipPayload(deviceID: " strap")
            ),
            (
                "trailing whitespace in device identifier",
                dayOwnershipPayload(deviceID: "strap ")
            ),
            (
                "oversized device identifier",
                dayOwnershipPayload(deviceID: oversizedDeviceID)
            ),
            (
                "oversized multibyte device identifier",
                dayOwnershipPayload(deviceID: oversizedMultibyteDeviceID)
            ),
            (
                "control character in device identifier",
                dayOwnershipPayload(deviceID: #"strap\u0001"#)
            ),
            (
                "fractional locked value",
                dayOwnershipPayload(locked: "0.5")
            ),
            (
                "out-of-range locked value",
                dayOwnershipPayload(locked: "2")
            ),
            (
                "string locked value",
                dayOwnershipPayload(locked: #""1""#)
            ),
        ]

        for testCase in cases {
            try await assertInvalidDayOwnershipPayload(
                testCase.payload,
                message: testCase.name
            )
        }
    }

    func testPendingDayOwnershipRejectsInvalidLocalRecord() async throws {
        let store = try await managedStore()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked)
                VALUES ('2026-02-30', 'strap', 2)
                """)
        }

        do {
            _ = try await store.pendingManagedDocuments(
                accountScopeHash: scope,
                contentMode: .serverReadable,
                limit: 10
            )
            XCTFail("Expected invalid local ownership state to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .invalidPayload
            )
        }
    }

    func testPendingDayOwnershipRejectsInvalidDeviceIdentifiers() async throws {
        let cases = [
            (name: "blank", value: "   "),
            (name: "leading whitespace", value: " strap"),
            (name: "trailing whitespace", value: "strap "),
            (name: "control", value: "strap\u{0001}"),
            (
                name: "oversized multibyte",
                value: String(repeating: "\u{00E9}", count: 129)
            ),
        ]

        for testCase in cases {
            let store = try await managedStore()
            try await store.registryWriter.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO dayOwnership (day, deviceId, locked)
                        VALUES ('2026-09-11', ?, 1)
                        """,
                    arguments: [testCase.value]
                )
            }

            do {
                _ = try await store.pendingManagedDocuments(
                    accountScopeHash: scope,
                    contentMode: .serverReadable,
                    limit: 10
                )
                XCTFail(
                    "Expected invalid local device identifier: \(testCase.name)"
                )
            } catch {
                XCTAssertEqual(
                    error as? ManagedDocumentStoreError,
                    .invalidPayload,
                    testCase.name
                )
            }
        }
    }

    func testRemoteHydrationRejectsNonExactSchemaAndNumericValues() async throws {
        let cases: [(name: String, payload: Data)] = [
            (
                "boolean schema",
                hydrationPayload(schemaVersion: "true")
            ),
            (
                "fractional schema",
                hydrationPayload(schemaVersion: "1.5")
            ),
            (
                "overflowing schema",
                hydrationPayload(schemaVersion: "9223372036854775808")
            ),
            (
                "boolean amount",
                hydrationPayload(amountML: "true")
            ),
            (
                "fractional amount",
                hydrationPayload(amountML: "237.5")
            ),
            (
                "overflowing amount",
                hydrationPayload(amountML: "9223372036854775808")
            ),
            (
                "excessive amount",
                hydrationPayload(amountML: "10001")
            ),
            (
                "boolean timestamp",
                hydrationPayload(loggedAt: "true")
            ),
            (
                "fractional timestamp",
                hydrationPayload(loggedAt: "1789142400.5")
            ),
            (
                "overflowing timestamp",
                hydrationPayload(loggedAt: "9223372036854775808")
            ),
        ]

        for testCase in cases {
            try await assertInvalidHydrationPayload(
                testCase.payload,
                message: testCase.name
            )
        }
    }

    func testRemoteHydrationRejectsInvalidDayAndTimestampRanges() async throws {
        let cases: [(name: String, payload: Data)] = [
            (
                "invalid calendar day",
                hydrationPayload(day: "2026-02-30")
            ),
            (
                "out-of-range calendar year",
                hydrationPayload(day: "1999-12-31", loggedAt: "946641600")
            ),
            (
                "timestamp outside possible local day",
                hydrationPayload(loggedAt: "1789344000")
            ),
            (
                "zero amount",
                hydrationPayload(amountML: "0")
            ),
            (
                "invalid identifier",
                hydrationPayload(id: "not-a-uuid")
            ),
        ]

        for testCase in cases {
            try await assertInvalidHydrationPayload(
                testCase.payload,
                message: testCase.name
            )
        }
    }

    func testPreferencesRemainClientEncryptedAndLocallyDirty() async throws {
        let store = try await managedStore()
        let first = Data(#"{"settings.schemaVersion":4,"units.system":"metric"}"#.utf8)
        try await store.stageManagedPreferences(first, updatedAtMs: 1_000)
        try await store.stageManagedPreferences(first, updatedAtMs: 2_000)

        let preferenceRows = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        let pending = try XCTUnwrap(preferenceRows.first)
        XCTAssertEqual(pending.tableName, "preferences")
        XCTAssertEqual(pending.localKey, "global")
        XCTAssertEqual(pending.contentMode, .clientEncrypted)
        XCTAssertEqual(pending.generation, 1)
        XCTAssertEqual(pending.payloadJSON, first)

        let serverReadable = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .serverReadable,
            limit: 10
        )
        XCTAssertTrue(serverReadable.isEmpty)

        do {
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
            XCTFail("Expected the local preference generation to remain dirty")
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .unacknowledgedLocalGeneration
            )
        }
        let afterApply = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertEqual(afterApply, preferenceRows)
    }

    func testRemoteManagedPreferencesPersistWithoutCreatingUploadEcho()
        async throws
    {
        let store = try await managedStore()
        let remote = Data(
            #"{"settings.schemaVersion":4,"units.system":"metric"}"#.utf8
        )
        let keyJSON = try JSONSerialization.data(
            withJSONObject: ["scope": "global"],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let documentID = ManagedDocumentStableIdentifier.uuid(
            documentKind: "preferences",
            tableName: "preferences",
            keyJSON: keyJSON
        )
        _ = try await store.applyManagedDocument(
            accountScopeHash: scope,
            documentKind: "preferences",
            documentID: documentID.uuidString.lowercased(),
            revision: 1,
            contentSHA256: String(repeating: "d", count: 64),
            payloadJSON: remote,
            deleted: false,
            appliedAtMs: 1_000
        )

        var pending = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertTrue(pending.isEmpty)

        try await store.stageManagedPreferences(remote, updatedAtMs: 2_000)
        pending = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertTrue(pending.isEmpty)

        let local = Data(
            #"{"settings.schemaVersion":4,"units.system":"imperial"}"#.utf8
        )
        try await store.stageManagedPreferences(local, updatedAtMs: 3_000)
        pending = try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.payloadJSON, local)
        XCTAssertEqual(pending.first?.generation, 2)
    }

    private func managedStore(
        accountScopeHash: String? = nil
    ) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.activateManagedDocumentProfile(
            accountScopeHash: accountScopeHash ?? scope,
            updatedAtMs: 1
        )
        return store
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

    private func insertDayOwnership(
        into store: WhoopStore,
        day: String,
        deviceID: String
    ) async throws {
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dayOwnership (day, deviceId, locked)
                    VALUES (?, ?, 0)
                    """,
                arguments: [day, deviceID]
            )
        }
    }

    private func updateDayOwnership(
        in store: WhoopStore,
        day: String,
        deviceID: String
    ) async throws {
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE dayOwnership
                    SET deviceId = ?
                    WHERE day = ?
                    """,
                arguments: [deviceID, day]
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

    private func hydrationPayload(
        schemaVersion: String = "1",
        id: String = "11111111-2222-4333-8444-555555555555",
        day: String = "2026-09-11",
        amountML: String = "237",
        loggedAt: String = "1789142400"
    ) -> Data {
        Data(
            """
            {
              "schema_version": \(schemaVersion),
              "table": "hydrationEntry",
              "key": {"id": "\(id)"},
              "record": {
                "id": "\(id)",
                "deviceId": "hydration",
                "day": "\(day)",
                "amountML": \(amountML),
                "loggedAt": \(loggedAt)
              }
            }
            """.utf8
        )
    }

    private func dayOwnershipPayload(
        keyDay: String? = nil,
        day: String = "2026-09-11",
        deviceID: String = "strap",
        locked: String = "1",
        includeExtraKey: Bool = false
    ) -> Data {
        let extraKey = includeExtraKey ? #", "extra": "value""# : ""
        return Data(
            """
            {
              "schema_version": 1,
              "table": "dayOwnership",
              "key": {"day": "\(keyDay ?? day)"\(extraKey)},
              "record": {
                "day": "\(day)",
                "deviceId": "\(deviceID)",
                "locked": \(locked)
              }
            }
            """.utf8
        )
    }

    private func tombstoneDigest(
        documentKind: String,
        documentID: String,
        revision: Int64
    ) -> String {
        SHA256.hash(
            data: Data(
                "deleted:\(documentKind):\(documentID):\(revision)".utf8
            )
        ).map { String(format: "%02x", $0) }.joined()
    }

    private func assertInvalidDayOwnershipPayload(
        _ payload: Data,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = try await managedStore()
        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: scope,
                documentKind: "day_ownership",
                documentID: "77777777-8888-5999-8aaa-bbbbbbbbbbbb",
                revision: 1,
                contentSHA256: String(repeating: "f", count: 64),
                payloadJSON: payload,
                deleted: false,
                appliedAtMs: 1_000
            )
            XCTFail(
                "Expected invalid day ownership payload: \(message)",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .invalidPayload,
                message,
                file: file,
                line: line
            )
        }
        let counts = try await store.registryWriter.read { db in
            (
                owners: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM dayOwnership"
                ) ?? -1,
                states: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM managedDocumentState"
                ) ?? -1
            )
        }
        XCTAssertEqual(counts.owners, 0, message, file: file, line: line)
        XCTAssertEqual(counts.states, 0, message, file: file, line: line)
    }

    private func dayOwnership(
        in store: WhoopStore,
        day: String
    ) async throws -> (deviceID: String, locked: Int64)? {
        try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT deviceId, locked
                    FROM dayOwnership
                    WHERE day = ?
                    """,
                arguments: [day]
            ).map {
                (deviceID: $0["deviceId"], locked: $0["locked"])
            }
        }
    }

    private func ownershipClaim(
        in store: WhoopStore
    ) async throws -> AnalysisInputGenerationClaim {
        let claims = try await store.pendingAnalysisInputGenerations(
            deviceIds: [AnalysisInputSource.ownership]
        )
        return try XCTUnwrap(claims.first)
    }

    private func assertInvalidHydrationPayload(
        _ payload: Data,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = try await managedStore()
        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: scope,
                documentKind: "hydration",
                documentID: "99999999-8888-5777-8666-555555555555",
                revision: 1,
                contentSHA256: String(repeating: "f", count: 64),
                payloadJSON: payload,
                deleted: false,
                appliedAtMs: 1_000
            )
            XCTFail(
                "Expected invalid hydration payload: \(message)",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? ManagedDocumentStoreError,
                .invalidPayload,
                message,
                file: file,
                line: line
            )
        }
        let counts = try await store.registryWriter.read { db in
            (
                entries: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM hydrationEntry"
                ) ?? -1,
                states: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM managedDocumentState"
                ) ?? -1
            )
        }
        XCTAssertEqual(counts.entries, 0, message, file: file, line: line)
        XCTAssertEqual(counts.states, 0, message, file: file, line: line)
    }

    private func hydrationCandidate(
        in store: WhoopStore
    ) async throws -> ManagedLocalDocumentCandidate? {
        try await store.pendingManagedDocuments(
            accountScopeHash: scope,
            contentMode: .clientEncrypted,
            limit: 10
        ).first {
            $0.tableName == "hydrationEntry"
        }
    }

    private func seedLocalHydrationDeleteEvidence(
        entryID: String,
        in store: WhoopStore
    ) async throws {
        try await store.registryWriter.write { db in
            let localProfileID = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: """
                        SELECT localProfileId
                        FROM managedLocalProfile
                        WHERE bindingId = 1
                        """
                )
            )
            let localKey = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT lower(hex(CAST(? AS BLOB)))",
                    arguments: [entryID]
                )
            )
            try db.execute(
                sql: """
                    INSERT INTO managedDocumentDirty (
                        localProfileId, tableName, localKey, documentKind,
                        generation, operation, updatedAtMs, payloadJSON
                    ) VALUES (?, 'hydrationEntry', ?, 'hydration',
                              1, 'delete', 1, NULL)
                    """,
                arguments: [localProfileID, localKey]
            )
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

    private func hydrationState(
        in store: WhoopStore,
        documentID: String
    ) async throws -> ManagedStateSnapshot? {
        try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT acknowledgedGeneration, remoteRevision,
                           remoteContentSHA256, updatedAtMs
                    FROM managedDocumentState
                    WHERE accountScopeHash = ?
                      AND documentKind = 'hydration'
                      AND documentId = ?
                    """,
                arguments: [self.scope, documentID.lowercased()]
            ).map {
                ManagedStateSnapshot(
                    acknowledgedGeneration: $0["acknowledgedGeneration"],
                    remoteRevision: $0["remoteRevision"],
                    remoteContentSHA256: $0["remoteContentSHA256"],
                    updatedAtMs: $0["updatedAtMs"]
                )
            }
        }
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
