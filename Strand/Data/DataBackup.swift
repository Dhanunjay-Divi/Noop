import Foundation
import CommonCrypto
import CryptoKit
import Darwin
import Security
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SQLite3
import UniformTypeIdentifiers
import WhoopStore
import ZIPFoundation

/// Full-database EXPORT / IMPORT for device migration.
///
/// NOOP keeps its database-backed history in one logical SQLite database
/// (`<AppSupport>/OpenWhoop/whoop.sqlite`, plus the `-wal`/`-shm` sidecars while the store is open).
/// Export uses SQLite's online-backup API to create a private, immutable standalone snapshot, then
/// wraps that snapshot in a ZIP written as `.noopbak`, alongside a
/// small `settings.json` entry (#1000) carrying the whitelisted profile/display settings (see
/// `BackupSettings`) so a restore also brings back weight/height/units, not just the rows.
/// ZIP deflate typically cuts a 100 MB+ SQLite backup to 10–20 MB. Manual Apple exports are then
/// protected by a versioned, passphrase-derived AES-256-GCM envelope. Folder/automatic snapshots
/// remain standard ZIP files because NOOP deliberately never stores a passphrase for unattended use.
///
/// Import detects the format by magic bytes: encrypted Apple envelope (`NOOPBAK\0`), ZIP
/// (`PK\x03\x04`), or legacy plain SQLite. An encrypted payload is authenticated into a unique
/// private staging directory first; only a complete successful decrypt reaches the existing ZIP /
/// SQLite validation and cold-launch staging path.
/// Old `.sqlite` / `.noopdb` backups keep working.
///
/// Sandbox-safe: relies on the `com.apple.security.files.user-selected.read-write` entitlement and
/// security-scoped access on the panel-returned URLs. Every path is best-effort — failures surface
/// as a `.failure` result and never crash.
enum DataBackup {
    private static let maxBackupSQLiteBytes: Int64 = 2_147_483_648
    private static let maxBackupSettingsBytes: Int64 = 1_048_576

    /// A streaming authenticated-encryption envelope for Apple `.noopbak` exports.
    ///
    /// Wire format v1 (all integers unsigned big-endian):
    ///
    /// ```
    ///  0  magic "NOOPBAK\0"       8 bytes
    ///  8  version / KDF / cipher / flags
    /// 12  PBKDF2 iterations        UInt32
    /// 16  plaintext chunk size     UInt32
    /// 20  plaintext ZIP length     UInt64
    /// 28  random salt              16 bytes
    /// 44  random nonce prefix       8 bytes
    /// 52  reserved zeros           12 bytes
    /// 64  repeated ciphertext chunk || 16-byte GCM tag
    /// ```
    ///
    /// Every chunk uses nonce `prefix(8) || chunkIndex(4)` and authenticates the entire header plus
    /// its index and plaintext length as AAD. The authenticated total length in the header makes a
    /// missing/reordered/appended chunk fail closed. CryptoKit's AES.GCM is one-shot, so independent
    /// bounded chunks give us its audited primitive without reading a multi-gigabyte backup into RAM.
    private enum EncryptedEnvelope {
        static let magic = Data([0x4E, 0x4F, 0x4F, 0x50, 0x42, 0x41, 0x4B, 0x00]) // NOOPBAK\0
        static let version: UInt8 = 1
        static let kdfPBKDF2SHA256: UInt8 = 1
        static let cipherChunkedAES256GCM: UInt8 = 1
        static let headerSize = 64
        static let saltSize = 16
        static let noncePrefixSize = 8
        static let tagSize = 16
        static let keySize = 32
        static let defaultIterations: UInt32 = 310_000
        static let minimumIterations: UInt32 = 100_000
        static let maximumIterations: UInt32 = 2_000_000
        static let defaultChunkSize = 1_048_576
        static let minimumChunkSize = 65_536
        static let maximumChunkSize = 8_388_608
        static let minimumPassphraseCharacters = 12
        /// Allows the maximum supported SQLite + settings payload and bounded ZIP metadata overhead.
        static let maximumPlaintextBytes = UInt64(maxBackupSQLiteBytes + maxBackupSettingsBytes)
            + UInt64(64 * 1_048_576)

        struct Header {
            let encoded: Data
            let iterations: UInt32
            let chunkSize: Int
            let plaintextLength: UInt64
            let salt: Data
            let noncePrefix: Data

            var chunkCount: UInt64 {
                (plaintextLength + UInt64(chunkSize) - 1) / UInt64(chunkSize)
            }
        }

        enum EnvelopeError: LocalizedError {
            case passphraseRequired
            case passphraseTooShort
            case randomGenerationFailed
            case invalidEnvelope
            case unsupportedVersion(Int)
            case payloadTooLarge
            case encryptionFailed
            case unlockFailed

            var errorDescription: String? {
                switch self {
                case .passphraseRequired:
                    return String(localized: "This backup is encrypted. Enter its passphrase to continue.")
                case .passphraseTooShort:
                    return String(localized: "Use a backup passphrase with at least 12 characters.")
                case .randomGenerationFailed:
                    return String(localized: "Couldn't generate secure encryption material for this backup.")
                case .invalidEnvelope:
                    return String(localized: "This encrypted backup has an invalid or incomplete envelope.")
                case .unsupportedVersion(let version):
                    return String(localized: "This encrypted backup uses unsupported format version \(version). Update NOOP and try again.")
                case .payloadTooLarge:
                    return String(localized: "This backup is too large to encrypt or restore safely.")
                case .encryptionFailed:
                    return String(localized: "Couldn't encrypt this backup. No partial backup was kept.")
                case .unlockFailed:
                    // Deliberately do not distinguish a wrong password from authentication damage.
                    return String(localized: "Couldn't unlock this encrypted backup. The passphrase is wrong or the file was changed or damaged. Your current data was left untouched.")
                }
            }
        }

        static func isEnvelope(at url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: magic.count) else { return false }
            return prefix == magic
        }

        static func encrypt(
            plaintextAt source: URL,
            to destination: URL,
            passphrase: String,
            salt suppliedSalt: Data? = nil,
            noncePrefix suppliedNoncePrefix: Data? = nil,
            iterations: UInt32 = defaultIterations,
            chunkSize: Int = defaultChunkSize
        ) throws {
            guard passphrase.count >= minimumPassphraseCharacters else {
                throw EnvelopeError.passphraseTooShort
            }
            guard minimumIterations...maximumIterations ~= iterations,
                  minimumChunkSize...maximumChunkSize ~= chunkSize else {
                throw EnvelopeError.invalidEnvelope
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
                  fileSize > 0, fileSize <= maximumPlaintextBytes else {
                throw EnvelopeError.payloadTooLarge
            }

            let salt = try suppliedSalt ?? secureRandom(count: saltSize)
            let noncePrefix = try suppliedNoncePrefix ?? secureRandom(count: noncePrefixSize)
            guard salt.count == saltSize, noncePrefix.count == noncePrefixSize else {
                throw EnvelopeError.invalidEnvelope
            }
            let header = try makeHeader(
                iterations: iterations,
                chunkSize: chunkSize,
                plaintextLength: fileSize,
                salt: salt,
                noncePrefix: noncePrefix
            )
            var keyBytes = try deriveKeyBytes(
                passphrase: passphrase, salt: salt, iterations: iterations)
            defer { keyBytes.resetBytes(in: 0..<keyBytes.count) }
            let key = SymmetricKey(data: keyBytes)

            let fm = FileManager.default
            let partial = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).encrypting-\(UUID().uuidString)")
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw EnvelopeError.encryptionFailed
            }
            DataBackup.applyPrivateTemporaryFileProtection(to: partial)
            var completed = false
            defer {
                if !completed { try? fm.removeItem(at: partial) }
            }

            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: partial)
            defer {
                try? input.close()
                try? output.close()
            }
            try output.write(contentsOf: header.encoded)

            var remaining = fileSize
            var chunkIndex: UInt32 = 0
            while remaining > 0 {
                let wanted = Int(min(UInt64(chunkSize), remaining))
                guard let plaintext = try input.read(upToCount: wanted), plaintext.count == wanted else {
                    throw EnvelopeError.encryptionFailed
                }
                let nonce = try nonce(prefix: noncePrefix, chunkIndex: chunkIndex)
                let aad = chunkAAD(header: header.encoded, index: chunkIndex, length: wanted)
                let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
                try output.write(contentsOf: sealed.ciphertext)
                try output.write(contentsOf: sealed.tag)
                remaining -= UInt64(wanted)
                guard chunkIndex < UInt32.max || remaining == 0 else {
                    throw EnvelopeError.payloadTooLarge
                }
                chunkIndex &+= 1
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
                throw EnvelopeError.encryptionFailed
            }
            try output.synchronize()
            try output.close()

            // `partial` is deliberately a sibling, so POSIX rename publishes it on the same volume.
            // rename(2) atomically replaces an existing regular file and, on failure, leaves that old
            // destination untouched. Never implement this as remove-then-move: a full disk, provider
            // error, or crash in that gap would destroy the user's last good backup.
            try DataBackup.atomicPublish(partial: partial, replacing: destination)
            completed = true
        }

        /// Authenticates and decrypts into a private sibling `.partial`, then atomically publishes the
        /// plaintext ZIP inside a unique app-temp directory. A wrong password or any tamper removes the
        /// partial and cannot reach DataBackup's pending-restore marker.
        static func decrypt(
            envelopeAt source: URL,
            to destination: URL,
            passphrase: String
        ) throws {
            guard !passphrase.isEmpty else { throw EnvelopeError.passphraseRequired }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard let headerData = try input.read(upToCount: headerSize),
                  headerData.count == headerSize else {
                throw EnvelopeError.invalidEnvelope
            }
            let header = try parseHeader(headerData)
            let sourceSize = ((try FileManager.default.attributesOfItem(atPath: source.path))[.size]
                as? NSNumber)?.uint64Value ?? 0
            let tagsLength = header.chunkCount.multipliedReportingOverflow(by: UInt64(tagSize))
            let totalLength = UInt64(headerSize).addingReportingOverflow(header.plaintextLength)
            guard !tagsLength.overflow, !totalLength.overflow else {
                throw EnvelopeError.invalidEnvelope
            }
            let expected = totalLength.partialValue.addingReportingOverflow(tagsLength.partialValue)
            guard !expected.overflow, expected.partialValue == sourceSize else {
                throw EnvelopeError.unlockFailed
            }

            var keyBytes = try deriveKeyBytes(
                passphrase: passphrase, salt: header.salt, iterations: header.iterations)
            defer { keyBytes.resetBytes(in: 0..<keyBytes.count) }
            let key = SymmetricKey(data: keyBytes)
            let fm = FileManager.default
            let partial = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).decrypting-\(UUID().uuidString)")
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw EnvelopeError.invalidEnvelope
            }
            DataBackup.applyPrivateTemporaryFileProtection(to: partial)
            var completed = false
            defer {
                if !completed { try? fm.removeItem(at: partial) }
            }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }

            do {
                var remaining = header.plaintextLength
                var chunkIndex: UInt32 = 0
                while remaining > 0 {
                    let length = Int(min(UInt64(header.chunkSize), remaining))
                    guard let ciphertext = try input.read(upToCount: length), ciphertext.count == length,
                          let tag = try input.read(upToCount: tagSize), tag.count == tagSize else {
                        throw EnvelopeError.unlockFailed
                    }
                    let nonce = try nonce(prefix: header.noncePrefix, chunkIndex: chunkIndex)
                    let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                    let aad = chunkAAD(header: header.encoded, index: chunkIndex, length: length)
                    let plaintext = try AES.GCM.open(sealed, using: key, authenticating: aad)
                    try output.write(contentsOf: plaintext)
                    remaining -= UInt64(length)
                    guard chunkIndex < UInt32.max || remaining == 0 else {
                        throw EnvelopeError.unlockFailed
                    }
                    chunkIndex &+= 1
                }
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
                    throw EnvelopeError.unlockFailed
                }
                try output.synchronize()
                try output.close()
                // Authentication is complete. Publish with the same same-volume atomic replacement as
                // encryption so a crash, provider error, or immutable destination cannot destroy an
                // older known-good staged plaintext file between remove and move.
                try DataBackup.atomicPublish(partial: partial, replacing: destination)
                completed = true
            } catch let error as EnvelopeError {
                throw error
            } catch {
                // CryptoKit deliberately exposes authentication failure. Collapse it with all other
                // post-header failures so UI and logs never become a password oracle.
                throw EnvelopeError.unlockFailed
            }
        }

        static func deriveKeyBytes(
            passphrase: String,
            salt: Data,
            iterations: UInt32
        ) throws -> Data {
            guard !passphrase.isEmpty, !salt.isEmpty, iterations > 0 else {
                throw EnvelopeError.invalidEnvelope
            }
            // Canonical composition prevents a visually identical Unicode passphrase from deriving a
            // different key after keyboard / OS normalization. The passphrase and key are never logged
            // or persisted; mutable byte buffers are zeroed before returning from their scope.
            var passwordBytes = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
            defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
            var derived = Data(repeating: 0, count: keySize)
            let passwordCount = passwordBytes.count
            let saltCount = salt.count
            let derivedCount = derived.count
            let status = passwordBytes.withUnsafeBytes { passwordRaw in
                salt.withUnsafeBytes { saltRaw in
                    derived.withUnsafeMutableBytes { derivedRaw in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordRaw.bindMemory(to: CChar.self).baseAddress,
                            passwordCount,
                            saltRaw.bindMemory(to: UInt8.self).baseAddress,
                            saltCount,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            iterations,
                            derivedRaw.bindMemory(to: UInt8.self).baseAddress,
                            derivedCount
                        )
                    }
                }
            }
            guard status == kCCSuccess else { throw EnvelopeError.encryptionFailed }
            return derived
        }

        private static func secureRandom(count: Int) throws -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            let status = bytes.withUnsafeMutableBytes { rawBuffer in
                SecRandomCopyBytes(kSecRandomDefault, count, rawBuffer.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw EnvelopeError.randomGenerationFailed
            }
            return Data(bytes)
        }

        private static func makeHeader(
            iterations: UInt32,
            chunkSize: Int,
            plaintextLength: UInt64,
            salt: Data,
            noncePrefix: Data
        ) throws -> Header {
            guard salt.count == saltSize, noncePrefix.count == noncePrefixSize,
                  plaintextLength > 0, plaintextLength <= maximumPlaintextBytes,
                  minimumIterations...maximumIterations ~= iterations,
                  minimumChunkSize...maximumChunkSize ~= chunkSize else {
                throw EnvelopeError.invalidEnvelope
            }
            var data = Data()
            data.reserveCapacity(headerSize)
            data.append(magic)
            data.append(contentsOf: [version, kdfPBKDF2SHA256, cipherChunkedAES256GCM, 0])
            appendUInt32(iterations, to: &data)
            appendUInt32(UInt32(chunkSize), to: &data)
            appendUInt64(plaintextLength, to: &data)
            data.append(salt)
            data.append(noncePrefix)
            data.append(Data(repeating: 0, count: headerSize - data.count))
            guard data.count == headerSize else { throw EnvelopeError.invalidEnvelope }
            return Header(encoded: data, iterations: iterations, chunkSize: chunkSize,
                          plaintextLength: plaintextLength, salt: salt, noncePrefix: noncePrefix)
        }

        private static func parseHeader(_ data: Data) throws -> Header {
            guard data.count == headerSize, data.prefix(magic.count) == magic else {
                throw EnvelopeError.invalidEnvelope
            }
            let envelopeVersion = data[8]
            guard envelopeVersion == version else {
                throw EnvelopeError.unsupportedVersion(Int(envelopeVersion))
            }
            guard data[9] == kdfPBKDF2SHA256,
                  data[10] == cipherChunkedAES256GCM,
                  data[11] == 0,
                  data[52..<headerSize].allSatisfy({ $0 == 0 }) else {
                throw EnvelopeError.invalidEnvelope
            }
            let iterations = readUInt32(data, at: 12)
            let chunkSize = Int(readUInt32(data, at: 16))
            let plaintextLength = readUInt64(data, at: 20)
            let salt = Data(data[28..<44])
            let noncePrefix = Data(data[44..<52])
            return try makeHeader(iterations: iterations, chunkSize: chunkSize,
                                  plaintextLength: plaintextLength, salt: salt,
                                  noncePrefix: noncePrefix)
        }

        private static func nonce(prefix: Data, chunkIndex: UInt32) throws -> AES.GCM.Nonce {
            var bytes = prefix
            appendUInt32(chunkIndex, to: &bytes)
            return try AES.GCM.Nonce(data: bytes)
        }

        private static func chunkAAD(header: Data, index: UInt32, length: Int) -> Data {
            var aad = header
            appendUInt32(index, to: &aad)
            appendUInt32(UInt32(length), to: &aad)
            return aad
        }

        private static func appendUInt32(_ value: UInt32, to data: inout Data) {
            var bigEndian = value.bigEndian
            Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        private static func appendUInt64(_ value: UInt64, to data: inout Data) {
            var bigEndian = value.bigEndian
            Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
            data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

    }

    /// Publish a fully-written sibling over `destination` with one same-volume POSIX rename. Existing
    /// regular files survive byte-for-byte when rename fails; callers own cleanup of `partial`.
    private static func atomicPublish(partial: URL, replacing destination: URL) throws {
        let outcome: (status: Int32, error: Int32) =
            partial.withUnsafeFileSystemRepresentation { sourcePath in
                guard let sourcePath else { return (-1, EINVAL) }
                return destination.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let destinationPath else { return (-1, EINVAL) }
                    let status = Darwin.rename(sourcePath, destinationPath)
                    return (status, status == 0 ? 0 : errno)
                }
            }
        guard outcome.status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: outcome.error) ?? .EIO)
        }
    }

    // MARK: - Result

    enum BackupResult {
        /// Export wrote the backup to `url`.
        case exported(URL)
        /// Import was validated and staged; a relaunch is required for it to take effect. `sidecar`
        /// is where the cold-launch apply will preserve the complete previous database (including any
        /// committed WAL rows), in case the user wants to roll back.
        case imported(sidecar: URL)
        /// The user dismissed the save/open panel — nothing happened, show nothing loud.
        case cancelled
        /// Something went wrong; `message` is user-facing.
        case failure(String)
    }

    // MARK: - Export

    /// Snapshot the live store and write it as a compressed, passphrase-encrypted `.noopbak` to a
    /// user-chosen file. The passphrase exists only for this call; callers must collect it explicitly,
    /// confirm it in UI, and discard their state after submission.
    ///
    /// - Parameter checkpoint: retained for source compatibility and invoked as a best-effort WAL
    ///   compaction. Correctness does not depend on it: another live pool can write immediately after
    ///   it, so the ZIP is always built from an SQLite online-backup snapshot that includes committed
    ///   WAL frames at one consistent instant.
    @MainActor
    static func runExport(
        checkpoint: @escaping () async -> Bool,
        passphrase: String
    ) async -> BackupResult {
        guard passphrase.count >= EncryptedEnvelope.minimumPassphraseCharacters else {
            return .failure(EncryptedEnvelope.EnvelopeError.passphraseTooShort.localizedDescription)
        }
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet. Import or record some first."))
        }

        // Best-effort compaction only. The immutable online-backup snapshot below is the correctness
        // boundary and remains complete if BLE/Repository writes more WAL frames after this returns.
        _ = await checkpoint()

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export NOOP backup")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = backupContentTypes()
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }

        do {
            // NSSavePanel already handled the "replace existing?" confirmation. Keep the old file in
            // place until EncryptedEnvelope's same-directory atomic rename publishes the new one.
            // Reading the whole SQLite and DEFLATE-compressing it is multi-second on a big library
            // (and #1014 added a quick_check read of the whole file first); run it off the main
            // actor so the UI never beach-balls. Only file paths cross the hop.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(
                    dbURL: dbURL,
                    to: dest,
                    settingsJSON: currentSettingsJSON(),
                    encryptionPassphrase: passphrase
                )
            }.value
            return .exported(dest)
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        #else
        let fm = FileManager.default

        // Stage the compressed backup in temp, then hand it to the share sheet.
        let staged = fm.temporaryDirectory.appendingPathComponent(defaultBackupName())
        do {
            // Keep a prior staged export until the authenticated replacement is ready to publish.
            // Off the main actor: same reason as the macOS branch (heavy read + DEFLATE). Only paths hop.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(
                    dbURL: dbURL,
                    to: staged,
                    settingsJSON: currentSettingsJSON(),
                    encryptionPassphrase: passphrase
                )
            }.value
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        let pickedDestination = await DocumentPicker.export(staged)
        if pickedDestination?.standardizedFileURL != staged.standardizedFileURL {
            try? fm.removeItem(at: staged)
        }
        guard let dest = pickedDestination else { return .cancelled }
        return .exported(dest)
        #endif
    }

    /// #1014 defence-in-depth (export side): the export's failure when the LIVE database itself is
    /// damaged. Thrown by `writeVerifiedBackupZip`; `LocalizedError` so the existing
    /// "Export failed: \(error.localizedDescription)" surfaces the specific, honest message.
    private struct ExportIntegrityFailure: LocalizedError {
        let complaint: String
        var errorDescription: String? {
            String(localized: "the NOOP database failed its integrity check (SQLite reports: \(complaint)). A backup of it would not restore. Export the WHOOP-format CSV (Settings → Export data) to save what's still readable.")
        }
    }

    /// The production export path: copy the logical live database (main + committed WAL frames) into
    /// a unique private file with SQLite's online-backup API, make that copy standalone, quick-check
    /// it, and archive only that immutable file. A second app-lifetime pool may keep writing while ZIP
    /// compression runs; those later commits belong to the next backup and cannot tear this one.
    /// Archiving an already-corrupt database writes a `.noopbak` that only fails the import-side gate
    /// months later, when the original may be gone, so the private snapshot is verified before zipping.
    /// `writeBackupForTesting` deliberately bypasses this so tests can build damaged containers.
    private static func writeVerifiedBackupZip(
        dbURL: URL,
        to dest: URL,
        settingsJSON: Data?,
        encryptionPassphrase: String? = nil,
        afterSnapshotInitialized: (() throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let snapshotDirectory = fm.temporaryDirectory
            .appendingPathComponent("noop-export-\(UUID().uuidString)", isDirectory: true)
        let snapshot = snapshotDirectory.appendingPathComponent("snapshot.sqlite")
        // Plaintext folder/automatic backups need the same last-known-good guarantee as encrypted
        // manual exports. Build a hidden sibling on the destination volume, then publish it with one
        // rename only after ZIP creation succeeds. Never stream directly into (or pre-delete) the old
        // archive: a full disk, provider error, or process exit must not destroy the user's prior backup.
        let plaintextArchive = encryptionPassphrase == nil
            ? dest.deletingLastPathComponent().appendingPathComponent(
                ".\(dest.lastPathComponent).writing-\(UUID().uuidString)")
            : snapshotDirectory.appendingPathComponent("plaintext.noopbak")
        try fm.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        applyPrivateTemporaryDirectoryProtection(to: snapshotDirectory)
        defer { try? fm.removeItem(at: snapshotDirectory) }

        do {
            try createStandaloneSnapshot(
                from: dbURL, to: snapshot, afterBackupInitialized: afterSnapshotInitialized)
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: snapshot.path) {
                throw ExportIntegrityFailure(complaint: complaint)
            }
            try writeBackupZip(dbURL: snapshot, to: plaintextArchive, settingsJSON: settingsJSON)
            if let encryptionPassphrase {
                try EncryptedEnvelope.encrypt(
                    plaintextAt: plaintextArchive,
                    to: dest,
                    passphrase: encryptionPassphrase
                )
            } else {
                try atomicPublish(partial: plaintextArchive, replacing: dest)
            }
        } catch {
            // ZIPFoundation creates its output before streaming entries. Remove only our work file;
            // `dest` remains the last known-good backup until atomic publication succeeds.
            try? fm.removeItem(at: plaintextArchive)
            throw error
        }
    }

    private struct SQLiteSnapshotFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Copy one consistent logical SQLite state. `sqlite3_backup` reads committed WAL pages through
    /// the source connection and writes a transactionally complete destination; it never copies the
    /// live main file byte-for-byte and never needs to stop the other app pool from writing.
    private static func createStandaloneSnapshot(
        from sourceURL: URL,
        to destinationURL: URL,
        afterBackupInitialized: (() throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = destinationURL.path + suffix
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }

        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &source,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = sqliteErrorMessage(source)
            sqlite3_close(source)
            throw SQLiteSnapshotFailure(message: "Couldn't open the live database for a backup snapshot: \(detail)")
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(destinationURL.path, &destination,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            let detail = sqliteErrorMessage(destination)
            sqlite3_close(destination)
            throw SQLiteSnapshotFailure(message: "Couldn't create the private backup snapshot: \(detail)")
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(source, 5_000)
        sqlite3_busy_timeout(destination, 5_000)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteSnapshotFailure(
                message: "Couldn't initialize the private backup snapshot: \(sqliteErrorMessage(destination))")
        }
        var backupFinished = false
        defer { if !backupFinished { sqlite3_backup_finish(backup) } }

        try afterBackupInitialized?()
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        backupFinished = true
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw SQLiteSnapshotFailure(message:
                "Couldn't complete the private backup snapshot (step=\(stepResult), finish=\(finishResult)): \(sqliteErrorMessage(destination))")
        }

        // A backup destination normally starts in DELETE mode. Assert it explicitly so the ZIP's one
        // SQLite entry never depends on a private -wal/-shm sibling.
        let journalMode = try sqliteTextResult(destination, sql: "PRAGMA journal_mode=DELETE")
        guard journalMode.lowercased() == "delete" else {
            throw SQLiteSnapshotFailure(message:
                "Couldn't make the private backup snapshot standalone (journal_mode=\(journalMode)).")
        }
    }

    private static func sqliteTextResult(_ db: OpaquePointer?, sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteSnapshotFailure(message: "SQLite snapshot verification failed: \(sqliteErrorMessage(db))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw SQLiteSnapshotFailure(message: "SQLite snapshot verification returned no result.")
        }
        return String(cString: value)
    }

    private static func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown SQLite error" }
        return String(cString: message)
    }

    /// Write the live SQLite at `dbURL` into a fresh deflate ZIP at `dest`: the DB under the canonical
    /// entry name `noop-backup.sqlite`, plus (#1000) an optional second entry `settings.json` carrying
    /// the whitelisted profile/display settings, so a restore brings back weight/height/units and not
    /// just the rows. Entry names, entry ORDER (DB first — older importers stop at the first `.sqlite`
    /// entry) and deflate compression match the Android exporter byte-for-byte at the container level,
    /// so a `.noopbak` produced on either platform imports on the other. `settingsJSON == nil` writes
    /// the legacy single-entry ZIP. Mirrors the `Archive` idiom in `WhoopCsvExporter`.
    private static func writeBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try archive.addEntry(with: backupEntryName, fileURL: dbURL, compressionMethod: .deflate)
        guard let settingsJSON else { return }
        // Stage the JSON through a temp file so the settings entry uses the exact same file-URL
        // addEntry idiom as the DB entry (one container code path, no provider-API variant to drift).
        let fm = FileManager.default
        let tmpJSON = fm.temporaryDirectory
            .appendingPathComponent("noop-settings-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: tmpJSON) }
        try settingsJSON.write(to: tmpJSON)
        applyPrivateTemporaryFileProtection(to: tmpJSON)
        try archive.addEntry(with: BackupSettings.entryName, fileURL: tmpJSON, compressionMethod: .deflate)
    }

    /// This device's whitelisted profile/display settings (see `BackupSettings.whitelist`) as the
    /// `settings.json` payload, or nil when nothing whitelisted was ever set (a fresh install then
    /// exports a legacy DB-only ZIP, which is the right degrade). UserDefaults is thread-safe, so
    /// the detached export tasks may call this off the main actor.
    private static func currentSettingsJSON() -> Data? {
        BackupSettings.encode(BackupSettings.snapshot(from: .standard))
    }

    /// (Backup & Sync) Write a `.noopbak` to a SPECIFIC `dest` URL with NO save panel: the folder /
    /// auto-backup path. It writes the same immutable online-backup snapshot and deflate ZIP that sits
    /// inside a manual encrypted export, but deliberately does NOT add the Apple encryption envelope:
    /// unattended backup cannot use a passphrase without persisting it. The CALLER owns any
    /// security-scoped access to `dest`
    /// (start/stop around this call). Never presents UI, so it is safe off the main actor.
    static func writeBackup(checkpoint: @escaping () async -> Bool, to dest: URL) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet."))
        }
        // Retained as best-effort compaction for source compatibility. The online backup below is what
        // makes the archive complete if another pool writes before or during export.
        _ = await checkpoint()
        do {
            try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            return .exported(dest)
        } catch {
            return .failure(String(localized: "Backup failed: \(error.localizedDescription)"))
        }
    }

    /// Test seam: write a `.noopbak` for an EXPLICIT source database (no checkpoint, no `StorePaths`),
    /// so a unit test can round-trip a throwaway SQLite through the exact ZIP container the app writes.
    /// `settings` (canonical `BackupSettings` keys) adds the `settings.json` entry; nil writes the
    /// legacy single-entry ZIP — tests cover both shapes. Not used by app code; production goes
    /// through `writeBackup(checkpoint:to:)`.
    static func writeBackupForTesting(databaseAt dbURL: URL, to dest: URL,
                                      settings: [String: Any]? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try writeBackupZip(dbURL: dbURL, to: dest,
                           settingsJSON: settings.flatMap { BackupSettings.encode($0) })
    }

    /// Test seam for the production encrypted container, including the real ZIP/settings payload.
    static func writeEncryptedBackupForTesting(
        databaseAt dbURL: URL,
        to dest: URL,
        passphrase: String,
        settings: [String: Any]? = nil
    ) throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("noop-encrypted-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let plaintext = directory.appendingPathComponent("plaintext.noopbak")
        try writeBackupZip(
            dbURL: dbURL,
            to: plaintext,
            settingsJSON: settings.flatMap { BackupSettings.encode($0) }
        )
        try EncryptedEnvelope.encrypt(
            plaintextAt: plaintext, to: dest, passphrase: passphrase)
    }

    /// Deterministic primitive seams for golden vectors; production never supplies salt/nonces.
    static func encryptFileForTesting(
        plaintextAt source: URL,
        to destination: URL,
        passphrase: String,
        salt: Data,
        noncePrefix: Data,
        iterations: UInt32 = EncryptedEnvelope.minimumIterations,
        chunkSize: Int = EncryptedEnvelope.minimumChunkSize
    ) throws {
        try EncryptedEnvelope.encrypt(
            plaintextAt: source,
            to: destination,
            passphrase: passphrase,
            salt: salt,
            noncePrefix: noncePrefix,
            iterations: iterations,
            chunkSize: chunkSize
        )
    }

    static func decryptFileForTesting(
        envelopeAt source: URL,
        to destination: URL,
        passphrase: String
    ) throws {
        try EncryptedEnvelope.decrypt(
            envelopeAt: source, to: destination, passphrase: passphrase)
    }

    static func deriveBackupKeyForTesting(
        passphrase: String,
        salt: Data,
        iterations: UInt32
    ) throws -> Data {
        try EncryptedEnvelope.deriveKeyBytes(
            passphrase: passphrase, salt: salt, iterations: iterations)
    }

    static func isEncryptedBackupForTesting(_ url: URL) -> Bool {
        EncryptedEnvelope.isEnvelope(at: url)
    }

    /// Test seam for the exact production snapshot path. The hook runs after `sqlite3_backup_init`
    /// and before pages are copied, allowing a second WAL connection to commit deterministically.
    static func writeSnapshotBackupForTesting(
        databaseAt dbURL: URL,
        to dest: URL,
        afterSnapshotInitialized: (() throws -> Void)? = nil
    ) throws {
        try writeVerifiedBackupZip(
            dbURL: dbURL,
            to: dest,
            settingsJSON: nil,
            afterSnapshotInitialized: afterSnapshotInitialized)
    }

    // MARK: - Import

    /// Pick a `.noopbak` (ZIP) or legacy `.sqlite` backup, validate it, and stage a private standalone
    /// restore candidate. The live database is not opened, checkpointed, copied, removed, or replaced
    /// here: Repository and BLE each own a live GRDB pool, so swapping the file in-session would leave
    /// stale handles on an unlinked inode. The process-wide WhoopStore open gate applies the candidate
    /// before either pool opens on the next launch.
    @MainActor
    static func runImport(passphrase: String? = nil) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import NOOP backup")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = backupContentTypes()

        guard panel.runModal() == .OK, let pickedSource = panel.url else { return .cancelled }

        let scoped = pickedSource.startAccessingSecurityScopedResource()
        defer { if scoped { pickedSource.stopAccessingSecurityScopedResource() } }
        #else
        // iOS: pick the backup through the system document picker (asCopy gives us a readable local
        // copy in our temp dir, so no security-scoped bookkeeping is needed).
        guard let pickedSource = await DocumentPicker.importFile(backupContentTypes()) else { return .cancelled }
        #endif

        // Hand the chosen file to the same hardened restore core the folder (Backup & Sync) path uses,
        // so the unzip / magic-byte / GRDB-origin / pending-candidate logic lives in one place.
        // The restore does heavy synchronous file work (unzip, normalize the whole DB, scan
        // sqlite_master, integrity-check), which can run tens of seconds on a big library. Push it off the main
        // actor so the picker's UI thread stays live; the security-scoped access opened above (macOS)
        // stays valid because the surrounding function is still awaiting here. Only Sendable value
        // types (URL, String) cross the hop; the result hops back to main for handleBackup.
        return await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath, passphrase: passphrase)
        }.value
    }

    /// Restore a chosen backup file directly, with NO picker. The Backup & Sync folder flow calls this
    /// with a snapshot it already resolved from the user's backup folder (the caller owns any
    /// security-scoped access around the call). Runs against the live database path.
    ///
    /// Reuses the exact same hardened path as the picker import: ZIP extraction, SQLite magic-byte
    /// validation, GRDB-origin rejection (a foreign-but-valid SQLite is refused), and a private pending
    /// candidate. The live database remains untouched until the next cold launch.
    static func restore(from pickedSource: URL, passphrase: String? = nil) -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        return restore(from: pickedSource, toDatabaseAt: dbPath, passphrase: passphrase)
    }

    /// The hardened staging core, with the destination database path injected so it is unit-testable
    /// against a throwaway DB (real file I/O, never the user's live store). A successful return means the
    /// candidate is ready; `PendingDatabaseRestore.applyIfPresent` performs the cold-launch transaction.
    static func restore(
        from pickedSource: URL,
        toDatabaseAt dbPath: String,
        passphrase: String? = nil
    ) -> BackupResult {
        // Encrypted Apple envelopes never feed unauthenticated bytes into ZIPFoundation or SQLite.
        // Decrypt into a unique private directory, atomically publish the complete plaintext ZIP there,
        // then recurse through the exact legacy validation/staging core. On any failure the live DB and
        // pending-restore marker are untouched and the temporary plaintext is removed.
        if EncryptedEnvelope.isEnvelope(at: pickedSource) {
            guard let passphrase, !passphrase.isEmpty else {
                return .failure(EncryptedEnvelope.EnvelopeError.passphraseRequired.localizedDescription)
            }
            let fm = FileManager.default
            let decryptDirectory = fm.temporaryDirectory
                .appendingPathComponent("noop-decrypt-\(UUID().uuidString)", isDirectory: true)
            let decrypted = decryptDirectory.appendingPathComponent("authenticated.noopbak")
            do {
                try fm.createDirectory(at: decryptDirectory, withIntermediateDirectories: true)
                applyPrivateTemporaryDirectoryProtection(to: decryptDirectory)
                defer { try? fm.removeItem(at: decryptDirectory) }
                try EncryptedEnvelope.decrypt(
                    envelopeAt: pickedSource,
                    to: decrypted,
                    passphrase: passphrase
                )
                return restore(from: decrypted, toDatabaseAt: dbPath, passphrase: nil)
            } catch {
                return .failure(error.localizedDescription)
            }
        }

        // If the picked file is a .noopbak ZIP, extract the SQLite entry to a temp dir first.
        // Legacy plain-SQLite files fall straight through. The extracted dir is cleaned up below.
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = fm.temporaryDirectory
                .appendingPathComponent("noop-import-\(UUID().uuidString)", isDirectory: true)
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract)
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "Couldn't open the backup archive: \(error.localizedDescription)"))
            }
            guard let sqliteEntry = (try? fm.contentsOfDirectory(
                at: tmpExtract, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "sqlite" }) else {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "The backup archive doesn't contain a database file."))
            }
            source = sqliteEntry
            extractedDir = tmpExtract
        } else {
            source = pickedSource
            extractedDir = nil
        }
        defer { if let d = extractedDir { try? fm.removeItem(at: d) } }

        // Validate: must be a real SQLite database (magic header "SQLite format 3\0").
        guard isSQLiteFile(at: source) else {
            return .failure(String(localized: "That file isn't a NOOP backup. It doesn't look like a SQLite database."))
        }

        // Reject any backup that isn't a clean GRDB (this-app) backup. The magic check passes for ANY
        // SQLite file, so an Android (Room) backup — or any other SQLite file that happens to carry our
        // table names without our `grdb_migrations` bookkeeping — would otherwise replace the live DB
        // and leave the migrator re-running v1 forever (`table "device" already exists`, #222). A valid
        // NOOP-Mac/iOS backup always carries `grdb_migrations`; reject everything else that holds data.
        let backupTables = sqliteTableNames(at: source)
        let origin = backupOrigin(of: backupTables)
        let holdsData = backupTables.contains("device") || backupTables.contains("hrSample")
        if origin == .android || (origin == .unknown && holdsData) {
            return .failure(String(localized: "This isn't a NOOP backup from this app. It's missing the migration bookkeeping a NOOP backup carries (it looks like an Android backup or another app's database), and restoring it would strand your store. To move your history across platforms, export the WHOOP-format CSV on the other device (Settings → Export data) and import that here, or import your original WHOOP / Apple Health export."))
        }

        // #1014 defence-in-depth: both gates above read only the FIRST pages of the file — the
        // 16-byte magic and sqlite_master both survive a backup that was truncated mid-upload or
        // torn by a flaky drive/cloud sync, and such a file then "restores" into a store that
        // silently shows no data (the #1014 report; the #1000 settings code was exonerated, the
        // family needed armour). Run SQLite's own `PRAGMA quick_check` over the STAGED file,
        // read-only, BEFORE anything stages the candidate, and refuse it honestly.
        // One carve-out: a legacy plain-SQLite file still travelling with its -wal/-shm siblings
        // (an uncheckpointed manual copy) skips THIS gate — a read-only probe can't recover someone
        // else's WAL (shm rebuild needs write access) and would refuse spuriously. Those rare files
        // are normalized with their sidecars into the private pending candidate below, and that complete
        // candidate gets its own quick_check before the manifest is published.
        let legacySidecarsPresent = extractedDir == nil
            && (fm.fileExists(atPath: source.path + "-wal") || fm.fileExists(atPath: source.path + "-shm"))
        if !legacySidecarsPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return .failure(String(localized: "This backup file is damaged and can't be restored (SQLite reports: \(complaint)). Your current data was left untouched. Try an earlier backup file."))
        }

        let dbURL = URL(fileURLWithPath: dbPath)
        let sidecar = dbURL.deletingLastPathComponent().appendingPathComponent(
            "whoop-replaced-\(timestamp())-\(UUID().uuidString.prefix(8)).sqlite")

        // Filter settings NOW, but do not apply them now. They travel with the pending candidate and are
        // written to UserDefaults only after the cold-launch database transaction passes its post-check.
        let pendingSettingsJSON: Data? = extractedDir.flatMap { directory in
            let settingsURL = directory.appendingPathComponent(BackupSettings.entryName)
            guard let data = try? Data(contentsOf: settingsURL) else { return nil }
            return BackupSettings.encode(BackupSettings.decode(data))
        }

        do {
            try PendingDatabaseRestore.stage(
                databaseAt: source.path,
                settingsJSON: pendingSettingsJSON,
                forDatabaseAt: dbPath,
                safetySnapshot: sidecar)
            return .imported(sidecar: sidecar)
        } catch {
            return .failure(String(localized: "Import failed while staging the restore. Your existing data was kept. \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    /// Canonical entry name for the SQLite inside a plaintext `.noopbak` ZIP. Matches the Android
    /// exporter so a plaintext backup produced on either platform restores on the other. Manual Apple
    /// export wraps this exact ZIP in its authenticated envelope after compression.
    private static let backupEntryName = "noop-backup.sqlite"

    private enum BackupArchiveError: LocalizedError {
        case entryTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let name):
                return "\(name) is too large to restore safely."
            }
        }
    }

    /// "NOOP-backup-2026-06-07.noopbak"
    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "NOOP-backup-\(f.string(from: Date())).noopbak"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Content types accepted by the export/import panels. Includes the new `.noopbak` (ZIP),
    /// generic ZIP, and legacy `.sqlite` / `.database` types so older backups keep working.
    private static func backupContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let noopbak = UTType(filenameExtension: "noopbak") { types.append(noopbak) }
        types.append(.zip)
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    private static func applyPrivateTemporaryDirectoryProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #else
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #endif
    }

    /// Apply the strongest protection available to transient plaintext backup material. The manual
    /// export ZIP/settings and decrypt output live only inside private temp paths, but this is an
    /// additional guard against another local process/user reading them before cleanup.
    private static func applyPrivateTemporaryFileProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #else
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    /// Which platform produced a NOOP backup, judged by its migrator's bookkeeping table.
    enum BackupOrigin: Equatable { case mac, android, unknown }

    /// Pure classification over a backup's `sqlite_master` table names: GRDB (this app) writes
    /// `grdb_migrations`, Room (the Android app) writes `room_master_table`. `.unknown` (neither —
    /// an empty or pre-migration file) falls through to the normal import path, where the
    /// open-time migrator decides. Mirrors the Android `DataBackup.backupOriginOf`.
    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        // This platform's marker wins on the (degenerate) both-present case: restoring here is the
        // less destructive read.
        if tableNames.contains("grdb_migrations") { return .mac }
        if tableNames.contains("room_master_table") { return .android }
        // Older Room layouts didn't carry `room_master_table`; treat the Room/AndroidX duo of
        // `android_metadata` + an internal `sqlite_sequence` as an Android backup too.
        if tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence") {
            return .android
        }
        return .unknown
    }

    /// Every table name in a SQLite file, opened READ-ONLY through the system SQLite so the probed
    /// file is never mutated. Returns an empty set on any failure — the caller treats that as
    /// `.unknown` and falls through to the existing behaviour.
    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    /// Read the first 4 bytes and check for the ZIP PK magic (`PK\x03\x04`).
    private static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    /// Extract only the canonical entries from a `.noopbak` ZIP at `zipURL` into `destDir`.
    /// Unknown files are ignored, and each accepted entry is streamed through an uncompressed-size cap
    /// before it lands on disk.
    private static func extractBackupZip(at zipURL: URL, into destDir: URL) throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            let limit: Int64
            switch name {
            case backupEntryName:
                limit = maxBackupSQLiteBytes
            case BackupSettings.entryName:
                limit = maxBackupSettingsBytes
            default:
                continue
            }
            let out = destDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var written: Int64 = 0
            _ = try archive.extract(entry) { data in
                let next = written + Int64(data.count)
                guard next <= limit else {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: out)
                    throw BackupArchiveError.entryTooLarge(name)
                }
                try handle.write(contentsOf: data)
                written = next
            }
        }
    }

    /// Read the first 16 bytes and check for the SQLite magic header.
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        // "SQLite format 3" + NUL terminator.
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

}
