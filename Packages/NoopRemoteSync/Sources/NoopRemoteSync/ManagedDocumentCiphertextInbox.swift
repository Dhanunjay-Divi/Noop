import CryptoKit
import Foundation

public enum ManagedDocumentCiphertextInboxError: Error, Equatable {
    case invalidRecord
    case quotaExceeded
    case unavailable
}

public struct ManagedDocumentCiphertextInboxPolicy: Equatable, Sendable {
    public let maximumRecordCount: Int
    public let maximumTotalBytes: Int64
    public let maximumAgeMilliseconds: Int64

    public init(
        maximumRecordCount: Int = 512,
        maximumTotalBytes: Int64 = 64 * 1_024 * 1_024,
        maximumAgeMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
    ) {
        precondition(maximumRecordCount > 0)
        precondition(maximumTotalBytes > 0)
        precondition(maximumAgeMilliseconds > 0)
        self.maximumRecordCount = maximumRecordCount
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
    }

    public static let standard = ManagedDocumentCiphertextInboxPolicy()
}

public enum ManagedDocumentCiphertextInboxLegacyDisposition:
    String,
    Equatable,
    Sendable
{
    case none
    case migrated
    case purgedUnattributable = "purged_unattributable"
}

public enum ManagedDocumentCiphertextInboxSweepDisposition:
    String,
    Equatable,
    Sendable
{
    case clean
    case invalidPurged = "invalid_purged"
    case stalePurged = "stale_purged"
    case quotaTrimmed = "quota_trimmed"
    case multiple
}

public struct ManagedDocumentCiphertextInboxMaintenanceResult:
    Equatable,
    Sendable
{
    public let legacyDisposition:
        ManagedDocumentCiphertextInboxLegacyDisposition
    public let sweepDisposition:
        ManagedDocumentCiphertextInboxSweepDisposition

    public init(
        legacyDisposition:
            ManagedDocumentCiphertextInboxLegacyDisposition,
        sweepDisposition:
            ManagedDocumentCiphertextInboxSweepDisposition
    ) {
        self.legacyDisposition = legacyDisposition
        self.sweepDisposition = sweepDisposition
    }
}

public enum ManagedDocumentCiphertextInboxPurgeDisposition:
    String,
    Equatable,
    Sendable
{
    case notPresent = "not_present"
    case removed
}

public actor ManagedDocumentCiphertextInbox {
    private struct Record: Codable, Equatable {
        let version: Int
        let direction: String
        let accountScopeHash: String
        let identity: String
        let documentKind: String
        let documentID: UUID
        let revision: Int64
        let keyID: UUID
        let plaintextSHA256: String?
        let contentSHA256: String
        let ciphertextBase64: String
        let stagedAtMilliseconds: Int64
    }

    private struct StoredEntry {
        let url: URL
        let data: Data
        let record: Record
        let byteCount: Int64
    }

    private enum LegacyInspection {
        case empty
        case safe([StoredEntry])
        case unsafe
    }

    private let root: URL
    private let configuredAccountScopeHash: String?
    private let policy: ManagedDocumentCiphertextInboxPolicy
    private let fileManager: FileManager
    private let clock: @Sendable () -> Int64
    private var boundAccountScopeHash: String?
    private var prepared = false

    public init(
        root: URL,
        accountScopeHash: String? = nil,
        policy: ManagedDocumentCiphertextInboxPolicy = .standard,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        }
    ) {
        self.root = root
        configuredAccountScopeHash = accountScopeHash
        self.policy = policy
        self.fileManager = fileManager
        self.clock = clock
    }

    public func startupMaintenance(
        accountScopeHash: String? = nil
    ) throws -> ManagedDocumentCiphertextInboxMaintenanceResult {
        let scope = try bind(accountScopeHash)
        let result = try performMaintenance(accountScopeHash: scope)
        prepared = true
        return result
    }

    public nonisolated static func purgeAccount(
        root: URL,
        accountScopeHash: String,
        fileManager: FileManager = .default
    ) throws -> ManagedDocumentCiphertextInboxPurgeDisposition {
        guard isValidAccountScopeHash(accountScopeHash) else {
            throw ManagedDocumentCiphertextInboxError.invalidRecord
        }

        var legacyMatches: [URL] = []
        for direction in ["incoming", "outgoing"] {
            let directory = legacyDirectory(
                root: root,
                direction: direction
            )
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ]
                )
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
            for file in files {
                guard let entry = validatedEntry(
                    at: file,
                    direction: direction,
                    expectedAccountScopeHash: nil,
                    maximumBytes:
                        ManagedDocumentCiphertextInboxPolicy.standard
                            .maximumTotalBytes,
                    fileManager: fileManager
                ) else {
                    throw ManagedDocumentCiphertextInboxError.invalidRecord
                }
                if entry.record.accountScopeHash == accountScopeHash {
                    legacyMatches.append(file)
                }
            }
        }

        var removed = false
        let accountRoot = accountRoot(
            root: root,
            accountScopeHash: accountScopeHash
        )
        if fileManager.fileExists(atPath: accountRoot.path) {
            do {
                try fileManager.removeItem(at: accountRoot)
                removed = true
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
        }

        for file in legacyMatches {
            do {
                try fileManager.removeItem(at: file)
                removed = true
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
        }
        do {
            try removeEmptyLegacyDirectories(
                root: root,
                fileManager: fileManager
            )
            try removeDirectoryIfEmpty(
                root.appendingPathComponent("accounts", isDirectory: true),
                fileManager: fileManager
            )
        } catch {
            throw ManagedDocumentCiphertextInboxError.unavailable
        }
        return removed ? .removed : .notPresent
    }

    public func stageIncoming(
        accountScopeHash: String,
        document: ManagedDocument
    ) throws {
        let scope = try prepareIfNeeded(accountScopeHash)
        guard document.contentMode == "client_encrypted",
              document.deletedAt == nil,
              let keyID = document.clientKeyID,
              let encoded = document.payloadCiphertextBase64,
              let ciphertext = Data(base64Encoded: encoded),
              ciphertext.base64EncodedString() == encoded,
              ManagedDocumentEnvelopeDigest.sha256(ciphertext)
                == document.contentSHA256 else {
            throw ManagedDocumentCiphertextInboxError.invalidRecord
        }
        let identity = incomingIdentity(
            accountScopeHash: scope,
            document: document
        )
        try write(
            Record(
                version: 1,
                direction: "incoming",
                accountScopeHash: scope,
                identity: identity,
                documentKind: document.documentKind.rawValue,
                documentID: document.documentID,
                revision: document.revision,
                keyID: keyID,
                plaintextSHA256: nil,
                contentSHA256: document.contentSHA256,
                ciphertextBase64: encoded,
                stagedAtMilliseconds: max(0, clock())
            ),
            at: url(
                accountScopeHash: scope,
                direction: "incoming",
                identity: identity
            )
        )
    }

    public func removeIncoming(
        accountScopeHash: String,
        document: ManagedDocument
    ) throws {
        let scope = try prepareIfNeeded(accountScopeHash)
        try remove(
            url(
                accountScopeHash: scope,
                direction: "incoming",
                identity: incomingIdentity(
                    accountScopeHash: scope,
                    document: document
                )
            ),
            accountScopeHash: scope
        )
    }

    public func outgoingEnvelope(
        accountScopeHash: String,
        localIdentifier: String,
        generation: Int64,
        documentKind: ManagedDocumentKind,
        documentID: UUID,
        revision: Int64,
        key: ManagedDocumentKey,
        plaintext: Data
    ) throws -> Data {
        let scope = try prepareIfNeeded(accountScopeHash)
        let identity = outgoingIdentity(
            accountScopeHash: scope,
            localIdentifier: localIdentifier,
            generation: generation,
            revision: revision
        )
        let destination = url(
            accountScopeHash: scope,
            direction: "outgoing",
            identity: identity
        )
        if let record = try read(
            destination,
            direction: "outgoing",
            accountScopeHash: scope
        ) {
            guard record.direction == "outgoing",
                  record.accountScopeHash == scope,
                  record.identity == identity,
                  record.documentKind == documentKind.rawValue,
                  record.documentID == documentID,
                  record.revision == revision,
                  record.keyID == key.keyID,
                  record.plaintextSHA256
                    == ManagedDocumentEnvelopeDigest.sha256(plaintext),
                  let ciphertext = Data(
                      base64Encoded: record.ciphertextBase64
                  ),
                  ciphertext.base64EncodedString()
                    == record.ciphertextBase64,
                  ManagedDocumentEnvelopeDigest.sha256(ciphertext)
                    == record.contentSHA256 else {
                throw ManagedDocumentCiphertextInboxError.invalidRecord
            }
            return ciphertext
        }
        let metadata = try ManagedDocumentEnvelopeMetadata(
            accountScopeHash: scope,
            documentKind: documentKind,
            documentID: documentID,
            revision: revision
        )
        let ciphertext = try ManagedDocumentEnvelope.seal(
            plaintext,
            key: key.keyData,
            metadata: metadata
        )
        try write(
            Record(
                version: 1,
                direction: "outgoing",
                accountScopeHash: scope,
                identity: identity,
                documentKind: documentKind.rawValue,
                documentID: documentID,
                revision: revision,
                keyID: key.keyID,
                plaintextSHA256:
                    ManagedDocumentEnvelopeDigest.sha256(plaintext),
                contentSHA256:
                    ManagedDocumentEnvelopeDigest.sha256(ciphertext),
                ciphertextBase64: ciphertext.base64EncodedString(),
                stagedAtMilliseconds: max(0, clock())
            ),
            at: destination
        )
        return ciphertext
    }

    public func removeOutgoing(
        accountScopeHash: String,
        localIdentifier: String,
        generation: Int64,
        revision: Int64
    ) throws {
        let scope = try prepareIfNeeded(accountScopeHash)
        try remove(
            url(
                accountScopeHash: scope,
                direction: "outgoing",
                identity: outgoingIdentity(
                    accountScopeHash: scope,
                    localIdentifier: localIdentifier,
                    generation: generation,
                    revision: revision
                )
            ),
            accountScopeHash: scope
        )
    }

    public func pendingIncomingCount() throws -> Int {
        try pendingCount(direction: "incoming")
    }

    public func pendingOutgoingCount() throws -> Int {
        try pendingCount(direction: "outgoing")
    }

    private func bind(_ accountScopeHash: String?) throws -> String {
        let selected = accountScopeHash
            ?? configuredAccountScopeHash
            ?? boundAccountScopeHash
        guard let selected,
              Self.isValidAccountScopeHash(selected),
              configuredAccountScopeHash == nil
                || configuredAccountScopeHash == selected,
              boundAccountScopeHash == nil
                || boundAccountScopeHash == selected else {
            throw ManagedDocumentCiphertextInboxError.invalidRecord
        }
        boundAccountScopeHash = selected
        return selected
    }

    private func prepareIfNeeded(_ accountScopeHash: String) throws -> String {
        let scope = try bind(accountScopeHash)
        if !prepared {
            _ = try performMaintenance(accountScopeHash: scope)
            prepared = true
        }
        return scope
    }

    private func performMaintenance(
        accountScopeHash: String
    ) throws -> ManagedDocumentCiphertextInboxMaintenanceResult {
        let legacy = try migrateLegacySharedStorage(
            accountScopeHash: accountScopeHash
        )
        let sweep = try sweepScopedStorage(
            accountScopeHash: accountScopeHash
        )
        return ManagedDocumentCiphertextInboxMaintenanceResult(
            legacyDisposition: legacy,
            sweepDisposition: sweep
        )
    }

    private func migrateLegacySharedStorage(
        accountScopeHash: String
    ) throws -> ManagedDocumentCiphertextInboxLegacyDisposition {
        let inspection = try inspectLegacySharedStorage(
            accountScopeHash: accountScopeHash
        )
        switch inspection {
        case .empty:
            do {
                try Self.removeEmptyLegacyDirectories(
                    root: root,
                    fileManager: fileManager
                )
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
            return .none
        case .unsafe:
            try purgeLegacySharedStorage()
            return .purgedUnattributable
        case .safe(let entries):
            for entry in entries {
                let destination = url(
                    accountScopeHash: accountScopeHash,
                    direction: entry.record.direction,
                    identity: entry.record.identity
                )
                if fileManager.fileExists(atPath: destination.path) {
                    guard (try? Data(contentsOf: destination)) == entry.data else {
                        try purgeLegacySharedStorage()
                        return .purgedUnattributable
                    }
                }
            }
            do {
                for entry in entries {
                    let destination = url(
                        accountScopeHash: accountScopeHash,
                        direction: entry.record.direction,
                        identity: entry.record.identity
                    )
                    try createSecureDirectory(
                        destination.deletingLastPathComponent()
                    )
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: entry.url)
                    } else {
                        try fileManager.moveItem(
                            at: entry.url,
                            to: destination
                        )
                        try secure(destination)
                    }
                }
                try Self.removeEmptyLegacyDirectories(
                    root: root,
                    fileManager: fileManager
                )
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
            return .migrated
        }
    }

    private func inspectLegacySharedStorage(
        accountScopeHash: String
    ) throws -> LegacyInspection {
        var entries: [StoredEntry] = []
        for direction in ["incoming", "outgoing"] {
            let directory = Self.legacyDirectory(
                root: root,
                direction: direction
            )
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ]
                )
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
            for file in files {
                guard let entry = Self.validatedEntry(
                    at: file,
                    direction: direction,
                    expectedAccountScopeHash: nil,
                    maximumBytes: policy.maximumTotalBytes,
                    fileManager: fileManager
                ), entry.record.accountScopeHash == accountScopeHash else {
                    return .unsafe
                }
                entries.append(entry)
            }
        }
        return entries.isEmpty ? .empty : .safe(entries)
    }

    private func purgeLegacySharedStorage() throws {
        do {
            for direction in ["incoming", "outgoing"] {
                let directory = Self.legacyDirectory(
                    root: root,
                    direction: direction
                )
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            }
        } catch {
            throw ManagedDocumentCiphertextInboxError.unavailable
        }
    }

    private func sweepScopedStorage(
        accountScopeHash: String
    ) throws -> ManagedDocumentCiphertextInboxSweepDisposition {
        let now = max(0, clock())
        var valid: [StoredEntry] = []
        var removedInvalid = false
        var removedStale = false
        var trimmedQuota = false

        for direction in ["incoming", "outgoing"] {
            let directory = scopedDirectory(
                accountScopeHash: accountScopeHash,
                direction: direction
            )
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ]
                )
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
            for file in files {
                guard let entry = Self.validatedEntry(
                    at: file,
                    direction: direction,
                    expectedAccountScopeHash: accountScopeHash,
                    maximumBytes: policy.maximumTotalBytes,
                    fileManager: fileManager
                ) else {
                    try removeFileOrDirectory(file)
                    removedInvalid = true
                    continue
                }
                guard entry.record.stagedAtMilliseconds <= now else {
                    try removeFileOrDirectory(file)
                    removedInvalid = true
                    continue
                }
                if now - entry.record.stagedAtMilliseconds
                    >= policy.maximumAgeMilliseconds {
                    try removeFileOrDirectory(file)
                    removedStale = true
                    continue
                }
                valid.append(entry)
            }
        }

        valid.sort(by: Self.oldestFirst)
        var totalBytes = valid.reduce(Int64(0)) { $0 + $1.byteCount }
        while valid.count > policy.maximumRecordCount
            || totalBytes > policy.maximumTotalBytes {
            let removed = valid.removeFirst()
            try removeFileOrDirectory(removed.url)
            totalBytes -= removed.byteCount
            trimmedQuota = true
        }
        try cleanupEmptyScopedDirectories(
            accountScopeHash: accountScopeHash
        )

        let flags = [removedInvalid, removedStale, trimmedQuota]
            .filter { $0 }.count
        if flags > 1 {
            return .multiple
        }
        if removedInvalid {
            return .invalidPurged
        }
        if removedStale {
            return .stalePurged
        }
        if trimmedQuota {
            return .quotaTrimmed
        }
        return .clean
    }

    private func write(_ record: Record, at destination: URL) throws {
        guard Self.validateRecord(
            record,
            direction: record.direction,
            expectedIdentity: record.identity,
            expectedAccountScopeHash: record.accountScopeHash
        ) else {
            throw ManagedDocumentCiphertextInboxError.invalidRecord
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw ManagedDocumentCiphertextInboxError.invalidRecord
        }
        try makeRoom(
            for: Int64(data.count),
            replacing: destination,
            accountScopeHash: record.accountScopeHash
        )
        do {
            try createSecureDirectory(
                destination.deletingLastPathComponent()
            )
            try data.write(to: destination, options: .atomic)
            try secure(destination)
        } catch let error as ManagedDocumentCiphertextInboxError {
            throw error
        } catch {
            throw ManagedDocumentCiphertextInboxError.unavailable
        }
    }

    private func makeRoom(
        for newByteCount: Int64,
        replacing destination: URL,
        accountScopeHash: String
    ) throws {
        guard newByteCount <= policy.maximumTotalBytes else {
            throw ManagedDocumentCiphertextInboxError.quotaExceeded
        }
        _ = try sweepScopedStorage(accountScopeHash: accountScopeHash)
        var entries = try scopedEntries(accountScopeHash: accountScopeHash)
            .filter { $0.url.standardizedFileURL != destination.standardizedFileURL }
            .sorted(by: Self.oldestFirst)
        var projectedCount = entries.count + 1
        var projectedBytes =
            entries.reduce(Int64(0)) { $0 + $1.byteCount } + newByteCount
        while projectedCount > policy.maximumRecordCount
            || projectedBytes > policy.maximumTotalBytes {
            guard !entries.isEmpty else {
                throw ManagedDocumentCiphertextInboxError.quotaExceeded
            }
            let removed = entries.removeFirst()
            try removeFileOrDirectory(removed.url)
            projectedCount -= 1
            projectedBytes -= removed.byteCount
        }
    }

    private func read(
        _ source: URL,
        direction: String,
        accountScopeHash: String
    ) throws -> Record? {
        guard fileManager.fileExists(atPath: source.path) else {
            return nil
        }
        guard let entry = Self.validatedEntry(
            at: source,
            direction: direction,
            expectedAccountScopeHash: accountScopeHash,
            maximumBytes: policy.maximumTotalBytes,
            fileManager: fileManager
        ) else {
            throw ManagedDocumentCiphertextInboxError.invalidRecord
        }
        return entry.record
    }

    private func remove(
        _ source: URL,
        accountScopeHash: String
    ) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: source)
            try cleanupEmptyScopedDirectories(
                accountScopeHash: accountScopeHash
            )
        } catch {
            throw ManagedDocumentCiphertextInboxError.unavailable
        }
    }

    private func pendingCount(direction: String) throws -> Int {
        let scope = try bind(nil)
        if !prepared {
            _ = try performMaintenance(accountScopeHash: scope)
            prepared = true
        } else {
            _ = try sweepScopedStorage(accountScopeHash: scope)
        }
        let directory = scopedDirectory(
            accountScopeHash: scope,
            direction: direction
        )
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ).filter { $0.pathExtension == "json" }.count
        } catch {
            throw ManagedDocumentCiphertextInboxError.unavailable
        }
    }

    private func scopedEntries(
        accountScopeHash: String
    ) throws -> [StoredEntry] {
        var entries: [StoredEntry] = []
        for direction in ["incoming", "outgoing"] {
            let directory = scopedDirectory(
                accountScopeHash: accountScopeHash,
                direction: direction
            )
            guard fileManager.fileExists(atPath: directory.path) else {
                continue
            }
            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ]
                )
            } catch {
                throw ManagedDocumentCiphertextInboxError.unavailable
            }
            for file in files {
                guard let entry = Self.validatedEntry(
                    at: file,
                    direction: direction,
                    expectedAccountScopeHash: accountScopeHash,
                    maximumBytes: policy.maximumTotalBytes,
                    fileManager: fileManager
                ) else {
                    throw ManagedDocumentCiphertextInboxError.invalidRecord
                }
                entries.append(entry)
            }
        }
        return entries
    }

    private func removeFileOrDirectory(_ url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw ManagedDocumentCiphertextInboxError.unavailable
        }
    }

    private func cleanupEmptyScopedDirectories(
        accountScopeHash: String
    ) throws {
        for direction in ["incoming", "outgoing"] {
            try Self.removeDirectoryIfEmpty(
                scopedDirectory(
                    accountScopeHash: accountScopeHash,
                    direction: direction
                ),
                fileManager: fileManager
            )
        }
        try Self.removeDirectoryIfEmpty(
            Self.accountRoot(
                root: root,
                accountScopeHash: accountScopeHash
            ),
            fileManager: fileManager
        )
        try Self.removeDirectoryIfEmpty(
            root.appendingPathComponent("accounts", isDirectory: true),
            fileManager: fileManager
        )
    }

    private func createSecureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try secureDirectory(url)
        let accountDirectory = url.deletingLastPathComponent()
        if accountDirectory.lastPathComponent != "accounts" {
            try secureDirectory(accountDirectory)
        }
        let accountsDirectory = accountDirectory.deletingLastPathComponent()
        if accountsDirectory.lastPathComponent == "accounts" {
            try secureDirectory(accountsDirectory)
        }
    }

    private func incomingIdentity(
        accountScopeHash: String,
        document: ManagedDocument
    ) -> String {
        Self.digest(
            accountScopeHash + "\0"
                + document.documentKind.rawValue + "\0"
                + document.documentID.uuidString.lowercased() + "\0"
                + String(document.revision)
        )
    }

    private func outgoingIdentity(
        accountScopeHash: String,
        localIdentifier: String,
        generation: Int64,
        revision: Int64
    ) -> String {
        Self.digest(
            accountScopeHash + "\0" + localIdentifier + "\0"
                + String(generation) + "\0" + String(revision)
        )
    }

    private func scopedDirectory(
        accountScopeHash: String,
        direction: String
    ) -> URL {
        Self.accountRoot(
            root: root,
            accountScopeHash: accountScopeHash
        ).appendingPathComponent(direction, isDirectory: true)
    }

    private func url(
        accountScopeHash: String,
        direction: String,
        identity: String
    ) -> URL {
        scopedDirectory(
            accountScopeHash: accountScopeHash,
            direction: direction
        ).appendingPathComponent(identity + ".json", isDirectory: false)
    }

    private nonisolated static func accountRoot(
        root: URL,
        accountScopeHash: String
    ) -> URL {
        root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(
                digest(
                    "noop-managed-document-ciphertext-account-v1\0"
                        + accountScopeHash
                ),
                isDirectory: true
            )
    }

    private nonisolated static func legacyDirectory(
        root: URL,
        direction: String
    ) -> URL {
        root.appendingPathComponent(direction, isDirectory: true)
    }

    private nonisolated static func validatedEntry(
        at url: URL,
        direction: String,
        expectedAccountScopeHash: String?,
        maximumBytes: Int64,
        fileManager: FileManager
    ) -> StoredEntry? {
        guard url.pathExtension == "json",
              let values = try? url.resourceValues(
                  forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                  ]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              Int64(fileSize) <= maximumBytes,
              let data = try? Data(contentsOf: url),
              Int64(data.count) == Int64(fileSize),
              let record = try? JSONDecoder().decode(
                  Record.self,
                  from: data
              ),
              validateRecord(
                  record,
                  direction: direction,
                  expectedIdentity: url.deletingPathExtension()
                      .lastPathComponent,
                  expectedAccountScopeHash: expectedAccountScopeHash
              ) else {
            return nil
        }
        return StoredEntry(
            url: url,
            data: data,
            record: record,
            byteCount: Int64(data.count)
        )
    }

    private nonisolated static func validateRecord(
        _ record: Record,
        direction: String,
        expectedIdentity: String,
        expectedAccountScopeHash: String?
    ) -> Bool {
        guard record.version == 1,
              record.direction == direction,
              direction == "incoming" || direction == "outgoing",
              isValidAccountScopeHash(record.accountScopeHash),
              expectedAccountScopeHash == nil
                || record.accountScopeHash == expectedAccountScopeHash,
              record.identity == expectedIdentity,
              record.identity.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              ManagedDocumentKind(rawValue: record.documentKind) != nil,
              record.revision >= 0,
              record.stagedAtMilliseconds >= 0,
              record.contentSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              let ciphertext = Data(
                  base64Encoded: record.ciphertextBase64
              ),
              ciphertext.base64EncodedString()
                == record.ciphertextBase64,
              ManagedDocumentEnvelopeDigest.sha256(ciphertext)
                == record.contentSHA256 else {
            return false
        }
        if direction == "incoming" {
            guard record.plaintextSHA256 == nil,
                  digest(
                      record.accountScopeHash + "\0"
                          + record.documentKind + "\0"
                          + record.documentID.uuidString.lowercased()
                          + "\0" + String(record.revision)
                  ) == record.identity else {
                return false
            }
        } else {
            guard record.plaintextSHA256?.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil else {
                return false
            }
        }
        return true
    }

    private nonisolated static func isValidAccountScopeHash(
        _ value: String
    ) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private nonisolated static func oldestFirst(
        _ lhs: StoredEntry,
        _ rhs: StoredEntry
    ) -> Bool {
        if lhs.record.stagedAtMilliseconds
            != rhs.record.stagedAtMilliseconds {
            return lhs.record.stagedAtMilliseconds
                < rhs.record.stagedAtMilliseconds
        }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }

    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func removeEmptyLegacyDirectories(
        root: URL,
        fileManager: FileManager
    ) throws {
        for direction in ["incoming", "outgoing"] {
            try removeDirectoryIfEmpty(
                legacyDirectory(root: root, direction: direction),
                fileManager: fileManager
            )
        }
    }

    private nonisolated static func removeDirectoryIfEmpty(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        if entries.isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    private func secure(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
#if os(iOS) || os(tvOS) || os(watchOS)
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: url.path
        )
#else
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
#endif
    }

    private func secureDirectory(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
#if os(macOS)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
#endif
    }
}
