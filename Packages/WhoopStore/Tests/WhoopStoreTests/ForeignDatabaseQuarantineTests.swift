import XCTest
import GRDB
@testable import WhoopStore

/// #222: a foreign (Android/Room) database dropped over ours by a bad cross-platform restore has our
/// table names but NO `grdb_migrations` bookkeeping, so the migrator re-runs v1 and crashes forever
/// with `table "device" already exists`. WhoopStore.init must quarantine such a file and open fresh,
/// while leaving a valid GRDB backup untouched.
final class ForeignDatabaseQuarantineTests: XCTestCase {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-quarantine-\(UUID().uuidString).sqlite").path
    }

    private func tableNames(at path: String) throws -> Set<String> {
        let q = try DatabaseQueue(path: path)
        return try q.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    private func cleanup(_ path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        for s in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where s.hasPrefix(base) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(s))
        }
    }

    func testForeignDatabaseIsQuarantinedAndStoreOpensFresh() async throws {
        let path = tempPath()
        defer { cleanup(path) }

        // Simulate the foreign DB: our table names + a row, but NO grdb_migrations bookkeeping.
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE device (id TEXT PRIMARY KEY, mac TEXT, name TEXT, firstSeen INTEGER, lastSeen INTEGER)")
            try db.execute(sql: "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)")
            try db.execute(sql: "INSERT INTO device (id, name) VALUES ('foreign', 'WHOOP')")
        }
        // Release the probe handle before opening the store.
        _ = raw
        XCTAssertFalse(try tableNames(at: path).contains("grdb_migrations"),
                       "precondition: a foreign DB has no grdb_migrations")

        // Opening must NOT throw `table "device" already exists` — it quarantines + starts fresh.
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("grdb_migrations"), "fresh store ran its migrations")
        XCTAssertTrue(tables.contains("device"))

        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertTrue(siblings.contains { $0.hasPrefix(base + ".incompatible-") },
                      "the foreign DB was quarantined to a .incompatible sidecar")
    }

    func testValidGrdbBackupIsNotQuarantined() async throws {
        let path = tempPath()
        defer { cleanup(path) }

        // A real GRDB store (migrations applied), then reopened.
        do {
            let store = try await WhoopStore(path: path)
            try await store.upsertDevice(id: "mine", mac: nil, name: "WHOOP")
        }
        let store = try await WhoopStore(path: path)
        let reopenedTables = try await store.tableNames()
        XCTAssertTrue(reopenedTables.contains("grdb_migrations"))

        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(base + ".incompatible-") },
                       "a valid GRDB DB must never be quarantined")
    }

    /// A committed SQLite row may live only in WAL while another connection remains open. Quarantine
    /// must preserve that logical state, not move the main file and discard its journal sidecars.
    func testForeignDatabaseQuarantinePreservesCommittedWalRows() async throws {
        let path = tempPath()
        defer { cleanup(path) }

        let writer = try DatabaseQueue(path: path)
        try await writer.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
            try db.execute(sql: "CREATE TABLE device (id TEXT PRIMARY KEY, mac TEXT, name TEXT, firstSeen INTEGER, lastSeen INTEGER)")
            try db.execute(sql: "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)")
        }
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO device (id, name) VALUES ('wal-only', 'WHOOP')")
        }
        let walPath = path + "-wal"
        XCTAssertGreaterThan(
            ((try? FileManager.default.attributesOfItem(atPath: walPath))?[.size] as? NSNumber)?.intValue ?? 0,
            0,
            "precondition: the foreign database has a live WAL"
        )

        _ = try await WhoopStore(path: path)

        let directory = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let quarantineName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory).first {
                $0.hasPrefix(base + ".incompatible-")
                    && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.hasSuffix("-journal")
            }
        )
        let quarantinePath = (directory as NSString).appendingPathComponent(quarantineName)
        let recovered = try DatabaseQueue(path: quarantinePath)
        let id = try await recovered.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM device WHERE id = 'wal-only'")
        }
        XCTAssertEqual(id, "wal-only", "the standalone quarantine must include committed WAL pages")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinePath + "-wal"),
                       "the recovery copy must not depend on a detached WAL")
    }
}
