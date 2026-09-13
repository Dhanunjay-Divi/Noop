import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "rrInterval", "event", "battery", "rawBatch"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    /// v24 widens the R-R key with a `seq` tiebreaker so two EQUAL successive intervals in the same
    /// second both survive (the old value-only key dropped the 2nd, biasing RMSSD/HRV high). #163.
    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV24AddsSeqColumnToRrInterval() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "rrInterval")
        XCTAssertTrue(cols.contains("seq"), "rrInterval missing v24 seq column")
    }

    func testV24KeepsEqualSameSecondBeats() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Two EQUAL R-R intervals in the same second: the old value-only key dropped the 2nd; v24 keeps both.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 812), RRInterval(ts: 100, rrMs: 812)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 2)
        let read = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(read.count, 2)
        XCTAssertTrue(read.allSatisfy { $0.ts == 100 && $0.rrMs == 812 })
    }

    func testV24DistinctBeatsAllKept() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // Distinct (ts, rrMs) beats — incl. two values in the same second — each keep seq 0 and their slot.
        let n = try await store.insert(
            Streams(rr: [RRInterval(ts: 100, rrMs: 602), RRInterval(ts: 100, rrMs: 613),
                         RRInterval(ts: 101, rrMs: 602)]),
            deviceId: "dev1")
        XCTAssertEqual(n.rr, 3)
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 60)
        let tableNames = try await store.tableNames()
        XCTAssertTrue(tableNames.contains("healthKitSyncState"))
        XCTAssertTrue(tableNames.contains("nutritionEntry"))
        XCTAssertTrue(tableNames.contains("strengthExercise"))
        XCTAssertTrue(tableNames.contains("strengthRoutine"))
        XCTAssertTrue(tableNames.contains("strengthRoutineExercise"))
        XCTAssertTrue(tableNames.contains("strengthSession"))
        XCTAssertTrue(tableNames.contains("strengthSet"))
        XCTAssertTrue(tableNames.contains("coachMessage"))
        XCTAssertTrue(tableNames.contains("coachMemory"))
        XCTAssertTrue(tableNames.contains("nutritionCatalogItem"))
    }

    func testV47KeepsRemoteIndexesAbsentUntilSelfHostedSyncNeedsThem() async throws {
        let store = try await WhoopStore.inMemory()
        let expected: [String: String] = [
            "hrSample": "idx_remoteSync_hr_pending",
            "rrInterval": "idx_remoteSync_rr_pending",
            "event": "idx_remoteSync_event_pending",
            "battery": "idx_remoteSync_battery_pending",
            "spo2Sample": "idx_remoteSync_spo2_pending",
            "skinTempSample": "idx_remoteSync_skin_pending",
            "respSample": "idx_remoteSync_resp_pending",
            "stepSample": "idx_remoteSync_steps_pending",
            "gravitySample": "idx_remoteSync_gravity_pending",
            "sleepStateSample": "idx_remoteSync_sleep_state_pending",
            "ppgHrSample": "idx_remoteSync_ppg_hr_pending",
            "ppgWaveformSample": "idx_remoteSync_ppg_waveform_pending",
        ]
        for (table, index) in expected {
            let names = try await store.indexNamesForTest(table: table)
            XCTAssertFalse(names.contains(index), "\(table) retained an unused pending outbox index")
        }
        try await store.configureRemoteSyncPendingIndexes(enabled: true)
        for (table, index) in expected {
            let names = try await store.indexNamesForTest(table: table)
            XCTAssertTrue(names.contains(index), "\(table) did not install pending outbox index")
        }
        try await store.configureRemoteSyncPendingIndexes(enabled: false)
        for (table, index) in expected {
            let names = try await store.indexNamesForTest(table: table)
            XCTAssertFalse(names.contains(index), "\(table) did not remove pending outbox index")
        }
    }

    func testV48AddsSleepStateSyncOutboxColumn() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "sleepStateSample")
        XCTAssertTrue(columns.contains("synced"))
    }

    func testV49AddsPpgSyncOutboxColumns() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["ppgHrSample", "ppgWaveformSample"] {
            let columns = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(columns.contains("synced"), "\(table) missing synced column")
        }
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    func testV44AddsNullableRREvidenceColumnsAndLegacyRowsRemainUnknown() async throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v43-nutrition-catalog")
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sleepSession (deviceId, startTs, endTs)
                    VALUES ('legacy', 1000, 5000)
                    """
            )
        }

        try migrator.migrate(queue)

        try await queue.read { db in
            let columns = try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('sleepSession') ORDER BY cid"
            )
            XCTAssertTrue(columns.contains("rrEligibleWindowCount"))
            XCTAssertTrue(columns.contains("rrValidWindowCount"))

            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT rrEligibleWindowCount, rrValidWindowCount
                        FROM sleepSession WHERE deviceId = 'legacy' AND startTs = 1000
                        """
                )
            )
            let eligible: Int? = row["rrEligibleWindowCount"]
            let valid: Int? = row["rrValidWindowCount"]
            XCTAssertNil(eligible)
            XCTAssertNil(valid)
        }
    }

    func testV45AddsNullableDailyHrvMethodAndLegacyRowsRemainUnknown() async throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v44-sleep-rr-window-evidence")
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dailyMetric (deviceId, day, avgHrv)
                    VALUES ('legacy', '2026-08-25', 57)
                    """
            )
        }

        try migrator.migrate(queue)

        try await queue.read { db in
            let columns = try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('dailyMetric') ORDER BY cid"
            )
            XCTAssertTrue(columns.contains("hrvMethod"))
            let method: String? = try String.fetchOne(
                db,
                sql: """
                    SELECT hrvMethod FROM dailyMetric
                    WHERE deviceId = 'legacy' AND day = '2026-08-25'
                    """
            )
            XCTAssertNil(method)
        }
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    /// v26 heals `efficiency` values stored on the 0-100 percent scale (written by the pre-fix Oura API
    /// importer AND the pre-fix WHOOP CSV importer, under any deviceId) back to NOOP's 0-1 fraction
    /// convention. UPDATE-only: seed rows at the v25 schema (i.e. BEFORE v26 has run), then apply the
    /// rest of the migrator and confirm the heal.
    func testV26HealsEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v25-oura-raw")
        try await dbQueue.write { db in
            // oura-api, bad (percent) → must be healed to a fraction.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 100, 200, 90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-01', 90)
                """)
            // oura-api, already a fraction → must be left unchanged (idempotent predicate: efficiency > 1.5).
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('oura-api', 300, 400, 0.9)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency) VALUES ('oura-api', '2026-01-02', 0.9)
                """)
            // A WHOOP-CSV-imported percent row (arbitrary strap deviceId) must ALSO be healed — the
            // pre-fix WhoopImporter wrote "Sleep efficiency %" straight through, same bug class.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 500, 600, 90)
                """)
            // A native fraction row under a strap deviceId must be left unchanged.
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency) VALUES ('my-whoop', 700, 800, 0.66)
                """)
        }

        // Apply the FULL migrator: GRDB resumes from the already-applied v25, so only v26 runs here.
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 500"), 0.9,
                           "a CSV-imported percent row must be healed regardless of deviceId")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 700"), 0.66,
                           "a native fraction row must never be touched")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"), 0.9)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"), 0.9)
        }
    }

    func testCompatibilityRepairHealsDatabasesThatAlreadyAppliedV26() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value) VALUES
                    ('wearable-import', '2026-01-01', 'sleep_efficiency', 91.5),
                    ('wearable-import', '2026-01-02', 'sleep_efficiency', 0.88),
                    ('wearable-import', '2026-01-01', 'sleep_performance', 91.5)
                """)
        }

        try WhoopStore.repairImportedSleepEfficiencySeries(dbQueue)
        try WhoopStore.repairImportedSleepEfficiencySeries(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try Double.fetchOne(
                    db,
                    sql: "SELECT value FROM metricSeries WHERE day = '2026-01-01' AND key = 'sleep_efficiency'"
                ),
                0.915
            )
            XCTAssertEqual(
                try Double.fetchOne(
                    db,
                    sql: "SELECT value FROM metricSeries WHERE day = '2026-01-02' AND key = 'sleep_efficiency'"
                ),
                0.88
            )
            XCTAssertEqual(
                try Double.fetchOne(
                    db,
                    sql: "SELECT value FROM metricSeries WHERE day = '2026-01-01' AND key = 'sleep_performance'"
                ),
                91.5
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM cursors
                        WHERE name = 'data-repair.metric-series-sleep-efficiency-fraction.v1'
                        """
                ),
                1
            )
        }
    }
}
