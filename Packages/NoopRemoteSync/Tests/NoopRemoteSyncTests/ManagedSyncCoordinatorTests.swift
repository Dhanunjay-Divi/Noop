import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedSyncCoordinatorTests: XCTestCase {
    private let windowMs: Int64 = 6 * 60 * 60 * 1_000
    private let settleMs: Int64 = 5 * 60 * 1_000
    private let installationToken = "noopm_" + String(repeating: "a", count: 43)

    func testLocalRetentionPolicyKeepsNinetyDaysAndClampsAtEpoch() {
        let dayMs: Int64 = 86_400_000
        XCTAssertEqual(ManagedLocalRetentionPolicy.detailedHistoryDays, 90)
        XCTAssertEqual(
            ManagedLocalRetentionPolicy.cutoff(nowMs: 100 * dayMs),
            10 * dayMs
        )
        XCTAssertEqual(
            ManagedLocalRetentionPolicy.cutoff(nowMs: 89 * dayMs),
            0
        )
    }

    func testBoundedForwardUploadReportsLocalContinuation() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let coordinator = ManagedSyncCoordinator(
            transport: CoordinatorTransport(),
            extractor: MultiWindowExtractor(
                eventTimes: [1_000, windowMs + 1_000]
            ),
            state: CoordinatorState(),
            restore: CoordinatorRestore()
        )

        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(
                timeIntervalSince1970: Double(2 * windowMs + settleMs) / 1_000
            ),
            dataClasses: ["essential_timeseries"],
            maxForwardWindowsPerClass: 1,
            maxChangePages: 0
        )

        XCTAssertEqual(result.uploadedChunks, 1)
        XCTAssertFalse(result.hasMoreChanges)
        XCTAssertTrue(result.hasMoreLocalWork)
        XCTAssertTrue(result.hasMoreWork)
    }

    func testBoundedDocumentUploadUsesLookAheadForLocalContinuation() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let pending = (0..<2).map { index in
            ManagedPendingDocument(
                localIdentifier: "document-\(index)",
                generation: 1,
                mutation: ManagedDocumentMutation(
                    requestID: UUID(),
                    documentKind: .journal,
                    documentID: UUID(),
                    baseRevision: 0,
                    contentMode: "server_readable",
                    payloadJSON: ["value": .integer(Int64(index))],
                    contentSHA256: String(repeating: "f", count: 64),
                    updatedAt: "2026-09-04T10:00:00Z"
                )
            )
        }
        let outbox = QueuedDocumentOutbox(pending: pending)
        let coordinator = ManagedSyncCoordinator(
            transport: CoordinatorTransport(),
            extractor: CoordinatorExtractor(),
            state: CoordinatorState(),
            restore: CoordinatorRestore(),
            documents: outbox
        )

        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: [],
            maxChangePages: 0,
            maxDocumentUploads: 1
        )

        XCTAssertEqual(result.uploadedDocuments, 1)
        XCTAssertTrue(result.hasMoreLocalWork)
        let remaining = await outbox.remainingCount()
        XCTAssertEqual(remaining, 1)
    }

    func testCompletionFailurePersistsReceiptAndRetryDoesNotUploadAgain() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let extractor = CoordinatorExtractor()
        let state = CoordinatorState()
        let transport = CoordinatorTransport(failFirstCompletion: true)
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: extractor,
            state: state,
            restore: CoordinatorRestore()
        )
        let now = Date(
            timeIntervalSince1970: Double(windowMs + settleMs) / 1_000
        )

        do {
            _ = try await coordinator.sync(
                source: source,
                authorization: authorization,
                now: now,
                dataClasses: ["essential_timeseries"],
                maxChangePages: 0
            )
            XCTFail("Expected completion failure")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .transport)
        }

        let firstUploads = await transport.uploadCount()
        let firstCompletions = await transport.completionCount()
        let pending = await state.currentWindow()
        let firstCheckpoint = await state.currentCheckpoint()
        XCTAssertEqual(firstUploads, 1)
        XCTAssertEqual(firstCompletions, 1)
        XCTAssertEqual(pending?.phase, .pendingCompletion)
        XCTAssertNil(firstCheckpoint.nextWindowStartMs)

        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: now,
            dataClasses: ["essential_timeseries"],
            maxChangePages: 0
        )

        let finalUploads = await transport.uploadCount()
        let finalCompletions = await transport.completionCount()
        let completed = await state.currentWindow()
        let finalCheckpoint = await state.currentCheckpoint()
        XCTAssertEqual(finalUploads, 1)
        XCTAssertEqual(finalCompletions, 2)
        XCTAssertEqual(completed?.phase, .awaitingValidation)
        XCTAssertEqual(finalCheckpoint.nextWindowStartMs, windowMs)
        XCTAssertEqual(result.uploadedChunks, 0)
    }

    func testRepairUploadsEmptySnapshotAfterLastRowIsDeleted() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let extractor = CoordinatorExtractor()
        let state = CoordinatorState()
        let transport = CoordinatorTransport()
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: extractor,
            state: state,
            restore: CoordinatorRestore()
        )
        let now = Date(
            timeIntervalSince1970: Double(windowMs + settleMs) / 1_000
        )

        _ = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: now,
            dataClasses: ["essential_timeseries"],
            maxChangePages: 0
        )
        let populated = await state.currentWindow()
        let populatedID = try XCTUnwrap(populated?.chunkID)
        await state.markCurrentWindowAvailable()

        await extractor.removeRow()
        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: now,
            dataClasses: ["essential_timeseries"],
            maxChangePages: 0
        )

        let uploads = await transport.uploadCount()
        let storedEmpty = await state.currentWindow()
        let empty = try XCTUnwrap(storedEmpty)
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(result.uploadedChunks, 1)
        XCTAssertEqual(empty.rowCount, 0)
        XCTAssertNotEqual(empty.chunkID, populatedID)
    }

    func testValidatedLocalUploadAdvancesFeedWithoutDownloadingDuplicate() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let chunkID = UUID()
        let change = ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: "chunk",
            resourceID: chunkID,
            operation: "available",
            contentSHA256: String(repeating: "a", count: 64),
            dataClass: "essential_timeseries",
            eventStart: "1970-01-01T00:00:00Z",
            eventEnd: "1970-01-01T00:00:01Z",
            chunk: .init(
                chunkID: chunkID,
                sourceID: source.sourceID,
                schemaVersion: 1,
                contentMode: "server_readable",
                state: "available",
                compression: "gzip",
                contentType: "application/vnd.noop.chunk+json",
                expectedCompressedBytes: 100,
                expectedUncompressedBytes: 200,
                objectGeneration: 1,
                expiresAt: nil
            ),
            document: nil
        )
        let state = CoordinatorState(localChunkIDs: [chunkID])
        let restore = CoordinatorRestore()
        let coordinator = ManagedSyncCoordinator(
            transport: CoordinatorTransport(changes: [change]),
            extractor: CoordinatorExtractor(),
            state: state,
            restore: restore
        )

        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 2),
            dataClasses: [],
            maxChangePages: 1
        )

        let currentSequence = await state.currentSequence()
        let acknowledgementCount = await state.acknowledgementCount()
        let appliedChunkCount = await restore.appliedChunkCount()
        XCTAssertEqual(result.appliedChanges, 1)
        XCTAssertEqual(currentSequence, 1)
        XCTAssertEqual(acknowledgementCount, 1)
        XCTAssertEqual(appliedChunkCount, 0)
    }

    func testDocumentsWaitForChangeBacklogThenUploadAndAcknowledge() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let changes = [Int64(1), 2].map { sequence in
            ManagedChangeFeed.Change(
                sequence: sequence,
                resourceKind: "quota",
                resourceID: UUID(),
                operation: "updated",
                contentSHA256: nil,
                dataClass: nil,
                eventStart: nil,
                eventEnd: nil,
                chunk: nil,
                document: nil
            )
        }
        let mutation = ManagedDocumentMutation(
            requestID: UUID(),
            documentKind: .journal,
            documentID: UUID(),
            baseRevision: 0,
            contentMode: "server_readable",
            payloadJSON: ["value": .string("kept")],
            contentSHA256: String(repeating: "f", count: 64),
            updatedAt: "2026-09-04T10:00:00Z"
        )
        let outbox = CoordinatorDocumentOutbox(mutation: mutation)
        let transport = CoordinatorTransport(changes: changes)
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: CoordinatorState(),
            restore: CoordinatorRestore(),
            documents: outbox
        )

        let first = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: [],
            maxChangePages: 1,
            changePageSize: 1,
            maxDocumentUploads: 1
        )
        let firstDocumentUploads = await transport.documentUploadCount()
        let firstAcknowledgements = await outbox.acknowledgementCount()
        XCTAssertTrue(first.hasMoreChanges)
        XCTAssertEqual(first.uploadedDocuments, 0)
        XCTAssertEqual(firstDocumentUploads, 0)
        XCTAssertEqual(firstAcknowledgements, 0)

        let second = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: [],
            maxChangePages: 1,
            changePageSize: 1,
            maxDocumentUploads: 1
        )
        let finalDocumentUploads = await transport.documentUploadCount()
        let finalAcknowledgements = await outbox.acknowledgementCount()
        XCTAssertFalse(second.hasMoreChanges)
        XCTAssertEqual(second.uploadedDocuments, 1)
        XCTAssertEqual(finalDocumentUploads, 1)
        XCTAssertEqual(finalAcknowledgements, 1)
    }

    func testDirtyPrunedWindowHydratesCloudBaseBeforeReplacementUpload() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let columns = ["event_at_ms", "bpm", "quality", "provenance"]
        let baseStream = ManagedChunkStreamPayload(
            streamKey: "heart_rate",
            columns: columns,
            rows: [[.integer(1_000), .integer(68), .null, .string("sensor")]]
        )
        let base = try XCTUnwrap(ManagedPreparedChunk.prepare(
            sourceID: source.sourceID,
            dataClass: "essential_timeseries",
            eventStartMs: 0,
            eventEndMs: windowMs - 1,
            streams: [baseStream]
        ))
        let compressedBase = try ManagedChunkCodec.encode(
            base.uncompressed,
            compression: .gzip
        )
        let extractor = PrunedWindowExtractor(
            columns: columns,
            localRows: [[.integer(2_000), .integer(72), .null, .string("sensor")]]
        )
        let state = PrunedWindowState(
            checkpoint: ManagedUploadCheckpoint(nextWindowStartMs: windowMs),
            upload: ManagedWindowUpload(
                windowEndMs: windowMs - 1,
                chunkID: base.payload.chunkID,
                rowCount: 1,
                phase: .available,
                snapshotGeneration: 1,
                validatedAtMs: 10,
                localPrunedAtMs: 20
            ),
            dirty: ManagedDirtyWindow(
                startMs: 0,
                endExclusiveMs: windowMs,
                generation: 2
            )
        )
        let transport = PrunedWindowTransport(
            chunkID: base.payload.chunkID,
            compressedBase: compressedBase,
            uncompressedBaseBytes: base.uncompressed.count
        )
        let restore = PrunedWindowRestore(extractor: extractor)
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: extractor,
            state: state,
            restore: restore
        )

        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(
                timeIntervalSince1970: Double(windowMs + settleMs) / 1_000
            ),
            dataClasses: ["essential_timeseries"],
            maxDirtyWindowsPerClass: 1,
            maxChangePages: 0
        )

        let replacement = try await transport.uploadedPayload()
        let hydrationCount = await restore.hydrationCount()
        let currentWindow = await state.currentWindow()
        XCTAssertEqual(hydrationCount, 1)
        XCTAssertEqual(replacement?.streams.first?.rows.count, 2)
        XCTAssertEqual(
            replacement?.streams.first?.rows.compactMap {
                $0.first?.timestampMilliseconds
            },
            [1_000, 2_000]
        )
        XCTAssertEqual(result.uploadedChunks, 1)
        XCTAssertNil(currentWindow?.localPrunedAtMs)
    }

    func testExpiredCursorSnapshotResumesAfterProcessDeathAndAnchorsFeed() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let first = availableChunk(
            id: UUID(uuidString: "11111111-1111-5111-8111-111111111111")!,
            sourceID: source.sourceID,
            eventStart: "2026-09-01T00:00:00Z",
            eventEnd: "2026-09-01T00:59:59Z"
        )
        let second = availableChunk(
            id: UUID(uuidString: "22222222-2222-5222-8222-222222222222")!,
            sourceID: source.sourceID,
            eventStart: "2026-09-01T01:00:00Z",
            eventEnd: "2026-09-01T01:59:59Z"
        )
        let state = CoordinatorState(localChunkIDs: [first.chunkID, second.chunkID])
        let transport = CoordinatorTransport(
            snapshotChunks: [first, second],
            expireFirstChangeCursor: true
        )

        let firstRun = try await ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: CoordinatorRestore()
        ).sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: ["essential_timeseries"],
            maxChangePages: 1,
            maxSnapshotRestoreObjects: 1
        )

        let persistedState = await state.currentSnapshotCheckpoint()
        let persisted = try XCTUnwrap(persistedState)
        let firstRestoreCreations = await transport.restoreCreationCount()
        XCTAssertEqual(firstRun.appliedChanges, 1)
        XCTAssertTrue(firstRun.hasMoreChanges)
        XCTAssertEqual(persisted.deliveredObjects, 1)
        XCTAssertEqual(persisted.cursor?.afterChunkID, first.chunkID)
        XCTAssertEqual(firstRestoreCreations, 1)

        let secondRun = try await ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: CoordinatorRestore()
        ).sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: ["essential_timeseries"],
            maxChangePages: 1
        )

        let anchoredSequence = await state.currentSequence()
        let finalCheckpoint = await state.currentSnapshotCheckpoint()
        let restoreCreations = await transport.restoreCreationCount()
        let restoreCompletions = await transport.restoreCompletionCount()
        let snapshotCursorChunkIDs = await transport.snapshotCursorChunkIDs()
        XCTAssertEqual(secondRun.appliedChanges, 1)
        XCTAssertFalse(secondRun.hasMoreChanges)
        XCTAssertEqual(anchoredSequence, 42)
        XCTAssertNil(finalCheckpoint)
        XCTAssertEqual(restoreCreations, 1)
        XCTAssertEqual(restoreCompletions, 1)
        XCTAssertEqual(
            snapshotCursorChunkIDs,
            [nil, first.chunkID]
        )
    }

    func testMissingSnapshotObjectRestartsOnlyRestoreCheckpoint() async throws {
        let source = try ManagedSourceDescriptor(
            localSourceID: "strap",
            sourceKind: "live_ble",
            platform: .iOS,
            installationID: "installation"
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "installation",
            installationToken: installationToken
        )
        let staleRequestID = UUID()
        let state = CoordinatorState(
            snapshotCheckpoint: ManagedSnapshotRestoreCheckpoint(
                requestID: staleRequestID,
                dataClasses: ["essential_timeseries"],
                restoreJobID: UUID(),
                snapshotAt: "2026-09-01T00:00:00Z",
                changeSequence: 7,
                selectedObjects: 1,
                selectedBytes: 100
            )
        )
        let transport = CoordinatorTransport(failSnapshotNotFound: true)

        let result = try await ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: CoordinatorRestore()
        ).sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: ["essential_timeseries"],
            maxChangePages: 1
        )

        let restartedState = await state.currentSnapshotCheckpoint()
        let restarted = try XCTUnwrap(restartedState)
        let currentSequence = await state.currentSequence()
        let clearCount = await state.snapshotClearCount()
        XCTAssertTrue(result.hasMoreChanges)
        XCTAssertNotEqual(restarted.requestID, staleRequestID)
        XCTAssertNil(restarted.restoreJobID)
        XCTAssertEqual(restarted.dataClasses, ["essential_timeseries"])
        XCTAssertEqual(currentSequence, 0)
        XCTAssertEqual(clearCount, 1)
    }

    private func availableChunk(
        id: UUID,
        sourceID: UUID,
        eventStart: String,
        eventEnd: String
    ) -> ManagedAvailableChunk {
        ManagedAvailableChunk(
            chunkID: id,
            sourceID: sourceID,
            dataClass: "essential_timeseries",
            schemaVersion: 1,
            contentMode: "server_readable",
            state: "available",
            eventStart: eventStart,
            eventEnd: eventEnd,
            compression: "gzip",
            contentType: "application/vnd.noop.chunk+json",
            expectedSHA256: String(repeating: "a", count: 64),
            expectedCompressedBytes: 100,
            expectedUncompressedBytes: 200,
            objectGeneration: 1,
            expiresAt: "2026-10-01T00:00:00Z"
        )
    }
}

private actor PrunedWindowExtractor: ManagedChunkExtracting {
    private let columns: [String]
    private var rows: [[ManagedJSONValue]]

    init(columns: [String], localRows: [[ManagedJSONValue]]) {
        self.columns = columns
        rows = localRows
    }

    func mergeCloudRows(_ cloudRows: [[ManagedJSONValue]]) {
        var byTimestamp = Dictionary(
            uniqueKeysWithValues: cloudRows.compactMap { row in
                row.first?.timestampMilliseconds.map { ($0, row) }
            }
        )
        for row in rows {
            if let timestamp = row.first?.timestampMilliseconds {
                byTimestamp[timestamp] = row
            }
        }
        rows = byTimestamp.sorted(by: { $0.key < $1.key }).map(\.value)
    }

    func nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Int64,
        beforeMs: Int64
    ) async throws -> Int64? {
        rows.compactMap { $0.first?.timestampMilliseconds }
            .filter { $0 >= atOrAfterMs && $0 < beforeMs }
            .min()
    }

    func streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> [ManagedChunkStreamPayload] {
        [
            ManagedChunkStreamPayload(
                streamKey: "heart_rate",
                columns: columns,
                rows: rows
            ),
        ]
    }
}

private actor PrunedWindowState: ManagedSyncStateStoring {
    private var checkpoint: ManagedUploadCheckpoint
    private var upload: ManagedWindowUpload
    private var dirty: ManagedDirtyWindow?

    init(
        checkpoint: ManagedUploadCheckpoint,
        upload: ManagedWindowUpload,
        dirty: ManagedDirtyWindow
    ) {
        self.checkpoint = checkpoint
        self.upload = upload
        self.dirty = dirty
    }

    func currentWindow() -> ManagedWindowUpload? { upload }

    func uploadCheckpoint(
        sourceID: UUID,
        dataClass: String
    ) async throws -> ManagedUploadCheckpoint { checkpoint }

    func saveUploadCheckpoint(
        _ checkpoint: ManagedUploadCheckpoint,
        sourceID: UUID,
        dataClass: String
    ) async throws {
        self.checkpoint = checkpoint
    }

    func windowUpload(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws -> ManagedWindowUpload? { upload }

    func saveWindowUpload(
        _ upload: ManagedWindowUpload,
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws {
        self.upload = upload
    }

    func claimWindowGeneration(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> Int64 { 2 }

    func claimNextDirtyWindow(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingAtOrBeforeMs: Int64
    ) async throws -> ManagedDirtyWindow? {
        defer { dirty = nil }
        return dirty
    }

    func acknowledgeAvailableChunk(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool { false }

    func markWindowHydrated(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool {
        guard upload.chunkID == chunkID,
              upload.windowEndMs == windowEndMs else {
            return false
        }
        upload = ManagedWindowUpload(
            windowEndMs: upload.windowEndMs,
            chunkID: upload.chunkID,
            rowCount: upload.rowCount,
            phase: upload.phase,
            snapshotGeneration: upload.snapshotGeneration,
            validatedAtMs: upload.validatedAtMs
        )
        return true
    }

    func pruneAvailableWindows(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingBeforeMs: Int64,
        limit: Int
    ) async throws -> ManagedPruneResult {
        ManagedPruneResult(prunedWindows: 0, deletedRows: 0)
    }

    func changeSequence() async throws -> Int64 { 0 }
    func saveChangeSequence(_ sequence: Int64) async throws {}
    func isChangeApplied(_ change: ManagedChangeFeed.Change) async throws -> Bool { false }
    func recordAppliedChange(_ change: ManagedChangeFeed.Change) async throws {}
}

private actor PrunedWindowRestore: ManagedRestoreApplying {
    private let extractor: PrunedWindowExtractor
    private var hydrations = 0

    init(extractor: PrunedWindowExtractor) {
        self.extractor = extractor
    }

    func hydrationCount() -> Int { hydrations }

    func apply(
        chunk: ManagedChunkPayload,
        change: ManagedChangeFeed.Change
    ) async throws {}

    func hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor
    ) async throws {
        hydrations += 1
        await extractor.mergeCloudRows(chunk.streams.first?.rows ?? [])
    }

    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {}
}

private actor PrunedWindowTransport: ManagedStorageTransport {
    private let chunkID: UUID
    private let compressedBase: Data
    private let uncompressedBaseBytes: Int
    private var uploaded: Data?
    private var uploadedCompression: String?
    private var uploadedUncompressedBytes: Int?

    init(chunkID: UUID, compressedBase: Data, uncompressedBaseBytes: Int) {
        self.chunkID = chunkID
        self.compressedBase = compressedBase
        self.uncompressedBaseBytes = uncompressedBaseBytes
    }

    func uploadedPayload() throws -> ManagedChunkPayload? {
        guard let uploaded,
              let uploadedCompression,
              let uploadedUncompressedBytes else {
            return nil
        }
        let decoded = try ManagedChunkCodec.decode(
            uploaded,
            compression: uploadedCompression,
            expectedUncompressedBytes: uploadedUncompressedBytes
        )
        return try JSONDecoder().decode(ManagedChunkPayload.self, from: decoded)
    }

    func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse {
        ManagedSourceResponse(
            source: .init(sourceID: source.sourceID, sourceKind: source.sourceKind)
        )
    }

    func reserveChunk(
        _ reservation: ManagedChunkReservation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkReservationResponse {
        uploadedCompression = reservation.compression
        uploadedUncompressedBytes = reservation.expectedUncompressedBytes
        return ManagedChunkReservationResponse(
            chunk: .init(
                chunkID: reservation.chunkID,
                state: "reserved",
                objectGeneration: nil,
                duplicate: false
            ),
            upload: .init(
                grantID: UUID(),
                method: "PUT",
                url: URL(string: "https://storage.googleapis.com/bucket/object")!,
                headers: [:],
                expiresAt: "2026-09-04T12:10:00Z"
            )
        )
    }

    func upload(
        _ bytes: Data,
        using capability: ManagedChunkReservationResponse.Upload
    ) async throws -> ManagedObjectUploadReceipt {
        uploaded = bytes
        return ManagedObjectUploadReceipt(
            objectGeneration: 42,
            objectMetageneration: 1,
            objectCRC32C: "AAAAAA=="
        )
    }

    func completeChunk(
        chunkID: UUID,
        receipt: ManagedObjectUploadReceipt,
        authorization: ManagedAuthorization
    ) async throws {}

    func changes(
        after sequence: Int64,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChangeFeed {
        ManagedChangeFeed(
            changes: [],
            minimumSequence: 0,
            highWatermark: sequence,
            nextSequence: sequence,
            hasMore: false
        )
    }

    func downloadCapability(
        chunkID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDownloadCapability {
        guard chunkID == self.chunkID else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedDownloadCapability(
            grantID: UUID(),
            method: "GET",
            url: URL(string: "https://storage.googleapis.com/bucket/base")!,
            headers: [:],
            expiresAt: "2026-09-04T12:10:00Z",
            chunk: .init(
                chunkID: chunkID,
                expectedSHA256: ManagedDigest.sha256(compressedBase),
                compression: "gzip",
                contentType: "application/vnd.noop.chunk+json",
                expectedUncompressedBytes: uncompressedBaseBytes
            )
        )
    }

    func download(using capability: ManagedDownloadCapability) async throws -> Data {
        compressedBase
    }

    func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64?,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        throw ManagedStorageError.invalidResponse
    }
}

private actor CoordinatorExtractor: ManagedChunkExtracting {
    private var hasRow = true

    func removeRow() {
        hasRow = false
    }

    func nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Int64,
        beforeMs: Int64
    ) async throws -> Int64? {
        hasRow && atOrAfterMs <= 1_000 && beforeMs > 1_000 ? 1_000 : nil
    }

    func streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> [ManagedChunkStreamPayload] {
        [
            ManagedChunkStreamPayload(
                streamKey: "heart_rate",
                columns: ["event_at_ms", "bpm", "quality", "provenance"],
                rows: hasRow
                    ? [[.integer(1_000), .integer(68), .null, .string("sensor")]]
                    : []
            ),
        ]
    }
}

private actor MultiWindowExtractor: ManagedChunkExtracting {
    private let eventTimes: [Int64]

    init(eventTimes: [Int64]) {
        self.eventTimes = eventTimes.sorted()
    }

    func nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Int64,
        beforeMs: Int64
    ) async throws -> Int64? {
        eventTimes.first { $0 >= atOrAfterMs && $0 < beforeMs }
    }

    func streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> [ManagedChunkStreamPayload] {
        [
            ManagedChunkStreamPayload(
                streamKey: "heart_rate",
                columns: ["event_at_ms", "bpm", "quality", "provenance"],
                rows: eventTimes
                    .filter {
                        $0 >= window.startMs && $0 < window.endExclusiveMs
                    }
                    .map {
                        [.integer($0), .integer(68), .null, .string("sensor")]
                    }
            ),
        ]
    }
}

private actor CoordinatorState: ManagedSyncStateStoring {
    private var checkpoint = ManagedUploadCheckpoint()
    private var window: ManagedWindowUpload?
    private var sequence: Int64 = 0
    private var generation: Int64 = 0
    private let localChunkIDs: Set<UUID>
    private var acknowledgements = 0
    private var snapshotCheckpoint: ManagedSnapshotRestoreCheckpoint?
    private var snapshotClears = 0

    init(
        localChunkIDs: Set<UUID> = [],
        snapshotCheckpoint: ManagedSnapshotRestoreCheckpoint? = nil
    ) {
        self.localChunkIDs = localChunkIDs
        self.snapshotCheckpoint = snapshotCheckpoint
    }

    func currentCheckpoint() -> ManagedUploadCheckpoint { checkpoint }
    func currentWindow() -> ManagedWindowUpload? { window }
    func currentSequence() -> Int64 { sequence }
    func acknowledgementCount() -> Int { acknowledgements }
    func currentSnapshotCheckpoint() -> ManagedSnapshotRestoreCheckpoint? {
        snapshotCheckpoint
    }
    func snapshotClearCount() -> Int { snapshotClears }
    func markCurrentWindowAvailable() {
        guard let window else { return }
        self.window = ManagedWindowUpload(
            windowEndMs: window.windowEndMs,
            chunkID: window.chunkID,
            rowCount: window.rowCount,
            phase: .available,
            snapshotGeneration: window.snapshotGeneration,
            validatedAtMs: 1
        )
    }

    func uploadCheckpoint(
        sourceID: UUID,
        dataClass: String
    ) async throws -> ManagedUploadCheckpoint {
        checkpoint
    }

    func saveUploadCheckpoint(
        _ checkpoint: ManagedUploadCheckpoint,
        sourceID: UUID,
        dataClass: String
    ) async throws {
        self.checkpoint = checkpoint
    }

    func windowUpload(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws -> ManagedWindowUpload? {
        window
    }

    func saveWindowUpload(
        _ upload: ManagedWindowUpload,
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64
    ) async throws {
        window = upload
    }

    func claimWindowGeneration(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        window: ManagedSyncWindow
    ) async throws -> Int64 {
        generation += 1
        return generation
    }

    func claimNextDirtyWindow(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingAtOrBeforeMs: Int64
    ) async throws -> ManagedDirtyWindow? {
        nil
    }

    func acknowledgeAvailableChunk(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool {
        guard localChunkIDs.contains(chunkID) else { return false }
        acknowledgements += 1
        return true
    }

    func markWindowHydrated(
        sourceID: UUID,
        dataClass: String,
        windowStartMs: Int64,
        windowEndMs: Int64,
        chunkID: UUID
    ) async throws -> Bool {
        guard let window,
              window.windowEndMs == windowEndMs,
              window.chunkID == chunkID else {
            return false
        }
        self.window = ManagedWindowUpload(
            windowEndMs: window.windowEndMs,
            chunkID: window.chunkID,
            rowCount: window.rowCount,
            phase: window.phase,
            receipt: window.receipt,
            snapshotGeneration: window.snapshotGeneration,
            validatedAtMs: window.validatedAtMs
        )
        return true
    }

    func pruneAvailableWindows(
        sourceID: UUID,
        localSourceID: String,
        dataClass: String,
        endingBeforeMs: Int64,
        limit: Int
    ) async throws -> ManagedPruneResult {
        ManagedPruneResult(prunedWindows: 0, deletedRows: 0)
    }

    func changeSequence() async throws -> Int64 { sequence }

    func saveChangeSequence(_ sequence: Int64) async throws {
        self.sequence = max(self.sequence, sequence)
    }

    func isChangeApplied(_ change: ManagedChangeFeed.Change) async throws -> Bool {
        false
    }

    func recordAppliedChange(_ change: ManagedChangeFeed.Change) async throws {}

    func snapshotRestoreCheckpoint() async throws -> ManagedSnapshotRestoreCheckpoint? {
        snapshotCheckpoint
    }

    func saveSnapshotRestoreCheckpoint(
        _ checkpoint: ManagedSnapshotRestoreCheckpoint
    ) async throws {
        snapshotCheckpoint = checkpoint
    }

    func clearSnapshotRestoreCheckpoint() async throws {
        snapshotCheckpoint = nil
        snapshotClears += 1
    }

    func finishSnapshotRestore(changeSequence: Int64) async throws {
        sequence = max(sequence, changeSequence)
        snapshotCheckpoint = nil
    }
}

private actor CoordinatorRestore: ManagedRestoreApplying {
    private var appliedChunks = 0

    func appliedChunkCount() -> Int { appliedChunks }

    func apply(
        chunk: ManagedChunkPayload,
        change: ManagedChangeFeed.Change
    ) async throws {
        appliedChunks += 1
    }

    func hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor
    ) async throws {}

    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {}
}

private actor CoordinatorDocumentOutbox: ManagedDocumentOutbox {
    private let mutation: ManagedDocumentMutation
    private var acknowledged = false

    init(mutation: ManagedDocumentMutation) {
        self.mutation = mutation
    }

    func acknowledgementCount() -> Int { acknowledged ? 1 : 0 }

    func pendingDocuments(limit: Int) async throws -> [ManagedPendingDocument] {
        guard !acknowledged, limit > 0 else { return [] }
        return [
            ManagedPendingDocument(
                localIdentifier: "document",
                generation: 1,
                mutation: mutation
            ),
        ]
    }

    func acknowledge(
        _ pending: ManagedPendingDocument,
        remote: ManagedDocument
    ) async throws {
        guard pending.mutation.documentID == remote.documentID else {
            throw ManagedStorageError.invalidResponse
        }
        acknowledged = true
    }
}

private actor QueuedDocumentOutbox: ManagedDocumentOutbox {
    private var pending: [ManagedPendingDocument]

    init(pending: [ManagedPendingDocument]) {
        self.pending = pending
    }

    func remainingCount() -> Int { pending.count }

    func pendingDocuments(limit: Int) async throws -> [ManagedPendingDocument] {
        Array(pending.prefix(limit))
    }

    func acknowledge(
        _ acknowledged: ManagedPendingDocument,
        remote: ManagedDocument
    ) async throws {
        guard let index = pending.firstIndex(where: {
            $0.localIdentifier == acknowledged.localIdentifier
        }), remote.documentID == acknowledged.mutation.documentID else {
            throw ManagedStorageError.invalidResponse
        }
        pending.remove(at: index)
    }
}

private actor CoordinatorTransport: ManagedStorageTransport {
    private let failFirstCompletion: Bool
    private let feedChanges: [ManagedChangeFeed.Change]
    private let snapshotChunks: [ManagedAvailableChunk]
    private let expireFirstChangeCursor: Bool
    private let failSnapshotNotFound: Bool
    private let restoreJobID = UUID()
    private var uploads = 0
    private var completions = 0
    private var changeRequests = 0
    private var restoreCreations = 0
    private var restoreCompletions = 0
    private var documentUploads = 0
    private var snapshotCursors: [ManagedChunkPage.Cursor?] = []

    init(
        failFirstCompletion: Bool = false,
        changes: [ManagedChangeFeed.Change] = [],
        snapshotChunks: [ManagedAvailableChunk] = [],
        expireFirstChangeCursor: Bool = false,
        failSnapshotNotFound: Bool = false
    ) {
        self.failFirstCompletion = failFirstCompletion
        feedChanges = changes
        self.snapshotChunks = snapshotChunks
        self.expireFirstChangeCursor = expireFirstChangeCursor
        self.failSnapshotNotFound = failSnapshotNotFound
    }

    func uploadCount() -> Int { uploads }
    func completionCount() -> Int { completions }
    func restoreCreationCount() -> Int { restoreCreations }
    func restoreCompletionCount() -> Int { restoreCompletions }
    func documentUploadCount() -> Int { documentUploads }
    func snapshotCursorChunkIDs() -> [UUID?] {
        snapshotCursors.map { $0?.afterChunkID }
    }

    func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse {
        ManagedSourceResponse(
            source: ManagedSourceResponse.Source(
                sourceID: source.sourceID,
                sourceKind: source.sourceKind
            )
        )
    }

    func reserveChunk(
        _ reservation: ManagedChunkReservation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkReservationResponse {
        ManagedChunkReservationResponse(
            chunk: ManagedChunkReservationResponse.Chunk(
                chunkID: reservation.chunkID,
                state: "reserved",
                objectGeneration: nil,
                duplicate: false
            ),
            upload: ManagedChunkReservationResponse.Upload(
                grantID: UUID(),
                method: "PUT",
                url: URL(string: "https://storage.googleapis.com/bucket/object")!,
                headers: [:],
                expiresAt: "2026-09-03T12:10:00Z"
            )
        )
    }

    func upload(
        _ bytes: Data,
        using capability: ManagedChunkReservationResponse.Upload
    ) async throws -> ManagedObjectUploadReceipt {
        uploads += 1
        return ManagedObjectUploadReceipt(
            objectGeneration: 42,
            objectMetageneration: 1,
            objectCRC32C: "AAAAAA=="
        )
    }

    func completeChunk(
        chunkID: UUID,
        receipt: ManagedObjectUploadReceipt,
        authorization: ManagedAuthorization
    ) async throws {
        completions += 1
        if failFirstCompletion, completions == 1 {
            throw ManagedStorageError.transport
        }
    }

    func changes(
        after sequence: Int64,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChangeFeed {
        changeRequests += 1
        if expireFirstChangeCursor, changeRequests == 1 {
            throw ManagedStorageError.cursorExpired(minimumSequence: 10)
        }
        let selected = Array(
            feedChanges.filter { $0.sequence > sequence }.prefix(limit)
        )
        return ManagedChangeFeed(
            changes: selected,
            minimumSequence: 0,
            highWatermark: feedChanges.last?.sequence ?? sequence,
            nextSequence: selected.last?.sequence ?? sequence,
            hasMore: feedChanges.contains {
                $0.sequence > (selected.last?.sequence ?? sequence)
            }
        )
    }

    func createRestore(
        requestID: UUID,
        dataClasses: [String],
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        restoreCreations += 1
        return ManagedRestoreJob(
            restoreJobID: restoreJobID,
            status: "running",
            snapshotAt: "2026-09-01T02:00:00Z",
            changeSequence: 42,
            selectedObjects: snapshotChunks.count,
            selectedBytes: Int64(
                snapshotChunks.reduce(0) { $0 + $1.expectedCompressedBytes }
            ),
            deliveredObjects: 0,
            deliveredBytes: 0,
            expiresAt: "2026-09-02T02:00:00Z",
            duplicate: false
        )
    }

    func availableChunks(
        dataClass: String,
        snapshotAt: String,
        after cursor: ManagedChunkPage.Cursor?,
        limit: Int,
        authorization: ManagedAuthorization
    ) async throws -> ManagedChunkPage {
        if failSnapshotNotFound {
            throw ManagedStorageError.notFound
        }
        snapshotCursors.append(cursor)
        let ordered = snapshotChunks.sorted {
            ($0.eventStart, $0.chunkID.uuidString)
                < ($1.eventStart, $1.chunkID.uuidString)
        }
        let remaining = ordered.filter { chunk in
            guard let cursor else { return true }
            return (chunk.eventStart, chunk.chunkID.uuidString)
                > (cursor.afterEventStart, cursor.afterChunkID.uuidString)
        }
        let selected = Array(remaining.prefix(limit))
        let next = remaining.count > selected.count
            ? selected.last.map {
                ManagedChunkPage.Cursor(
                    afterEventStart: $0.eventStart,
                    afterChunkID: $0.chunkID
                )
            }
            : nil
        return ManagedChunkPage(chunks: selected, nextCursor: next)
    }

    func completeRestore(
        restoreJobID: UUID,
        deliveredObjects: Int,
        deliveredBytes: Int64,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        restoreCompletions += 1
        return ManagedRestoreJob(
            restoreJobID: restoreJobID,
            status: "completed",
            snapshotAt: "2026-09-01T02:00:00Z",
            changeSequence: 42,
            selectedObjects: snapshotChunks.count,
            selectedBytes: Int64(
                snapshotChunks.reduce(0) { $0 + $1.expectedCompressedBytes }
            ),
            deliveredObjects: deliveredObjects,
            deliveredBytes: deliveredBytes,
            expiresAt: "2026-09-02T02:00:00Z",
            duplicate: false
        )
    }

    func downloadCapability(
        chunkID: UUID,
        requestID: UUID,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDownloadCapability {
        throw ManagedStorageError.invalidResponse
    }

    func download(using capability: ManagedDownloadCapability) async throws -> Data {
        throw ManagedStorageError.invalidResponse
    }

    func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64?,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        throw ManagedStorageError.invalidResponse
    }

    func putDocument(
        _ mutation: ManagedDocumentMutation,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        documentUploads += 1
        return ManagedDocument(
            documentKind: mutation.documentKind,
            documentID: mutation.documentID,
            revision: mutation.baseRevision + 1,
            originInstallationID: authorization.installationID,
            contentMode: mutation.contentMode,
            clientKeyID: mutation.clientKeyID,
            contentSHA256: mutation.contentSHA256
                ?? String(repeating: "a", count: 64),
            payloadJSON: mutation.payloadJSON,
            payloadCiphertextBase64: mutation.payloadCiphertextBase64,
            updatedAt: mutation.updatedAt,
            deletedAt: mutation.deleted
                ? "2026-09-04T10:01:00Z"
                : nil,
            duplicate: false
        )
    }
}
