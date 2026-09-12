import Foundation
import GRDB

/// A validated database restore that is staged while the app is running and applied before the first
/// `WhoopStore` pool opens on the next launch.
///
/// Replacing an SQLite main file while a pool still has it open is undefined: the old connections keep
/// the unlinked inode while a newly-opened connection sees a different file, and both files can then
/// share one WAL name. NOOP has two app-lifetime pools (Repository and BLE), so an in-session file swap
/// cannot be made safe by closing only one owner. This handoff keeps the running store untouched. The
/// process-wide `StoreOpenGate` consumes it synchronously before creating the first pool.
///
/// All database copies use SQLite's online-backup API through GRDB. That API reads committed WAL frames,
/// holds a transaction on the destination, and rolls the destination back if the copy does not finish.
/// A pre-restore safety snapshot is therefore a complete database even when the live main file has
/// committed rows only in `-wal`.
public enum PendingDatabaseRestore {
    public enum ApplyResult {
        case none
        case applied(safetySnapshot: URL)
        /// The pending candidate failed a preflight check before the live database was touched, or the
        /// post-apply check failed and the safety snapshot was restored successfully.
        case discarded(String)
    }

    private struct Manifest: Codable {
        let version: Int
        let candidateFileName: String
        let settingsFileName: String?
        let safetySnapshotFileName: String
    }

    private struct RestoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let manifestVersion = 1
    private static let manifestSuffix = ".pending-restore.json"
    private static let candidatePrefix = ".noop-pending-restore-"
    private static let stagingIOLock = NSLock()
    private static let processAttemptLock = NSLock()
    // Every read and mutation of these process-wide registries is serialized by `processAttemptLock`.
    // `nonisolated(unsafe)` teaches Swift's static checker about that explicit synchronization contract.
    nonisolated(unsafe) private static var processAttemptedPaths: Set<String> = []
    nonisolated(unsafe) private static var processCompletedPaths: Set<String> = []
    nonisolated(unsafe) private static var processFailures: [String: String] = [:]

    /// Normalize `sourcePath` (including legacy `-wal`/`-shm` siblings) into a private, standalone
    /// candidate and publish the pending manifest last. Nothing at `databasePath` is opened, checkpointed,
    /// copied, removed, or replaced here, so both live app pools remain untouched until cold launch.
    ///
    /// `settingsJSON` must already have been filtered through `BackupSettings`; it is applied only after
    /// the database copy succeeds on launch. `safetySnapshot` must sit beside the live database so the
    /// sandbox and iOS data-protection policy are identical to the store's.
    public static func stage(
        databaseAt sourcePath: String,
        settingsJSON: Data?,
        forDatabaseAt databasePath: String,
        safetySnapshot: URL
    ) throws {
        stagingIOLock.lock()
        defer { stagingIOLock.unlock() }

        let fm = FileManager.default
        let liveURL = URL(fileURLWithPath: databasePath).standardizedFileURL
        let directory = liveURL.deletingLastPathComponent()
        guard safetySnapshot.standardizedFileURL.deletingLastPathComponent() == directory else {
            throw RestoreError(message: "The restore safety snapshot must be stored beside the NOOP database.")
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = manifestURL(forDatabaseAt: databasePath)
        let currentManifest = try? readManifest(at: manifestURL, databaseDirectory: directory)
        cleanupOrphanedStagingFiles(in: directory, preserving: currentManifest)

        let id = UUID().uuidString
        let scratch = directory.appendingPathComponent("\(candidatePrefix)\(id)-source.sqlite")
        let candidate = directory.appendingPathComponent("\(candidatePrefix)\(id).sqlite")
        let settings = settingsJSON.map { _ in
            directory.appendingPathComponent("\(candidatePrefix)\(id)-settings.json")
        }

        // A legacy plain-SQLite backup may carry committed rows only in its WAL. Copy its triplet into
        // our writable directory first so opening it can rebuild SHM/checkpoint without ever mutating the
        // user-selected source file.
        do {
            try copyDatabaseTriplet(from: sourcePath, to: scratch.path)
            defer { removeDatabaseTriplet(at: scratch.path) }

            try backupDatabase(from: scratch.path, to: candidate.path, freshDestination: true,
                               makeDestinationStandalone: true)

            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: candidate.path) {
                throw RestoreError(message: "The staged backup failed SQLite's integrity check: \(complaint)")
            }
            try migrateAndValidateCandidate(at: candidate.path)

            if let settingsJSON, let settings {
                guard let normalizedSettings = BackupSettings.encode(BackupSettings.decode(settingsJSON)) else {
                    throw RestoreError(message: "The staged backup settings payload was invalid.")
                }
                try normalizedSettings.write(to: settings, options: .atomic)
            }

            let manifest = Manifest(
                version: manifestVersion,
                candidateFileName: candidate.lastPathComponent,
                settingsFileName: settings?.lastPathComponent,
                safetySnapshotFileName: safetySnapshot.lastPathComponent)
            let data = try JSONEncoder().encode(manifest)

            // Read the previous manifest before atomically publishing the new one. Once the new manifest
            // lands, its candidate/settings form one complete restore request; old private staging files
            // can then be reclaimed best-effort without risking the new request.
            let oldManifest = try? readManifest(at: manifestURL, databaseDirectory: directory)
            try data.write(to: manifestURL, options: .atomic)
            if let oldManifest {
                removeManifestResources(oldManifest, in: directory, preserving: manifest)
            }
        } catch {
            removeDatabaseTriplet(at: candidate.path)
            if let settings { try? fm.removeItem(at: settings) }
            throw error
        }
    }

    /// Consume a staged restore. `WhoopStore` calls this only from `StoreOpenGate`, before the first
    /// pool is created. Tests may call it directly against a throwaway path to exercise the same I/O.
    ///
    /// A missing/corrupt candidate is discarded before the live store is opened. Failures while making
    /// the safety snapshot or applying the transactional SQLite backup throw and prevent the store from
    /// opening; this is safer than silently opening a database whose requested restore state is unknown.
    @discardableResult
    public static func applyIfPresent(
        toDatabaseAt databasePath: String,
        settingsDefaults: UserDefaults = .standard
    ) throws -> ApplyResult {
        let fm = FileManager.default
        let liveURL = URL(fileURLWithPath: databasePath).standardizedFileURL
        // Claim the path even when no manifest exists. AppModel performs this check before constructing
        // ProfileStore/BLE/Repository; if the user stages a restore later in that running process, a
        // subsequent WhoopStore opener must NOT consume it underneath already-live pools. The in-memory
        // claim resets naturally on the next cold launch, when the staged manifest is eligible.
        switch claimApplyAttempt(for: liveURL.path) {
        case .first:
            break
        case .completed:
            return .none
        case .inProgress:
            throw RestoreError(message: "A restore for this database is already in progress.")
        case .failed(let message):
            throw RestoreError(message: message)
        }
        stagingIOLock.lock()
        defer { stagingIOLock.unlock() }
        let directory = liveURL.deletingLastPathComponent()
        let manifestURL = manifestURL(forDatabaseAt: databasePath)
        guard fm.fileExists(atPath: manifestURL.path) else {
            cleanupOrphanedStagingFiles(in: directory, preserving: nil)
            markApplyCompleted(for: liveURL.path)
            return .none
        }

        let manifest: Manifest
        do {
            manifest = try readManifest(at: manifestURL, databaseDirectory: directory)
        } catch {
            // The manifest itself is the only authority for private candidate paths. If it cannot be
            // decoded safely, remove just the marker and leave the current database byte-for-byte alone.
            try? fm.removeItem(at: manifestURL)
            cleanupOrphanedStagingFiles(in: directory, preserving: nil)
            let result = ApplyResult.discarded(
                "The pending restore manifest was invalid; the existing database was kept.")
            markApplyCompleted(for: liveURL.path)
            return result
        }

        let candidate = directory.appendingPathComponent(manifest.candidateFileName)
        let settings = manifest.settingsFileName.map { directory.appendingPathComponent($0) }
        let safetySnapshot = directory.appendingPathComponent(manifest.safetySnapshotFileName)
        cleanupOrphanedStagingFiles(in: directory, preserving: manifest)

        guard fm.fileExists(atPath: candidate.path) else {
            finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
            let result = ApplyResult.discarded(
                "The pending restore database was missing; the existing database was kept.")
            markApplyCompleted(for: liveURL.path)
            return result
        }
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: candidate.path) {
            finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
            let result = ApplyResult.discarded(
                "The pending restore database was damaged (SQLite reports: \(complaint)); the existing database was kept.")
            markApplyCompleted(for: liveURL.path)
            return result
        }
        do {
            // Re-run the real migrator on the private file immediately before apply. This both supports
            // old NOOP backups and protects against a staged candidate being changed after publication.
            // The live database is still untouched at this point.
            try migrateAndValidateCandidate(at: candidate.path)
        } catch {
            finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
            let result = ApplyResult.discarded(error.localizedDescription)
            markApplyCompleted(for: liveURL.path)
            return result
        }

        // A manifest that promises settings is one atomic restore request. Read and validate those
        // private bytes before snapshotting or writing the live database, then apply the cached values
        // only after the database post-check succeeds.
        let pendingSettings: [String: Any]?
        if let settings {
            guard let data = try? Data(contentsOf: settings),
                  BackupSettings.encode(BackupSettings.decode(data)) != nil else {
                finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
                let result = ApplyResult.discarded(
                    "The pending restore settings were missing or damaged; the existing database was kept.")
                markApplyCompleted(for: liveURL.path)
                return result
            }
            pendingSettings = BackupSettings.decode(data)
        } else {
            pendingSettings = nil
        }

        let hadLiveDatabase = fm.fileExists(atPath: liveURL.path)
        if hadLiveDatabase {
            // Do not overwrite an existing snapshot. It means a previous launch completed this step and
            // then exited before clearing the manifest; retaining it preserves the true pre-restore state.
            if existingSnapshotFailure(at: safetySnapshot) != nil {
                removeDatabaseTriplet(at: safetySnapshot.path)
                do {
                    try backupDatabase(from: liveURL.path, to: safetySnapshot.path,
                                       freshDestination: true, makeDestinationStandalone: true)
                } catch {
                    markApplyFailed(for: liveURL.path, error: error)
                    throw error
                }
            }
        }

        do {
            // This does not unlink/rename the live main file. SQLite writes the candidate through a
            // transaction, so any other-process handle on the same inode remains coherent and a failed
            // copy rolls back automatically.
            try backupDatabase(from: candidate.path, to: liveURL.path,
                               freshDestination: !hadLiveDatabase, makeDestinationStandalone: false)
        } catch {
            if !hadLiveDatabase { removeDatabaseTriplet(at: liveURL.path) }
            markApplyFailed(for: liveURL.path, error: error)
            throw error
        }

        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: liveURL.path) {
            if hadLiveDatabase {
                do {
                    try backupDatabase(from: safetySnapshot.path, to: liveURL.path,
                                       freshDestination: false, makeDestinationStandalone: false)
                    guard DatabaseIntegrity.quickCheckFailure(atPath: liveURL.path) == nil else {
                        throw RestoreError(message: "the safety snapshot did not pass verification after rollback")
                    }
                    finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
                    let result = ApplyResult.discarded(
                        "The restored database failed its post-restore integrity check (SQLite reports: \(complaint)); the complete safety snapshot was restored.")
                    markApplyCompleted(for: liveURL.path)
                    return result
                } catch {
                    let fatal = RestoreError(message: "The restore failed its integrity check and the safety rollback could not be verified: \(error.localizedDescription)")
                    markApplyFailed(for: liveURL.path, error: fatal)
                    throw fatal
                }
            } else {
                removeDatabaseTriplet(at: liveURL.path)
                finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
                let result = ApplyResult.discarded(
                    "The restored database failed its post-restore integrity check (SQLite reports: \(complaint)); there was no previous database and the damaged file was removed.")
                markApplyCompleted(for: liveURL.path)
                return result
            }
        }

        BackupSettings.apply(
            pendingSettings ?? [:],
            to: settingsDefaults,
            clearDerivedPlannerState: true
        )
        settingsDefaults.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
        finishPendingRestore(manifest, manifestURL: manifestURL, directory: directory)
        let result = ApplyResult.applied(safetySnapshot: hadLiveDatabase ? safetySnapshot : liveURL)
        markApplyCompleted(for: liveURL.path)
        return result
    }

    // MARK: - Private I/O

    private static func manifestURL(forDatabaseAt path: String) -> URL {
        URL(fileURLWithPath: path + manifestSuffix)
    }

    private enum ProcessAttempt {
        case first
        case completed
        case inProgress
        case failed(String)
    }

    private static func claimApplyAttempt(for path: String) -> ProcessAttempt {
        processAttemptLock.lock()
        defer { processAttemptLock.unlock() }
        if let failure = processFailures[path] { return .failed(failure) }
        if processCompletedPaths.contains(path) { return .completed }
        return processAttemptedPaths.insert(path).inserted ? .first : .inProgress
    }

    private static func markApplyCompleted(for path: String) {
        processAttemptLock.lock()
        defer { processAttemptLock.unlock() }
        processCompletedPaths.insert(path)
        processAttemptedPaths.remove(path)
        processFailures.removeValue(forKey: path)
    }

    private static func markApplyFailed(for path: String, error: Error) {
        processAttemptLock.lock()
        defer { processAttemptLock.unlock() }
        processAttemptedPaths.remove(path)
        processFailures[path] = error.localizedDescription
    }

    private static func readManifest(at url: URL, databaseDirectory: URL) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.version == manifestVersion,
              isSafePrivateFileName(manifest.candidateFileName),
              manifest.candidateFileName.hasPrefix(candidatePrefix),
              manifest.candidateFileName.hasSuffix(".sqlite"),
              manifest.settingsFileName.map({ isSafePrivateFileName($0) && $0.hasPrefix(candidatePrefix) }) ?? true,
              isSafePrivateFileName(manifest.safetySnapshotFileName),
              manifest.safetySnapshotFileName.hasPrefix("whoop-replaced-"),
              manifest.safetySnapshotFileName.hasSuffix(".sqlite") else {
            throw RestoreError(message: "Invalid pending restore manifest")
        }
        // Resolving the names under the known directory after the basename checks above prevents a
        // corrupted/tampered manifest from reaching outside the store directory.
        _ = databaseDirectory.appendingPathComponent(manifest.candidateFileName)
        return manifest
    }

    private static func isSafePrivateFileName(_ name: String) -> Bool {
        !name.isEmpty && (name as NSString).lastPathComponent == name && name != "." && name != ".."
    }

    private static func copyDatabaseTriplet(from sourcePath: String, to destinationPath: String) throws {
        let fm = FileManager.default
        removeDatabaseTriplet(at: destinationPath)
        try fm.copyItem(atPath: sourcePath, toPath: destinationPath)
        do {
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: sourcePath + suffix) {
                try fm.copyItem(atPath: sourcePath + suffix, toPath: destinationPath + suffix)
            }
        } catch {
            removeDatabaseTriplet(at: destinationPath)
            throw error
        }
    }

    /// Copy a logical SQLite database with the online-backup API exposed by GRDB. `freshDestination`
    /// is used only for private candidate/snapshot files; the live path is never removed when it exists.
    private static func backupDatabase(
        from sourcePath: String,
        to destinationPath: String,
        freshDestination: Bool,
        makeDestinationStandalone: Bool
    ) throws {
        if freshDestination { removeDatabaseTriplet(at: destinationPath) }

        var sourceConfig = Configuration()
        sourceConfig.busyMode = .timeout(5)
        var destinationConfig = Configuration()
        destinationConfig.busyMode = .timeout(5)

        do {
            let source = try DatabaseQueue(path: sourcePath, configuration: sourceConfig)
            let destination = try DatabaseQueue(path: destinationPath, configuration: destinationConfig)
            try source.backup(to: destination)

            if makeDestinationStandalone {
                try destination.writeWithoutTransaction { db in
                    let checkpoint = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    guard let checkpoint else {
                        throw RestoreError(message: "SQLite returned no WAL checkpoint result")
                    }
                    let busy: Int = checkpoint[0]
                    let log: Int = checkpoint[1]
                    let checkpointed: Int = checkpoint[2]
                    guard busy == 0, log == checkpointed else {
                        throw RestoreError(message: "SQLite could not flatten the staged WAL (busy=\(busy), log=\(log), checkpointed=\(checkpointed))")
                    }
                    let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE") ?? ""
                    guard mode.lowercased() == "delete" else {
                        throw RestoreError(message: "SQLite could not make the staged database standalone (journal_mode=\(mode))")
                    }
                }
            }
        } catch {
            if freshDestination { removeDatabaseTriplet(at: destinationPath) }
            throw error
        }
    }

    /// Require a genuine NOOP migration ledger, reject databases produced by a newer/unknown
    /// migrator or with a non-prefix ledger, and run this build's complete migrator against the
    /// private candidate. No user-selected source or live store is mutated by this validation.
    private static func migrateAndValidateCandidate(at path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: path, configuration: config)
        let migrator = WhoopStore.makeMigrator()

        try queue.read { db in
            let names = try Set(String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            guard names.contains("grdb_migrations") else {
                throw RestoreError(message: "The pending database is not a compatible NOOP/GRDB backup; the existing database was kept.")
            }

            let applied = try migrator.appliedIdentifiers(db)
            let known = migrator.migrations
            let knownSet = Set(known)
            guard let first = known.first, !applied.isEmpty, applied.contains(first) else {
                throw RestoreError(message: "The pending database has no completed NOOP base migration; the existing database was kept.")
            }
            guard applied.isSubset(of: knownSet) else {
                throw RestoreError(message: "The pending database was created by a newer or unknown NOOP schema; the existing database was kept.")
            }
            let expectedPrefix = Set(known.prefix(applied.count))
            guard applied == expectedPrefix else {
                throw RestoreError(message: "The pending database has inconsistent migration bookkeeping; the existing database was kept.")
            }
        }

        do {
            try migrator.migrate(queue)
            try queue.read { db in
                guard try migrator.hasCompletedMigrations(db),
                      try !migrator.hasBeenSuperseded(db) else {
                    throw RestoreError(message: "The pending database could not be brought to this NOOP schema version; the existing database was kept.")
                }
                try validateCurrentSchema(db)
            }
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError(message: "The pending database could not be migrated safely; the existing database was kept. \(error.localizedDescription)")
        }

        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: path) {
            throw RestoreError(message: "The migrated pending database failed SQLite's integrity check (SQLite reports: \(complaint)); the existing database was kept.")
        }

        try queue.writeWithoutTransaction { db in
            let checkpoint = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            guard let checkpoint else {
                throw RestoreError(message: "SQLite returned no WAL checkpoint result for the migrated pending database.")
            }
            let busy: Int = checkpoint[0]
            let log: Int = checkpoint[1]
            let checkpointed: Int = checkpoint[2]
            guard busy == 0, log == checkpointed else {
                throw RestoreError(message: "SQLite could not flatten the migrated pending database WAL (busy=\(busy), log=\(log), checkpointed=\(checkpointed)).")
            }
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE") ?? ""
            guard mode.lowercased() == "delete" else {
                throw RestoreError(message: "SQLite could not make the migrated pending database standalone (journal_mode=\(mode)).")
            }
        }
    }

    /// Compare the migrated candidate with a canonical database built by this exact migrator. We
    /// intentionally compare required tables/columns and named indexes instead of raw sqlite_master
    /// SQL, whose harmless quoting/formatting can differ across GRDB/SQLite releases.
    private static func validateCurrentSchema(_ candidate: Database) throws {
        let canonical = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(canonical)
        let expected = try canonical.read { db in try schemaRequirements(in: db) }
        let actual = try schemaRequirements(in: candidate)

        for (table, expectedColumns) in expected.tableColumns {
            guard let actualColumns = actual.tableColumns[table],
                  expectedColumns.isSubset(of: actualColumns) else {
                throw RestoreError(message: "The pending database's \(table) table does not match the current NOOP schema; the existing database was kept.")
            }
        }
        guard expected.indexes.isSubset(of: actual.indexes) else {
            throw RestoreError(message: "The pending database is missing indexes required by the current NOOP schema; the existing database was kept.")
        }
    }

    private struct SchemaRequirements {
        let tableColumns: [String: Set<String>]
        let indexes: Set<String>
    }

    private static func schemaRequirements(in db: Database) throws -> SchemaRequirements {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
            ORDER BY name
            """)
        var columns: [String: Set<String>] = [:]
        for table in tables {
            columns[table] = Set(try db.columns(in: table).map(\.name))
        }
        let indexes = try Set(String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'index' AND sql IS NOT NULL
            """))
        return SchemaRequirements(tableColumns: columns, indexes: indexes)
    }

    private static func existingSnapshotFailure(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return "not a regular database file"
        }
        return DatabaseIntegrity.quickCheckFailure(atPath: url.path)
    }

    private static func finishPendingRestore(_ manifest: Manifest, manifestURL: URL, directory: URL) {
        // Clear the authority marker first. If the process exits during later best-effort cleanup, the
        // private leftovers are inert; if marker removal fails, the next apply is idempotent and never
        // overwrites the already-created safety snapshot.
        try? FileManager.default.removeItem(at: manifestURL)
        removeManifestResources(manifest, in: directory, preserving: nil)
    }

    private static func removeManifestResources(_ manifest: Manifest, in directory: URL,
                                                preserving keep: Manifest?) {
        if keep?.candidateFileName != manifest.candidateFileName {
            removeDatabaseTriplet(at: directory.appendingPathComponent(manifest.candidateFileName).path)
        }
        if let settings = manifest.settingsFileName, keep?.settingsFileName != settings {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(settings))
        }
    }

    /// Reclaim private files left by a crash during staging. Only our hidden, UUID-prefixed files in
    /// the known database directory are eligible; resources named by the currently valid manifest are
    /// preserved. The I/O lock prevents a same-process stage/apply from deleting another active copy.
    private static func cleanupOrphanedStagingFiles(in directory: URL, preserving manifest: Manifest?) {
        let keep: Set<String> = {
            guard let manifest else { return [] }
            var names = Set([manifest.candidateFileName])
            for suffix in ["-wal", "-shm", "-journal"] {
                names.insert(manifest.candidateFileName + suffix)
            }
            if let settings = manifest.settingsFileName { names.insert(settings) }
            return names
        }()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.lastPathComponent.hasPrefix(candidatePrefix)
            && !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func removeDatabaseTriplet(at path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let candidate = path + suffix
            if fm.fileExists(atPath: candidate) { try? fm.removeItem(atPath: candidate) }
        }
    }
}
