import Foundation
import WhoopStore

public enum ManagedHistoryImportPhase: String, Sendable {
    case validating
    case importing
    case finalizing
}

public struct ManagedHistoryImportProgress: Equatable, Sendable {
    public let phase: ManagedHistoryImportPhase
    public let completedObjects: Int
    public let totalObjects: Int
    public let completedChunkBytes: Int64
    public let totalChunkBytes: Int64

    public init(
        phase: ManagedHistoryImportPhase,
        completedObjects: Int,
        totalObjects: Int,
        completedChunkBytes: Int64,
        totalChunkBytes: Int64
    ) {
        self.phase = phase
        self.completedObjects = completedObjects
        self.totalObjects = totalObjects
        self.completedChunkBytes = completedChunkBytes
        self.totalChunkBytes = totalChunkBytes
    }
}

public struct ManagedHistoryImportCheckpoint: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let format: String
    public let formatVersion: Int
    public let archiveSHA256: String
    public var nextObjectIndex: Int
    public var importedObjects: Int
    public var importedChunkBytes: Int64
    public var completed: Bool

    private enum CodingKeys: String, CodingKey {
        case format
        case formatVersion
        case archiveSHA256 = "archiveSha256"
        case nextObjectIndex
        case importedObjects
        case importedChunkBytes
        case completed
    }

    public init(
        archiveSHA256: String,
        nextObjectIndex: Int = 0,
        importedObjects: Int = 0,
        importedChunkBytes: Int64 = 0,
        completed: Bool = false
    ) {
        format = "noop_managed_history_import_checkpoint"
        formatVersion = Self.currentFormatVersion
        self.archiveSHA256 = archiveSHA256
        self.nextObjectIndex = nextObjectIndex
        self.importedObjects = importedObjects
        self.importedChunkBytes = importedChunkBytes
        self.completed = completed
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw ManagedStorageError.encoding
        }
    }

    public static func decoded(from data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Self.self, from: data)
        } catch {
            throw ManagedStorageError.decoding
        }
    }
}

public struct ManagedHistoryImportSummary: Equatable, Sendable {
    public let archiveSHA256: String
    public let importedObjects: Int
    public let importedChunkBytes: Int64
    public let resumed: Bool

    public init(
        archiveSHA256: String,
        importedObjects: Int,
        importedChunkBytes: Int64,
        resumed: Bool
    ) {
        self.archiveSHA256 = archiveSHA256
        self.importedObjects = importedObjects
        self.importedChunkBytes = importedChunkBytes
        self.resumed = resumed
    }
}

public actor ManagedHistoryImporter {
    public typealias EntryReader =
        @Sendable (_ path: String, _ maximumBytes: Int) async throws -> Data
    public typealias ProgressConsumer =
        @Sendable (_ progress: ManagedHistoryImportProgress) async -> Void
    public typealias CheckpointConsumer =
        @Sendable (_ checkpoint: ManagedHistoryImportCheckpoint) async throws -> Void

    private enum Object {
        case chunk(ManagedHistoryExportManifest.Chunk)
        case document(ManagedHistoryExportManifest.Document)

        var path: String {
            switch self {
            case .chunk(let value): return value.path
            case .document(let value): return value.path
            }
        }

        var archiveBytes: Int {
            switch self {
            case .chunk(let value): return value.compressedBytes
            case .document(let value): return value.archiveBytes
            }
        }

        var chunkBytes: Int64 {
            switch self {
            case .chunk(let value): return Int64(value.compressedBytes)
            case .document: return 0
            }
        }
    }

    private struct ArchivedDocument: Codable {
        let documentKind: ManagedDocumentKind
        let documentID: UUID
        let revision: Int64
        let originInstallationID: String
        let contentMode: String
        let clientKeyID: UUID?
        let contentSHA256: String
        let payloadJSON: [String: ManagedDocumentJSONValue]?
        let payloadCiphertextBase64: String?
        let updatedAt: String
        let deletedAt: String?

        private enum CodingKeys: String, CodingKey {
            case documentKind
            case documentID = "documentId"
            case revision
            case originInstallationID = "originInstallationId"
            case contentMode
            case clientKeyID = "clientKeyId"
            case contentSHA256 = "contentSha256"
            case payloadJSON = "payloadJson"
            case payloadCiphertextBase64
            case updatedAt
            case deletedAt
        }

        var managedDocument: ManagedDocument {
            ManagedDocument(
                documentKind: documentKind,
                documentID: documentID,
                revision: revision,
                originInstallationID: originInstallationID,
                contentMode: contentMode,
                clientKeyID: clientKeyID,
                contentSHA256: contentSHA256,
                payloadJSON: payloadJSON,
                payloadCiphertextBase64: payloadCiphertextBase64,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                duplicate: false
            )
        }
    }

    public init() {}

    public func importArchive(
        manifestData: Data,
        entryPaths: [String],
        resumeFrom resumeCheckpoint: ManagedHistoryImportCheckpoint? = nil,
        restore: any ManagedRestoreApplying,
        progress: ProgressConsumer? = nil,
        saveCheckpoint: CheckpointConsumer? = nil,
        read: @escaping EntryReader
    ) async throws -> ManagedHistoryImportSummary {
        let manifest = try ManagedHistoryExportManifest.decoded(
            from: manifestData
        )
        let objects = try Self.validateManifest(
            manifest,
            manifestData: manifestData,
            entryPaths: entryPaths
        )
        let archiveSHA256 = ManagedDigest.sha256(try manifest.encoded())
        let resumed = resumeCheckpoint != nil
        var checkpoint: ManagedHistoryImportCheckpoint
        if let resumeCheckpoint {
            try Self.validate(
                resumeCheckpoint,
                archiveSHA256: archiveSHA256,
                objects: objects
            )
            checkpoint = resumeCheckpoint
        } else {
            checkpoint = ManagedHistoryImportCheckpoint(
                archiveSHA256: archiveSHA256
            )
            try await saveCheckpoint?(checkpoint)
        }

        await report(
            .validating,
            checkpoint: checkpoint,
            manifest: manifest,
            to: progress
        )
        for object in objects {
            try Task.checkCancellation()
            let data = try await read(object.path, object.archiveBytes)
            switch object {
            case .chunk(let record):
                _ = try Self.validatedChunk(
                    record,
                    manifest: manifest,
                    data: data
                )
            case .document(let record):
                _ = try Self.validatedDocument(record, data: data)
            }
        }

        if checkpoint.completed {
            await report(
                .finalizing,
                checkpoint: checkpoint,
                manifest: manifest,
                to: progress
            )
            return ManagedHistoryImportSummary(
                archiveSHA256: archiveSHA256,
                importedObjects: checkpoint.importedObjects,
                importedChunkBytes: checkpoint.importedChunkBytes,
                resumed: resumed
            )
        }

        await report(
            .importing,
            checkpoint: checkpoint,
            manifest: manifest,
            to: progress
        )
        while checkpoint.nextObjectIndex < objects.count {
            try Task.checkCancellation()
            let object = objects[checkpoint.nextObjectIndex]
            let data = try await read(object.path, object.archiveBytes)
            switch object {
            case .chunk(let record):
                let value = try Self.validatedChunk(
                    record,
                    manifest: manifest,
                    data: data
                )
                try await restore.apply(
                    chunk: value.payload,
                    change: value.change
                )
            case .document(let record):
                let document = try Self.validatedDocument(record, data: data)
                try await restore.apply(
                    document: document,
                    change: document.changeMetadata
                )
            }
            checkpoint.nextObjectIndex += 1
            checkpoint.importedObjects += 1
            checkpoint.importedChunkBytes = try Self.add(
                checkpoint.importedChunkBytes,
                object.chunkBytes
            )
            try await saveCheckpoint?(checkpoint)
            await report(
                .importing,
                checkpoint: checkpoint,
                manifest: manifest,
                to: progress
            )
        }

        guard checkpoint.importedObjects == manifest.exportedObjects,
              checkpoint.importedChunkBytes
                == manifest.exportedChunkBytes else {
            throw ManagedStorageError.invalidResponse
        }
        checkpoint.completed = true
        try await saveCheckpoint?(checkpoint)
        await report(
            .finalizing,
            checkpoint: checkpoint,
            manifest: manifest,
            to: progress
        )
        return ManagedHistoryImportSummary(
            archiveSHA256: archiveSHA256,
            importedObjects: checkpoint.importedObjects,
            importedChunkBytes: checkpoint.importedChunkBytes,
            resumed: resumed
        )
    }

    private static func validateManifest(
        _ manifest: ManagedHistoryExportManifest,
        manifestData: Data,
        entryPaths: [String]
    ) throws -> [Object] {
        let objects = manifest.chunks.map(Object.chunk)
            + manifest.documents.map(Object.document)
        let paths = objects.map(\.path)
        let expectedPaths = Set(paths + ["manifest.json"])
        let actualPaths = Set(entryPaths)
        let chunkBytes = try manifest.chunks.reduce(Int64(0)) {
            try add($0, Int64($1.compressedBytes))
        }
        guard manifestData.count
                <= ManagedHistoryTransferLimits.maximumManifestBytes,
              manifest.format == "noop_managed_history",
              (1...2).contains(manifest.formatVersion),
              ManagedTimestamp.milliseconds(
                  iso8601: manifest.createdAt
              ) != nil,
              ManagedTimestamp.milliseconds(
                  iso8601: manifest.snapshotAt
              ) != nil,
              manifest.changeSequence >= 0,
              !manifest.dataClasses.isEmpty,
              manifest.dataClasses == manifest.dataClasses.sorted(),
              Set(manifest.dataClasses).count == manifest.dataClasses.count,
              manifest.dataClasses.allSatisfy(Self.validDataClass),
              manifest.selectedObjects == manifest.exportedObjects,
              manifest.exportedObjects == objects.count,
              manifest.exportedObjects
                <= ManagedHistoryTransferLimits.maximumObjectCount,
              manifest.selectedChunkBytes == manifest.exportedChunkBytes,
              manifest.exportedChunkBytes == chunkBytes,
              manifest.exportedChunkBytes >= 0,
              Set(paths).count == paths.count,
              entryPaths.count == actualPaths.count,
              actualPaths == expectedPaths,
              manifest.chunks.allSatisfy({
                  valid(chunk: $0, dataClasses: manifest.dataClasses)
              }),
              manifest.documents.allSatisfy(valid(document:)) else {
            throw ManagedStorageError.invalidResponse
        }

        if manifest.formatVersion == 2 {
            let digest = ManagedHistoryArchiveIntegrity.entriesSHA256(
                chunks: manifest.chunks,
                documents: manifest.documents
            )
            guard let integrity = manifest.integrity,
                  integrity.algorithm == "sha256",
                  integrity.entryCount == manifest.exportedObjects,
                  integrity.entriesSHA256 == digest,
                  let cursor = manifest.snapshotCursor,
                  cursor.formatVersion == 1,
                  cursor.snapshotAt == manifest.snapshotAt,
                  cursor.changeSequence == manifest.changeSequence else {
                throw ManagedStorageError.digestMismatch
            }
        }
        return objects
    }

    private static func validate(
        _ checkpoint: ManagedHistoryImportCheckpoint,
        archiveSHA256: String,
        objects: [Object]
    ) throws {
        guard checkpoint.archiveSHA256 == archiveSHA256 else {
            throw ManagedStorageError.conflict
        }
        guard checkpoint.nextObjectIndex >= 0,
              checkpoint.nextObjectIndex <= objects.count else {
            throw ManagedStorageError.invalidResponse
        }
        let expectedBytes = try objects.prefix(
            checkpoint.nextObjectIndex
        ).reduce(Int64(0)) {
            try add($0, $1.chunkBytes)
        }
        guard checkpoint.format == "noop_managed_history_import_checkpoint",
              checkpoint.formatVersion
                == ManagedHistoryImportCheckpoint.currentFormatVersion,
              checkpoint.importedObjects == checkpoint.nextObjectIndex,
              checkpoint.importedChunkBytes == expectedBytes,
              !checkpoint.completed
                || checkpoint.nextObjectIndex == objects.count else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func validatedChunk(
        _ record: ManagedHistoryExportManifest.Chunk,
        manifest: ManagedHistoryExportManifest,
        data: Data
    ) throws -> (payload: ManagedChunkPayload, change: ManagedChangeFeed.Change) {
        guard data.count == record.compressedBytes,
              ManagedDigest.sha256(data) == record.sha256 else {
            throw ManagedStorageError.digestMismatch
        }
        let decoded = try ManagedChunkCodec.decode(
            data,
            compression: record.compression,
            expectedUncompressedBytes: record.uncompressedBytes
        )
        let payload: ManagedChunkPayload
        do {
            payload = try JSONDecoder().decode(
                ManagedChunkPayload.self,
                from: decoded
            )
        } catch {
            throw ManagedStorageError.decoding
        }
        let canonical = try ManagedPreparedChunk.prepare(
            sourceID: payload.sourceID,
            dataClass: payload.dataClass,
            eventStartMs: payload.eventStartMs,
            eventEndMs: payload.eventEndMs,
            streams: payload.streams
        )
        guard let canonical,
              canonical.payload == payload,
              canonical.uncompressed == decoded,
              payload.chunkID == record.chunkID,
              payload.sourceID == record.sourceID,
              payload.dataClass == record.dataClass,
              payload.schemaVersion == record.schemaVersion,
              payload.eventStartMs
                == ManagedTimestamp.milliseconds(iso8601: record.eventStart),
              payload.eventEndMs
                == ManagedTimestamp.milliseconds(iso8601: record.eventEnd) else {
            throw ManagedStorageError.invalidResponse
        }
        let available = ManagedAvailableChunk(
            chunkID: record.chunkID,
            sourceID: record.sourceID,
            dataClass: record.dataClass,
            schemaVersion: record.schemaVersion,
            contentMode: "server_readable",
            state: "available",
            eventStart: record.eventStart,
            eventEnd: record.eventEnd,
            compression: record.compression,
            contentType: record.contentType,
            expectedSHA256: record.sha256,
            expectedCompressedBytes: record.compressedBytes,
            expectedUncompressedBytes: record.uncompressedBytes,
            objectGeneration: record.objectGeneration,
            expiresAt: manifest.createdAt
        )
        return (payload, available.changeMetadata)
    }

    private static func validatedDocument(
        _ record: ManagedHistoryExportManifest.Document,
        data: Data
    ) throws -> ManagedDocument {
        guard data.count == record.archiveBytes,
              ManagedDigest.sha256(data) == record.archiveSHA256 else {
            throw ManagedStorageError.digestMismatch
        }
        let archived: ArchivedDocument
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            archived = try decoder.decode(ArchivedDocument.self, from: data)
        } catch {
            throw ManagedStorageError.decoding
        }
        let document = archived.managedDocument
        guard document.documentKind == record.documentKind,
              document.documentID == record.documentID,
              document.revision == record.revision,
              document.contentMode == record.contentMode,
              document.contentSHA256 == record.contentSHA256,
              document.updatedAt == record.updatedAt,
              document.deletedAt == nil,
              !document.originInstallationID.isEmpty,
              document.originInstallationID.utf8.count <= 64 else {
            throw ManagedStorageError.invalidResponse
        }
        try validateDocumentContent(document)
        return document
    }

    private static func validateDocumentContent(
        _ document: ManagedDocument
    ) throws {
        if document.contentMode == "server_readable" {
            guard document.clientKeyID == nil,
                  document.payloadCiphertextBase64 == nil,
                  let payload = document.payloadJSON else {
                throw ManagedStorageError.invalidResponse
            }
            let canonical = try canonicalData(payload)
            guard ManagedDigest.sha256(canonical)
                    == document.contentSHA256,
                  try documentID(
                      kind: document.documentKind,
                      payload: payload
                  ) == document.documentID else {
                throw ManagedStorageError.invalidResponse
            }
            return
        }
        guard document.contentMode == "client_encrypted",
              document.payloadJSON == nil,
              document.clientKeyID != nil,
              let encoded = document.payloadCiphertextBase64,
              let ciphertext = Data(base64Encoded: encoded),
              ciphertext.base64EncodedString() == encoded,
              (17...1_048_576).contains(ciphertext.count),
              ManagedDigest.sha256(ciphertext)
                == document.contentSHA256 else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func documentID(
        kind: ManagedDocumentKind,
        payload: [String: ManagedDocumentJSONValue]
    ) throws -> UUID {
        if kind == .preferences {
            return ManagedDocumentStableIdentifier.uuid(
                documentKind: kind.rawValue,
                tableName: "preferences",
                keyJSON: try canonicalData([
                    "scope": .string("global"),
                ])
            )
        }
        guard case .string(let tableName)? = payload["table"],
              case .object(let key)? = payload["key"] else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedDocumentStableIdentifier.uuid(
            documentKind: kind.rawValue,
            tableName: tableName,
            keyJSON: try canonicalData(key)
        )
    }

    private static func canonicalData(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(payload)
        } catch {
            throw ManagedStorageError.encoding
        }
    }

    private static func valid(
        chunk: ManagedHistoryExportManifest.Chunk,
        dataClasses: [String]
    ) -> Bool {
        chunk.path == chunkPath(chunk)
            && valid(path: chunk.path)
            && dataClasses.contains(chunk.dataClass)
            && chunk.schemaVersion == 1
            && ManagedTimestamp.milliseconds(
                iso8601: chunk.eventStart
            ) != nil
            && ManagedTimestamp.milliseconds(
                iso8601: chunk.eventEnd
            ) != nil
            && ["gzip", "none"].contains(chunk.compression)
            && chunk.contentType == "application/vnd.noop.chunk+json"
            && isSHA256(chunk.sha256)
            && chunk.compressedBytes > 0
            && chunk.compressedBytes <= 16 * 1_024 * 1_024
            && chunk.uncompressedBytes > 0
            && chunk.uncompressedBytes <= ManagedChunkCodec.maximumUncompressedBytes
            && chunk.objectGeneration > 0
    }

    private static func valid(
        document: ManagedHistoryExportManifest.Document
    ) -> Bool {
        document.path == documentPath(document)
            && valid(path: document.path)
            && document.revision > 0
            && ["server_readable", "client_encrypted"]
                .contains(document.contentMode)
            && isSHA256(document.contentSHA256)
            && isSHA256(document.archiveSHA256)
            && document.archiveBytes > 0
            && document.archiveBytes <= 2 * 1_024 * 1_024
            && ManagedTimestamp.milliseconds(
                iso8601: document.updatedAt
            ) != nil
    }

    private static func chunkPath(
        _ chunk: ManagedHistoryExportManifest.Chunk
    ) -> String {
        let suffix: String
        switch chunk.compression {
        case "gzip": suffix = "json.gz"
        case "zstd": suffix = "json.zst"
        default: suffix = "json"
        }
        return "chunks/\(chunk.dataClass)/"
            + chunk.chunkID.uuidString.lowercased()
            + ".\(suffix)"
    }

    private static func documentPath(
        _ document: ManagedHistoryExportManifest.Document
    ) -> String {
        "documents/\(document.documentKind.rawValue)/"
            + document.documentID.uuidString.lowercased()
            + ".json"
    }

    private static func validDataClass(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z][a-z0-9_]{1,63}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func valid(path: String) -> Bool {
        !path.isEmpty
            && path.utf8.count <= ManagedHistoryTransferLimits.maximumPathBytes
            && !path.hasPrefix("/")
            && !path.hasSuffix("/")
            && !path.contains("\\")
            && !path.contains("\0")
            && path.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private func report(
        _ phase: ManagedHistoryImportPhase,
        checkpoint: ManagedHistoryImportCheckpoint,
        manifest: ManagedHistoryExportManifest,
        to consumer: ProgressConsumer?
    ) async {
        await consumer?(
            ManagedHistoryImportProgress(
                phase: phase,
                completedObjects: checkpoint.importedObjects,
                totalObjects: manifest.exportedObjects,
                completedChunkBytes: checkpoint.importedChunkBytes,
                totalChunkBytes: manifest.exportedChunkBytes
            )
        )
    }

    private static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw ManagedStorageError.invalidResponse
        }
        return result.partialValue
    }
}
