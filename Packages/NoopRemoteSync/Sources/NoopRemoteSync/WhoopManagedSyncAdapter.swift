import Foundation
import WhoopStore

public actor WhoopManagedSyncStateStore: ManagedSyncStateStoring {
    private let store: WhoopStore
    private let accountScopeHash: String

    public init(store: WhoopStore, accountScopeHash: String) throws {
        guard accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidConfiguration
        }
        self.store = store
        self.accountScopeHash = accountScopeHash
    }

    public func uploadCheckpoint(
        sourceID: UUID,
        dataClass: String
    ) async throws -> ManagedUploadCheckpoint {
        guard let stored = try await store.managedSyncCheckpoint(
            accountScopeHash: accountScopeHash,
            sourceID: sourceID.uuidString.lowercased(),
            dataClass: dataClass
        ) else {
            return ManagedUploadCheckpoint()
        }
        return ManagedUploadCheckpoint(
            nextWindowStartMs: stored.nextWindowStartMs,
            repairWindowStartMs: stored.repairWindowStartMs
        )
    }

    public func saveUploadCheckpoint(
        _ checkpoint: ManagedUploadCheckpoint,
        sourceID: UUID,
        dataClass: String
    ) async throws {
        try await store.saveManagedSyncCheckpoint(
            ManagedSyncCheckpointState(
                accountScopeHash: accountScopeHash,
                sourceID: sourceID.uuidString.lowercased(),
                dataClass: dataClass,
                nextWindowStartMs: checkpoint.nextWindowStartMs,
                repairWindowStartMs: checkpoint.repairWindowStartMs,
                updatedAtMs: Self.nowMilliseconds()
            )
        )
    }

    public func windowUpload(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws -> ManagedWindowUpload? {
        guard let stored = try await store.managedWindowUpload(
            accountScopeHash: accountScopeHash,
            sourceID: sourceID.uuidString.lowercased(),
            dataClass: dataClass,
            windowStartMs: windowStartMs
        ) else {
            return nil
        }
        guard let chunkID = UUID(uuidString: stored.chunkID),
              stored.windowEndMs >= windowStartMs,
              stored.rowCount >= 0,
              let phase = ManagedWindowUploadPhase(rawValue: stored.phase) else {
            throw ManagedStorageError.invalidResponse
        }
        let receipt: ManagedObjectUploadReceipt?
        switch phase {
        case .pendingCompletion:
            guard let generation = stored.objectGeneration,
                  generation > 0,
                  let metageneration = stored.objectMetageneration,
                  metageneration > 0,
                  let crc = stored.objectCRC32C,
                  crc.range(
                    of: #"^[A-Za-z0-9+/]{6}==$"#,
                    options: .regularExpression
                  ) != nil else {
                throw ManagedStorageError.invalidResponse
            }
            receipt = ManagedObjectUploadReceipt(
                objectGeneration: generation,
                objectMetageneration: metageneration,
                objectCRC32C: crc
            )
        case .awaitingValidation, .available:
            guard stored.objectGeneration == nil,
                  stored.objectMetageneration == nil,
                  stored.objectCRC32C == nil else {
                throw ManagedStorageError.invalidResponse
            }
            receipt = nil
        }
        guard stored.snapshotGeneration >= 0,
              (phase == .available) == (stored.validatedAtMs != nil),
              stored.localPrunedAtMs == nil || phase == .available else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedWindowUpload(
            windowEndMs: stored.windowEndMs,
            chunkID: chunkID,
            rowCount: stored.rowCount,
            phase: phase,
            receipt: receipt,
            snapshotGeneration: stored.snapshotGeneration,
            validatedAtMs: stored.validatedAtMs,
            localPrunedAtMs: stored.localPrunedAtMs
        )
    }

    public func saveWindowUpload(
        _ upload: ManagedWindowUpload,
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws {
        guard (upload.phase == .pendingCompletion) == (upload.receipt != nil) else {
            throw ManagedStorageError.invalidResponse
        }
        try await store.saveManagedWindowUpload(
            ManagedWindowUploadState(
                accountScopeHash: accountScopeHash,
                sourceID: sourceID.uuidString.lowercased(),
                dataClass: dataClass,
                windowStartMs: windowStartMs,
                windowEndMs: upload.windowEndMs,
                chunkID: upload.chunkID.uuidString.lowercased(),
                rowCount: upload.rowCount,
                phase: upload.phase.rawValue,
                objectGeneration: upload.receipt?.objectGeneration,
                objectMetageneration: upload.receipt?.objectMetageneration,
                objectCRC32C: upload.receipt?.objectCRC32C,
                updatedAtMs: Self.nowMilliseconds(),
                snapshotGeneration: upload.snapshotGeneration,
                validatedAtMs: upload.validatedAtMs,
                localPrunedAtMs: upload.localPrunedAtMs
            )
        )
    }

    public func claimWindowGeneration(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> Int64 {
        try await store.claimManagedDirtyWindow(
            localSourceID: localSourceID,
            dataClass: dataClass,
            windowStartMs: window.startMs,
            windowEndMs: window.endExclusiveMs,
            updatedAtMs: Self.nowMilliseconds()
        ).generation
    }

    public func claimNextDirtyWindow(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingAtOrBeforeMs: Int64
    ) async throws -> ManagedDirtyWindow? {
        try await store.claimNextManagedDirtyWindow(
            accountScopeHash: accountScopeHash,
            sourceID: sourceID.uuidString.lowercased(),
            localSourceID: localSourceID,
            dataClass: dataClass,
            endingAtOrBeforeMs: endingAtOrBeforeMs,
            updatedAtMs: Self.nowMilliseconds()
        ).map {
            ManagedDirtyWindow(
                startMs: $0.windowStartMs,
                endExclusiveMs: $0.windowEndMs,
                generation: $0.generation
            )
        }
    }

    public func acknowledgeAvailableChunk(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool {
        try await store.acknowledgeManagedAvailableChunk(
            accountScopeHash: accountScopeHash,
            sourceID: sourceID.uuidString.lowercased(),
            dataClass: dataClass,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            chunkID: chunkID.uuidString.lowercased(),
            validatedAtMs: Self.nowMilliseconds()
        )
    }

    public func markWindowHydrated(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool {
        try await store.markManagedWindowHydrated(
            accountScopeHash: accountScopeHash,
            sourceID: sourceID.uuidString.lowercased(),
            dataClass: dataClass,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            chunkID: chunkID.uuidString.lowercased(),
            updatedAtMs: Self.nowMilliseconds()
        )
    }

    public func pruneAvailableWindows(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingBeforeMs: Int64,
        limit: Int
    ) async throws -> ManagedPruneResult {
        let result = try await store.pruneManagedAvailableWindows(
            accountScopeHash: accountScopeHash,
            sourceID: sourceID.uuidString.lowercased(),
            localSourceID: localSourceID,
            dataClass: dataClass,
            endingBeforeMs: endingBeforeMs,
            limit: limit,
            prunedAtMs: Self.nowMilliseconds()
        )
        return ManagedPruneResult(
            prunedWindows: result.prunedWindows,
            deletedRows: result.deletedRows
        )
    }

    public func changeSequence() async throws -> Int64 {
        try await store.managedChangeSequence(accountScopeHash: accountScopeHash)
    }

    public func saveChangeSequence(_ sequence: Int64) async throws {
        try await store.saveManagedChangeSequence(
            sequence,
            accountScopeHash: accountScopeHash,
            updatedAtMs: Self.nowMilliseconds()
        )
    }

    public func isChangeApplied(_ change: ManagedChangeFeed.Change) async throws -> Bool {
        guard let stored = try await store.managedAppliedChange(
            accountScopeHash: accountScopeHash,
            sequence: change.sequence
        ) else {
            return false
        }
        guard stored.resourceKind == change.resourceKind,
              stored.resourceID.caseInsensitiveCompare(
                change.resourceID.uuidString
              ) == .orderedSame,
              stored.contentSHA256 == change.contentSHA256 else {
            throw ManagedStorageError.invalidResponse
        }
        return true
    }

    public func recordAppliedChange(_ change: ManagedChangeFeed.Change) async throws {
        try await store.recordManagedAppliedChange(
            ManagedAppliedChangeState(
                accountScopeHash: accountScopeHash,
                sequence: change.sequence,
                resourceKind: change.resourceKind,
                resourceID: change.resourceID.uuidString.lowercased(),
                contentSHA256: change.contentSHA256,
                appliedAtMs: Self.nowMilliseconds()
            )
        )
    }

    public func snapshotRestoreCheckpoint(
    ) async throws -> ManagedSnapshotRestoreCheckpoint? {
        guard let stored = try await store.managedSnapshotRestore(
            accountScopeHash: accountScopeHash
        ) else {
            return nil
        }
        guard let requestID = UUID(uuidString: stored.requestID),
              stored.dataClasses == stored.dataClasses.sorted(),
              !stored.dataClasses.isEmpty else {
            throw ManagedStorageError.invalidResponse
        }
        if stored.restoreJobID == nil {
            guard stored.snapshotAt == nil,
                  stored.changeSequence == nil,
                  stored.selectedObjects == nil,
                  stored.selectedBytes == nil,
                  stored.afterEventStart == nil,
                  stored.afterChunkID == nil,
                  stored.afterDocumentUpdatedAt == nil,
                  stored.afterDocumentKind == nil,
                  stored.afterDocumentID == nil,
                  !stored.documentsComplete,
                  stored.dataClassIndex == 0,
                  stored.deliveredObjects == 0,
                  stored.deliveredBytes == 0 else {
                throw ManagedStorageError.invalidResponse
            }
            return ManagedSnapshotRestoreCheckpoint(
                requestID: requestID,
                dataClasses: stored.dataClasses
            )
        }
        guard let restoreJobID = stored.restoreJobID.flatMap(UUID.init(uuidString:)),
              let snapshotAt = stored.snapshotAt,
              let changeSequence = stored.changeSequence,
              let selectedObjects = stored.selectedObjects,
              let selectedBytes = stored.selectedBytes,
              (stored.afterEventStart == nil) == (stored.afterChunkID == nil) else {
            throw ManagedStorageError.invalidResponse
        }
        let cursor = try Self.cursor(
            eventStart: stored.afterEventStart,
            chunkID: stored.afterChunkID
        )
        let documentCursor = try Self.documentCursor(
            updatedAt: stored.afterDocumentUpdatedAt,
            kind: stored.afterDocumentKind,
            documentID: stored.afterDocumentID
        )
        return ManagedSnapshotRestoreCheckpoint(
            requestID: requestID,
            dataClasses: stored.dataClasses,
            restoreJobID: restoreJobID,
            snapshotAt: snapshotAt,
            changeSequence: changeSequence,
            selectedObjects: selectedObjects,
            selectedBytes: selectedBytes,
            dataClassIndex: stored.dataClassIndex,
            cursor: cursor,
            documentCursor: documentCursor,
            documentsComplete: stored.documentsComplete,
            deliveredObjects: stored.deliveredObjects,
            deliveredBytes: stored.deliveredBytes
        )
    }

    public func saveSnapshotRestoreCheckpoint(
        _ checkpoint: ManagedSnapshotRestoreCheckpoint
    ) async throws {
        guard checkpoint.dataClasses == checkpoint.dataClasses.sorted(),
              !checkpoint.dataClasses.isEmpty,
              (checkpoint.cursor == nil || checkpoint.restoreJobID != nil),
              (checkpoint.documentCursor == nil || checkpoint.restoreJobID != nil) else {
            throw ManagedStorageError.invalidResponse
        }
        try await store.saveManagedSnapshotRestore(
            ManagedSnapshotRestoreState(
                accountScopeHash: accountScopeHash,
                requestID: checkpoint.requestID.uuidString.lowercased(),
                dataClasses: checkpoint.dataClasses,
                restoreJobID: checkpoint.restoreJobID?.uuidString.lowercased(),
                snapshotAt: checkpoint.snapshotAt,
                changeSequence: checkpoint.changeSequence,
                selectedObjects: checkpoint.selectedObjects,
                selectedBytes: checkpoint.selectedBytes,
                dataClassIndex: checkpoint.dataClassIndex,
                afterEventStart: checkpoint.cursor?.afterEventStart,
                afterChunkID: checkpoint.cursor?.afterChunkID.uuidString.lowercased(),
                afterDocumentUpdatedAt: checkpoint.documentCursor?.afterUpdatedAt,
                afterDocumentKind: checkpoint.documentCursor?
                    .afterDocumentKind.rawValue,
                afterDocumentID: checkpoint.documentCursor?
                    .afterDocumentID.uuidString.lowercased(),
                documentsComplete: checkpoint.documentsComplete,
                deliveredObjects: checkpoint.deliveredObjects,
                deliveredBytes: checkpoint.deliveredBytes,
                updatedAtMs: Self.nowMilliseconds()
            )
        )
    }

    public func clearSnapshotRestoreCheckpoint() async throws {
        try await store.clearManagedSnapshotRestore(accountScopeHash: accountScopeHash)
    }

    public func finishSnapshotRestore(changeSequence: Int64) async throws {
        try await store.finishManagedSnapshotRestore(
            accountScopeHash: accountScopeHash,
            changeSequence: changeSequence,
            updatedAtMs: Self.nowMilliseconds()
        )
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func cursor(
        eventStart: String?,
        chunkID: String?
    ) throws -> ManagedChunkPage.Cursor? {
        guard let eventStart, let chunkID else { return nil }
        guard ManagedTimestamp.milliseconds(iso8601: eventStart) != nil,
              let id = UUID(uuidString: chunkID) else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedChunkPage.Cursor(
            afterEventStart: eventStart,
            afterChunkID: id
        )
    }

    private static func documentCursor(
        updatedAt: String?,
        kind: String?,
        documentID: String?
    ) throws -> ManagedDocumentPage.Cursor? {
        let values = [updatedAt, kind, documentID]
        guard values.contains(where: { $0 != nil }) else { return nil }
        guard let updatedAt,
              ManagedTimestamp.milliseconds(iso8601: updatedAt) != nil,
              let kind,
              let documentKind = ManagedDocumentKind(rawValue: kind),
              let documentID,
              let id = UUID(uuidString: documentID) else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedDocumentPage.Cursor(
            afterUpdatedAt: updatedAt,
            afterDocumentKind: documentKind,
            afterDocumentID: id
        )
    }
}

public actor WhoopManagedChunkExtractor: ManagedChunkExtracting {
    private let store: WhoopStore

    public init(store: WhoopStore) {
        self.store = store
    }

    public func nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Int64,
        beforeMs: Int64
    ) async throws -> Int64? {
        try await remember(source)
        return try await store.managedSyncNextEventTime(
            localSourceID: source.localSourceID,
            dataClass: dataClass,
            atOrAfterMs: atOrAfterMs,
            beforeMs: beforeMs
        )
    }

    public func streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> [ManagedChunkStreamPayload] {
        try await remember(source)
        return try await store.managedSyncStreams(
            localSourceID: source.localSourceID,
            dataClass: dataClass,
            startMs: window.startMs,
            endExclusiveMs: window.endExclusiveMs
        ).map { stream in
            ManagedChunkStreamPayload(
                streamKey: stream.streamKey,
                columns: stream.columns,
                rows: stream.rows.map { $0.map(Self.convert) },
                schemaRevision: stream.schemaRevision
            )
        }
    }

    private func remember(_ source: ManagedSourceDescriptor) async throws {
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let existing = try await store.managedSyncSource(localSourceID: source.localSourceID)
        try await store.upsertManagedSyncSource(
            ManagedSyncSourceState(
                sourceID: source.sourceID.uuidString.lowercased(),
                localSourceID: source.localSourceID,
                sourceKind: source.sourceKind,
                platform: source.platform.rawValue,
                logicalSourceHash: source.logicalSourceHash,
                createdAtMs: existing?.createdAtMs ?? now,
                updatedAtMs: now
            )
        )
    }

    private static func convert(_ value: ManagedSyncCell) -> ManagedJSONValue {
        switch value {
        case .integer(let value): return .integer(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .boolean(let value): return .boolean(value)
        case .null: return .null
        }
    }
}

public actor WhoopManagedDocumentAdapter:
    ManagedDocumentOutbox,
    WhoopManagedDocumentRestoring
{
    private let store: WhoopStore
    private let accountScopeHash: String
    private let preferencesDefaults: UserDefaults?
    private var candidates: [String: ManagedLocalDocumentCandidate] = [:]

    public init(
        store: WhoopStore,
        accountScopeHash: String,
        preferencesDefaults: UserDefaults? = nil
    ) throws {
        guard accountScopeHash.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw ManagedStorageError.invalidConfiguration
        }
        self.store = store
        self.accountScopeHash = accountScopeHash
        self.preferencesDefaults = preferencesDefaults
    }

    public func pendingDocuments(
        limit: Int
    ) async throws -> [ManagedPendingDocument] {
        // The coordinator reads one look-ahead record to report a truthful bounded backlog.
        guard (1...101).contains(limit) else {
            throw ManagedStorageError.invalidConfiguration
        }
        let local = try await store.pendingManagedDocuments(
            accountScopeHash: accountScopeHash,
            limit: limit
        )
        var pending: [ManagedPendingDocument] = []
        for candidate in local {
            guard let kind = ManagedDocumentKind(
                rawValue: candidate.documentKind
            ) else {
                throw ManagedStorageError.invalidResponse
            }
            let documentID = Self.documentID(
                kind: kind,
                tableName: candidate.tableName,
                keyJSON: candidate.keyJSON
            )
            let payload: [String: ManagedDocumentJSONValue]?
            let contentSHA256: String?
            if let payloadJSON = candidate.payloadJSON {
                do {
                    payload = try JSONDecoder().decode(
                        [String: ManagedDocumentJSONValue].self,
                        from: payloadJSON
                    )
                    contentSHA256 = try Self.canonicalDigest(
                        payload ?? [:]
                    )
                } catch {
                    throw ManagedStorageError.encoding
                }
            } else {
                payload = nil
                contentSHA256 = nil
            }
            let requestID = Self.requestID(
                documentID: documentID,
                generation: candidate.generation,
                baseRevision: candidate.baseRevision,
                contentSHA256: contentSHA256
            )
            let mutation = ManagedDocumentMutation(
                requestID: requestID,
                documentKind: kind,
                documentID: documentID,
                baseRevision: candidate.baseRevision,
                contentMode: "server_readable",
                payloadJSON: payload,
                contentSHA256: contentSHA256,
                updatedAt: ManagedTimestamp.iso8601(
                    milliseconds: candidate.updatedAtMs
                ),
                deleted: candidate.deleted
            )
            let localIdentifier = ManagedDigest.sha256(
                Data(
                    (
                        candidate.tableName + "\0" + candidate.localKey
                    ).utf8
                )
            )
            candidates[localIdentifier] = candidate
            pending.append(
                ManagedPendingDocument(
                    localIdentifier: localIdentifier,
                    generation: candidate.generation,
                    mutation: mutation
                )
            )
        }
        return pending
    }

    public func acknowledge(
        _ pending: ManagedPendingDocument,
        remote: ManagedDocument
    ) async throws {
        guard let candidate = candidates[pending.localIdentifier],
              candidate.generation == pending.generation,
              remote.documentKind == pending.mutation.documentKind,
              remote.documentID == pending.mutation.documentID,
              remote.revision == pending.mutation.baseRevision + 1 else {
            throw ManagedStorageError.invalidResponse
        }
        let expectedDigest: String
        if pending.mutation.deleted {
            expectedDigest = ManagedDigest.sha256(
                Data(
                    (
                        "deleted:\(remote.documentKind.rawValue):"
                            + "\(remote.documentID.uuidString.lowercased()):"
                            + "\(remote.revision)"
                    ).utf8
                )
            )
        } else {
            guard let digest = pending.mutation.contentSHA256 else {
                throw ManagedStorageError.invalidResponse
            }
            expectedDigest = digest
        }
        guard remote.contentSHA256 == expectedDigest else {
            throw ManagedStorageError.invalidResponse
        }
        try await store.acknowledgeManagedDocument(
            accountScopeHash: accountScopeHash,
            candidate: candidate,
            documentID: remote.documentID.uuidString.lowercased(),
            remoteRevision: remote.revision,
            remoteContentSHA256: remote.contentSHA256,
            acknowledgedAtMs: Self.nowMilliseconds()
        )
        candidates.removeValue(forKey: pending.localIdentifier)
    }

    public func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {
        guard document.contentMode == "server_readable",
              document.clientKeyID == nil,
              document.payloadCiphertextBase64 == nil,
              document.revision > 0 else {
            throw ManagedStorageError.invalidResponse
        }

        let deleted = document.deletedAt != nil
        let payloadData: Data?
        if deleted {
            guard document.payloadJSON == nil,
                  change.operation == "tombstone" else {
                throw ManagedStorageError.invalidResponse
            }
            payloadData = nil
        } else {
            guard let payload = document.payloadJSON,
                  change.operation == "upsert" else {
                throw ManagedStorageError.invalidResponse
            }
            let canonical = try Self.canonicalData(payload)
            guard ManagedDigest.sha256(canonical)
                    == document.contentSHA256 else {
                throw ManagedStorageError.invalidResponse
            }
            let expectedID = try Self.documentID(
                kind: document.documentKind,
                payload: payload
            )
            guard expectedID == document.documentID else {
                throw ManagedStorageError.invalidResponse
            }
            payloadData = canonical
        }

        if deleted {
            let expectedDigest = ManagedDigest.sha256(
                Data(
                    (
                        "deleted:\(document.documentKind.rawValue):"
                            + "\(document.documentID.uuidString.lowercased()):"
                            + "\(document.revision)"
                    ).utf8
                )
            )
            guard expectedDigest == document.contentSHA256 else {
                throw ManagedStorageError.invalidResponse
            }
        }

        if document.documentKind == .preferences, !deleted {
            guard let preferencesDefaults, let payloadData else {
                throw ManagedStorageError.invalidResponse
            }
            let decoded = BackupSettings.decode(payloadData)
            guard !decoded.isEmpty,
                  let normalized = BackupSettings.encode(decoded),
                  try Self.equalJSON(normalized, payloadData) else {
                throw ManagedStorageError.invalidResponse
            }
            BackupSettings.apply(decoded, to: preferencesDefaults)
            try await store.stageManagedPreferences(
                normalized,
                updatedAtMs: Self.nowMilliseconds()
            )
        }

        do {
            _ = try await store.applyManagedDocument(
                accountScopeHash: accountScopeHash,
                documentKind: document.documentKind.rawValue,
                documentID: document.documentID.uuidString.lowercased(),
                revision: document.revision,
                contentSHA256: document.contentSHA256,
                payloadJSON: payloadData,
                deleted: deleted,
                appliedAtMs: Self.nowMilliseconds()
            )
        } catch {
            throw ManagedStorageError.invalidResponse
        }
    }

    private static func documentID(
        kind: ManagedDocumentKind,
        tableName: String,
        keyJSON: Data
    ) -> UUID {
        ManagedStableIdentifier.uuid(
            seed: Data(
                (
                    "noop-managed-document-v1\0\(kind.rawValue)\0"
                        + "\(tableName)\0"
                ).utf8
            ) + keyJSON
        )
    }

    private static func documentID(
        kind: ManagedDocumentKind,
        payload: [String: ManagedDocumentJSONValue]
    ) throws -> UUID {
        if kind == .preferences {
            return documentID(
                kind: kind,
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
        return documentID(
            kind: kind,
            tableName: tableName,
            keyJSON: try canonicalData(key)
        )
    }

    private static func requestID(
        documentID: UUID,
        generation: Int64,
        baseRevision: Int64,
        contentSHA256: String?
    ) -> UUID {
        ManagedStableIdentifier.uuid(
            seed: Data(
                (
                    "noop-managed-document-request-v1\0"
                        + "\(documentID.uuidString.lowercased())\0"
                        + "\(generation)\0\(baseRevision)\0"
                        + (contentSHA256 ?? "deleted")
                ).utf8
            )
        )
    }

    private static func canonicalDigest(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> String {
        ManagedDigest.sha256(try canonicalData(payload))
    }

    private static func canonicalData(
        _ payload: [String: ManagedDocumentJSONValue]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func equalJSON(_ lhs: Data, _ rhs: Data) throws -> Bool {
        let left = try JSONSerialization.jsonObject(with: lhs)
        let right = try JSONSerialization.jsonObject(with: rhs)
        return (left as? NSObject)?.isEqual(right) == true
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

public protocol WhoopManagedDocumentRestoring: Sendable {
    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws
}

public struct WhoopManagedRestoreApplier: ManagedRestoreApplying {
    private let store: WhoopStore
    private let documentRestore: (any WhoopManagedDocumentRestoring)?

    public init(
        store: WhoopStore,
        documentRestore: (any WhoopManagedDocumentRestoring)? = nil
    ) {
        self.store = store
        self.documentRestore = documentRestore
    }

    public func apply(
        chunk: ManagedChunkPayload,
        change: ManagedChangeFeed.Change
    ) async throws {
        let canonical: ManagedPreparedChunk
        do {
            guard let prepared = try ManagedPreparedChunk.prepare(
                sourceID: chunk.sourceID,
                dataClass: chunk.dataClass,
                eventStartMs: chunk.eventStartMs,
                eventEndMs: chunk.eventEndMs,
                streams: chunk.streams
            ) else {
                throw ManagedStorageError.invalidResponse
            }
            canonical = prepared
        } catch {
            throw ManagedStorageError.invalidResponse
        }
        guard change.resourceKind == "chunk",
              change.operation == "available",
              canonical.payload == chunk,
              change.resourceID == chunk.chunkID,
              change.dataClass == chunk.dataClass,
              change.eventStart.flatMap(ManagedTimestamp.milliseconds)
                == chunk.eventStartMs,
              change.eventEnd.flatMap(ManagedTimestamp.milliseconds)
                == chunk.eventEndMs,
              let metadata = change.chunk,
              metadata.chunkID == chunk.chunkID,
              metadata.sourceID == chunk.sourceID,
              metadata.schemaVersion == chunk.schemaVersion,
              metadata.state == "available",
              metadata.contentMode == "server_readable",
              metadata.expectedCompressedBytes.map({ $0 > 0 }) == true,
              metadata.expectedUncompressedBytes.map({ $0 > 0 }) == true,
              change.contentSHA256.map(Self.isSHA256) == true else {
            throw ManagedStorageError.invalidResponse
        }

        _ = try await store.applyManagedSyncChunk(Self.restoreChunk(chunk))
    }

    public func hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor
    ) async throws {
        let canonical: ManagedPreparedChunk
        do {
            guard let prepared = try ManagedPreparedChunk.prepare(
                sourceID: chunk.sourceID,
                dataClass: chunk.dataClass,
                eventStartMs: chunk.eventStartMs,
                eventEndMs: chunk.eventEndMs,
                streams: chunk.streams
            ) else {
                throw ManagedStorageError.invalidResponse
            }
            canonical = prepared
        } catch {
            throw ManagedStorageError.invalidResponse
        }
        guard canonical.payload == chunk,
              chunk.sourceID == source.sourceID else {
            throw ManagedStorageError.invalidResponse
        }
        _ = try await store.hydrateManagedSyncChunk(
            Self.restoreChunk(chunk),
            localSourceID: source.localSourceID
        )
    }

    public func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {
        guard change.resourceKind == "document",
              change.resourceID == document.documentID,
              change.contentSHA256 == document.contentSHA256,
              Self.isSHA256(document.contentSHA256),
              let metadata = change.document,
              metadata.documentKind == document.documentKind,
              metadata.documentID == document.documentID,
              metadata.revision == document.revision,
              metadata.contentMode == document.contentMode,
              metadata.clientKeyID == document.clientKeyID,
              metadata.updatedAt == document.updatedAt,
              metadata.deletedAt == document.deletedAt,
              (change.operation == "upsert" || change.operation == "tombstone"),
              let documentRestore else {
            throw ManagedStorageError.invalidResponse
        }
        try await documentRestore.apply(document: document, change: change)
    }

    private static func convert(_ value: ManagedJSONValue) -> ManagedSyncCell {
        switch value {
        case .integer(let value): return .integer(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .boolean(let value): return .boolean(value)
        case .null: return .null
        }
    }

    private static func restoreChunk(
        _ chunk: ManagedChunkPayload
    ) -> ManagedSyncRestoreChunk {
        ManagedSyncRestoreChunk(
            chunkID: chunk.chunkID,
            sourceID: chunk.sourceID,
            dataClass: chunk.dataClass,
            schemaVersion: chunk.schemaVersion,
            eventStartMs: chunk.eventStartMs,
            eventEndMs: chunk.eventEndMs,
            streams: chunk.streams.map { stream in
                ManagedSyncTabularStream(
                    streamKey: stream.streamKey,
                    columns: stream.columns,
                    rows: stream.rows.map { $0.map(Self.convert) },
                    schemaRevision: stream.schemaRevision
                )
            }
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }
}
