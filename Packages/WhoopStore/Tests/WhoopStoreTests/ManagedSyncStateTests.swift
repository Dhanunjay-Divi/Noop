import GRDB
import XCTest
@testable import WhoopStore

final class ManagedSyncStateTests: XCTestCase {
    func testV54CreatesCompactManagedSyncRestoreAndDocumentState() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for table in [
            "managedSyncSource",
            "managedSyncCheckpoint",
            "managedWindowUpload",
            "managedChangeCursor",
            "managedAppliedChange",
            "managedDirtyWindow",
            "managedPruneGuard",
            "managedSnapshotRestore",
            "managedDocumentDirty",
            "managedDocumentState",
            "managedDocumentApplyGuard",
        ] {
            XCTAssertTrue(tables.contains(table), "missing \(table)")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 54)
    }

    func testSourceAndCheckpointRoundTripWithoutSampleOutbox() async throws {
        let store = try await WhoopStore.inMemory()
        let source = ManagedSyncSourceState(
            sourceID: "11111111-1111-5111-8111-111111111111",
            localSourceID: "my-whoop",
            sourceKind: "wearable",
            platform: "ios",
            logicalSourceHash: String(repeating: "a", count: 64),
            createdAtMs: 1_000,
            updatedAtMs: 2_000
        )
        try await store.upsertManagedSyncSource(source)
        let storedSource = try await store.managedSyncSource(localSourceID: "my-whoop")
        XCTAssertEqual(storedSource, source)

        let scope = String(repeating: "b", count: 64)
        let checkpoint = ManagedSyncCheckpointState(
            accountScopeHash: scope,
            sourceID: source.sourceID,
            dataClass: "essential_timeseries",
            nextWindowStartMs: 3_600_000,
            repairWindowStartMs: 0,
            updatedAtMs: 2_500
        )
        try await store.saveManagedSyncCheckpoint(checkpoint)
        let storedCheckpoint = try await store.managedSyncCheckpoint(
            accountScopeHash: scope,
            sourceID: source.sourceID,
            dataClass: checkpoint.dataClass
        )
        XCTAssertEqual(storedCheckpoint, checkpoint)
        let otherAccountCheckpoint = try await store.managedSyncCheckpoint(
            accountScopeHash: String(repeating: "c", count: 64),
            sourceID: source.sourceID,
            dataClass: checkpoint.dataClass
        )
        XCTAssertNil(otherAccountCheckpoint)

        let window = ManagedWindowUploadState(
            accountScopeHash: scope,
            sourceID: source.sourceID,
            dataClass: checkpoint.dataClass,
            windowStartMs: 0,
            windowEndMs: 3_599_999,
            chunkID: "22222222-2222-5222-8222-222222222222",
            rowCount: 2,
            phase: "pending_completion",
            objectGeneration: 42,
            objectMetageneration: 1,
            objectCRC32C: "AAAAAA==",
            updatedAtMs: 2_600
        )
        try await store.saveManagedWindowUpload(window)
        let storedWindow = try await store.managedWindowUpload(
            accountScopeHash: scope,
            sourceID: source.sourceID,
            dataClass: checkpoint.dataClass,
            windowStartMs: 0
        )
        XCTAssertEqual(storedWindow, window)
    }

    func testChangeCursorCannotMoveBackwardAndReceiptsStayBounded() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = String(repeating: "b", count: 64)
        try await store.saveManagedChangeSequence(9, accountScopeHash: scope, updatedAtMs: 90)
        try await store.saveManagedChangeSequence(3, accountScopeHash: scope, updatedAtMs: 100)
        let sequenceBeforeReceipts = try await store.managedChangeSequence(accountScopeHash: scope)
        XCTAssertEqual(sequenceBeforeReceipts, 9)

        for sequence in 1...40 {
            try await store.recordManagedAppliedChange(
                ManagedAppliedChangeState(
                    accountScopeHash: scope,
                    sequence: Int64(sequence),
                    resourceKind: "chunk",
                    resourceID: "resource-\(sequence)",
                    contentSHA256: nil,
                    appliedAtMs: Int64(sequence)
                ),
                retainingLatest: 32
            )
        }
        let retained8 = try await store.hasManagedAppliedChange(accountScopeHash: scope, sequence: 8)
        let retained9 = try await store.hasManagedAppliedChange(accountScopeHash: scope, sequence: 9)
        let retained40 = try await store.hasManagedAppliedChange(accountScopeHash: scope, sequence: 40)
        XCTAssertFalse(retained8)
        XCTAssertTrue(retained9)
        XCTAssertTrue(retained40)

        try await store.resetManagedChangeState(accountScopeHash: scope)
        let resetSequence = try await store.managedChangeSequence(accountScopeHash: scope)
        let retainedAfterReset = try await store.hasManagedAppliedChange(
            accountScopeHash: scope,
            sequence: 40
        )
        XCTAssertEqual(resetSequence, 0)
        XCTAssertFalse(retainedAfterReset)
    }

    func testDirtyTriggerAdvancesOncePerClaimedGeneration() async throws {
        let store = try await WhoopStore.inMemory()
        let sourceID = "11111111-1111-5111-8111-111111111111"
        try await store.upsertManagedSyncSource(
            ManagedSyncSourceState(
                sourceID: sourceID,
                localSourceID: "strap",
                sourceKind: "live_ble",
                platform: "ios",
                logicalSourceHash: String(repeating: "a", count: 64),
                createdAtMs: 1,
                updatedAtMs: 1
            )
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm, synced)
                    VALUES ('strap', 100, 68, 0)
                    """
            )
            try db.execute(
                sql: "UPDATE hrSample SET synced = 1 WHERE deviceId = 'strap'"
            )
        }
        let initial = try await store.claimManagedDirtyWindow(
            localSourceID: "strap",
            dataClass: "essential_timeseries",
            windowStartMs: 0,
            windowEndMs: 21_600_000,
            updatedAtMs: 2
        )
        XCTAssertEqual(initial.generation, 1)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE hrSample SET bpm = 69 WHERE deviceId = 'strap'"
            )
            try db.execute(
                sql: "UPDATE hrSample SET bpm = 70 WHERE deviceId = 'strap'"
            )
        }
        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT generation, claimedGeneration
                    FROM managedDirtyWindow
                    WHERE localSourceId = 'strap'
                      AND dataClass = 'essential_timeseries'
                      AND windowStartMs = 0
                    """
            )
        }
        XCTAssertEqual(row?["generation"] as Int64?, 2)
        XCTAssertEqual(row?["claimedGeneration"] as Int64?, 1)
    }

    func testOnlyValidatedUnchangedWindowCanPruneAndBodyMeasurementStays() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = String(repeating: "b", count: 64)
        let sourceID = "11111111-1111-5111-8111-111111111111"
        let chunkID = "22222222-2222-5222-8222-222222222222"
        try await store.upsertManagedSyncSource(
            ManagedSyncSourceState(
                sourceID: sourceID,
                localSourceID: "strap",
                sourceKind: "live_ble",
                platform: "ios",
                logicalSourceHash: String(repeating: "a", count: 64),
                createdAtMs: 1,
                updatedAtMs: 1
            )
        )
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm, synced)
                    VALUES ('strap', 100, 68, 0)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO bodyMeasurement (
                        deviceId, measuredAt, receivedAt, weightKg, bmi, heightCm,
                        userId, unit, source
                    ) VALUES ('strap', 100, 100, 72, 22, 181, -1, 'kg', 'manual')
                    """
            )
        }
        let dirty = try await store.claimManagedDirtyWindow(
            localSourceID: "strap",
            dataClass: "essential_timeseries",
            windowStartMs: 0,
            windowEndMs: 21_600_000,
            updatedAtMs: 2
        )
        try await store.saveManagedWindowUpload(
            ManagedWindowUploadState(
                accountScopeHash: scope,
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                windowStartMs: 0,
                windowEndMs: 21_599_999,
                chunkID: chunkID,
                rowCount: 2,
                phase: "awaiting_validation",
                objectGeneration: nil,
                objectMetageneration: nil,
                objectCRC32C: nil,
                updatedAtMs: 3,
                snapshotGeneration: dirty.generation
            )
        )

        let beforeValidation = try await store.pruneManagedAvailableWindows(
            accountScopeHash: scope,
            sourceID: sourceID,
            localSourceID: "strap",
            dataClass: "essential_timeseries",
            endingBeforeMs: 21_600_001,
            limit: 4,
            prunedAtMs: 4
        )
        XCTAssertEqual(beforeValidation.prunedWindows, 0)
        let acknowledged = try await store.acknowledgeManagedAvailableChunk(
            accountScopeHash: scope,
            sourceID: sourceID,
            dataClass: "essential_timeseries",
            windowStartMs: 0,
            windowEndMs: 21_599_999,
            chunkID: chunkID,
            validatedAtMs: 5
        )
        XCTAssertTrue(acknowledged)
        let pruned = try await store.pruneManagedAvailableWindows(
            accountScopeHash: scope,
            sourceID: sourceID,
            localSourceID: "strap",
            dataClass: "essential_timeseries",
            endingBeforeMs: 21_600_001,
            limit: 4,
            prunedAtMs: 6
        )
        let counts = try await store.registryWriter.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = 'strap'"
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM bodyMeasurement
                        WHERE deviceId = 'strap'
                        """
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM managedDirtyWindow"
                ) ?? 0
            )
        }
        let upload = try await store.managedWindowUpload(
            accountScopeHash: scope,
            sourceID: sourceID,
            dataClass: "essential_timeseries",
            windowStartMs: 0
        )
        XCTAssertEqual(pruned.prunedWindows, 1)
        XCTAssertEqual(pruned.deletedRows, 1)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(upload?.localPrunedAtMs, 6)
    }

    func testValidatedRawWindowsPruneMappedRowsAndKeepDailySummary() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = String(repeating: "b", count: 64)
        let sourceID = "11111111-1111-5111-8111-111111111111"
        try await store.upsertManagedSyncSource(
            ManagedSyncSourceState(
                sourceID: sourceID,
                localSourceID: "strap",
                sourceKind: "live_ble",
                platform: "ios",
                logicalSourceHash: String(repeating: "a", count: 64),
                createdAtMs: 1,
                updatedAtMs: 1
            )
        )
        try await store.registryWriter.write { db in
            for statement in [
                "INSERT INTO skinTempSample (deviceId, ts, raw, synced) VALUES ('strap', 100, 1, 0)",
                "INSERT INTO respSample (deviceId, ts, raw, synced) VALUES ('strap', 100, 2, 0)",
                "INSERT INTO sleepStateSample (deviceId, ts, state, synced) VALUES ('strap', 100, 1, 0)",
                "INSERT INTO spo2Sample (deviceId, ts, red, ir, synced) VALUES ('strap', 100, 3, 4, 0)",
                "INSERT INTO ppgWaveformSample (deviceId, ts, samples, synced) VALUES ('strap', 100, X'0001', 0)",
                "INSERT INTO gravitySample (deviceId, ts, x, y, z, synced) VALUES ('strap', 100, 0, 0, 1, 0)",
                "INSERT INTO rawImuSample (deviceId, ts, samples) VALUES ('strap', 100, X'0001')",
                "INSERT INTO dailyMetric (deviceId, day) VALUES ('strap', '1970-01-01')",
            ] {
                try db.execute(sql: statement)
            }
        }

        let classes: [(name: String, rowCount: Int, chunkID: String)] = [
            ("raw_auxiliary", 3, "22222222-2222-5222-8222-222222222221"),
            ("raw_ppg", 2, "22222222-2222-5222-8222-222222222222"),
            ("raw_motion", 2, "22222222-2222-5222-8222-222222222223"),
        ]
        for (index, item) in classes.enumerated() {
            let dirty = try await store.claimManagedDirtyWindow(
                localSourceID: "strap",
                dataClass: item.name,
                windowStartMs: 0,
                windowEndMs: 3_600_000,
                updatedAtMs: Int64(index + 2)
            )
            try await store.saveManagedWindowUpload(
                ManagedWindowUploadState(
                    accountScopeHash: scope,
                    sourceID: sourceID,
                    dataClass: item.name,
                    windowStartMs: 0,
                    windowEndMs: 3_599_999,
                    chunkID: item.chunkID,
                    rowCount: item.rowCount,
                    phase: "awaiting_validation",
                    objectGeneration: nil,
                    objectMetageneration: nil,
                    objectCRC32C: nil,
                    updatedAtMs: Int64(index + 10),
                    snapshotGeneration: dirty.generation
                )
            )
            let acknowledged = try await store.acknowledgeManagedAvailableChunk(
                accountScopeHash: scope,
                sourceID: sourceID,
                dataClass: item.name,
                windowStartMs: 0,
                windowEndMs: 3_599_999,
                chunkID: item.chunkID,
                validatedAtMs: Int64(index + 20)
            )
            XCTAssertTrue(acknowledged)
            let result = try await store.pruneManagedAvailableWindows(
                accountScopeHash: scope,
                sourceID: sourceID,
                localSourceID: "strap",
                dataClass: item.name,
                endingBeforeMs: 3_600_001,
                limit: 4,
                prunedAtMs: Int64(index + 30)
            )
            XCTAssertEqual(result.prunedWindows, 1, item.name)
            XCTAssertEqual(result.deletedRows, item.rowCount, item.name)
        }

        let counts = try await store.registryWriter.read { db in
            try [
                "skinTempSample", "respSample", "sleepStateSample",
                "spo2Sample", "ppgWaveformSample", "gravitySample", "rawImuSample",
            ].map { table in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = 'strap'"
                ) ?? 0
            }
        }
        XCTAssertEqual(counts, Array(repeating: 0, count: 7))
        let dailyCount = try await store.registryWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM dailyMetric WHERE deviceId = 'strap'"
            ) ?? 0
        }
        XCTAssertEqual(dailyCount, 1)
    }

    func testCloudImportWritesNeverCreateDirtyWindows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pairedDevice (
                        id, brand, model, nickname, sourceKind, capabilities,
                        status, addedAt, lastSeenAt, peripheralId
                    ) VALUES (
                        'noop-plus-source', 'NOOP', 'cloud', NULL, 'cloudImport',
                        'hr', 'paired', 1, 1, NULL
                    )
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm, synced)
                    VALUES ('noop-plus-source', 100, 68, 0)
                    """
            )
        }
        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM managedDirtyWindow") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testSnapshotRestoreCheckpointRoundTripsAndFinishCannotRegressCursor() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = String(repeating: "b", count: 64)
        let checkpoint = ManagedSnapshotRestoreState(
            accountScopeHash: scope,
            requestID: "11111111-1111-5111-8111-111111111111",
            dataClasses: ["essential_timeseries", "raw_ppg"],
            restoreJobID: "22222222-2222-5222-8222-222222222222",
            snapshotAt: "2026-09-01T00:00:00Z",
            changeSequence: 42,
            selectedObjects: 3,
            selectedBytes: 1_024,
            dataClassIndex: 1,
            afterEventStart: "2026-08-31T23:00:00Z",
            afterChunkID: "33333333-3333-5333-8333-333333333333",
            deliveredObjects: 2,
            deliveredBytes: 768,
            updatedAtMs: 1_000
        )
        try await store.saveManagedSnapshotRestore(checkpoint)
        let restored = try await store.managedSnapshotRestore(accountScopeHash: scope)
        XCTAssertEqual(restored, checkpoint)

        try await store.finishManagedSnapshotRestore(
            accountScopeHash: scope,
            changeSequence: 42,
            updatedAtMs: 2_000
        )
        let firstSequence = try await store.managedChangeSequence(accountScopeHash: scope)
        let firstFinishedCheckpoint = try await store.managedSnapshotRestore(
            accountScopeHash: scope
        )
        XCTAssertEqual(firstSequence, 42)
        XCTAssertNil(firstFinishedCheckpoint)

        try await store.saveManagedSnapshotRestore(checkpoint)
        try await store.finishManagedSnapshotRestore(
            accountScopeHash: scope,
            changeSequence: 7,
            updatedAtMs: 3_000
        )
        let finalSequence = try await store.managedChangeSequence(accountScopeHash: scope)
        let finalCheckpoint = try await store.managedSnapshotRestore(
            accountScopeHash: scope
        )
        XCTAssertEqual(finalSequence, 42)
        XCTAssertNil(finalCheckpoint)
    }
}
