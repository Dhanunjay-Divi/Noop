import XCTest
import CryptoKit
import SQLite3
import WhoopStore
import ZIPFoundation
@testable import Strand

/// Real file-I/O tests for the Backup & Sync restore path - not string logic (must-fix #5).
///
/// These exercise the SAME hardened core the picker import uses, via the injectable
/// `DataBackup.restore(from:toDatabaseAt:)` seam (a throwaway DB path, never the user's live store):
///  - a `.noopbak` ZIP backup stages without touching live data, then cold-launch apply returns the rows;
///  - committed rows present only in a live WAL are preserved in the safety snapshot;
///  - a foreign-but-valid SQLite (Room / no `grdb_migrations`) is REJECTED and the live DB is intact;
///  - a corrupt (non-SQLite) file is REJECTED and the live DB is intact;
///  - a folder prune actually deletes the oldest files past keep-N (pure selection, applied to real files).
final class BackupSyncRoundTripTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("backupsync-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
    }

    /// A suite-scoped UserDefaults for the settings half of a restore, so these tests NEVER write into
    /// the test runner's `.standard` domain (which on a dev Mac is the developer's real NOOP profile).
    private func freshDefaults() throws -> UserDefaults {
        let name = "backupsync-test-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { throw TestError("no suite defaults") }
        suites.append(name)
        return d
    }

    // MARK: - Round trip: backupNow → restore returns the same rows

    func testBackupThenRestoreReturnsTheSameRows() throws {
        // A genuine v1 NOOP database. Staging must run every later production migration privately
        // before it publishes the restore marker.
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["my-whoop", "watch"])

        // Write it into a `.noopbak` ZIP exactly as the folder/auto path does.
        let backup = tmp.appendingPathComponent(BackupSync.snapshotName(1_782_000_000_000))
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)
        XCTAssertTrue(isZip(backup), "Backup should be a ZIP container (.noopbak)")
        let archive = try XCTUnwrap(Archive(url: backup, accessMode: .read))
        let manifestEntry = try XCTUnwrap(archive[BackupManifest.entryName])
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { manifestData.append($0) }
        let manifest = try BackupManifest.decoded(from: manifestData)
        XCTAssertEqual(manifest.sourcePlatform, .apple)
        XCTAssertEqual(manifest.databaseEngine, .grdb)
        XCTAssertEqual(manifest.databaseSchemaVersion, WhoopStoreInfo.schemaVersion)
        XCTAssertEqual(manifest.payloads.database.path, "noop-backup.sqlite")

        // Restore into a DIFFERENT, throwaway live-DB path (so the user's real store is never touched).
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)

        guard case .imported = result else {
            return XCTFail("Restore should stage a valid NOOP backup, got \(result)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path),
                       "Staging must not create or replace the live database in-session")
        try applyPendingRestore(to: liveDB, settingsDefaults: freshDefaults())
        XCTAssertEqual(try deviceRows(in: liveDB), ["my-whoop", "watch"],
                       "Restored DB should hold exactly the backed-up rows")
    }

    // MARK: - Encrypted Apple envelope v1

    func testPBKDF2SHA256MatchesPublishedGoldenVector() throws {
        // RFC 7914 / common PBKDF2-HMAC-SHA256 known answer (P="password", S="salt", c=1,
        // dkLen=32). This pins normalization/UTF-8, PRF choice and byte order independently of GCM.
        let key = try DataBackup.deriveBackupKeyForTesting(
            passphrase: "password",
            salt: Data("salt".utf8),
            iterations: 1
        )
        XCTAssertEqual(
            hex(key),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        )
    }

    func testEncryptedEnvelopeDeterministicGoldenRoundTrip() throws {
        // 65,553 bytes forces two independently authenticated chunks at the v1 minimum chunk size.
        // Salt/nonce are injected only through the test seam; production always draws fresh randoms.
        let plaintext = Data((0..<65_553).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let source = tmp.appendingPathComponent("golden-plaintext.bin")
        let envelope = tmp.appendingPathComponent("golden.noopbak")
        let restored = tmp.appendingPathComponent("golden-restored.bin")
        try plaintext.write(to: source)
        try DataBackup.encryptFileForTesting(
            plaintextAt: source,
            to: envelope,
            passphrase: "golden backup phrase",
            salt: Data(0x00...0x0F),
            noncePrefix: Data(0xA0...0xA7)
        )

        let encoded = try Data(contentsOf: envelope)
        XCTAssertEqual(encoded.count, 64 + plaintext.count + 2 * 16)
        XCTAssertEqual(
            hex(encoded.prefix(64)),
            "4e4f4f5042414b0001010100000186a0000100000000000000010011"
                + "000102030405060708090a0b0c0d0e0f"
                + "a0a1a2a3a4a5a6a7"
                + "000000000000000000000000"
        )
        // Generated independently with a second AES-256-GCM + PBKDF2-HMAC-SHA256 implementation
        // from the documented v1 fields. Cipher/KDF/AAD/record-layout drift changes this digest.
        XCTAssertEqual(
            hex(Data(SHA256.hash(data: encoded))),
            "e84759fc93d512cc67596ae665e33ab32ef6ba7ebfc403aaa4eaaba2f6a455dc"
        )

        try DataBackup.decryptFileForTesting(
            envelopeAt: envelope,
            to: restored,
            passphrase: "golden backup phrase"
        )
        XCTAssertEqual(try Data(contentsOf: restored), plaintext)
    }

    func testEncryptedAtomicPublishFailurePreservesExistingBackup() throws {
        let source = tmp.appendingPathComponent("replacement-source.bin")
        let destination = tmp.appendingPathComponent("existing.noopbak")
        let oldBackup = Data("the last known-good backup".utf8)
        try Data(repeating: 0xA5, count: 70_000).write(to: source)
        try oldBackup.write(to: destination)

        // A user-immutable destination makes the final same-directory rename fail after encryption
        // has completed. This exercises the exact publish failure path without a mock: the old backup
        // must remain byte-for-byte intact and the hidden partial must be cleaned up.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: destination.path)
        }

        XCTAssertThrowsError(
            try DataBackup.encryptFileForTesting(
                plaintextAt: source,
                to: destination,
                passphrase: "replacement test passphrase",
                salt: Data(0x10...0x1F),
                noncePrefix: Data(0xB0...0xB7)
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), oldBackup)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertFalse(siblingNames.contains(where: { $0.contains(".encrypting-") }))
    }

    func testEncryptedDecryptPublishFailurePreservesExistingDestination() throws {
        let plaintext = tmp.appendingPathComponent("decrypt-replacement-source.bin")
        let envelope = tmp.appendingPathComponent("decrypt-replacement.noopbak")
        let destination = tmp.appendingPathComponent("existing-decrypted.zip")
        let previous = Data("the prior authenticated staging file".utf8)
        try Data(repeating: 0x5A, count: 70_000).write(to: plaintext)
        try DataBackup.encryptFileForTesting(
            plaintextAt: plaintext,
            to: envelope,
            passphrase: "decrypt replacement passphrase",
            salt: Data(0x20...0x2F),
            noncePrefix: Data(0xC0...0xC7)
        )
        try previous.write(to: destination)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: destination.path)
        }

        XCTAssertThrowsError(try DataBackup.decryptFileForTesting(
            envelopeAt: envelope,
            to: destination,
            passphrase: "decrypt replacement passphrase"
        ))
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertFalse(siblingNames.contains(where: { $0.contains(".decrypting-") }))
    }

    func testEncryptedBackupRestoresRowsAndSettingsWithCorrectPassphrase() throws {
        let sourceDB = tmp.appendingPathComponent("encrypted-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["encrypted-whoop", "encrypted-watch"])
        let backup = tmp.appendingPathComponent("encrypted.noopbak")
        try DataBackup.writeEncryptedBackupForTesting(
            databaseAt: sourceDB,
            to: backup,
            passphrase: "correct horse battery staple",
            settings: ["profile.age": 31, "units.system": "metric"]
        )
        XCTAssertTrue(DataBackup.isEncryptedBackupForTesting(backup))
        XCTAssertFalse(isZip(backup), "ciphertext must not expose the ZIP container magic")

        let liveDB = tmp.appendingPathComponent("encrypted-live.sqlite")
        let result = DataBackup.restore(
            from: backup,
            toDatabaseAt: liveDB.path,
            passphrase: "correct horse battery staple"
        )
        guard case .imported = result else {
            return XCTFail("authenticated backup should stage, got \(result)")
        }
        let defaults = try freshDefaults()
        try applyPendingRestore(to: liveDB, settingsDefaults: defaults)
        XCTAssertEqual(try deviceRows(in: liveDB), ["encrypted-watch", "encrypted-whoop"])
        XCTAssertEqual(defaults.integer(forKey: "profile.age"), 31)
        XCTAssertEqual(defaults.string(forKey: "units.system"), "metric")
    }

    func testWrongPassphraseFailsWithoutPublishingRestoreOrTouchingLiveData() throws {
        let sourceDB = tmp.appendingPathComponent("wrong-password-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["secret"])
        let backup = tmp.appendingPathComponent("wrong-password.noopbak")
        try DataBackup.writeEncryptedBackupForTesting(
            databaseAt: sourceDB,
            to: backup,
            passphrase: "the actual long passphrase"
        )
        let liveDB = tmp.appendingPathComponent("wrong-password-live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["keep-me"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(
            from: backup,
            toDatabaseAt: liveDB.path,
            passphrase: "a different long passphrase"
        )
        guard case .failure(let message) = result else {
            return XCTFail("wrong passphrase must fail, got \(result)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("wrong"))
        XCTAssertEqual(try Data(contentsOf: liveDB), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path + ".pending-restore.json"))
    }

    func testTamperedEncryptedBackupFailsWithoutPublishingRestoreOrTouchingLiveData() throws {
        let sourceDB = tmp.appendingPathComponent("tamper-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["secret"])
        let backup = tmp.appendingPathComponent("tampered.noopbak")
        try DataBackup.writeEncryptedBackupForTesting(
            databaseAt: sourceDB,
            to: backup,
            passphrase: "the actual long passphrase"
        )
        var tampered = try Data(contentsOf: backup)
        XCTAssertGreaterThan(tampered.count, 80)
        tampered[75] ^= 0x80 // ciphertext, not a parse-only header byte
        try tampered.write(to: backup, options: .atomic)

        let liveDB = tmp.appendingPathComponent("tamper-live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["keep-me"])
        let before = try Data(contentsOf: liveDB)
        let result = DataBackup.restore(
            from: backup,
            toDatabaseAt: liveDB.path,
            passphrase: "the actual long passphrase"
        )
        guard case .failure = result else {
            return XCTFail("tampered ciphertext must fail, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path + ".pending-restore.json"))
    }

    func testSnapshotExportCapturesWALCommitMadeAfterCheckpointBoundary() throws {
        let sourceDB = tmp.appendingPathComponent("export-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["before-checkpoint"])

        var writer: OpaquePointer?
        guard sqlite3_open_v2(sourceDB.path, &writer,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw TestError("could not open export writer")
        }
        defer { sqlite3_close(writer) }
        try exec(writer, "PRAGMA journal_mode=WAL")
        try exec(writer, "PRAGMA wal_autocheckpoint=0")
        try exec(writer, "PRAGMA wal_checkpoint(TRUNCATE)")

        let backup = tmp.appendingPathComponent("immutable-export.noopbak")
        try DataBackup.writeSnapshotBackupForTesting(
            databaseAt: sourceDB,
            to: backup,
            afterSnapshotInitialized: {
                // This separate live connection commits after the old export's checkpoint boundary
                // but before the online backup copies pages. A raw main-file ZIP would omit this WAL
                // row; sqlite3_backup reads it as part of one consistent logical snapshot.
                try self.exec(writer, "INSERT INTO device (id, name) VALUES ('after-checkpoint', 'late')")
            })

        let archive = try XCTUnwrap(Archive(url: backup, accessMode: .read))
        let entry = try XCTUnwrap(archive["noop-backup.sqlite"])
        var payload = Data()
        _ = try archive.extract(entry) { payload.append($0) }
        let extracted = tmp.appendingPathComponent("exported-snapshot.sqlite")
        try payload.write(to: extracted)

        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: extracted.path))
        XCTAssertEqual(try deviceRows(in: extracted), ["after-checkpoint", "before-checkpoint"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.path + "-wal"),
                       "the archive must contain a standalone SQLite snapshot")
    }

    func testPlaintextSnapshotPublishFailurePreservesExistingBackup() throws {
        let sourceDB = tmp.appendingPathComponent("plaintext-replacement-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["fresh-snapshot"])
        let destination = tmp.appendingPathComponent("existing-plaintext.noopbak")
        let previous = Data("the last known-good plaintext backup".utf8)
        try previous.write(to: destination)

        // Automatic/folder backups are intentionally plaintext. Their final publish still must be
        // transactional: an immutable destination makes the sibling rename fail after the new ZIP has
        // completed, and the old archive must remain byte-for-byte intact.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: destination.path)
        }

        XCTAssertThrowsError(
            try DataBackup.writeSnapshotBackupForTesting(
                databaseAt: sourceDB,
                to: destination
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertFalse(siblingNames.contains(where: { $0.contains(".writing-") }))
    }

    // MARK: - Settings round trip (#1000: restore brings back weight/height/settings)

    func testBackupWithSettingsRestoresSettingsAfterDbSwap() throws {
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["my-whoop"])

        // Export with the whitelisted settings payload (what a real device writes from its defaults).
        let backup = tmp.appendingPathComponent("with-settings.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup, settings: [
            "profile.age": 34,
            "profile.sex": "female",
            "profile.weightKg": 62.5,
            "profile.targetWeightKg": 60.0,
            "profile.heightCm": 168.0,
            "profile.hrMax": 191,
            "units.system": "imperial",
        ])

        // Restore into a throwaway DB path AND a suite-scoped defaults (never the runner's real domain).
        let defaults = try freshDefaults()
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)

        guard case .imported = result else {
            return XCTFail("Restore should stage, got \(result)")
        }
        XCTAssertNil(defaults.object(forKey: "profile.age"),
                     "Settings must not apply while live pools are still open")
        try applyPendingRestore(to: liveDB, settingsDefaults: defaults)
        XCTAssertEqual(try deviceRows(in: liveDB), ["my-whoop"], "DB half still round-trips")
        XCTAssertEqual(defaults.object(forKey: "profile.age") as? Int, 34)
        XCTAssertEqual(defaults.string(forKey: "profile.sex"), "female")
        XCTAssertEqual(defaults.object(forKey: "profile.weightKg") as? Double, 62.5)
        XCTAssertEqual(defaults.object(forKey: "profile.targetWeightKg") as? Double, 60.0)
        XCTAssertEqual(defaults.object(forKey: "profile.heightCm") as? Double, 168.0)
        XCTAssertEqual(defaults.object(forKey: "profile.hrMaxOverride") as? Int, 191,
                       "Canonical profile.hrMax lands on ProfileStore's profile.hrMaxOverride key")
        XCTAssertEqual(defaults.string(forKey: "units.system"), "imperial")
    }

    func testLegacySingleEntryZipStillRestoresAndAppliesNoSettings() throws {
        // A pre-#1000 backup: DB entry only (writeBackupForTesting with settings nil).
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["legacy-strap"])
        let backup = tmp.appendingPathComponent("legacy.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let defaults = try freshDefaults()
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)

        guard case .imported = result else {
            return XCTFail("A legacy single-entry ZIP must restore exactly as today, got \(result)")
        }
        try applyPendingRestore(to: liveDB, settingsDefaults: defaults)
        XCTAssertEqual(try deviceRows(in: liveDB), ["legacy-strap"])
        XCTAssertNil(defaults.object(forKey: "profile.age"), "No settings entry → defaults untouched")
        XCTAssertNil(defaults.object(forKey: "units.system"))
    }

    func testSettingsAreNotAppliedWhenTheRestoreIsRejected() throws {
        // A foreign (Room) DB zipped together WITH a settings payload: the origin gate refuses the
        // restore, so the settings must not leak through either ("apply AFTER the DB swap succeeds").
        let foreign = tmp.appendingPathComponent("foreign.sqlite")
        try makeForeignDatabase(at: foreign)
        let backup = tmp.appendingPathComponent("foreign.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: foreign, to: backup,
                                             settings: ["profile.age": 99, "profile.weightKg": 40.0])

        let defaults = try freshDefaults()
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])

        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("Foreign backup must still be rejected, got \(result)")
        }
        XCTAssertNil(defaults.object(forKey: "profile.age"),
                     "A rejected restore must never apply the backup's settings")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"], "Live DB untouched")
    }

    func testClaimedV1WithMissingBaseTablesIsRejectedBeforePendingPublish() throws {
        let malformed = tmp.appendingPathComponent("malformed-v1.sqlite")
        try makeMalformedClaimedV1Database(at: malformed)
        let backup = tmp.appendingPathComponent("malformed-v1.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: malformed, to: backup)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)

        guard case .failure = result else {
            return XCTFail("a migration ledger must not substitute for the actual v1 schema: \(result)")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path + ".pending-restore.json"),
                       "a candidate that cannot run the real migrator must never be published")
    }

    func testUnrelatedSQLiteWithoutMigrationLedgerIsRejected() throws {
        let unrelated = tmp.appendingPathComponent("unrelated.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(unrelated.path, &db) == SQLITE_OK else {
            throw TestError("could not open unrelated fixture")
        }
        try exec(db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        sqlite3_close(db)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let result = DataBackup.restore(from: unrelated, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("an unrelated valid SQLite file must not become an empty NOOP store: \(result)")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
    }

    // MARK: - P0: cold-launch apply preserves WAL data and never strands an open inode

    func testColdLaunchApplySnapshotsCommittedWALAndKeepsExistingHandleCoherent() throws {
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["restored"])
        let backup = tmp.appendingPathComponent("wal-safe.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["main-row"])

        // Keep this connection open across stage + apply. It stands in for another-process access and,
        // more importantly, proves the implementation never unlinks the inode underneath SQLite.
        // (Production's two in-process GRDB pools are absent at cold apply by construction.)
        var liveHandle: OpaquePointer?
        guard sqlite3_open_v2(liveDB.path, &liveHandle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw TestError("could not open live WAL fixture")
        }
        defer { sqlite3_close(liveHandle) }
        try exec(liveHandle, "PRAGMA journal_mode=WAL")
        try exec(liveHandle, "PRAGMA wal_autocheckpoint=0")
        try exec(liveHandle, "PRAGMA wal_checkpoint(TRUNCATE)")
        try exec(liveHandle, "INSERT INTO device (id) VALUES ('wal-only-row')")

        let walSize = ((try FileManager.default.attributesOfItem(atPath: liveDB.path + "-wal"))[.size]
            as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(walSize, 0, "precondition: the committed row is still represented in WAL")
        XCTAssertEqual(try deviceRows(using: liveHandle), ["main-row", "wal-only-row"])

        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)
        guard case .imported(let promisedSnapshot) = result else {
            return XCTFail("valid backup should stage, got \(result)")
        }

        // Staging is deliberately non-destructive: both committed rows and the WAL remain visible through
        // the exact same connection until the simulated cold-launch handoff is consumed.
        XCTAssertEqual(try deviceRows(using: liveHandle), ["main-row", "wal-only-row"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: promisedSnapshot.path),
                       "the live snapshot is created at cold apply, not by the running app")

        let apply = try PendingDatabaseRestore.applyIfPresent(
            toDatabaseAt: liveDB.path, settingsDefaults: freshDefaults())
        guard case .applied(let snapshot) = apply else {
            return XCTFail("pending restore should apply, got \(apply)")
        }
        XCTAssertEqual(snapshot.standardizedFileURL, promisedSnapshot.standardizedFileURL)

        // The old raw-copy implementation left this handle on the deleted pre-restore inode. SQLite's
        // transactional backup writes the same inode, so a fresh statement on the SAME handle sees the
        // restored row immediately — no stale-handle split brain.
        XCTAssertEqual(try deviceRows(using: liveHandle), ["restored"])
        XCTAssertEqual(try deviceRows(in: liveDB), ["restored"])

        // The rollback side file is a standalone logical snapshot, not just a copy of the main file:
        // it contains the row that was committed only to the live WAL at the time of restore.
        XCTAssertEqual(try deviceRows(in: snapshot), ["main-row", "wal-only-row"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path + "-wal"),
                       "the safety snapshot must not depend on a WAL sidecar")
    }

    func testCorruptRestoreLeavesCommittedWALAndOpenHandleUntouched() throws {
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["main-row"])

        var liveHandle: OpaquePointer?
        guard sqlite3_open_v2(liveDB.path, &liveHandle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw TestError("could not open live WAL fixture")
        }
        defer { sqlite3_close(liveHandle) }
        try exec(liveHandle, "PRAGMA journal_mode=WAL")
        try exec(liveHandle, "PRAGMA wal_autocheckpoint=0")
        try exec(liveHandle, "PRAGMA wal_checkpoint(TRUNCATE)")
        try exec(liveHandle, "INSERT INTO device (id) VALUES ('wal-only-row')")

        let corrupt = tmp.appendingPathComponent("corrupt.noopbak")
        try Data("not sqlite and not zip".utf8).write(to: corrupt)
        let result = DataBackup.restore(from: corrupt, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("corrupt restore must be rejected, got \(result)")
        }

        XCTAssertEqual(try deviceRows(using: liveHandle), ["main-row", "wal-only-row"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveDB.path + "-wal"),
                      "rejection must not remove the live WAL")
        if case .none = try PendingDatabaseRestore.applyIfPresent(toDatabaseAt: liveDB.path) {
            // expected: corrupt input never publishes a pending marker
        } else {
            XCTFail("corrupt input must not leave a pending restore")
        }
    }

    // MARK: - Foreign SQLite is rejected, live DB untouched

    func testForeignSqliteIsRejectedAndLiveDbIntact() throws {
        // A Room/Android-flavoured DB: valid SQLite, but no `grdb_migrations`. It DOES hold a `device`
        // table, so the origin gate must refuse it (would otherwise strand the GRDB migrator).
        let foreign = tmp.appendingPathComponent("foreign.sqlite")
        try makeForeignDatabase(at: foreign)

        // Seed an existing live DB so we can prove it survives a rejected restore.
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: foreign, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A foreign SQLite must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be byte-for-byte unchanged after a rejected restore")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
    }

    // MARK: - Corrupt file is rejected, live DB untouched

    func testCorruptFileIsRejectedAndLiveDbIntact() throws {
        let corrupt = tmp.appendingPathComponent("corrupt.noopbak")
        try Data("this is not a database or a zip".utf8).write(to: corrupt)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: corrupt, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A corrupt file must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after a rejected restore")
    }

    func testZipWithNonCanonicalSqliteEntryIsRejectedAndLiveDbIntact() throws {
        let wrong = tmp.appendingPathComponent("wrong-entry.noopbak")
        let fake = tmp.appendingPathComponent("evil.sqlite")
        var bytes = Data("SQLite format 3".utf8)
        bytes.append(0)
        bytes.append(Data("junk".utf8))
        try bytes.write(to: fake)
        let archive = try XCTUnwrap(Archive(url: wrong, accessMode: .create))
        try archive.addEntry(with: "evil.sqlite", fileURL: fake)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: wrong, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A zip without noop-backup.sqlite must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after a rejected restore")
    }

    // MARK: - #1014: damaged-but-plausible backups are refused by the quick_check gate

    func testGarbageBehindSqliteMagicInsideZipIsRejectedAndLiveDbIntact() throws {
        // 16 valid magic bytes + junk, zipped as a real `.noopbak`: passes the container check AND
        // the magic check AND the origin gate (no readable sqlite_master → `.unknown`, holds no
        // data) — before #1014 this sailed all the way through to the swap. Only SQLite's own
        // `PRAGMA quick_check` sees it for what it is.
        let fake = tmp.appendingPathComponent("fake.sqlite")
        var bytes = Data("SQLite format 3".utf8)
        bytes.append(0x00)
        bytes.append(Data(repeating: 0x5A, count: 8192))
        try bytes.write(to: fake)
        let backup = tmp.appendingPathComponent("damaged.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: fake, to: backup)
        XCTAssertTrue(isZip(backup), "precondition: the damaged payload rides in a real ZIP")

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A structurally damaged backup must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be byte-for-byte unchanged after the integrity rejection")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
    }

    func testTruncatedNoopBackupIsRejectedAndLiveDbIntact() throws {
        // A REAL NOOP database grown past one page, then truncated to its first page (the #1014
        // shape: a backup clipped mid-upload/mid-copy). Page 1 still reads perfectly — magic bytes
        // intact, `grdb_migrations` visible in sqlite_master — so the header and origin gates both
        // PASS. Only quick_check notices the file no longer holds the pages its header promises.
        let sourceDB = tmp.appendingPathComponent("big.sqlite")
        try makeMultiPageNoopDatabase(at: sourceDB)
        let fullSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: sourceDB.path))[.size] as? NSNumber
        ).int64Value
        XCTAssertGreaterThan(fullSize, 4096, "precondition: fixture spans multiple pages")

        let handle = try FileHandle(forWritingTo: sourceDB)
        try handle.truncate(atOffset: 4096)
        try handle.close()

        // Feed it through the legacy plain-SQLite path (truncation hits both container shapes the
        // same way; the ZIP shape is covered by the garbage test above).
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: sourceDB, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A truncated backup must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after the integrity rejection")
    }

    // MARK: - Prune deletes the oldest files past keep-N (real files)

    func testPruneDeletesOldestRealFilesPastKeepN() throws {
        let folder = tmp.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Five real snapshot files + one unrelated file.
        var names: [String] = []
        for i in 0..<5 {
            let name = BackupSync.snapshotName(1_782_000_000_000 + i * 60_000)
            names.append(name)
            try Data("backup \(i)".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        // Apply the pure prune selection to the real directory listing, then delete (the same two
        // steps `FolderBackup.prune` performs internally).
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let toDelete = Set(BackupSync.snapshotsToPrune(listing, keep: 2))
        for name in listing where toDelete.contains(name) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(after.contains(names[4]), "Newest snapshot kept")
        XCTAssertTrue(after.contains(names[3]), "2nd-newest snapshot kept")
        XCTAssertFalse(after.contains(names[0]), "Oldest snapshot pruned")
        XCTAssertFalse(after.contains(names[1]))
        XCTAssertFalse(after.contains(names[2]))
        XCTAssertTrue(after.contains("notes.txt"), "Non-snapshot files are never pruned")
    }

    // MARK: - SQLite fixtures (system SQLite3)

    @discardableResult
    private func applyPendingRestore(to database: URL,
                                     settingsDefaults: UserDefaults = .standard) throws -> URL {
        switch try PendingDatabaseRestore.applyIfPresent(
            toDatabaseAt: database.path, settingsDefaults: settingsDefaults) {
        case .applied(let safetySnapshot):
            return safetySnapshot
        case .none:
            throw TestError("no pending restore was published")
        case .discarded(let reason):
            throw TestError("pending restore was discarded: \(reason)")
        }
    }

    /// Build the exact schema produced by migration v1, then mark only v1 applied. Restore staging is
    /// expected to run v2...current on its private candidate without mutating this source fixture.
    private func makeNoopDatabase(at url: URL, deviceRows: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(db, """
            CREATE TABLE device (
                id TEXT PRIMARY KEY,
                mac TEXT,
                name TEXT,
                firstSeen INTEGER,
                lastSeen INTEGER
            );
            CREATE TABLE hrSample (
                deviceId TEXT NOT NULL,
                ts INTEGER NOT NULL,
                bpm INTEGER NOT NULL,
                PRIMARY KEY (deviceId, ts)
            );
            CREATE TABLE rrInterval (
                deviceId TEXT NOT NULL,
                ts INTEGER NOT NULL,
                rrMs INTEGER NOT NULL,
                PRIMARY KEY (deviceId, ts, rrMs)
            );
            CREATE TABLE event (
                deviceId TEXT NOT NULL,
                ts INTEGER NOT NULL,
                kind TEXT NOT NULL,
                payloadJSON TEXT NOT NULL,
                PRIMARY KEY (deviceId, ts, kind)
            );
            CREATE TABLE battery (
                deviceId TEXT NOT NULL,
                ts INTEGER NOT NULL,
                soc REAL,
                mv INTEGER,
                PRIMARY KEY (deviceId, ts)
            );
            CREATE TABLE rawBatch (
                batchId TEXT PRIMARY KEY,
                deviceId TEXT NOT NULL,
                capturedAt INTEGER NOT NULL,
                deviceClockRef INTEGER NOT NULL,
                wallClockRef INTEGER NOT NULL,
                startTs INTEGER NOT NULL,
                endTs INTEGER NOT NULL,
                frameCount INTEGER NOT NULL,
                byteSize INTEGER NOT NULL,
                framesBlob BLOB NOT NULL,
                syncedAt INTEGER
            );
            """)
        for id in deviceRows {
            try exec(db, "INSERT INTO device (id) VALUES ('\(id)')")
        }
    }

    private func makeMalformedClaimedV1Database(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO device (id) VALUES ('fake-v1')")
    }

    /// Build a valid GRDB-origin NOOP DB that spans MULTIPLE pages, so a truncation fixture can cut
    /// real pages off while page 1 (magic + sqlite_master) stays perfectly readable (#1014).
    private func makeMultiPageNoopDatabase(at url: URL) throws {
        try makeNoopDatabase(at: url, deviceRows: [])
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        let filler = String(repeating: "x", count: 200)
        for i in 0..<200 {
            try exec(db, "INSERT INTO device (id, name) VALUES ('row-\(i)', '\(filler)')")
        }
    }

    /// Build a valid SQLite file that is NOT a NOOP/GRDB backup: it carries the Room marker and a
    /// `device` table but no `grdb_migrations`, so the origin gate must reject it.
    private func makeForeignDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO device (id) VALUES ('android-strap')")
    }

    private func deviceRows(in url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TestError("open (read) failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        return try deviceRows(using: db)
    }

    private func deviceRows(using db: OpaquePointer?) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM device ORDER BY id", -1, &stmt, nil) == SQLITE_OK else {
            throw TestError("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { rows.append(String(cString: c)) }
        }
        return rows.sorted()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TestError("exec failed (\(message)): \(sql)")
        }
    }

    private func isZip(_ url: URL) -> Bool {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4), head.count >= 4 else { return false }
        return Array(head).prefix(4) == [0x50, 0x4B, 0x03, 0x04]
    }

    private func hex<Bytes: DataProtocol>(_ bytes: Bytes) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private struct TestError: Error { let message: String; init(_ m: String) { message = m } }
}
