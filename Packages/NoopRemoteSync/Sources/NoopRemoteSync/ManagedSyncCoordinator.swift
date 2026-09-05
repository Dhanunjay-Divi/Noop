import Foundation

public struct ManagedSourceDescriptor: Equatable, Sendable {
    public let localSourceID: String
    public let sourceID: UUID
    public let sourceKind: String
    public let platform: ManagedStoragePlatform
    public let logicalSourceHash: String

    public init(
        localSourceID: String,
        sourceKind: String,
        platform: ManagedStoragePlatform,
        installationID: String
    ) throws {
        guard !localSourceID.isEmpty,
              sourceKind.range(
                of: #"^[a-z][a-z0-9_]{1,63}$"#,
                options: .regularExpression
              ) != nil,
              !installationID.isEmpty else {
            throw ManagedStorageError.invalidConfiguration
        }
        let logicalSeed = Data(
            "\(platform.rawValue)\0\(installationID)\0\(localSourceID)".utf8
        )
        self.localSourceID = localSourceID
        self.sourceID = ManagedStableIdentifier.uuid(
            seed: Data("noop-managed-source-v1\0".utf8) + logicalSeed
        )
        self.sourceKind = sourceKind
        self.platform = platform
        self.logicalSourceHash = ManagedDigest.sha256(logicalSeed)
    }
}

public struct ManagedSyncWindow: Codable, Equatable, Sendable {
    public let startMs: Int64
    public let endExclusiveMs: Int64

    public init(startMs: Int64, endExclusiveMs: Int64) throws {
        guard startMs >= 0, endExclusiveMs > startMs else {
            throw ManagedStorageError.invalidConfiguration
        }
        self.startMs = startMs
        self.endExclusiveMs = endExclusiveMs
    }

    public var reservationEndMs: Int64 { endExclusiveMs - 1 }
}

public struct ManagedUploadCheckpoint: Codable, Equatable, Sendable {
    public var nextWindowStartMs: Int64?
    public var repairWindowStartMs: Int64?

    public init(
        nextWindowStartMs: Int64? = nil,
        repairWindowStartMs: Int64? = nil
    ) {
        self.nextWindowStartMs = nextWindowStartMs
        self.repairWindowStartMs = repairWindowStartMs
    }
}

public struct ManagedSnapshotRestoreCheckpoint: Equatable, Sendable {
    public var requestID: UUID
    public var dataClasses: [String]
    public var restoreJobID: UUID?
    public var snapshotAt: String?
    public var changeSequence: Int64?
    public var selectedObjects: Int?
    public var selectedBytes: Int64?
    public var dataClassIndex: Int
    public var cursor: ManagedChunkPage.Cursor?
    public var documentCursor: ManagedDocumentPage.Cursor?
    public var documentsComplete: Bool
    public var deliveredObjects: Int
    public var deliveredBytes: Int64

    public init(
        requestID: UUID,
        dataClasses: [String],
        restoreJobID: UUID? = nil,
        snapshotAt: String? = nil,
        changeSequence: Int64? = nil,
        selectedObjects: Int? = nil,
        selectedBytes: Int64? = nil,
        dataClassIndex: Int = 0,
        cursor: ManagedChunkPage.Cursor? = nil,
        documentCursor: ManagedDocumentPage.Cursor? = nil,
        documentsComplete: Bool = false,
        deliveredObjects: Int = 0,
        deliveredBytes: Int64 = 0
    ) {
        self.requestID = requestID
        self.dataClasses = dataClasses
        self.restoreJobID = restoreJobID
        self.snapshotAt = snapshotAt
        self.changeSequence = changeSequence
        self.selectedObjects = selectedObjects
        self.selectedBytes = selectedBytes
        self.dataClassIndex = dataClassIndex
        self.cursor = cursor
        self.documentCursor = documentCursor
        self.documentsComplete = documentsComplete
        self.deliveredObjects = deliveredObjects
        self.deliveredBytes = deliveredBytes
    }
}

public enum ManagedWindowUploadPhase: String, Equatable, Sendable {
    case pendingCompletion = "pending_completion"
    case awaitingValidation = "awaiting_validation"
    case available
}

public struct ManagedWindowUpload: Equatable, Sendable {
    public let windowEndMs: Int64
    public let chunkID: UUID
    public let rowCount: Int
    public let phase: ManagedWindowUploadPhase
    public let receipt: ManagedObjectUploadReceipt?
    public let snapshotGeneration: Int64
    public let validatedAtMs: Int64?
    public let localPrunedAtMs: Int64?

    public init(
        windowEndMs: Int64,
        chunkID: UUID,
        rowCount: Int,
        phase: ManagedWindowUploadPhase,
        receipt: ManagedObjectUploadReceipt? = nil,
        snapshotGeneration: Int64 = 0,
        validatedAtMs: Int64? = nil,
        localPrunedAtMs: Int64? = nil
    ) {
        self.windowEndMs = windowEndMs
        self.chunkID = chunkID
        self.rowCount = rowCount
        self.phase = phase
        self.receipt = receipt
        self.snapshotGeneration = snapshotGeneration
        self.validatedAtMs = validatedAtMs
        self.localPrunedAtMs = localPrunedAtMs
    }
}

public struct ManagedDirtyWindow: Equatable, Sendable {
    public let startMs: Int64
    public let endExclusiveMs: Int64
    public let generation: Int64

    public init(startMs: Int64, endExclusiveMs: Int64, generation: Int64) {
        self.startMs = startMs
        self.endExclusiveMs = endExclusiveMs
        self.generation = generation
    }
}

public struct ManagedPruneResult: Equatable, Sendable {
    public let prunedWindows: Int
    public let deletedRows: Int

    public init(prunedWindows: Int, deletedRows: Int) {
        self.prunedWindows = prunedWindows
        self.deletedRows = deletedRows
    }
}

public struct ManagedPendingDocument: Equatable, Sendable {
    public let localIdentifier: String
    public let generation: Int64
    public let mutation: ManagedDocumentMutation

    public init(
        localIdentifier: String,
        generation: Int64,
        mutation: ManagedDocumentMutation
    ) {
        self.localIdentifier = localIdentifier
        self.generation = generation
        self.mutation = mutation
    }
}

public protocol ManagedDocumentOutbox: Sendable {
    func pendingDocuments(limit: Int) async throws -> [ManagedPendingDocument]

    func acknowledge(
        _ pending: ManagedPendingDocument,
        remote: ManagedDocument
    ) async throws
}

public protocol ManagedChunkExtracting: Sendable {
    func nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Int64,
        beforeMs: Int64
    ) async throws -> Int64?

    func streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> [ManagedChunkStreamPayload]
}

public protocol ManagedSyncStateStoring: Sendable {
    func uploadCheckpoint(
        sourceID: UUID,
        dataClass: String
    ) async throws -> ManagedUploadCheckpoint

    func saveUploadCheckpoint(
        _ checkpoint: ManagedUploadCheckpoint,
        sourceID: UUID,
        dataClass: String
    ) async throws

    func windowUpload(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws -> ManagedWindowUpload?

    func saveWindowUpload(
        _ upload: ManagedWindowUpload,
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws

    func claimWindowGeneration(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> Int64

    func claimNextDirtyWindow(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingAtOrBeforeMs: Int64
    ) async throws -> ManagedDirtyWindow?

    @discardableResult
    func acknowledgeAvailableChunk(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool

    @discardableResult
    func markWindowHydrated(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool

    func pruneAvailableWindows(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingBeforeMs: Int64,
        limit: Int
    ) async throws -> ManagedPruneResult

    func changeSequence() async throws -> Int64
    func saveChangeSequence(_ sequence: Int64) async throws

    func isChangeApplied(_ change: ManagedChangeFeed.Change) async throws -> Bool
    func recordAppliedChange(_ change: ManagedChangeFeed.Change) async throws

    func snapshotRestoreCheckpoint() async throws -> ManagedSnapshotRestoreCheckpoint?
    func saveSnapshotRestoreCheckpoint(
        _ checkpoint: ManagedSnapshotRestoreCheckpoint
    ) async throws
    func clearSnapshotRestoreCheckpoint() async throws
    func finishSnapshotRestore(changeSequence: Int64) async throws
}

public extension ManagedSyncStateStoring {
    func snapshotRestoreCheckpoint() async throws -> ManagedSnapshotRestoreCheckpoint? {
        nil
    }

    func saveSnapshotRestoreCheckpoint(
        _ checkpoint: ManagedSnapshotRestoreCheckpoint
    ) async throws {
        throw ManagedStorageError.invalidResponse
    }

    func clearSnapshotRestoreCheckpoint() async throws {}

    func finishSnapshotRestore(changeSequence: Int64) async throws {
        try await saveChangeSequence(changeSequence)
        try await clearSnapshotRestoreCheckpoint()
    }
}

public protocol ManagedRestoreApplying: Sendable {
    func apply(
        chunk: ManagedChunkPayload,
        change: ManagedChangeFeed.Change
    ) async throws

    func hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor
    ) async throws

    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws

    func applyMetadataOnly(change: ManagedChangeFeed.Change) async throws
}

public extension ManagedRestoreApplying {
    func applyMetadataOnly(change: ManagedChangeFeed.Change) async throws {}
}

public struct ManagedSyncPolicy: Equatable, Sendable {
    public let windowMilliseconds: Int64
    public let settleMilliseconds: Int64
    public let repairLookbackMilliseconds: Int64
    public let compression: ManagedChunkCompression
    public let maximumCompressedBytes: Int

    public init(
        windowMilliseconds: Int64,
        settleMilliseconds: Int64,
        repairLookbackMilliseconds: Int64,
        compression: ManagedChunkCompression,
        maximumCompressedBytes: Int
    ) throws {
        guard windowMilliseconds > 0,
              settleMilliseconds >= 0,
              repairLookbackMilliseconds >= windowMilliseconds,
              maximumCompressedBytes > 0 else {
            throw ManagedStorageError.invalidConfiguration
        }
        self.windowMilliseconds = windowMilliseconds
        self.settleMilliseconds = settleMilliseconds
        self.repairLookbackMilliseconds = repairLookbackMilliseconds
        self.compression = compression
        self.maximumCompressedBytes = maximumCompressedBytes
    }

    public static func standard(for dataClass: String) throws -> Self {
        let minute: Int64 = 60_000
        let hour = 60 * minute
        let day = 24 * hour
        switch dataClass {
        case "essential_timeseries":
            return try Self(
                windowMilliseconds: 6 * hour,
                settleMilliseconds: 5 * minute,
                repairLookbackMilliseconds: 14 * day,
                compression: .gzip,
                maximumCompressedBytes: 16 * 1_024 * 1_024
            )
        case "raw_auxiliary", "raw_ppg", "raw_motion":
            return try Self(
                windowMilliseconds: hour,
                settleMilliseconds: 5 * minute,
                repairLookbackMilliseconds: 14 * day,
                compression: .gzip,
                maximumCompressedBytes: 16 * 1_024 * 1_024
            )
        case "derived_summaries":
            return try Self(
                windowMilliseconds: 7 * day,
                settleMilliseconds: 5 * minute,
                repairLookbackMilliseconds: 90 * day,
                compression: .gzip,
                maximumCompressedBytes: 4 * 1_024 * 1_024
            )
        default:
            throw ManagedStorageError.invalidConfiguration
        }
    }
}

public enum ManagedLocalRetentionPolicy {
    public static let rawHistoryDays: Int64 = 7
    public static let essentialHistoryDays: Int64 = 30
    private static let dayMilliseconds: Int64 = 86_400_000

    public static func retainedDays(for dataClass: String) -> Int64? {
        switch dataClass {
        case "essential_timeseries":
            essentialHistoryDays
        case "raw_auxiliary", "raw_ppg", "raw_motion":
            rawHistoryDays
        default:
            nil
        }
    }

    public static func cutoff(nowMs: Int64, dataClass: String) -> Int64? {
        guard let days = retainedDays(for: dataClass) else { return nil }
        let retainedMilliseconds = days * dayMilliseconds
        return nowMs > retainedMilliseconds ? nowMs - retainedMilliseconds : 0
    }
}

public struct ManagedSyncRunResult: Equatable, Sendable {
    public let uploadedChunks: Int
    public let uploadedBytes: Int
    public let uploadedDocuments: Int
    public let advancedEmptyWindows: Int
    public let repairedWindows: Int
    public let appliedChanges: Int
    public let hasMoreChanges: Bool
    /// A bounded local budget was exhausted or known local work remains. A confirmation pass may
    /// discover that a budget was hit exactly; schedulers should still continue once rather than
    /// leave a large first backup waiting for an unrelated future wake.
    public let hasMoreLocalWork: Bool
    public let prunedWindows: Int
    public let prunedRows: Int

    public var hasMoreWork: Bool {
        hasMoreChanges || hasMoreLocalWork
    }
}

public actor ManagedSyncCoordinator {
    public static let chunkDataClasses = [
        "essential_timeseries",
        "raw_auxiliary",
        "raw_ppg",
        "raw_motion",
        "derived_summaries",
    ]

    private let transport: any ManagedStorageTransport
    private let extractor: any ManagedChunkExtracting
    private let state: any ManagedSyncStateStoring
    private let restore: any ManagedRestoreApplying
    private let documents: (any ManagedDocumentOutbox)?

    public init(
        transport: any ManagedStorageTransport,
        extractor: any ManagedChunkExtracting,
        state: any ManagedSyncStateStoring,
        restore: any ManagedRestoreApplying,
        documents: (any ManagedDocumentOutbox)? = nil
    ) {
        self.transport = transport
        self.extractor = extractor
        self.state = state
        self.restore = restore
        self.documents = documents
    }

    public func sync(
        source: ManagedSourceDescriptor,
        authorization: ManagedAuthorization,
        now: Date = Date(),
        dataClasses: [String] = ManagedSyncCoordinator.chunkDataClasses,
        maxForwardWindowsPerClass: Int = 4,
        maxDirtyWindowsPerClass: Int = 4,
        maxChangePages: Int = 2,
        changePageSize: Int = 100,
        maxSnapshotRestoreObjects: Int = 16,
        maxSnapshotRestoreBytes: Int = 32 * 1_024 * 1_024,
        maxDocumentUploads: Int = 16,
        localPruneNowMs: Int64? = nil,
        maxPruneWindowsPerClass: Int = 4
    ) async throws -> ManagedSyncRunResult {
        guard (1...100).contains(maxForwardWindowsPerClass),
              (1...100).contains(maxDirtyWindowsPerClass),
              (0...20).contains(maxChangePages),
              (1...500).contains(changePageSize),
              (1...200).contains(maxSnapshotRestoreObjects),
              maxSnapshotRestoreBytes > 0,
              (0...100).contains(maxDocumentUploads),
              (0...16).contains(maxPruneWindowsPerClass),
              localPruneNowMs.map({ $0 >= 0 }) ?? true,
              Set(dataClasses).count == dataClasses.count else {
            throw ManagedStorageError.invalidConfiguration
        }
        _ = try await transport.registerSource(
            ManagedSourceRegistration(
                sourceID: source.sourceID,
                sourceKind: source.sourceKind,
                platform: source.platform,
                logicalSourceHash: source.logicalSourceHash
            ),
            authorization: authorization
        )

        var uploadedChunks = 0
        var uploadedBytes = 0
        var emptyWindows = 0
        var repairedWindows = 0
        var prunedWindows = 0
        var prunedRows = 0
        var hasMoreLocalWork = false
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let changes = try await applyChanges(
            authorization: authorization,
            maxPages: maxChangePages,
            pageSize: changePageSize,
            dataClasses: dataClasses.sorted(),
            maxSnapshotObjects: maxSnapshotRestoreObjects,
            maxSnapshotBytes: maxSnapshotRestoreBytes
        )
        let documentUpload = try await uploadPendingDocuments(
            authorization: authorization,
            limit: changes.hasMore ? 0 : maxDocumentUploads
        )
        hasMoreLocalWork = documentUpload.hasMore

        for dataClass in dataClasses.sorted() {
            let policy = try ManagedSyncPolicy.standard(for: dataClass)
            var checkpoint = try await state.uploadCheckpoint(
                sourceID: source.sourceID,
                dataClass: dataClass
            )
            let cutoff = alignedFloor(
                max(0, nowMs - policy.settleMilliseconds),
                interval: policy.windowMilliseconds
            )
            var dirtyProcessed = 0
            while dirtyProcessed < maxDirtyWindowsPerClass,
                  let dirty = try await state.claimNextDirtyWindow(
                      sourceID: source.sourceID,
                      localSourceID: source.localSourceID,
                      dataClass: dataClass,
                      endingAtOrBeforeMs: cutoff
                  ) {
                guard dirty.startMs % policy.windowMilliseconds == 0,
                      dirty.endExclusiveMs ==
                        dirty.startMs + policy.windowMilliseconds,
                      dirty.generation > 0 else {
                    throw ManagedStorageError.invalidResponse
                }
                let transfer = try await transferWindow(
                    source: source,
                    dataClass: dataClass,
                    window: try ManagedSyncWindow(
                        startMs: dirty.startMs,
                        endExclusiveMs: dirty.endExclusiveMs
                    ),
                    policy: policy,
                    authorization: authorization,
                    snapshotGeneration: dirty.generation
                )
                uploadedChunks += transfer.uploaded ? 1 : 0
                uploadedBytes += transfer.bytes
                dirtyProcessed += 1
            }
            if dirtyProcessed == maxDirtyWindowsPerClass {
                hasMoreLocalWork = true
            }
            var next = checkpoint.nextWindowStartMs
            if next == nil {
                next = try await extractor.nextEventTime(
                    source: source,
                    dataClass: dataClass,
                    atOrAfterMs: 0,
                    beforeMs: cutoff
                ).map {
                    alignedFloor($0, interval: policy.windowMilliseconds)
                } ?? cutoff
            }

            var processed = 0
            while let cursor = next, cursor < cutoff,
                  processed < maxForwardWindowsPerClass {
                let event = try await extractor.nextEventTime(
                    source: source,
                    dataClass: dataClass,
                    atOrAfterMs: cursor,
                    beforeMs: cutoff
                )
                guard let event else {
                    next = cutoff
                    break
                }
                let start = max(
                    cursor,
                    alignedFloor(event, interval: policy.windowMilliseconds)
                )
                let end = min(cutoff, start + policy.windowMilliseconds)
                let window = try ManagedSyncWindow(
                    startMs: start,
                    endExclusiveMs: end
                )
                let transfer = try await transferWindow(
                    source: source,
                    dataClass: dataClass,
                    window: window,
                    policy: policy,
                    authorization: authorization
                )
                uploadedChunks += transfer.uploaded ? 1 : 0
                uploadedBytes += transfer.bytes
                emptyWindows += transfer.hadRows ? 0 : 1
                next = end
                checkpoint.nextWindowStartMs = end
                try await state.saveUploadCheckpoint(
                    checkpoint,
                    sourceID: source.sourceID,
                    dataClass: dataClass
                )
                processed += 1
            }
            if let next, next < cutoff {
                hasMoreLocalWork = true
            }
            checkpoint.nextWindowStartMs = next

            if next == cutoff, cutoff > 0 {
                let lower = alignedFloor(
                    max(0, cutoff - policy.repairLookbackMilliseconds),
                    interval: policy.windowMilliseconds
                )
                var repairStart = checkpoint.repairWindowStartMs ?? lower
                if repairStart < lower || repairStart >= cutoff {
                    repairStart = lower
                }
                if repairStart < cutoff {
                    let repairEnd = min(
                        cutoff,
                        repairStart + policy.windowMilliseconds
                    )
                    let hasEvent = try await extractor.nextEventTime(
                        source: source,
                        dataClass: dataClass,
                        atOrAfterMs: repairStart,
                        beforeMs: repairEnd
                    ) != nil
                    let priorUpload = try await state.windowUpload(
                        sourceID: source.sourceID,
                        dataClass: dataClass,
                        windowStartMs: repairStart
                    )
                    if hasEvent || priorUpload != nil {
                        let transfer = try await transferWindow(
                            source: source,
                            dataClass: dataClass,
                            window: try ManagedSyncWindow(
                                startMs: repairStart,
                                endExclusiveMs: repairEnd
                            ),
                            policy: policy,
                            authorization: authorization
                        )
                        uploadedChunks += transfer.uploaded ? 1 : 0
                        uploadedBytes += transfer.bytes
                        repairedWindows += 1
                    }
                    checkpoint.repairWindowStartMs =
                        repairEnd >= cutoff ? lower : repairEnd
                }
            }
            try await state.saveUploadCheckpoint(
                checkpoint,
                sourceID: source.sourceID,
                dataClass: dataClass
            )
            if let localPruneNowMs,
               let localPruneBeforeMs = ManagedLocalRetentionPolicy.cutoff(
                   nowMs: localPruneNowMs,
                   dataClass: dataClass
               ),
               maxPruneWindowsPerClass > 0 {
                let result = try await state.pruneAvailableWindows(
                    sourceID: source.sourceID,
                    localSourceID: source.localSourceID,
                    dataClass: dataClass,
                    endingBeforeMs: localPruneBeforeMs,
                    limit: maxPruneWindowsPerClass
                )
                prunedWindows += result.prunedWindows
                prunedRows += result.deletedRows
                if result.prunedWindows == maxPruneWindowsPerClass {
                    hasMoreLocalWork = true
                }
            }
        }

        return ManagedSyncRunResult(
            uploadedChunks: uploadedChunks,
            uploadedBytes: uploadedBytes,
            uploadedDocuments: documentUpload.uploaded,
            advancedEmptyWindows: emptyWindows,
            repairedWindows: repairedWindows,
            appliedChanges: changes.applied,
            hasMoreChanges: changes.hasMore,
            hasMoreLocalWork: hasMoreLocalWork,
            prunedWindows: prunedWindows,
            prunedRows: prunedRows
        )
    }

    private func uploadPendingDocuments(
        authorization: ManagedAuthorization,
        limit: Int
    ) async throws -> (uploaded: Int, hasMore: Bool) {
        guard limit > 0, let documents else { return (0, false) }
        let pending = try await documents.pendingDocuments(limit: limit + 1)
        guard pending.count <= limit + 1,
              Set(pending.map(\.localIdentifier)).count == pending.count else {
            throw ManagedStorageError.invalidResponse
        }

        for item in pending.prefix(limit) {
            try Task.checkCancellation()
            let mutation = item.mutation
            guard item.generation > 0,
                  !item.localIdentifier.isEmpty,
                  mutation.baseRevision >= 0,
                  ManagedTimestamp.milliseconds(
                      iso8601: mutation.updatedAt
                  ) != nil else {
                throw ManagedStorageError.invalidResponse
            }
            let remote = try await transport.putDocument(
                mutation,
                authorization: authorization
            )
            guard remote.documentKind == mutation.documentKind,
                  remote.documentID == mutation.documentID,
                  remote.revision == mutation.baseRevision + 1,
                  remote.originInstallationID == authorization.installationID,
                  remote.contentMode == mutation.contentMode,
                  remote.clientKeyID == mutation.clientKeyID,
                  remote.payloadJSON == mutation.payloadJSON,
                  remote.payloadCiphertextBase64
                    == mutation.payloadCiphertextBase64,
                  (remote.deletedAt != nil) == mutation.deleted,
                  ManagedTimestamp.milliseconds(
                      iso8601: remote.updatedAt
                  ) != nil,
                  remote.contentSHA256.range(
                      of: #"^[0-9a-f]{64}$"#,
                      options: .regularExpression
                  ) != nil,
                  mutation.contentSHA256.map({
                      $0 == remote.contentSHA256
                  }) ?? true else {
                throw ManagedStorageError.invalidResponse
            }
            try await documents.acknowledge(item, remote: remote)
        }
        return (min(pending.count, limit), pending.count > limit)
    }

    private func transferWindow(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow,
        policy: ManagedSyncPolicy,
        authorization: ManagedAuthorization,
        snapshotGeneration suppliedGeneration: Int64? = nil
    ) async throws -> (uploaded: Bool, bytes: Int, hadRows: Bool) {
        var previous = try await state.windowUpload(
            sourceID: source.sourceID,
            dataClass: dataClass,
            windowStartMs: window.startMs
        )
        if let previous, previous.windowEndMs != window.reservationEndMs {
            throw ManagedStorageError.invalidResponse
        }
        if let pending = previous, pending.phase == .pendingCompletion {
            guard let receipt = pending.receipt else {
                throw ManagedStorageError.invalidResponse
            }
            try await transport.completeChunk(
                chunkID: pending.chunkID,
                receipt: receipt,
                authorization: authorization
            )
            let awaiting = ManagedWindowUpload(
                windowEndMs: pending.windowEndMs,
                chunkID: pending.chunkID,
                rowCount: pending.rowCount,
                phase: .awaitingValidation,
                snapshotGeneration: pending.snapshotGeneration
            )
            try await state.saveWindowUpload(
                awaiting,
                sourceID: source.sourceID,
                dataClass: dataClass,
                windowStartMs: window.startMs
            )
            return (false, 0, pending.rowCount > 0)
        }
        if previous?.phase == .awaitingValidation {
            return (false, 0, previous?.rowCount ?? 0 > 0)
        }
        if let pruned = previous, pruned.localPrunedAtMs != nil {
            // A periodic repair must not restore data the user explicitly chose to remove from
            // the phone. Hydration is required only for a real post-prune local mutation.
            guard suppliedGeneration != nil else {
                return (false, 0, pruned.rowCount > 0)
            }
            try await hydratePrunedWindow(
                source: source,
                dataClass: dataClass,
                window: window,
                upload: pruned,
                authorization: authorization
            )
            previous = try await state.windowUpload(
                sourceID: source.sourceID,
                dataClass: dataClass,
                windowStartMs: window.startMs
            )
            guard previous?.localPrunedAtMs == nil else {
                throw ManagedStorageError.invalidResponse
            }
        }
        let streams = try await extractor.streams(
            source: source,
            dataClass: dataClass,
            window: window
        )
        let rowCount = streams.reduce(0) { $0 + $1.rows.count }
        guard let prepared = try ManagedPreparedChunk.prepare(
            sourceID: source.sourceID,
            dataClass: dataClass,
            eventStartMs: window.startMs,
            eventEndMs: window.reservationEndMs,
            streams: streams
        ) else {
            return (false, 0, false)
        }
        if let previous,
           previous.phase == .available,
           previous.chunkID == prepared.payload.chunkID {
            let generation: Int64
            if let suppliedGeneration {
                generation = suppliedGeneration
            } else {
                generation = try await state.claimWindowGeneration(
                    sourceID: source.sourceID,
                    localSourceID: source.localSourceID,
                    dataClass: dataClass,
                    window: window
                )
            }
            guard let validatedAtMs = previous.validatedAtMs else {
                throw ManagedStorageError.invalidResponse
            }
            try await state.saveWindowUpload(
                ManagedWindowUpload(
                    windowEndMs: previous.windowEndMs,
                    chunkID: previous.chunkID,
                    rowCount: rowCount,
                    phase: .available,
                    snapshotGeneration: generation,
                    validatedAtMs: validatedAtMs,
                    localPrunedAtMs: previous.localPrunedAtMs
                ),
                sourceID: source.sourceID,
                dataClass: dataClass,
                windowStartMs: window.startMs
            )
            return (false, 0, rowCount > 0)
        }
        if rowCount == 0, previous == nil {
            return (false, 0, false)
        }
        let snapshotGeneration: Int64
        if let suppliedGeneration {
            snapshotGeneration = suppliedGeneration
        } else {
            snapshotGeneration = try await state.claimWindowGeneration(
                sourceID: source.sourceID,
                localSourceID: source.localSourceID,
                dataClass: dataClass,
                window: window
            )
        }
        let encoded = try ManagedChunkCodec.encode(
            prepared.uncompressed,
            compression: policy.compression
        )
        guard encoded.count <= policy.maximumCompressedBytes else {
            throw ManagedStorageError.quotaExceeded
        }
        let reservation = prepared.reservation(
            compressed: encoded,
            compression: policy.compression.rawValue
        )
        let response = try await transport.reserveChunk(
            reservation,
            authorization: authorization
        )
        guard let capability = response.upload else {
            guard response.chunk.chunkID == prepared.payload.chunkID,
                  ["uploaded", "validating", "available"].contains(
                    response.chunk.state
                  ) else {
                throw ManagedStorageError.invalidResponse
            }
            try await state.saveWindowUpload(
                ManagedWindowUpload(
                    windowEndMs: window.reservationEndMs,
                    chunkID: prepared.payload.chunkID,
                    rowCount: rowCount,
                    phase: .awaitingValidation,
                    snapshotGeneration: snapshotGeneration
                ),
                sourceID: source.sourceID,
                dataClass: dataClass,
                windowStartMs: window.startMs
            )
            return (false, 0, rowCount > 0)
        }
        let receipt = try await transport.upload(encoded, using: capability)
        try await state.saveWindowUpload(
            ManagedWindowUpload(
                windowEndMs: window.reservationEndMs,
                chunkID: prepared.payload.chunkID,
                rowCount: rowCount,
                phase: .pendingCompletion,
                receipt: receipt,
                snapshotGeneration: snapshotGeneration
            ),
            sourceID: source.sourceID,
            dataClass: dataClass,
            windowStartMs: window.startMs
        )
        try await transport.completeChunk(
            chunkID: prepared.payload.chunkID,
            receipt: receipt,
            authorization: authorization
        )
        try await state.saveWindowUpload(
            ManagedWindowUpload(
                windowEndMs: window.reservationEndMs,
                chunkID: prepared.payload.chunkID,
                rowCount: rowCount,
                phase: .awaitingValidation,
                snapshotGeneration: snapshotGeneration
            ),
            sourceID: source.sourceID,
            dataClass: dataClass,
            windowStartMs: window.startMs
        )
        return (true, encoded.count, rowCount > 0)
    }

    private func hydratePrunedWindow(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow,
        upload: ManagedWindowUpload,
        authorization: ManagedAuthorization
    ) async throws {
        guard upload.phase == .available,
              upload.validatedAtMs != nil,
              upload.localPrunedAtMs != nil,
              upload.windowEndMs == window.reservationEndMs else {
            throw ManagedStorageError.invalidResponse
        }
        let capability = try await transport.downloadCapability(
            chunkID: upload.chunkID,
            requestID: ManagedStableIdentifier.uuid(
                seed: Data(
                    "noop-managed-hydration-v1\0"
                        .utf8
                ) + Data(upload.chunkID.uuidString.lowercased().utf8)
            ),
            authorization: authorization
        )
        guard capability.chunk.chunkID == upload.chunkID,
              capability.chunk.expectedSHA256.range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil,
              capability.chunk.contentType == "application/vnd.noop.chunk+json",
              let expectedBytes = capability.chunk.expectedUncompressedBytes,
              expectedBytes > 0 else {
            throw ManagedStorageError.invalidResponse
        }
        let compressed = try await transport.download(using: capability)
        let decoded = try ManagedChunkCodec.decode(
            compressed,
            compression: capability.chunk.compression,
            expectedUncompressedBytes: expectedBytes
        )
        let payload: ManagedChunkPayload
        do {
            payload = try JSONDecoder().decode(ManagedChunkPayload.self, from: decoded)
        } catch {
            throw ManagedStorageError.decoding
        }
        guard payload.chunkID == upload.chunkID,
              payload.sourceID == source.sourceID,
              payload.dataClass == dataClass,
              payload.eventStartMs == window.startMs,
              payload.eventEndMs == window.reservationEndMs,
              let canonical = try ManagedPreparedChunk.prepare(
                  sourceID: payload.sourceID,
                  dataClass: payload.dataClass,
                  eventStartMs: payload.eventStartMs,
                  eventEndMs: payload.eventEndMs,
                  streams: payload.streams
              ),
              canonical.payload == payload,
              canonical.uncompressed == decoded else {
            throw ManagedStorageError.invalidResponse
        }
        try await restore.hydrate(chunk: payload, source: source)
        guard try await state.markWindowHydrated(
            sourceID: source.sourceID,
            dataClass: dataClass,
            windowStartMs: window.startMs,
            windowEndMs: window.reservationEndMs,
            chunkID: upload.chunkID
        ) else {
            throw ManagedStorageError.invalidResponse
        }
    }

    private func applyChanges(
        authorization: ManagedAuthorization,
        maxPages: Int,
        pageSize: Int,
        dataClasses: [String],
        maxSnapshotObjects: Int,
        maxSnapshotBytes: Int
    ) async throws -> (applied: Int, hasMore: Bool) {
        guard maxPages > 0 else { return (0, false) }
        var sequence = try await state.changeSequence()
        var applied = 0
        var hasMore = false

        if var checkpoint = try await state.snapshotRestoreCheckpoint() {
            if checkpoint.dataClasses != dataClasses {
                try await state.clearSnapshotRestoreCheckpoint()
                checkpoint = ManagedSnapshotRestoreCheckpoint(
                    requestID: UUID(),
                    dataClasses: dataClasses
                )
                try await state.saveSnapshotRestoreCheckpoint(checkpoint)
            }
            let snapshot = try await resumeSnapshotRestoreRecoveringInvalidation(
                checkpoint: checkpoint,
                authorization: authorization,
                maxPages: maxPages,
                pageSize: min(pageSize, 200),
                maxObjects: maxSnapshotObjects,
                maxBytes: maxSnapshotBytes
            )
            applied += snapshot.applied
            guard snapshot.completed else {
                return (applied, true)
            }
            sequence = try await state.changeSequence()
        }

        for _ in 0..<maxPages {
            let feed: ManagedChangeFeed
            do {
                feed = try await transport.changes(
                    after: sequence,
                    limit: pageSize,
                    authorization: authorization
                )
            } catch let error as ManagedStorageError {
                guard case .cursorExpired = error else { throw error }
                var checkpoint = ManagedSnapshotRestoreCheckpoint(
                    requestID: UUID(),
                    dataClasses: dataClasses
                )
                try await state.saveSnapshotRestoreCheckpoint(checkpoint)
                checkpoint = try await state.snapshotRestoreCheckpoint() ?? checkpoint
                let snapshot = try await resumeSnapshotRestoreRecoveringInvalidation(
                    checkpoint: checkpoint,
                    authorization: authorization,
                    maxPages: maxPages,
                    pageSize: min(pageSize, 200),
                    maxObjects: maxSnapshotObjects,
                    maxBytes: maxSnapshotBytes
                )
                return (applied + snapshot.applied, true)
            }
            for change in feed.changes {
                guard change.sequence > sequence else {
                    throw ManagedStorageError.invalidResponse
                }
                if try await state.isChangeApplied(change) {
                    _ = try await acknowledgeAvailableChange(change)
                    sequence = change.sequence
                    try await state.saveChangeSequence(sequence)
                    applied += 1
                    continue
                }
                let isLocalUpload = try await acknowledgeAvailableChange(change)
                if change.resourceKind == "chunk",
                   change.operation == "available",
                   let changedChunk = change.chunk {
                    if !isLocalUpload {
                        _ = try await downloadAndApply(
                            change: change,
                            chunk: changedChunk,
                            requestID: ManagedStableIdentifier.uuid(
                                seed: Data(
                                    "noop-managed-download-v1\0\(change.sequence)"
                                        .utf8
                                )
                            ),
                            authorization: authorization
                        )
                    }
                } else if change.resourceKind == "document",
                          let changedDocument = change.document {
                    let document = try await transport.document(
                        kind: changedDocument.documentKind,
                        id: changedDocument.documentID,
                        revision: changedDocument.revision,
                        authorization: authorization
                    )
                    try await restore.apply(document: document, change: change)
                } else {
                    try await restore.applyMetadataOnly(change: change)
                }
                try await state.recordAppliedChange(change)
                sequence = change.sequence
                try await state.saveChangeSequence(sequence)
                applied += 1
            }
            hasMore = feed.hasMore
            if !feed.hasMore { break }
        }
        return (applied, hasMore)
    }

    private func resumeSnapshotRestoreRecoveringInvalidation(
        checkpoint: ManagedSnapshotRestoreCheckpoint,
        authorization: ManagedAuthorization,
        maxPages: Int,
        pageSize: Int,
        maxObjects: Int,
        maxBytes: Int
    ) async throws -> (applied: Int, completed: Bool) {
        do {
            return try await resumeSnapshotRestore(
                checkpoint: checkpoint,
                authorization: authorization,
                maxPages: maxPages,
                pageSize: pageSize,
                maxObjects: maxObjects,
                maxBytes: maxBytes
            )
        } catch let error as ManagedStorageError {
            switch error {
            case .notFound, .conflict:
                // Restore jobs and immutable objects can expire between background
                // runs. Replace only the restore checkpoint; the local data and
                // anchored change cursor remain untouched.
                try await state.clearSnapshotRestoreCheckpoint()
                try await state.saveSnapshotRestoreCheckpoint(
                    ManagedSnapshotRestoreCheckpoint(
                        requestID: UUID(),
                        dataClasses: checkpoint.dataClasses
                    )
                )
                return (0, false)
            default:
                throw error
            }
        }
    }

    private func resumeSnapshotRestore(
        checkpoint initialCheckpoint: ManagedSnapshotRestoreCheckpoint,
        authorization: ManagedAuthorization,
        maxPages: Int,
        pageSize: Int,
        maxObjects: Int,
        maxBytes: Int
    ) async throws -> (applied: Int, completed: Bool) {
        var checkpoint = initialCheckpoint
        if checkpoint.restoreJobID == nil {
            let restoreJob = try await transport.createRestore(
                requestID: checkpoint.requestID,
                dataClasses: checkpoint.dataClasses,
                authorization: authorization
            )
            guard restoreJob.status == "running" else {
                throw ManagedStorageError.invalidResponse
            }
            checkpoint.restoreJobID = restoreJob.restoreJobID
            checkpoint.snapshotAt = restoreJob.snapshotAt
            checkpoint.changeSequence = restoreJob.changeSequence
            checkpoint.selectedObjects = restoreJob.selectedObjects
            checkpoint.selectedBytes = restoreJob.selectedBytes
            try await state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        guard let restoreJobID = checkpoint.restoreJobID,
              let snapshotAt = checkpoint.snapshotAt,
              let changeSequence = checkpoint.changeSequence,
              let selectedObjects = checkpoint.selectedObjects,
              let selectedBytes = checkpoint.selectedBytes,
              changeSequence >= 0,
              selectedObjects >= 0,
              selectedBytes >= 0,
              checkpoint.dataClassIndex >= 0,
              checkpoint.dataClassIndex <= checkpoint.dataClasses.count,
              checkpoint.deliveredObjects >= 0,
              checkpoint.deliveredObjects <= selectedObjects,
              checkpoint.deliveredBytes >= 0,
              checkpoint.deliveredBytes <= selectedBytes else {
            throw ManagedStorageError.invalidResponse
        }

        var pages = 0
        var applied = 0
        var downloadedBytes = 0
        var processedObjects = 0
        while checkpoint.dataClassIndex < checkpoint.dataClasses.count,
              pages < maxPages,
              processedObjects < maxObjects {
            let dataClass = checkpoint.dataClasses[checkpoint.dataClassIndex]
            let page = try await transport.availableChunks(
                dataClass: dataClass,
                snapshotAt: snapshotAt,
                after: checkpoint.cursor,
                limit: min(pageSize, maxObjects - processedObjects),
                authorization: authorization
            )
            guard !page.chunks.isEmpty || page.nextCursor == nil else {
                throw ManagedStorageError.invalidResponse
            }
            var consumedPage = true
            for available in page.chunks {
                if processedObjects >= maxObjects {
                    consumedPage = false
                    break
                }
                let change = available.changeMetadata
                let localUpload = try await acknowledgeAvailableChange(change)
                let expectedDownload = localUpload ? 0 : available.expectedCompressedBytes
                if processedObjects > 0,
                   expectedDownload > maxBytes - downloadedBytes {
                    consumedPage = false
                    break
                }
                var deliveredBytes = 0
                if !localUpload {
                    guard let changedChunk = change.chunk else {
                        throw ManagedStorageError.invalidResponse
                    }
                    deliveredBytes = try await downloadAndApply(
                        change: change,
                        chunk: changedChunk,
                        requestID: ManagedStableIdentifier.uuid(
                            seed: Data(
                                (
                                    "noop-managed-snapshot-download-v1\0"
                                    + restoreJobID.uuidString.lowercased()
                                    + "\0"
                                    + available.chunkID.uuidString.lowercased()
                                ).utf8
                            )
                        ),
                        authorization: authorization
                    )
                }
                let nextDeliveredBytes = checkpoint.deliveredBytes
                    .addingReportingOverflow(Int64(deliveredBytes))
                guard !nextDeliveredBytes.overflow,
                      nextDeliveredBytes.partialValue <= selectedBytes else {
                    throw ManagedStorageError.invalidResponse
                }
                checkpoint.deliveredObjects += 1
                checkpoint.deliveredBytes = nextDeliveredBytes.partialValue
                checkpoint.cursor = ManagedChunkPage.Cursor(
                    afterEventStart: available.eventStart,
                    afterChunkID: available.chunkID
                )
                try await state.saveSnapshotRestoreCheckpoint(checkpoint)
                downloadedBytes += deliveredBytes
                processedObjects += 1
                applied += 1
            }
            pages += 1
            if !consumedPage {
                return (applied, false)
            }
            if page.nextCursor == nil {
                checkpoint.dataClassIndex += 1
                checkpoint.cursor = nil
            } else {
                checkpoint.cursor = page.nextCursor
            }
            try await state.saveSnapshotRestoreCheckpoint(checkpoint)
        }

        guard checkpoint.dataClassIndex == checkpoint.dataClasses.count else {
            return (applied, false)
        }
        if checkpoint.deliveredObjects == selectedObjects {
            checkpoint.documentCursor = nil
            checkpoint.documentsComplete = true
            try await state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        while !checkpoint.documentsComplete,
              pages < maxPages,
              processedObjects < maxObjects {
            let page = try await transport.documents(
                snapshotAt: snapshotAt,
                after: checkpoint.documentCursor,
                limit: min(pageSize, maxObjects - processedObjects),
                authorization: authorization
            )
            guard !page.documents.isEmpty || page.nextCursor == nil else {
                throw ManagedStorageError.invalidResponse
            }
            var consumedPage = true
            for document in page.documents {
                if processedObjects >= maxObjects {
                    consumedPage = false
                    break
                }
                try await restore.apply(
                    document: document,
                    change: document.changeMetadata
                )
                checkpoint.documentCursor = document.pageCursor
                checkpoint.deliveredObjects += 1
                guard checkpoint.deliveredObjects <= selectedObjects else {
                    throw ManagedStorageError.invalidResponse
                }
                try await state.saveSnapshotRestoreCheckpoint(checkpoint)
                processedObjects += 1
                applied += 1
            }
            pages += 1
            if !consumedPage {
                return (applied, false)
            }
            if let next = page.nextCursor {
                checkpoint.documentCursor = next
            } else {
                checkpoint.documentCursor = nil
                checkpoint.documentsComplete = true
            }
            try await state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        guard checkpoint.documentsComplete else {
            return (applied, false)
        }
        guard checkpoint.deliveredObjects == selectedObjects else {
            throw ManagedStorageError.invalidResponse
        }
        let completed = try await transport.completeRestore(
            restoreJobID: restoreJobID,
            deliveredObjects: checkpoint.deliveredObjects,
            deliveredBytes: checkpoint.deliveredBytes,
            authorization: authorization
        )
        guard completed.status == "completed",
              completed.changeSequence == changeSequence,
              completed.selectedObjects == selectedObjects,
              completed.selectedBytes == selectedBytes else {
            throw ManagedStorageError.invalidResponse
        }
        try await state.finishSnapshotRestore(changeSequence: changeSequence)
        return (applied, true)
    }

    private func downloadAndApply(
        change: ManagedChangeFeed.Change,
        chunk changedChunk: ManagedChangeFeed.Change.Chunk,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> Int {
        let capability = try await transport.downloadCapability(
            chunkID: changedChunk.chunkID,
            requestID: requestID,
            authorization: authorization
        )
        guard capability.chunk.chunkID == changedChunk.chunkID,
              capability.chunk.expectedSHA256 == change.contentSHA256,
              capability.chunk.compression == changedChunk.compression,
              capability.chunk.contentType == changedChunk.contentType,
              let expectedCompressedBytes = changedChunk.expectedCompressedBytes,
              expectedCompressedBytes > 0,
              let expectedBytes = changedChunk.expectedUncompressedBytes,
              expectedBytes > 0 else {
            throw ManagedStorageError.invalidResponse
        }
        let compressed = try await transport.download(using: capability)
        guard compressed.count == expectedCompressedBytes else {
            throw ManagedStorageError.invalidResponse
        }
        let decoded = try ManagedChunkCodec.decode(
            compressed,
            compression: capability.chunk.compression,
            expectedUncompressedBytes: expectedBytes
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
        guard payload.chunkID == changedChunk.chunkID,
              payload.sourceID == changedChunk.sourceID,
              payload.dataClass == change.dataClass,
              payload.eventStartMs == change.eventStart
                .flatMap(ManagedTimestamp.milliseconds),
              payload.eventEndMs == change.eventEnd
                .flatMap(ManagedTimestamp.milliseconds) else {
            throw ManagedStorageError.invalidResponse
        }
        try await restore.apply(chunk: payload, change: change)
        return compressed.count
    }

    private func acknowledgeAvailableChange(
        _ change: ManagedChangeFeed.Change
    ) async throws -> Bool {
        guard change.resourceKind == "chunk",
              change.operation == "available" else {
            return false
        }
        guard let chunk = change.chunk,
              chunk.chunkID == change.resourceID,
              chunk.state == "available",
              let sourceID = chunk.sourceID,
              let dataClass = change.dataClass,
              let windowStartMs = change.eventStart
                .flatMap(ManagedTimestamp.milliseconds),
              let windowEndMs = change.eventEnd
                .flatMap(ManagedTimestamp.milliseconds),
              windowStartMs >= 0,
              windowEndMs >= windowStartMs else {
            throw ManagedStorageError.invalidResponse
        }
        return try await state.acknowledgeAvailableChunk(
            sourceID: sourceID,
            dataClass: dataClass,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            chunkID: chunk.chunkID
        )
    }

    private func alignedFloor(_ value: Int64, interval: Int64) -> Int64 {
        value - (value % interval)
    }
}
