import Foundation
import GRDB
import WhoopProtocol

/// OpenWhoop persistence library — decoded streams are durable; raw frames are a
/// transient, compressed, prunable outbox. Built on GRDB/SQLite.
public enum WhoopStoreInfo {
    /// Bumped whenever the migrator gains a new migration.
    public static let schemaVersion = 56

    // NOOP opens this file through two pools (the BLE writer and the read repository). SQLite's cache
    // and mmap limits apply per connection, so the old desktop-sized values could make a large iPhone
    // database resident across several pooled readers at once. Keep desktop throughput unchanged while
    // bounding the mobile process strongly enough that CoreBluetooth restoration is not competing with
    // hundreds of megabytes of database cache under iOS memory pressure.
    #if os(iOS)
    static let maximumReaderCount = 3
    static let pageCacheKiB = 4_096
    static let memoryMapBytes = 32 * 1_024 * 1_024
    #else
    static let maximumReaderCount = 5
    static let pageCacheKiB = 16_000
    static let memoryMapBytes = 256 * 1_024 * 1_024
    #endif
}

/// Allocated SQLite pages attributed to one logical table, including that table's indexes.
public struct DatabaseObjectStorage: Equatable, Sendable {
    public let tableName: String
    public let bytes: Int64

    public init(tableName: String, bytes: Int64) {
        self.tableName = tableName
        self.bytes = bytes
    }
}

/// Physical composition of the live database. `objects` attributes table and index pages through
/// SQLite's dbstat view; `otherMainBytes` covers free pages and SQLite bookkeeping, while
/// `sidecarBytes` covers WAL/SHM working files. The values sum to the same on-disk footprint shown by
/// `databaseFileSizeBytes()` apart from a file changing between the two snapshots.
public struct DatabaseStorageBreakdown: Equatable, Sendable {
    public let objects: [DatabaseObjectStorage]
    public let otherMainBytes: Int64
    public let sidecarBytes: Int64

    public init(
        objects: [DatabaseObjectStorage],
        otherMainBytes: Int64,
        sidecarBytes: Int64
    ) {
        self.objects = objects
        self.otherMainBytes = otherMainBytes
        self.sidecarBytes = sidecarBytes
    }
}

/// Serializes `DatabasePool` creation + migration so two concurrent opens of the SAME file can never
/// run their GRDB migrators at once (#261).
///
/// `WhoopStore(path:)` is opened from more than one place on the same file — the BLEManager's backfill
/// store and the app's MetricsRepository (see the `init(path:)` note). On the first launch after an
/// update that adds a migration, a cold *background* relaunch (iOS CoreBluetooth state restoration) can
/// fire both opens at once. Each `DatabaseMigrator` reads "migration N unapplied", both apply it, and
/// the loser's bookkeeping `INSERT` collides: `UNIQUE constraint failed: grdb_migrations.identifier`
/// (SQLITE_CONSTRAINT). That open throws - on iOS the backfill sees "store not ready" and the offload
/// is deferred to the next tick. It self-heals once one migrator commits, but the failed open is a
/// real, user-visible sync stall.
///
/// `openAndMigrate` is actor-isolated and fully synchronous (no `await` inside), so the actor's serial
/// executor runs exactly one open+migrate to completion before starting the next — closing the race at
/// the source, for every opener present and future, not just the two we know about. Opens are
/// launch-time-rare and a fully-migrated DB migrates nothing, so the serial gate costs nothing in
/// practice. Each caller still gets its OWN pool; only the open+migrate step is serialized.
private actor StoreOpenGate {
    static let shared = StoreOpenGate()

    func openAndMigrate(path: String, configuration config: Configuration) throws -> DatabasePool {
        // A restore is staged while the app is running, but is NEVER swapped under the two live pools
        // (Repository + BLE). Consume it here, synchronously behind the process-wide open gate, before
        // the first pool opens this path. A second concurrent opener reaches this line only after the
        // first has applied the restore and cleared its manifest.
        switch try PendingDatabaseRestore.applyIfPresent(toDatabaseAt: path) {
        case .none:
            break
        case .applied(let safetySnapshot):
            NSLog("WhoopStore: applied pending restore; previous database saved at \(safetySnapshot.path)")
        case .discarded(let reason):
            NSLog("WhoopStore: discarded pending restore safely: \(reason)")
        }
        // Self-heal a foreign DB left in place by a bad cross-platform restore (#222): an Android
        // (Room) backup that slipped past the import guard replaces our file with one that has our
        // data tables but NO `grdb_migrations` bookkeeping. The migrator then thinks nothing is
        // applied, re-runs v1, and crashes with `table "device" already exists` on every open - the
        // store never bootstraps. Quarantine such a file BEFORE opening so we start fresh instead of
        // looping forever. (A normal GRDB backup carries grdb_migrations and is left untouched.)
        WhoopStore.quarantineIncompatibleDatabase(at: path)
        let pool = try DatabasePool(path: path, configuration: config)
        try WhoopStore.makeMigrator().migrate(pool)
        try WhoopStore.repairImportedSleepEfficiencySeries(pool)
        return pool
    }
}

/// WhoopStore is an `actor`: its public API is `async`, and all GRDB work runs on the
/// actor's serial executor rather than the caller's (the main actor).
///
/// The connection is a GRDB `DatabasePool` (WAL): reads (`.read`) run CONCURRENTLY with the
/// backfill's bulk writes (`.write`) instead of serializing behind them (#755). A `DatabaseQueue`
/// funnels every read AND write through one serial executor, so the dashboard's ~40-55 reads
/// queued behind a multi-thousand-row import and froze Today for seconds. A Pool keeps a single
/// writer (writes still serialize, exactly as before, so every read-modify-write inside one
/// `.write` stays atomic) but serves reads from WAL snapshots in parallel (committed data only,
/// never a partial write). The actor still moves the synchronous-blocking GRDB calls off the
/// caller's (main) thread; what changed is read/write CONCURRENCY at the SQLite layer, not the
/// data or the query results.
public actor WhoopStore {
    let dbWriter: any DatabaseWriter

    /// Read-only handle to the underlying GRDB writer for the synchronous `DeviceRegistryStore`.
    /// `nonisolated` because a GRDB `DatabaseWriter` (here a `DatabasePool`) is `Sendable` and
    /// manages its own concurrency, so concurrent access alongside the actor's own DB work is safe
    /// (the Pool serializes writes and runs reads in parallel under WAL).
    public nonisolated var registryWriter: any DatabaseWriter { dbWriter }

    private init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try WhoopStore.makeMigrator().migrate(dbWriter)
        try WhoopStore.repairImportedSleepEfficiencySeries(dbWriter)
    }

    /// Store an already-open, already-migrated writer WITHOUT re-running the migrator: the
    /// `StoreOpenGate` (below) opened the pool and migrated it under the process-wide open lock, so
    /// re-migrating here would be a redundant (and, if it raced a sibling opener, failing) second run.
    /// (#261)
    private init(preMigrated dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Open (creating if needed) a database at `path` and run migrations.
    /// Uses a `DatabasePool`, which enables WAL automatically, plus a 5-second busy timeout so two
    /// handles to the same file (BLEManager + MetricsRepository) don't deadlock on write contention.
    ///
    /// Open + migrate runs through `StoreOpenGate` so two concurrent openers of the SAME file never
    /// run their GRDB migrators at once (#261) — see that actor's note for the failure it prevents.
    public init(path: String) async throws {
        var config = Configuration()
        config.maximumReaderCount = WhoopStoreInfo.maximumReaderCount
        config.prepareDatabase { db in
            // `DatabasePool` puts the database in WAL mode itself (reads run as concurrent snapshots
            // alongside the single writer, #755), so there is no explicit `PRAGMA journal_mode = WAL`.
            // Bulk-write/read tuning. NORMAL is the durable, recommended pairing with WAL (only an
            // OS crash/power loss can lose the last transaction — acceptable here). The limits are
            // platform-sized above because every pool connection owns its own cache/mmap window.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -\(WhoopStoreInfo.pageCacheKiB)")
            try db.execute(sql: "PRAGMA mmap_size = \(WhoopStoreInfo.memoryMapBytes)")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        config.busyMode = .timeout(5)
        let pool = try await StoreOpenGate.shared.openAndMigrate(path: path, configuration: config)
        self.init(preMigrated: pool)
    }

    /// Move aside a database file that has our data tables but no GRDB migration bookkeeping — the
    /// signature of a foreign (Android/Room) DB dropped over ours by a bad restore (#222). Opening it
    /// would make the migrator re-run v1 and throw `table "device" already exists` forever. A logical
    /// SQLite online backup is written to a `.incompatible-<ts>` sidecar before the live triplet is
    /// removed. This is intentionally not a plain move of only the main file: committed rows may still
    /// exist solely in `-wal`, and separating that WAL from its main database destroys the only readable
    /// copy. A valid GRDB DB (has `grdb_migrations`) and a fresh/empty file are both left untouched.
    /// If the backup cannot be completed and quick-checked, fail closed and leave the live triplet in
    /// place; a failed open is recoverable, silent data loss is not.
    static func quarantineIncompatibleDatabase(at path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let names: Set<String>
        do {
            // Read-only probe of sqlite_master; a raw queue does NOT run migrations.
            let probe = try DatabaseQueue(path: path)
            names = try probe.read { db in
                try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            }
        } catch {
            return // unreadable/locked → let the real open + migrator deal with it
        }
        let isForeign = !names.contains("grdb_migrations")
            && (names.contains("device") || names.contains("hrSample"))
        guard isForeign else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let quarantine = "\(path).incompatible-\(stamp)-\(UUID().uuidString.prefix(8))"

        // `DatabaseQueue.backup(to:)` uses SQLite's online-backup API, so the destination includes every
        // committed page visible through the source connection, including pages still resident in WAL.
        // Flatten the destination to DELETE mode so the quarantine is one standalone, inspectable file.
        do {
            let source = try DatabaseQueue(path: path)
            let destination = try DatabaseQueue(path: quarantine)
            try source.backup(to: destination)
            try destination.writeWithoutTransaction { db in
                guard let checkpoint = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") else {
                    throw NSError(domain: "WhoopStore.Quarantine", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "SQLite returned no checkpoint result"])
                }
                let busy: Int = checkpoint[0]
                let log: Int = checkpoint[1]
                let checkpointed: Int = checkpoint[2]
                guard busy == 0, log == checkpointed else {
                    throw NSError(domain: "WhoopStore.Quarantine", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                                "SQLite could not flatten quarantine WAL"])
                }
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE") ?? ""
                guard mode.lowercased() == "delete" else {
                    throw NSError(domain: "WhoopStore.Quarantine", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey:
                                                "SQLite could not make quarantine standalone"])
                }
                let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? ""
                guard quickCheck.lowercased() == "ok" else {
                    throw NSError(domain: "WhoopStore.Quarantine", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey:
                                                "SQLite quarantine quick_check failed: \(quickCheck)"])
                }
            }
        } catch {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? fm.removeItem(atPath: quarantine + suffix)
            }
            NSLog("WhoopStore: incompatible database kept in place because safe quarantine failed: \(error.localizedDescription)")
            return
        }

        // The verified standalone backup is now the recovery copy. Remove the complete live journal set
        // before DatabasePool creates the fresh database; no old WAL may attach to that new main file.
        for suffix in ["-wal", "-shm", "-journal", ""] {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    /// An in-memory store (migrations applied). For tests.
    ///
    /// Backed by a `DatabaseQueue`, not a `DatabasePool`: GRDB has no in-memory `DatabasePool`
    /// (a Pool needs a real file so its reader connections can open WAL snapshots of it). A
    /// `DatabaseQueue` is also a `DatabaseWriter`, so this is API-identical; only the concurrency
    /// differs, which an in-memory test store doesn't exercise. The production `init(path:)` path
    /// is the one that gets the Pool (#755). Tests that need real read/write concurrency open a
    /// file-backed Pool directly.
    public static func inMemory() async throws -> WhoopStore {
        try WhoopStore(dbWriter: try DatabaseQueue())
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync read/write overloads @_disfavoredOverload so that in an async
    // context Swift would otherwise pick the async overloads. These thin wrappers are
    // regular (non-async) functions, so overload resolution always selects the synchronous
    // GRDB API — which then blocks on the actor's serial executor (off main thread).

    @inline(__always)
    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    @inline(__always)
    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    // MARK: - Maintenance

    /// Fully checkpoint the WAL into the main database file and truncate the -wal file.
    /// Used before a file-level backup so the single `whoop.sqlite` carries all committed data
    /// (the -wal/-shm siblings can then be ignored). Runs outside a transaction — `wal_checkpoint`
    /// must. Best-effort: throws on a hard SQLite error so callers can fall back to a plain copy.
    public func checkpointWAL() async throws {
        try checkpointWALImpl()
    }

    /// Non-async so GRDB's synchronous `writeWithoutTransaction` overload is chosen (mirrors the
    /// syncRead/syncWrite pattern). Runs on the actor's executor, off the main thread.
    private func checkpointWALImpl() throws {
        try dbWriter.writeWithoutTransaction { db in
            // `wal_checkpoint` reports SQLITE_OK even when a reader/writer prevented a complete
            // checkpoint; the first result column carries that busy verdict. Discarding the row made
            // callers believe a single-file export was complete while committed pages could still live
            // only in `-wal`. Inspect all three fields and fail closed unless every WAL page landed.
            guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") else {
                throw WALCheckpointError.noResult
            }
            let busy: Int = row[0]
            let log: Int = row[1]
            let checkpointed: Int = row[2]
            guard busy == 0, log == checkpointed else {
                throw WALCheckpointError.incomplete(busy: busy, log: log, checkpointed: checkpointed)
            }
        }
    }

    private enum WALCheckpointError: LocalizedError {
        case noResult
        case incomplete(busy: Int, log: Int, checkpointed: Int)

        var errorDescription: String? {
            switch self {
            case .noResult:
                return "SQLite returned no WAL checkpoint result."
            case .incomplete(let busy, let log, let checkpointed):
                return "SQLite WAL checkpoint was incomplete (busy=\(busy), log=\(log), checkpointed=\(checkpointed))."
            }
        }
    }

    /// Permanently delete every recorded sample/derived row for one device across all `deviceId`-keyed
    /// tables (16+ `DELETE FROM <table> WHERE deviceId = ?` in one GRDB transaction). Wraps the
    /// synchronous `DeviceRegistryStore.deleteAllData` so the heavy multi-table write runs on the actor's
    /// own serial executor, OFF the main thread. The "Delete all of this device's data" and "Remove
    /// Apple Health data" actions previously ran this same store write synchronously on the main actor and
    /// froze the UI on a large dataset. The `pairedDevice` registry row is left intact (archiving/removing
    /// it is a separate op). Async entry point; the actual write is on `deleteAllDataImpl`.
    public func deleteAllData(deviceId: String) async throws {
        try deleteAllDataImpl(deviceId: deviceId)
    }

    /// Non-async so the synchronous `DeviceRegistryStore.deleteAllData` (a blocking GRDB write) is called
    /// directly (mirrors the syncRead/syncWrite pattern). Runs on the actor's executor, off the main
    /// thread. Builds the synchronous registry wrapper over the same GRDB writer the store owns.
    private func deleteAllDataImpl(deviceId: String) throws {
        try DeviceRegistryStore(dbQueue: dbWriter).deleteAllData(deviceId: deviceId)
    }

    /// Total on-disk size of the database — the main file plus its `-wal`/`-shm` siblings — in bytes.
    /// Drives the iOS Storage diagnostics screen (#590). `nil` for an in-memory store (no path). Runs
    /// on the actor's executor, off the main thread. Note (#755): under the `DatabasePool` the `-wal`
    /// component can stay non-zero while a reader connection holds an open snapshot, so a `checkpointWAL`
    /// may not fully truncate it; this total stays correct (it always includes the sidecars) but can
    /// read a little higher than the old single-connection `DatabaseQueue` did right after a checkpoint.
    public func databaseFileSizeBytes() async -> Int64? {
        let base = dbWriter.path
        guard base != ":memory:", !base.isEmpty else { return nil }
        let fm = FileManager.default
        var total: Int64 = 0
        var found = false
        for suffix in ["", "-wal", "-shm"] {
            let path = base + suffix
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                total += size.int64Value
                found = true
            }
        }
        return found ? total : nil
    }

    /// Attribute the database footprint to its logical tables. Unlike row counts, dbstat measures the
    /// actual pages occupied by both table records and indexes, so a large RR or waveform table is
    /// visible immediately instead of being hidden inside one aggregate "Health database" number.
    ///
    /// Returns nil when the store is in-memory or the platform SQLite lacks the read-only dbstat view.
    /// The Storage screen treats that as "detail unavailable" and still shows the total file size.
    public func databaseStorageBreakdown() async -> DatabaseStorageBreakdown? {
        let base = dbWriter.path
        guard base != ":memory:", !base.isEmpty else { return nil }

        let main: (objects: [DatabaseObjectStorage], allocatedBytes: Int64)
        do {
            main = try syncRead { db in
                let pageSize = Int64(try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
                let pageCount = Int64(try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT COALESCE(m.tbl_name, d.name) AS tableName,
                           SUM(d.pgsize) AS bytes
                    FROM dbstat AS d
                    LEFT JOIN sqlite_master AS m ON m.name = d.name
                    WHERE d.name <> 'sqlite_schema'
                    GROUP BY COALESCE(m.tbl_name, d.name)
                    ORDER BY bytes DESC
                    """)
                let objects = rows.compactMap { row -> DatabaseObjectStorage? in
                    let tableName: String = row["tableName"]
                    let bytes: Int64 = row["bytes"]
                    guard !tableName.isEmpty, bytes > 0 else { return nil }
                    return DatabaseObjectStorage(tableName: tableName, bytes: bytes)
                }
                return (objects, pageSize * pageCount)
            }
        } catch {
            return nil
        }

        let attributed = main.objects.reduce(Int64(0)) { $0 + $1.bytes }
        let otherMain = max(0, main.allocatedBytes - attributed)
        let fm = FileManager.default
        var sidecars: Int64 = 0
        for suffix in ["-wal", "-shm"] {
            if let size = (try? fm.attributesOfItem(atPath: base + suffix))?[.size] as? NSNumber {
                sidecars += size.int64Value
            }
        }
        return DatabaseStorageBreakdown(
            objects: main.objects,
            otherMainBytes: otherMain,
            sidecarBytes: sidecars
        )
    }

    /// Rebuild the database file so pages released by retention or dropped optional indexes are returned
    /// to iOS. This is intentionally explicit: VACUUM takes an exclusive write phase and does not belong
    /// on the BLE ingestion hot path.
    public func compactDatabase() async throws {
        try syncWrite { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - Introspection (used by tests)

    public func tableNames() async throws -> Set<String> {
        try syncRead { db in
            try Set(String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    public func primaryKeyColumns(_ table: String) async throws -> [String] {
        try syncRead { db in
            try db.primaryKey(table).columns
        }
    }

    public func columnNamesForTest(table: String) async throws -> [String] {
        try syncRead { db in
            try db.columns(in: table).map(\.name)
        }
    }

    public func indexNamesForTest(table: String) async throws -> Set<String> {
        try syncRead { db in
            try Set(db.indexes(on: table).map(\.name))
        }
    }
}
