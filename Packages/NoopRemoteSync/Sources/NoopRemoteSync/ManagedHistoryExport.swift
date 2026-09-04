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
        documents: [Document]
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
}

public actor ManagedHistoryExporter {
    public typealias AuthorizationProvider =
        @Sendable (_ forceRefresh: Bool) async throws -> ManagedAuthorization
    public typealias EntryConsumer =
        @Sendable (_ entry: ManagedHistoryExportEntry) async throws -> Void
    public typealias ProgressConsumer =
        @Sendable (_ progress: ManagedHistoryExportProgress) async -> Void

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
        authorization: @escaping AuthorizationProvider,
        progress: ProgressConsumer? = nil,
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

        let requestID = UUID()
        await report(
            .preparing,
            completedObjects: 0,
            totalObjects: 0,
            completedBytes: 0,
            totalBytes: 0,
            to: progress
        )
        let restore = try await authorized(
            using: authorization,
            operation: { credential in
                try await self.transport.createRestore(
                    requestID: requestID,
                    dataClasses: classes,
                    authorization: credential
                )
            }
        )
        guard restore.status == "running",
              restore.selectedObjects >= 0,
              restore.selectedBytes >= 0,
              restore.deliveredObjects == 0,
              restore.deliveredBytes == 0,
              ManagedTimestamp.milliseconds(iso8601: restore.snapshotAt) != nil else {
            throw ManagedStorageError.invalidResponse
        }

        var chunkRecords: [ManagedHistoryExportManifest.Chunk] = []
        var documentRecords: [ManagedHistoryExportManifest.Document] = []
        var entryPaths: Set<String> = []
        var completedObjects = 0
        var completedBytes: Int64 = 0

        await report(
            .chunks,
            completedObjects: completedObjects,
            totalObjects: restore.selectedObjects,
            completedBytes: completedBytes,
            totalBytes: restore.selectedBytes,
            to: progress
        )

        for dataClass in classes {
            var cursor: ManagedChunkPage.Cursor?
            repeat {
                try Task.checkCancellation()
                let pageCursor = cursor
                let page = try await authorized(
                    using: authorization,
                    operation: { credential in
                        try await self.transport.availableChunks(
                            dataClass: dataClass,
                            snapshotAt: restore.snapshotAt,
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
                    let capability = try await authorized(
                        using: authorization,
                        operation: { credential in
                            try await self.transport.downloadCapability(
                                chunkID: chunk.chunkID,
                                requestID: ManagedStableIdentifier.uuid(
                                    seed: Data(
                                        (
                                            "noop-managed-history-export-v1\0"
                                            + restore.restoreJobID.uuidString.lowercased()
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
                    chunkRecords.append(
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
                    completedObjects = try Self.add(completedObjects, 1)
                    completedBytes = try Self.add(
                        completedBytes,
                        Int64(chunk.expectedCompressedBytes)
                    )
                    guard completedObjects <= restore.selectedObjects,
                          completedBytes <= restore.selectedBytes else {
                        throw ManagedStorageError.invalidResponse
                    }
                    await report(
                        .chunks,
                        completedObjects: completedObjects,
                        totalObjects: restore.selectedObjects,
                        completedBytes: completedBytes,
                        totalBytes: restore.selectedBytes,
                        to: progress
                    )
                }
                cursor = page.nextCursor
            } while cursor != nil
        }

        await report(
            .documents,
            completedObjects: completedObjects,
            totalObjects: restore.selectedObjects,
            completedBytes: completedBytes,
            totalBytes: restore.selectedBytes,
            to: progress
        )
        var documentCursor: ManagedDocumentPage.Cursor?
        repeat {
            try Task.checkCancellation()
            let pageCursor = documentCursor
            let page = try await authorized(
                using: authorization,
                operation: { credential in
                    try await self.transport.documents(
                        snapshotAt: restore.snapshotAt,
                        after: pageCursor,
                        limit: pageSize,
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
                documentRecords.append(
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
                completedObjects = try Self.add(completedObjects, 1)
                guard completedObjects <= restore.selectedObjects else {
                    throw ManagedStorageError.invalidResponse
                }
                await report(
                    .documents,
                    completedObjects: completedObjects,
                    totalObjects: restore.selectedObjects,
                    completedBytes: completedBytes,
                    totalBytes: restore.selectedBytes,
                    to: progress
                )
            }
            documentCursor = page.nextCursor
        } while documentCursor != nil

        guard completedObjects == restore.selectedObjects,
              completedBytes == restore.selectedBytes else {
            throw ManagedStorageError.invalidResponse
        }
        await report(
            .finalizing,
            completedObjects: completedObjects,
            totalObjects: restore.selectedObjects,
            completedBytes: completedBytes,
            totalBytes: restore.selectedBytes,
            to: progress
        )
        let deliveredObjects = completedObjects
        let deliveredBytes = completedBytes
        let completed = try await authorized(
            using: authorization,
            operation: { credential in
                try await self.transport.completeRestore(
                    restoreJobID: restore.restoreJobID,
                    deliveredObjects: deliveredObjects,
                    deliveredBytes: deliveredBytes,
                    authorization: credential
                )
            }
        )
        guard completed.status == "completed",
              completed.restoreJobID == restore.restoreJobID,
              completed.snapshotAt == restore.snapshotAt,
              completed.changeSequence == restore.changeSequence,
              completed.selectedObjects == restore.selectedObjects,
              completed.selectedBytes == restore.selectedBytes,
              completed.deliveredObjects == completedObjects,
              completed.deliveredBytes == completedBytes else {
            throw ManagedStorageError.invalidResponse
        }

        return ManagedHistoryExportManifest(
            format: "noop_managed_history",
            formatVersion: 1,
            createdAt: ManagedTimestamp.iso8601(
                milliseconds: Int64(
                    (Date().timeIntervalSince1970 * 1_000).rounded(.down)
                )
            ),
            snapshotAt: restore.snapshotAt,
            changeSequence: restore.changeSequence,
            dataClasses: classes,
            selectedObjects: restore.selectedObjects,
            selectedChunkBytes: restore.selectedBytes,
            exportedObjects: completedObjects,
            exportedChunkBytes: completedBytes,
            chunks: chunkRecords,
            documents: documentRecords
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
