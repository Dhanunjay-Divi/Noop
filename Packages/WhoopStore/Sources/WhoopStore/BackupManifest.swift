import CryptoKit
import Foundation

/// Self-describing metadata for a `.noopbak` container.
///
/// The SQLite payload remains native to its database engine (GRDB on Apple, Room on Android), but
/// the outer ZIP contract is shared. A manifest lets either client reject a wrong-platform or
/// future-schema restore before opening SQLite, and gives plaintext folder snapshots the same
/// payload-integrity check as encrypted manual exports. Manifest-less backups remain valid legacy
/// inputs.
public struct BackupManifest: Codable, Equatable, Sendable {
    public static let entryName = "manifest.json"
    public static let formatName = "noop-backup"
    public static let formatVersion = 1

    public enum SourcePlatform: String, Codable, Sendable {
        case apple
        case android
    }

    public enum DatabaseEngine: String, Codable, Sendable {
        case grdb
        case room
    }

    public struct Payload: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String

        public init(path: String, bytes: Int64, sha256: String) {
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Payloads: Codable, Equatable, Sendable {
        public let database: Payload
        public let settings: Payload?

        public init(database: Payload, settings: Payload?) {
            self.database = database
            self.settings = settings
        }
    }

    public let format: String
    public let version: Int
    public let createdAtEpochMs: Int64
    public let sourcePlatform: SourcePlatform
    public let databaseEngine: DatabaseEngine
    public let databaseSchemaVersion: Int
    public let settingsSchemaVersion: Int?
    public let appVersion: String?
    public let payloads: Payloads

    public init(
        format: String = BackupManifest.formatName,
        version: Int = BackupManifest.formatVersion,
        createdAtEpochMs: Int64,
        sourcePlatform: SourcePlatform,
        databaseEngine: DatabaseEngine,
        databaseSchemaVersion: Int,
        settingsSchemaVersion: Int?,
        appVersion: String?,
        payloads: Payloads
    ) {
        self.format = format
        self.version = version
        self.createdAtEpochMs = createdAtEpochMs
        self.sourcePlatform = sourcePlatform
        self.databaseEngine = databaseEngine
        self.databaseSchemaVersion = databaseSchemaVersion
        self.settingsSchemaVersion = settingsSchemaVersion
        self.appVersion = appVersion
        self.payloads = payloads
    }

    public static func make(
        databaseAt databaseURL: URL,
        databaseEntryName: String,
        settingsData: Data?,
        settingsEntryName: String,
        createdAtEpochMs: Int64,
        sourcePlatform: SourcePlatform,
        databaseEngine: DatabaseEngine,
        databaseSchemaVersion: Int,
        settingsSchemaVersion: Int?,
        appVersion: String?
    ) throws -> BackupManifest {
        let database = try payload(fileAt: databaseURL, path: databaseEntryName)
        let settings = settingsData.map {
            Payload(path: settingsEntryName, bytes: Int64($0.count), sha256: sha256($0))
        }
        return BackupManifest(
            createdAtEpochMs: createdAtEpochMs,
            sourcePlatform: sourcePlatform,
            databaseEngine: databaseEngine,
            databaseSchemaVersion: databaseSchemaVersion,
            settingsSchemaVersion: settings == nil ? nil : settingsSchemaVersion,
            appVersion: appVersion,
            payloads: Payloads(database: database, settings: settings)
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> BackupManifest {
        try JSONDecoder().decode(BackupManifest.self, from: data)
    }

    /// Returns a user-facing incompatibility/integrity problem, or `nil` when the manifest and
    /// extracted payloads are valid for this client. This performs bounded streaming SHA-256 reads;
    /// the database is never loaded into memory.
    public func validationProblem(
        databaseAt databaseURL: URL,
        settingsAt settingsURL: URL?,
        expectedDatabaseEntryName: String,
        expectedSettingsEntryName: String,
        currentPlatform: SourcePlatform,
        currentDatabaseEngine: DatabaseEngine,
        currentDatabaseSchemaVersion: Int
    ) -> String? {
        guard format == Self.formatName else {
            return "This file uses an unknown NOOP backup format."
        }
        guard version == Self.formatVersion else {
            return "This backup uses unsupported container version \(version). Update NOOP and try again."
        }
        guard createdAtEpochMs >= 0, databaseSchemaVersion > 0 else {
            return "This backup manifest contains invalid version metadata."
        }
        guard sourcePlatform == currentPlatform, databaseEngine == currentDatabaseEngine else {
            let source = sourcePlatform == .apple ? "Apple" : "Android"
            let target = currentPlatform == .apple ? "Apple" : "Android"
            return "This is a \(source) full-device backup and cannot replace the \(target) database. Use NOOP's portable CSV export to move health history between platforms."
        }
        guard databaseSchemaVersion <= currentDatabaseSchemaVersion else {
            return "This backup was created by a newer NOOP database schema. Update NOOP before restoring it."
        }
        guard payloads.database.path == expectedDatabaseEntryName else {
            return "This backup manifest points to an unexpected database payload."
        }
        if let problem = Self.payloadProblem(payloads.database, fileAt: databaseURL) {
            return "The backup database \(problem)"
        }

        switch (payloads.settings, settingsURL) {
        case (nil, nil):
            guard settingsSchemaVersion == nil else {
                return "This backup manifest declares settings metadata without a settings payload."
            }
        case (nil, .some):
            return "This backup contains settings that are not covered by its integrity manifest."
        case (.some, nil):
            return "This backup is missing the settings payload declared by its manifest."
        case let (.some(settings), .some(url)):
            guard settings.path == expectedSettingsEntryName,
                  let settingsSchemaVersion, settingsSchemaVersion > 0 else {
                return "This backup manifest contains invalid settings metadata."
            }
            if let problem = Self.payloadProblem(settings, fileAt: url) {
                return "The backup settings \(problem)"
            }
        }
        return nil
    }

    private static func payload(fileAt url: URL, path: String) throws -> Payload {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return Payload(path: path, bytes: bytes, sha256: try sha256(fileAt: url))
    }

    private static func payloadProblem(_ payload: Payload, fileAt url: URL) -> String? {
        guard payload.bytes >= 0, isSHA256(payload.sha256) else {
            return "has invalid integrity metadata."
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = (attributes[.size] as? NSNumber)?.int64Value else {
            return "could not be read."
        }
        guard bytes == payload.bytes else {
            return "size does not match its integrity manifest."
        }
        guard let digest = try? sha256(fileAt: url), digest == payload.sha256 else {
            return "hash does not match its integrity manifest."
        }
        return nil
    }

    private static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
