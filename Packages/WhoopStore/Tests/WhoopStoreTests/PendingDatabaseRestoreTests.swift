import XCTest
import GRDB
@testable import WhoopStore

final class PendingDatabaseRestoreTests: XCTestCase {
    private var paths: [String] = []

    override func tearDownWithError() throws {
        let fm = FileManager.default
        var directories: Set<URL> = []
        for path in paths {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            directories.insert(directory)
            let base = URL(fileURLWithPath: path).lastPathComponent
            if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
                for name in names where name == base || name.hasPrefix(base + "-")
                    || name.hasPrefix(base + ".") || name.hasPrefix(".noop-pending-restore-")
                    || name.hasPrefix("whoop-replaced-") {
                    try? fm.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }
        for directory in directories { try? fm.removeItem(at: directory) }
        paths = []
    }

    /// Exercises the production hook, not `applyIfPresent` directly: the first `WhoopStore(path:)`
    /// must consume the pending manifest inside `StoreOpenGate` before its DatabasePool is created.
    func testFirstStoreOpenAppliesPendingRestoreBeforePoolCreation() async throws {
        let original = tempPath("original")
        let replacement = tempPath("replacement")
        let live = tempPath("live")
        paths += [original, replacement, live]

        try await seedFullStore(at: original, deviceID: "pre-restore")
        try seedV1Store(at: replacement, deviceID: "from-backup")
        try FileManager.default.copyItem(atPath: original, toPath: live)

        let snapshot = URL(fileURLWithPath: live).deletingLastPathComponent()
            .appendingPathComponent("whoop-replaced-gate-test.sqlite")
        try PendingDatabaseRestore.stage(
            databaseAt: replacement,
            settingsJSON: nil,
            forDatabaseAt: live,
            safetySnapshot: snapshot)

        XCTAssertEqual(try appliedMigrationIDs(at: replacement), ["v1"],
                       "staging must migrate only its private normalized candidate")

        let opened = try await WhoopStore(path: live)
        let ids = try await opened.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM device ORDER BY id")
        }
        XCTAssertTrue(ids.contains("from-backup"))
        XCTAssertFalse(ids.contains("pre-restore"))
        let migrationCount = try await opened.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }
        XCTAssertEqual(migrationCount, WhoopStoreInfo.schemaVersion,
                       "the old v1 backup must be fully migrated before it reaches the live path")

        let oldIDs = try readDeviceIDs(at: snapshot.path)
        XCTAssertTrue(oldIDs.contains("pre-restore"), "cold-launch safety snapshot keeps the prior store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: live + ".pending-restore.json"),
                       "the first open must consume the pending authority marker")
    }

    func testStageRejectsClaimedV1ThatCannotRunRealMigrator() async throws {
        let malformed = tempPath("malformed-v1")
        let live = tempPath("live-malformed")
        paths += [malformed, live]
        try makeLedgerDatabase(at: malformed, identifiers: ["v1"], includeMinimalDevice: true)
        try await seedFullStore(at: live, deviceID: "keep-me")
        let snapshot = siblingSnapshot(of: live, name: "malformed")

        XCTAssertThrowsError(try PendingDatabaseRestore.stage(
            databaseAt: malformed,
            settingsJSON: nil,
            forDatabaseAt: live,
            safetySnapshot: snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: live + ".pending-restore.json"))

        let opened = try await WhoopStore(path: live)
        let ids = try await deviceIDs(in: opened)
        XCTAssertEqual(ids, ["keep-me"])
    }

    func testStageRejectsAllKnownLedgerWithMissingSchema() async throws {
        let malformed = tempPath("all-known-missing-schema")
        let live = tempPath("live-all-known")
        paths += [malformed, live]
        try makeLedgerDatabase(
            at: malformed,
            identifiers: WhoopStore.makeMigrator().migrations,
            includeMinimalDevice: true)
        try await seedFullStore(at: live, deviceID: "keep-me")

        XCTAssertThrowsError(try PendingDatabaseRestore.stage(
            databaseAt: malformed,
            settingsJSON: nil,
            forDatabaseAt: live,
            safetySnapshot: siblingSnapshot(of: live, name: "all-known")))
        let opened = try await WhoopStore(path: live)
        let ids = try await deviceIDs(in: opened)
        XCTAssertEqual(ids, ["keep-me"])
    }

    func testStageRejectsUnrelatedDatabaseWithEmptyMigrationLedger() async throws {
        let unrelated = tempPath("empty-ledger")
        let live = tempPath("live-empty-ledger")
        paths += [unrelated, live]
        try makeLedgerDatabase(at: unrelated, identifiers: [], includeMinimalDevice: false)
        try await seedFullStore(at: live, deviceID: "keep-me")

        XCTAssertThrowsError(try PendingDatabaseRestore.stage(
            databaseAt: unrelated,
            settingsJSON: nil,
            forDatabaseAt: live,
            safetySnapshot: siblingSnapshot(of: live, name: "empty-ledger")))
        let opened = try await WhoopStore(path: live)
        let ids = try await deviceIDs(in: opened)
        XCTAssertEqual(ids, ["keep-me"])
    }

    func testColdLaunchCleanupRemovesOnlyOrphanedPrivateStagingFiles() throws {
        let live = tempPath("orphan-cleanup")
        paths.append(live)
        let directory = URL(fileURLWithPath: live).deletingLastPathComponent()
        let orphan = directory.appendingPathComponent(".noop-pending-restore-orphan.sqlite")
        let orphanWAL = URL(fileURLWithPath: orphan.path + "-wal")
        let unrelated = directory.appendingPathComponent("keep-this.txt")
        try Data("orphan".utf8).write(to: orphan)
        try Data("wal".utf8).write(to: orphanWAL)
        try Data("user".utf8).write(to: unrelated)

        guard case .none = try PendingDatabaseRestore.applyIfPresent(toDatabaseAt: live) else {
            return XCTFail("no manifest should be a no-op")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanWAL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testApplyFailureIsMemoizedAndEveryLaterOpenerFailsClosed() async throws {
        let replacement = tempPath("failure-replacement")
        let live = tempPath("failure-live")
        paths += [replacement, live]
        try seedV1Store(at: replacement, deviceID: "replacement")
        try seedFullDatabaseDirect(at: live, deviceID: "original")
        let snapshot = siblingSnapshot(of: live, name: "blocked")
        try PendingDatabaseRestore.stage(
            databaseAt: replacement,
            settingsJSON: nil,
            forDatabaseAt: live,
            safetySnapshot: snapshot)

        // Hold a real write transaction from a second connection. The safety read can complete, but
        // candidate -> live cannot acquire its destination transaction within the restore timeout.
        let blocker = try DatabaseQueue(path: live)
        let lockAcquired = expectation(description: "live database write lock acquired")
        let releaseLock = DispatchSemaphore(value: 0)
        let lockTask = Task.detached {
            try blocker.write { db in
                try db.execute(sql: "UPDATE device SET name = 'locked' WHERE id = 'original'")
                lockAcquired.fulfill()
                releaseLock.wait()
            }
        }
        await fulfillment(of: [lockAcquired], timeout: 5)
        var firstFailure: Error?
        do {
            _ = try PendingDatabaseRestore.applyIfPresent(toDatabaseAt: live)
        } catch {
            firstFailure = error
        }
        releaseLock.signal()
        try await lockTask.value
        XCTAssertNotNil(firstFailure, "a locked live destination must fail closed")

        XCTAssertThrowsError(try PendingDatabaseRestore.applyIfPresent(toDatabaseAt: live),
                             "the process must retain one fail-closed verdict instead of retrying large I/O")
        do {
            _ = try await WhoopStore(path: live)
            XCTFail("StoreOpenGate must rethrow the memoized restore failure")
        } catch {
            // expected
        }
        XCTAssertEqual(try readDeviceIDs(at: live), ["original"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: live + ".pending-restore.json"),
                      "a failed apply remains pending for a clean retry next process")
    }

    func testMissingStagedSettingsDiscardsBeforeLiveDatabaseIsTouched() async throws {
        let replacement = tempPath("settings-replacement")
        let live = tempPath("settings-live")
        paths += [replacement, live]
        try seedV1Store(at: replacement, deviceID: "replacement")
        try seedFullDatabaseDirect(at: live, deviceID: "original")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-settings-\(UUID().uuidString)"))
        let settings = try XCTUnwrap(BackupSettings.encode(["profile.age": 44]))
        try PendingDatabaseRestore.stage(
            databaseAt: replacement,
            settingsJSON: settings,
            forDatabaseAt: live,
            safetySnapshot: siblingSnapshot(of: live, name: "settings"))

        let directory = URL(fileURLWithPath: live).deletingLastPathComponent()
        let stagedSettings = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".noop-pending-restore-")
                    && $0.lastPathComponent.hasSuffix("-settings.json") })
        try FileManager.default.removeItem(at: stagedSettings)

        let result = try PendingDatabaseRestore.applyIfPresent(
            toDatabaseAt: live, settingsDefaults: defaults)
        guard case .discarded = result else {
            return XCTFail("missing promised settings must discard the atomic restore request")
        }
        XCTAssertEqual(try readDeviceIDs(at: live), ["original"])
        XCTAssertNil(defaults.object(forKey: "profile.age"))
    }

    func testDatabaseOnlyRestoreClearsDerivedPlannerStateAfterVerifiedReplacement() throws {
        let replacement = tempPath("database-only-replacement")
        let live = tempPath("database-only-live")
        paths += [replacement, live]
        try seedV1Store(at: replacement, deviceID: "replacement")
        try seedFullDatabaseDirect(at: live, deviceID: "original")

        let suiteName = "pending-database-only-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(45, forKey: BackupSettings.legacyRecoveryMinutesKey)

        try PendingDatabaseRestore.stage(
            databaseAt: replacement,
            settingsJSON: nil,
            forDatabaseAt: live,
            safetySnapshot: siblingSnapshot(of: live, name: "database-only"))

        let result = try PendingDatabaseRestore.applyIfPresent(
            toDatabaseAt: live,
            settingsDefaults: defaults)
        guard case .applied = result else {
            return XCTFail("a valid DB-only restore must be applied")
        }
        XCTAssertEqual(try readDeviceIDs(at: live), ["replacement"])
        XCTAssertNil(
            defaults.object(forKey: BackupSettings.legacyRecoveryMinutesKey),
            "a DB-only replacement must not retain planner output derived from the old database")
    }

    /// `PRAGMA wal_checkpoint` returns a row even when it could not finish. Hold an old reader snapshot,
    /// append a newer WAL frame, and prove `checkpointWAL` fails closed until that reader releases it.
    func testCheckpointWALRejectsBusyIncompleteResult() async throws {
        let path = tempPath("checkpoint")
        paths.append(path)
        let store = try await WhoopStore(path: path)
        try await store.upsertDevice(id: "before-reader", mac: nil, name: "Before")
        try await store.checkpointWAL()

        var config = Configuration()
        config.busyMode = .timeout(1)
        let reader = try DatabaseQueue(path: path, configuration: config)
        let insideRead = expectation(description: "reader acquired WAL snapshot")
        let releaseRead = DispatchSemaphore(value: 0)
        let readerTask = Task.detached {
            try reader.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device")
                insideRead.fulfill()
                releaseRead.wait()
            }
        }
        await fulfillment(of: [insideRead], timeout: 5)

        try await store.upsertDevice(id: "after-reader", mac: nil, name: "After")
        do {
            try await store.checkpointWAL()
            XCTFail("TRUNCATE checkpoint must report the reader-blocked WAL instead of false success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("incomplete"), "unexpected error: \(error)")
        }

        releaseRead.signal()
        try await readerTask.value
        try await store.checkpointWAL()
    }

    private func tempPath(_ label: String) -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-restore-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(label).sqlite").path
    }

    private func seedFullStore(at path: String, deviceID: String) async throws {
        let store = try await WhoopStore(path: path)
        try await store.upsertDevice(id: deviceID, mac: nil, name: deviceID)
        try await store.checkpointWAL()
    }

    private func seedV1Store(at path: String, deviceID: String) throws {
        let queue = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO device (id, name) VALUES (?, ?)",
                arguments: [deviceID, deviceID])
        }
    }

    private func seedFullDatabaseDirect(at path: String, deviceID: String) throws {
        let queue = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO device (id, name) VALUES (?, ?)",
                arguments: [deviceID, deviceID])
        }
    }

    private func makeLedgerDatabase(
        at path: String,
        identifiers: [String],
        includeMinimalDevice: Bool
    ) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for identifier in identifiers {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier])
            }
            if includeMinimalDevice {
                try db.execute(sql: "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
            } else {
                try db.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
            }
        }
    }

    private func siblingSnapshot(of path: String, name: String) -> URL {
        URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("whoop-replaced-\(name).sqlite")
    }

    private func deviceIDs(in store: WhoopStore) async throws -> [String] {
        try await store.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM device ORDER BY id")
        }
    }

    private func appliedMigrationIDs(at path: String) throws -> [String] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    private func readDeviceIDs(at path: String) throws -> [String] {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM device ORDER BY id")
        }
    }
}
