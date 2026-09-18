import Foundation

public struct ManagedHistoryExportEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case chunk
        case document
    }

    public let kind: Kind
    public let path: String
    public let data: Data

    public init(kind: Kind, path: String, data: Data) {
        self.kind = kind
        self.path = path
        self.data = data
    }
}

public struct ManagedHistoryExportProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case preparing
        case chunks
        case documents
        case finalizing
    }

    public let phase: Phase
    public let completedObjects: Int
    public let totalObjects: Int
    public let completedChunkBytes: Int64
    public let totalChunkBytes: Int64

    public init(
        phase: Phase,
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

public struct ManagedHistoryExportManifest: Codable, Equatable, Sendable {
    public struct Integrity: Codable, Equatable, Sendable {
        public let algorithm: String
        public let entryCount: Int
        public let entriesSHA256: String

        private enum CodingKeys: String, CodingKey {
            case algorithm
            case entryCount
            case entriesSHA256 = "entriesSha256"
        }

        public init(
            algorithm: String,
            entryCount: Int,
            entriesSHA256: String
        ) {
            self.algorithm = algorithm
            self.entryCount = entryCount
            self.entriesSHA256 = entriesSHA256
        }
    }

    public struct SnapshotCursor: Codable, Equatable, Sendable {
        public let formatVersion: Int
        public let snapshotAt: String
        public let changeSequence: Int64

        public init(
            formatVersion: Int,
            snapshotAt: String,
            changeSequence: Int64
        ) {
            self.formatVersion = formatVersion
            self.snapshotAt = snapshotAt
            self.changeSequence = changeSequence
        }
    }

    public struct Chunk: Codable, Equatable, Sendable {
        public let path: String
        public let chunkID: UUID
        public let sourceID: UUID
        public let dataClass: String
        public let schemaVersion: Int
        public let eventStart: String
        public let eventEnd: String
        public let compression: String
        public let contentType: String
        public let sha256: String
        public let compressedBytes: Int
        public let uncompressedBytes: Int
        public let objectGeneration: Int64

        private enum CodingKeys: String, CodingKey {
            case path
            case chunkID = "chunkId"
            case sourceID = "sourceId"
            case dataClass
            case schemaVersion
            case eventStart
            case eventEnd
            case compression
            case contentType
            case sha256
            case compressedBytes
            case uncompressedBytes
            case objectGeneration
        }

        public init(
            path: String,
            chunkID: UUID,
            sourceID: UUID,
            dataClass: String,
            schemaVersion: Int,
            eventStart: String,
            eventEnd: String,
            compression: String,
            contentType: String,
            sha256: String,
            compressedBytes: Int,
            uncompressedBytes: Int,
            objectGeneration: Int64
        ) {
            self.path = path
            self.chunkID = chunkID
            self.sourceID = sourceID
            self.dataClass = dataClass
            self.schemaVersion = schemaVersion
            self.eventStart = eventStart
            self.eventEnd = eventEnd
            self.compression = compression
            self.contentType = contentType
            self.sha256 = sha256
            self.compressedBytes = compressedBytes
            self.uncompressedBytes = uncompressedBytes
            self.objectGeneration = objectGeneration
        }
    }

    public struct Document: Codable, Equatable, Sendable {
        public let path: String
        public let documentKind: ManagedDocumentKind
        public let documentID: UUID
        public let revision: Int64
        public let contentMode: String
        public let contentSHA256: String
        public let archiveSHA256: String
        public let archiveBytes: Int
        public let updatedAt: String

        private enum CodingKeys: String, CodingKey {
            case path
            case documentKind
            case documentID = "documentId"
            case revision
            case contentMode
            case contentSHA256 = "contentSha256"
            case archiveSHA256 = "archiveSha256"
            case archiveBytes
            case updatedAt
        }

        public init(
            path: String,
            documentKind: ManagedDocumentKind,
            documentID: UUID,
            revision: Int64,
            contentMode: String,
            contentSHA256: String,
            archiveSHA256: String,
            archiveBytes: Int,
            updatedAt: String
        ) {
            self.path = path
            self.documentKind = documentKind
            self.documentID = documentID
            self.revision = revision
            self.contentMode = contentMode
            self.contentSHA256 = contentSHA256
            self.archiveSHA256 = archiveSHA256
            self.archiveBytes = archiveBytes
            self.updatedAt = updatedAt
        }
    }

    public let format: String
    public let formatVersion: Int
    public let createdAt: String
    public let snapshotAt: String
    public let changeSequence: Int64
    public let dataClasses: [String]
    public let selectedObjects: Int
    public let selectedChunkBytes: Int64
    public let exportedObjects: Int
    public let exportedChunkBytes: Int64
    public let chunks: [Chunk]
    public let documents: [Document]
    public let integrity: Integrity?
    public let snapshotCursor: SnapshotCursor?

    public init(
        format: String,
        formatVersion: Int,
        createdAt: String,
        snapshotAt: String,
        changeSequence: Int64,
        dataClasses: [String],
        selectedObjects: Int,
        selectedChunkBytes: Int64,
        exportedObjects: Int,
        exportedChunkBytes: Int64,
        chunks: [Chunk],
        documents: [Document],
        integrity: Integrity? = nil,
        snapshotCursor: SnapshotCursor? = nil
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.snapshotAt = snapshotAt
        self.changeSequence = changeSequence
        self.dataClasses = dataClasses
        self.selectedObjects = selectedObjects
        self.selectedChunkBytes = selectedChunkBytes
        self.exportedObjects = exportedObjects
        self.exportedChunkBytes = exportedChunkBytes
        self.chunks = chunks
        self.documents = documents
        self.integrity = integrity
        self.snapshotCursor = snapshotCursor
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

public struct ManagedHistoryExportCheckpoint: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let format: String
    public let formatVersion: Int
    public let createdAt: String
    public let requestID: UUID
    public let restoreJobID: UUID
    public let snapshotAt: String
    public let changeSequence: Int64
    public let expiresAt: String
    public let dataClasses: [String]
    public let pageSize: Int
    public let selectedObjects: Int
    public let selectedChunkBytes: Int64
    public var dataClassIndex: Int
    public var chunkCursor: ManagedChunkPage.Cursor?
    public var documentCursor: ManagedDocumentPage.Cursor?
    public var documentsComplete: Bool
    public var serverCompleted: Bool
    public var exportedObjects: Int
    public var exportedChunkBytes: Int64
    public var chunks: [ManagedHistoryExportManifest.Chunk]
    public var documents: [ManagedHistoryExportManifest.Document]

    private enum CodingKeys: String, CodingKey {
        case format
        case formatVersion
        case createdAt
        case requestID = "requestId"
        case restoreJobID = "restoreJobId"
        case snapshotAt
        case changeSequence
        case expiresAt
        case dataClasses
        case pageSize
        case selectedObjects
        case selectedChunkBytes
        case dataClassIndex
        case chunkCursor
        case documentCursor
        case documentsComplete
        case serverCompleted
        case exportedObjects
        case exportedChunkBytes
        case chunks
        case documents
    }

    public init(
        createdAt: String,
        requestID: UUID,
        restoreJobID: UUID,
        snapshotAt: String,
        changeSequence: Int64,
        expiresAt: String,
        dataClasses: [String],
        pageSize: Int,
        selectedObjects: Int,
        selectedChunkBytes: Int64,
        dataClassIndex: Int = 0,
        chunkCursor: ManagedChunkPage.Cursor? = nil,
        documentCursor: ManagedDocumentPage.Cursor? = nil,
        documentsComplete: Bool = false,
        serverCompleted: Bool = false,
        exportedObjects: Int = 0,
        exportedChunkBytes: Int64 = 0,
        chunks: [ManagedHistoryExportManifest.Chunk] = [],
        documents: [ManagedHistoryExportManifest.Document] = []
    ) {
        format = "noop_managed_history_export_checkpoint"
        formatVersion = Self.currentFormatVersion
        self.createdAt = createdAt
        self.requestID = requestID
        self.restoreJobID = restoreJobID
        self.snapshotAt = snapshotAt
        self.changeSequence = changeSequence
        self.expiresAt = expiresAt
        self.dataClasses = dataClasses
        self.pageSize = pageSize
        self.selectedObjects = selectedObjects
        self.selectedChunkBytes = selectedChunkBytes
        self.dataClassIndex = dataClassIndex
        self.chunkCursor = chunkCursor
        self.documentCursor = documentCursor
        self.documentsComplete = documentsComplete
        self.serverCompleted = serverCompleted
        self.exportedObjects = exportedObjects
        self.exportedChunkBytes = exportedChunkBytes
        self.chunks = chunks
        self.documents = documents
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

public enum ManagedHistoryArchiveIntegrity {
    public static func entriesSHA256(
        chunks: [ManagedHistoryExportManifest.Chunk],
        documents: [ManagedHistoryExportManifest.Document]
    ) -> String {
        let entries =
            chunks.map { ("chunk", $0.path, $0.sha256, $0.compressedBytes) }
            + documents.map {
                ("document", $0.path, $0.archiveSHA256, $0.archiveBytes)
            }
        let canonical = entries
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0 < $1.0
            }
            .map { kind, path, digest, bytes in
                "\(kind)\0\(path)\0\(digest)\0\(bytes)\n"
            }
            .joined()
        return ManagedDigest.sha256(Data(canonical.utf8))
    }
}

public actor ManagedHistoryExporter {
    public typealias AuthorizationProvider =
        @Sendable (_ forceRefresh: Bool) async throws -> ManagedAuthorization
    public typealias EntryConsumer =
        @Sendable (_ entry: ManagedHistoryExportEntry) async throws -> Void
    public typealias ProgressConsumer =
        @Sendable (_ progress: ManagedHistoryExportProgress) async -> Void
    public typealias CheckpointConsumer =
        @Sendable (_ checkpoint: ManagedHistoryExportCheckpoint) async throws -> Void

    private struct ExportedDocument: Codable {
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

        init(_ document: ManagedDocument) {
            documentKind = document.documentKind
            documentID = document.documentID
            revision = document.revision
            originInstallationID = document.originInstallationID
            contentMode = document.contentMode
            clientKeyID = document.clientKeyID
            contentSHA256 = document.contentSHA256
            payloadJSON = document.payloadJSON
            payloadCiphertextBase64 = document.payloadCiphertextBase64
            updatedAt = document.updatedAt
            deletedAt = document.deletedAt
        }
    }

    private let transport: any ManagedStorageTransport

    public init(transport: any ManagedStorageTransport) {
        self.transport = transport
    }

    public func export(
        dataClasses: [String] = ManagedSyncCoordinator.chunkDataClasses,
        pageSize: Int = 100,
        resumeFrom resumeCheckpoint: ManagedHistoryExportCheckpoint? = nil,
        authorization: @escaping AuthorizationProvider,
        progress: ProgressConsumer? = nil,
        saveCheckpoint: CheckpointConsumer? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        consume: @escaping EntryConsumer
    ) async throws -> ManagedHistoryExportManifest {
        let classes = dataClasses.sorted()
        guard !classes.isEmpty,
              Set(classes).count == classes.count,
              classes.allSatisfy({
                  $0.range(
                      of: #"^[a-z][a-z0-9_]{1,63}$"#,
                      options: .regularExpression
                  ) != nil
              }),
              (1...200).contains(pageSize) else {
            throw ManagedStorageError.invalidConfiguration
        }

        await report(
            .preparing,
            completedObjects: 0,
            totalObjects: 0,
            completedBytes: 0,
            totalBytes: 0,
            to: progress
        )
        var checkpoint: ManagedHistoryExportCheckpoint
        if let resumeCheckpoint {
            try Self.validate(
                resumeCheckpoint,
                dataClasses: classes,
                pageSize: pageSize,
                now: now()
            )
            checkpoint = resumeCheckpoint
        } else {
            let requestID = UUID()
            let restore = try await authorized(
                using: authorization,
                operation: { credential in
                    try await self.transport.createRestore(
                        requestID: requestID,
                        dataClasses: classes,
                        includeDeletedDocuments: false,
                        authorization: credential
                    )
                }
            )
            guard restore.status == "running",
                  restore.selectedObjects >= 0,
                  restore.selectedBytes >= 0,
                  restore.deliveredObjects == 0,
                  restore.deliveredBytes == 0,
                  ManagedTimestamp.milliseconds(iso8601: restore.snapshotAt) != nil,
                  ManagedTimestamp.milliseconds(iso8601: restore.expiresAt) != nil else {
                throw ManagedStorageError.invalidResponse
            }
            checkpoint = ManagedHistoryExportCheckpoint(
                createdAt: ManagedTimestamp.iso8601(
                    milliseconds: Int64(
                        (now().timeIntervalSince1970 * 1_000).rounded(.down)
                    )
                ),
                requestID: requestID,
                restoreJobID: restore.restoreJobID,
                snapshotAt: restore.snapshotAt,
                changeSequence: restore.changeSequence,
                expiresAt: restore.expiresAt,
                dataClasses: classes,
                pageSize: pageSize,
                selectedObjects: restore.selectedObjects,
                selectedChunkBytes: restore.selectedBytes
            )
            try await saveCheckpoint?(checkpoint)
        }

        var entryPaths = Set(
            checkpoint.chunks.map(\.path) + checkpoint.documents.map(\.path)
        )

        await report(
            .chunks,
            completedObjects: checkpoint.exportedObjects,
            totalObjects: checkpoint.selectedObjects,
            completedBytes: checkpoint.exportedChunkBytes,
            totalBytes: checkpoint.selectedChunkBytes,
            to: progress
        )

        while checkpoint.dataClassIndex < classes.count {
            let dataClass = classes[checkpoint.dataClassIndex]
            repeat {
                try Task.checkCancellation()
                let pageCursor = checkpoint.chunkCursor
                let snapshotAt = checkpoint.snapshotAt
                let page = try await authorized(
                    using: authorization,
                    operation: { credential in
                        try await self.transport.availableChunks(
                            dataClass: dataClass,
                            snapshotAt: snapshotAt,
                            after: pageCursor,
                            limit: pageSize,
                            authorization: credential
                        )
                    }
                )
                guard !page.chunks.isEmpty || page.nextCursor == nil else {
                    throw ManagedStorageError.invalidResponse
                }
                for chunk in page.chunks {
                    try Task.checkCancellation()
                    guard chunk.dataClass == dataClass,
                          chunk.contentMode == "server_readable",
                          chunk.state == "available",
                          chunk.expectedCompressedBytes > 0,
                          chunk.expectedUncompressedBytes > 0,
                          Self.isSHA256(chunk.expectedSHA256) else {
                        throw ManagedStorageError.invalidResponse
                    }
                    let restoreJobID = checkpoint.restoreJobID
                    let capability = try await authorized(
                        using: authorization,
                        operation: { credential in
                            try await self.transport.downloadCapability(
                                chunkID: chunk.chunkID,
                                requestID: ManagedStableIdentifier.uuid(
                                    seed: Data(
                                        (
                                            "noop-managed-history-export-v1\0"
                                            + restoreJobID.uuidString.lowercased()
                                            + "\0"
                                            + chunk.chunkID.uuidString.lowercased()
                                        ).utf8
                                    )
                                ),
                                authorization: credential
                            )
                        }
                    )
                    let data = try await transport.download(using: capability)
                    guard data.count == chunk.expectedCompressedBytes,
                          ManagedDigest.sha256(data) == chunk.expectedSHA256 else {
                        throw ManagedStorageError.digestMismatch
                    }
                    let path = Self.chunkPath(chunk)
                    guard entryPaths.insert(path).inserted else {
                        throw ManagedStorageError.invalidResponse
                    }
                    try await consume(
                        ManagedHistoryExportEntry(
                            kind: .chunk,
                            path: path,
                            data: data
                        )
                    )
                    checkpoint.chunks.append(
                        .init(
                            path: path,
                            chunkID: chunk.chunkID,
                            sourceID: chunk.sourceID,
                            dataClass: chunk.dataClass,
                            schemaVersion: chunk.schemaVersion,
                            eventStart: chunk.eventStart,
                            eventEnd: chunk.eventEnd,
                            compression: chunk.compression,
                            contentType: chunk.contentType,
                            sha256: chunk.expectedSHA256,
                            compressedBytes: chunk.expectedCompressedBytes,
                            uncompressedBytes: chunk.expectedUncompressedBytes,
                            objectGeneration: chunk.objectGeneration
                        )
                    )
                    checkpoint.exportedObjects = try Self.add(
                        checkpoint.exportedObjects,
                        1
                    )
                    checkpoint.exportedChunkBytes = try Self.add(
                        checkpoint.exportedChunkBytes,
                        Int64(chunk.expectedCompressedBytes)
                    )
                    checkpoint.chunkCursor = ManagedChunkPage.Cursor(
                        afterEventStart: chunk.eventStart,
                        afterChunkID: chunk.chunkID
                    )
                    guard checkpoint.exportedObjects <= checkpoint.selectedObjects,
                          checkpoint.exportedChunkBytes
                            <= checkpoint.selectedChunkBytes else {
                        throw ManagedStorageError.invalidResponse
                    }
                    try await saveCheckpoint?(checkpoint)
                    await report(
                        .chunks,
                        completedObjects: checkpoint.exportedObjects,
                        totalObjects: checkpoint.selectedObjects,
                        completedBytes: checkpoint.exportedChunkBytes,
                        totalBytes: checkpoint.selectedChunkBytes,
                        to: progress
                    )
                }
                if let nextCursor = page.nextCursor {
                    guard checkpoint.chunkCursor == nextCursor else {
                        throw ManagedStorageError.invalidResponse
                    }
                } else {
                    checkpoint.dataClassIndex += 1
                    checkpoint.chunkCursor = nil
                }
                try await saveCheckpoint?(checkpoint)
            } while checkpoint.chunkCursor != nil
        }

        await report(
            .documents,
            completedObjects: checkpoint.exportedObjects,
            totalObjects: checkpoint.selectedObjects,
            completedBytes: checkpoint.exportedChunkBytes,
            totalBytes: checkpoint.selectedChunkBytes,
            to: progress
        )
        while !checkpoint.documentsComplete {
            try Task.checkCancellation()
            let pageCursor = checkpoint.documentCursor
            let snapshotAt = checkpoint.snapshotAt
            let page = try await authorized(
                using: authorization,
                operation: { credential in
                    try await self.transport.documents(
                        snapshotAt: snapshotAt,
                        after: pageCursor,
                        limit: pageSize,
                        includeDeleted: false,
                        authorization: credential
                    )
                }
            )
            guard !page.documents.isEmpty || page.nextCursor == nil else {
                throw ManagedStorageError.invalidResponse
            }
            for document in page.documents {
                try Task.checkCancellation()
                guard document.deletedAt == nil else {
                    throw ManagedStorageError.invalidResponse
                }
                let data = try Self.encode(document)
                let path = Self.documentPath(document)
                guard entryPaths.insert(path).inserted else {
                    throw ManagedStorageError.invalidResponse
                }
                try await consume(
                    ManagedHistoryExportEntry(
                        kind: .document,
                        path: path,
                        data: data
                    )
                )
                checkpoint.documents.append(
                    .init(
                        path: path,
                        documentKind: document.documentKind,
                        documentID: document.documentID,
                        revision: document.revision,
                        contentMode: document.contentMode,
                        contentSHA256: document.contentSHA256,
                        archiveSHA256: ManagedDigest.sha256(data),
                        archiveBytes: data.count,
                        updatedAt: document.updatedAt
                    )
                )
                checkpoint.exportedObjects = try Self.add(
                    checkpoint.exportedObjects,
                    1
                )
                checkpoint.documentCursor = document.pageCursor
                guard checkpoint.exportedObjects <= checkpoint.selectedObjects else {
                    throw ManagedStorageError.invalidResponse
                }
                try await saveCheckpoint?(checkpoint)
                await report(
                    .documents,
                    completedObjects: checkpoint.exportedObjects,
                    totalObjects: checkpoint.selectedObjects,
                    completedBytes: checkpoint.exportedChunkBytes,
                    totalBytes: checkpoint.selectedChunkBytes,
                    to: progress
                )
            }
            if let nextCursor = page.nextCursor {
                guard checkpoint.documentCursor == nextCursor else {
                    throw ManagedStorageError.invalidResponse
                }
            } else {
                checkpoint.documentCursor = nil
                checkpoint.documentsComplete = true
            }
            try await saveCheckpoint?(checkpoint)
        }

        guard checkpoint.exportedObjects == checkpoint.selectedObjects,
              checkpoint.exportedChunkBytes == checkpoint.selectedChunkBytes else {
            throw ManagedStorageError.invalidResponse
        }
        await report(
            .finalizing,
            completedObjects: checkpoint.exportedObjects,
            totalObjects: checkpoint.selectedObjects,
            completedBytes: checkpoint.exportedChunkBytes,
            totalBytes: checkpoint.selectedChunkBytes,
            to: progress
        )
        if !checkpoint.serverCompleted {
            let restoreJobID = checkpoint.restoreJobID
            let deliveredObjects = checkpoint.exportedObjects
            let deliveredBytes = checkpoint.exportedChunkBytes
            let completed = try await authorized(
                using: authorization,
                operation: { credential in
                    try await self.transport.completeRestore(
                        restoreJobID: restoreJobID,
                        deliveredObjects: deliveredObjects,
                        deliveredBytes: deliveredBytes,
                        authorization: credential
                    )
                }
            )
            guard completed.status == "completed",
                  completed.restoreJobID == checkpoint.restoreJobID,
                  completed.snapshotAt == checkpoint.snapshotAt,
                  completed.changeSequence == checkpoint.changeSequence,
                  completed.selectedObjects == checkpoint.selectedObjects,
                  completed.selectedBytes == checkpoint.selectedChunkBytes,
                  completed.deliveredObjects == checkpoint.exportedObjects,
                  completed.deliveredBytes == checkpoint.exportedChunkBytes else {
                throw ManagedStorageError.invalidResponse
            }
            checkpoint.serverCompleted = true
            try await saveCheckpoint?(checkpoint)
        }

        let entriesSHA256 = ManagedHistoryArchiveIntegrity.entriesSHA256(
            chunks: checkpoint.chunks,
            documents: checkpoint.documents
        )
        return ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: 2,
            createdAt: checkpoint.createdAt,
            snapshotAt: checkpoint.snapshotAt,
            changeSequence: checkpoint.changeSequence,
            dataClasses: classes,
            selectedObjects: checkpoint.selectedObjects,
            selectedChunkBytes: checkpoint.selectedChunkBytes,
            exportedObjects: checkpoint.exportedObjects,
            exportedChunkBytes: checkpoint.exportedChunkBytes,
            chunks: checkpoint.chunks,
            documents: checkpoint.documents,
            integrity: .init(
                algorithm: "sha256",
                entryCount: checkpoint.exportedObjects,
                entriesSHA256: entriesSHA256
            ),
            snapshotCursor: .init(
                formatVersion: 1,
                snapshotAt: checkpoint.snapshotAt,
                changeSequence: checkpoint.changeSequence
            )
        )
    }

    private func authorized<Result>(
        using provider: @escaping AuthorizationProvider,
        operation: @escaping @Sendable (ManagedAuthorization) async throws -> Result
    ) async throws -> Result {
        try await ManagedAuthenticationRetry.run(
            authorization: provider,
            operation: operation
        )
    }

    private func report(
        _ phase: ManagedHistoryExportProgress.Phase,
        completedObjects: Int,
        totalObjects: Int,
        completedBytes: Int64,
        totalBytes: Int64,
        to consumer: ProgressConsumer?
    ) async {
        await consumer?(
            ManagedHistoryExportProgress(
                phase: phase,
                completedObjects: completedObjects,
                totalObjects: totalObjects,
                completedChunkBytes: completedBytes,
                totalChunkBytes: totalBytes
            )
        )
    }

    private static func chunkPath(_ chunk: ManagedAvailableChunk) -> String {
        let suffix: String
        switch chunk.compression {
        case "gzip":
            suffix = "json.gz"
        case "zstd":
            suffix = "json.zst"
        default:
            suffix = "json"
        }
        return "chunks/\(chunk.dataClass)/"
            + chunk.chunkID.uuidString.lowercased()
            + ".\(suffix)"
    }

    private static func documentPath(_ document: ManagedDocument) -> String {
        "documents/\(document.documentKind.rawValue)/"
            + document.documentID.uuidString.lowercased()
            + ".json"
    }

    private static func encode(_ document: ManagedDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(ExportedDocument(document))
        } catch {
            throw ManagedStorageError.encoding
        }
    }

    private static func validate(
        _ checkpoint: ManagedHistoryExportCheckpoint,
        dataClasses: [String],
        pageSize: Int,
        now: Date
    ) throws {
        let paths = checkpoint.chunks.map(\.path)
            + checkpoint.documents.map(\.path)
        let chunkBytes = checkpoint.chunks.reduce(Int64(0)) {
            $0 + Int64($1.compressedBytes)
        }
        let expiresAt = ManagedTimestamp.milliseconds(
            iso8601: checkpoint.expiresAt
        )
        guard checkpoint.format == "noop_managed_history_export_checkpoint",
              checkpoint.formatVersion
                == ManagedHistoryExportCheckpoint.currentFormatVersion,
              checkpoint.dataClasses == dataClasses,
              checkpoint.pageSize == pageSize,
              checkpoint.changeSequence >= 0,
              ManagedTimestamp.milliseconds(
                  iso8601: checkpoint.createdAt
              ) != nil,
              ManagedTimestamp.milliseconds(
                  iso8601: checkpoint.snapshotAt
              ) != nil,
              let expiresAt,
              expiresAt > Int64(
                  (now.timeIntervalSince1970 * 1_000).rounded(.down)
              ),
              checkpoint.selectedObjects >= 0,
              checkpoint.selectedChunkBytes >= 0,
              checkpoint.dataClassIndex >= 0,
              checkpoint.dataClassIndex <= dataClasses.count,
              checkpoint.exportedObjects
                == checkpoint.chunks.count + checkpoint.documents.count,
              checkpoint.exportedObjects <= checkpoint.selectedObjects,
              checkpoint.exportedChunkBytes == chunkBytes,
              checkpoint.exportedChunkBytes
                <= checkpoint.selectedChunkBytes,
              Set(paths).count == paths.count,
              !checkpoint.serverCompleted
                || (
                    checkpoint.documentsComplete
                        && checkpoint.exportedObjects
                            == checkpoint.selectedObjects
                        && checkpoint.exportedChunkBytes
                            == checkpoint.selectedChunkBytes
                ),
              checkpoint.chunks.allSatisfy({
                  Self.valid(path: $0.path)
                      && Self.isSHA256($0.sha256)
                      && $0.compressedBytes > 0
                      && $0.uncompressedBytes > 0
                      && dataClasses.contains($0.dataClass)
              }),
              checkpoint.documents.allSatisfy({
                  Self.valid(path: $0.path)
                      && Self.isSHA256($0.contentSHA256)
                      && Self.isSHA256($0.archiveSHA256)
                      && $0.archiveBytes > 0
                      && $0.revision > 0
              }) else {
            if expiresAt.map({
                $0 <= Int64(
                    (now.timeIntervalSince1970 * 1_000).rounded(.down)
                )
            }) == true {
                throw ManagedStorageError.cursorExpired(minimumSequence: nil)
            }
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func valid(path: String) -> Bool {
        !path.isEmpty
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

    private static func add(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw ManagedStorageError.invalidResponse }
        return result.partialValue
    }

    private static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw ManagedStorageError.invalidResponse }
        return result.partialValue
    }
}
