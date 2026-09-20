import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedSyncCoordinatorTests: XCTestCase {
    private let windowMs: Int64 = 6 * 60 * 60 * 1_000
    private let settleMs: Int64 = 5 * 60 * 1_000
    private let installationToken = "noopm_" + String(repeating: "a", count: 43)

    func testLocalRetentionPolicyKeepsRawHotAndEssentialDetail() {
        let dayMs: Int64 = 86_400_000
        XCTAssertEqual(ManagedLocalRetentionPolicy.rawHistoryDays, 7)
        XCTAssertEqual(ManagedLocalRetentionPolicy.essentialHistoryDays, 30)
        XCTAssertEqual(
            ManagedLocalRetentionPolicy.cutoff(
                nowMs: 100 * dayMs,
                dataClass: "essential_timeseries"
            ),
            70 * dayMs
        )
        XCTAssertEqual(
            ManagedLocalRetentionPolicy.cutoff(
                nowMs: 100 * dayMs,
                dataClass: "raw_ppg"
            ),
            93 * dayMs
        )
        XCTAssertEqual(
            ManagedLocalRetentionPolicy.cutoff(
                nowMs: 6 * dayMs,
                dataClass: "raw_motion"
            ),
            0
        )
        XCTAssertNil(
            ManagedLocalRetentionPolicy.cutoff(
                nowMs: 100 * dayMs,
                dataClass: "derived_summaries"
            )
        )
        XCTAssertNil(
            ManagedLocalRetentionPolicy.cutoff(
                nowMs: 100 * dayMs,
                dataClass: "unknown"
            )
        )
    }

    func testRestoreOnlyNeverRegistersUploadsOrPrunes() async throws {
        let sourceID = UUID()
        let prepared = try XCTUnwrap(
            ManagedPreparedChunk.prepare(
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                eventStartMs: 0,
                eventEndMs: 1_000,
                streams: [
                    ManagedChunkStreamPayload(
                        streamKey: "heart_rate",
                        columns: ["event_at_ms", "bpm", "quality", "provenance"],
                        rows: [
                            [.integer(500), .integer(68), .null, .string("sensor")],
                        ]
                    ),
                ]
            )
        )
        let compressed = try ManagedChunkCodec.encode(
            prepared.uncompressed,
            compression: .gzip
        )
        let change = ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: "chunk",
            resourceID: prepared.payload.chunkID,
            operation: "available",
            contentSHA256: ManagedDigest.sha256(compressed),
            dataClass: prepared.payload.dataClass,
            eventStart: "1970-01-01T00:00:00Z",
            eventEnd: "1970-01-01T00:00:01Z",
            chunk: .init(
                chunkID: prepared.payload.chunkID,
                sourceID: sourceID,
                schemaVersion: 1,
                contentMode: "server_readable",
                state: "available",
                compression: "gzip",
                contentType: "application/vnd.noop.chunk+json",
                expectedCompressedBytes: compressed.count,
                expectedUncompressedBytes: prepared.uncompressed.count,
                objectGeneration: 1,
                expiresAt: nil
            ),
            document: nil
        )
        let transport = CoordinatorTransport(
            changes: [change],
            downloadableChunks: [
                prepared.payload.chunkID: CoordinatorDownloadFixture(
                    compressed: compressed,
                    uncompressedBytes: prepared.uncompressed.count
                ),
            ]
        )
        let state = CoordinatorState(localChunkIDs: [prepared.payload.chunkID])
        let restore = CoordinatorRestore()
        let outbox = QueuedDocumentOutbox(
            pending: [
                ManagedPendingDocument(
                    localIdentifier: "pending-document",
                    generation: 1,
                    mutation: ManagedDocumentMutation(
                        requestID: UUID(),
                        documentKind: .journal,
                        documentID: UUID(),
                        baseRevision: 0,
                        contentMode: "server_readable",
                        payloadJSON: ["value": .string("pending")],
                        contentSHA256: String(repeating: "f", count: 64),
                        updatedAt: "2026-09-19T10:00:00Z"
                    )
                ),
            ]
        )
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: restore,
            documents: outbox
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "macos-viewer",
            installationToken: installationToken
        )

        let result = try await coordinator.restoreOnly(
            authorization: authorization,
            dataClasses: ["essential_timeseries"]
        )

        XCTAssertEqual(result.appliedChanges, 1)
        XCTAssertFalse(result.hasMoreChanges)
        XCTAssertEqual(ManagedStoragePlatform.macOS.rawValue, "macos")
        let sourceRegistrations = await transport.sourceRegistrationCount()
        let chunkReservations = await transport.chunkReservationCount()
        let uploads = await transport.uploadCount()
        let completions = await transport.completionCount()
        let documentUploads = await transport.documentUploadCount()
        let downloads = await transport.downloadCount()
        let uploadAcknowledgements = await state.acknowledgementCount()
        let appliedChunks = await restore.appliedChunkCount()
        let pruneCutoffs = await state.recordedPruneCutoffs()
        XCTAssertEqual(sourceRegistrations, 0)
        XCTAssertEqual(chunkReservations, 0)
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(documentUploads, 0)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(uploadAcknowledgements, 0)
        XCTAssertEqual(appliedChunks, 1)
        XCTAssertEqual(pruneCutoffs, [:])
    }

    func testLocalRetentionAppliesPerDataClassCutoffs() async throws {
        let dayMs: Int64 = 86_400_000
        let state = CoordinatorState()
        let coordinator = ManagedSyncCoordinator(
            transport: CoordinatorTransport(),
            extractor: MultiWindowExtractor(eventTimes: []),
            state: state,
            restore: CoordinatorRestore()
        )
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

        _ = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: Double(100 * dayMs) / 1_000),
            dataClasses: ManagedSyncCoordinator.chunkDataClasses,
            maxChangePages: 0,
            maxDocumentUploads: 0,
            localPruneNowMs: 100 * dayMs
        )

        let recordedCutoffs = await state.recordedPruneCutoffs()
        XCTAssertEqual(
            recordedCutoffs,
            [
                "essential_timeseries": 70 * dayMs,
                "raw_auxiliary": 93 * dayMs,
                "raw_ppg": 93 * dayMs,
                "raw_motion": 93 * dayMs,
            ]
        )
    }

    func testCancellationAfterCheckpointPreventsLocalPruning() async throws {
        let dayMs: Int64 = 86_400_000
        let state = CoordinatorState(blockCheckpointSave: true)
        let coordinator = ManagedSyncCoordinator(
            transport: CoordinatorTransport(),
            extractor: MultiWindowExtractor(eventTimes: []),
            state: state,
            restore: CoordinatorRestore()
        )
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

        let task = Task {
            try await coordinator.sync(
                source: source,
                authorization: authorization,
                now: Date(
                    timeIntervalSince1970:
                        Double(100 * dayMs) / 1_000
                ),
                dataClasses: ["essential_timeseries"],
                maxChangePages: 0,
                maxDocumentUploads: 0,
                localPruneNowMs: 100 * dayMs,
                maxPruneWindowsPerClass: 1
            )
        }

        await state.waitForCheckpointSave()
        task.cancel()
        await state.releaseCheckpointSave()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before local pruning")
        } catch is CancellationError {
            // Expected.
        }
        let pruneCutoffs = await state.recordedPruneCutoffs()
        XCTAssertEqual(pruneCutoffs, [:])
    }

    func testAccountFenceStopsDownloadedChunkBeforeApplyOrCursorAdvance()
        async throws
    {
        let sourceID = UUID()
        let prepared = try XCTUnwrap(
            ManagedPreparedChunk.prepare(
                sourceID: sourceID,
                dataClass: "essential_timeseries",
                eventStartMs: 0,
                eventEndMs: 1_000,
                streams: [
                    ManagedChunkStreamPayload(
                        streamKey: "heart_rate",
                        columns: [
                            "event_at_ms",
                            "bpm",
                            "quality",
                            "provenance",
                        ],
                        rows: [
                            [
                                .integer(500),
                                .integer(68),
                                .null,
                                .string("sensor"),
                            ],
                        ]
                    ),
                ]
            )
        )
        let compressed = try ManagedChunkCodec.encode(
            prepared.uncompressed,
            compression: .gzip
        )
        let change = ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: "chunk",
            resourceID: prepared.payload.chunkID,
            operation: "available",
            contentSHA256: ManagedDigest.sha256(compressed),
            dataClass: prepared.payload.dataClass,
            eventStart: "1970-01-01T00:00:00Z",
            eventEnd: "1970-01-01T00:00:01Z",
            chunk: .init(
                chunkID: prepared.payload.chunkID,
                sourceID: sourceID,
                schemaVersion: 1,
                contentMode: "server_readable",
                state: "available",
                compression: "gzip",
                contentType: "application/vnd.noop.chunk+json",
                expectedCompressedBytes: compressed.count,
                expectedUncompressedBytes: prepared.uncompressed.count,
                objectGeneration: 1,
                expiresAt: nil
            ),
            document: nil
        )
        let gate = OperationValidityGate()
        let transport = CoordinatorTransport(
            changes: [change],
            downloadableChunks: [
                prepared.payload.chunkID: CoordinatorDownloadFixture(
                    compressed: compressed,
                    uncompressedBytes: prepared.uncompressed.count
                ),
            ],
            onDownload: {
                await gate.invalidate()
            }
        )
        let state = CoordinatorState()
        let restore = CoordinatorRestore()
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: MultiWindowExtractor(eventTimes: []),
            state: state,
            restore: restore,
            operationValidator: {
                try await gate.validate()
            }
        )
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

        do {
            _ = try await coordinator.sync(
                source: source,
                authorization: authorization,
                now: Date(timeIntervalSince1970: 1),
                dataClasses: ["essential_timeseries"],
                maxChangePages: 1,
                maxDocumentUploads: 0
            )
            XCTFail("Expected the account fence to cancel restore")
        } catch is CancellationError {
            // Expected.
        }

        let appliedChunks = await restore.appliedChunkCount()
        let sequence = await state.currentSequence()
        let pruneCutoffs = await state.recordedPruneCutoffs()
        XCTAssertEqual(appliedChunks, 0)
        XCTAssertEqual(sequence, 0)
        XCTAssertEqual(pruneCutoffs, [:])
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

    func testFilteredEmptyChangePageAdvancesCursorToHighWatermark() async throws {
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
        let state = CoordinatorState()
        let transport = CoordinatorTransport(feedHighWatermark: 7)
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: CoordinatorRestore()
        )

        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: [],
            maxChangePages: 1,
            maxDocumentUploads: 0
        )

        let currentSequence = await state.currentSequence()
        let restoreCreations = await transport.restoreCreationCount()
        XCTAssertEqual(result.appliedChanges, 0)
        XCTAssertFalse(result.hasMoreChanges)
        XCTAssertEqual(currentSequence, 7)
        XCTAssertEqual(restoreCreations, 0)
    }

    func testChangeFeedCapabilityUpgradeSnapshotsBeforeIncrementalSync() async throws {
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
        let state = CoordinatorState(changeFeedCapabilityVersion: 0)
        let documentID = UUID(
            uuidString: "33333333-3333-5333-8333-333333333333"
        )!
        let document = ManagedDocument(
            documentKind: .dayOwnership,
            documentID: documentID,
            revision: 2,
            originInstallationID: "remote-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: ManagedDigest.sha256(
                Data(
                    (
                        "deleted:day_ownership:"
                            + "\(documentID.uuidString.lowercased()):2"
                    ).utf8
                )
            ),
            payloadJSON: nil,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-01T01:00:00Z",
            deletedAt: "2026-09-01T01:00:00Z",
            duplicate: false
        )
        let restore = CoordinatorRestore()
        let transport = CoordinatorTransport(
            snapshotDocuments: [document],
            feedHighWatermark: 99
        )

        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: restore
        )
        let first = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: ["essential_timeseries"],
            maxChangePages: 1,
            maxDocumentUploads: 0
        )
        let result = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: ["essential_timeseries"],
            maxChangePages: 1,
            maxDocumentUploads: 0
        )

        let restoreCreations = await transport.restoreCreationCount()
        let currentSequence = await state.currentSequence()
        let capabilityVersion = await state.currentChangeFeedCapabilityVersion()
        let checkpoint = await state.currentSnapshotCheckpoint()
        let documentOperations = await restore.appliedDocumentOperations()
        let includeDeletedValues = await transport.snapshotIncludeDeletedValues()
        let restoreIncludeDeletedValues =
            await transport.restoreIncludeDeletedValues()
        XCTAssertEqual(first.appliedChanges, 0)
        XCTAssertTrue(first.hasMoreChanges)
        XCTAssertEqual(result.appliedChanges, 1)
        XCTAssertFalse(result.hasMoreChanges)
        XCTAssertEqual(restoreCreations, 1)
        XCTAssertEqual(documentOperations, ["tombstone"])
        XCTAssertEqual(includeDeletedValues, [true])
        XCTAssertEqual(restoreIncludeDeletedValues, [true])
        XCTAssertEqual(currentSequence, 99)
        XCTAssertEqual(
            capabilityVersion,
            ManagedSyncCoordinator.changeFeedCapabilityVersion
        )
        XCTAssertNil(checkpoint)
    }

    func testRejectedCapabilityUpgradeTombstoneDoesNotAdvanceSnapshotCursor() async throws {
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
        let documentID = UUID(
            uuidString: "44444444-4444-5444-8444-444444444444"
        )!
        let document = ManagedDocument(
            documentKind: .dayOwnership,
            documentID: documentID,
            revision: 3,
            originInstallationID: "remote-installation",
            contentMode: "server_readable",
            clientKeyID: nil,
            contentSHA256: ManagedDigest.sha256(
                Data(
                    (
                        "deleted:day_ownership:"
                            + "\(documentID.uuidString.lowercased()):3"
                    ).utf8
                )
            ),
            payloadJSON: nil,
            payloadCiphertextBase64: nil,
            updatedAt: "2026-09-01T01:00:00Z",
            deletedAt: "2026-09-01T01:00:00Z",
            duplicate: false
        )
        let state = CoordinatorState(changeFeedCapabilityVersion: 0)
        let transport = CoordinatorTransport(snapshotDocuments: [document])
        let coordinator = ManagedSyncCoordinator(
            transport: transport,
            extractor: CoordinatorExtractor(),
            state: state,
            restore: RejectingDocumentRestore()
        )

        let first = try await coordinator.sync(
            source: source,
            authorization: authorization,
            now: Date(timeIntervalSince1970: 0),
            dataClasses: ["essential_timeseries"],
            maxChangePages: 1,
            maxDocumentUploads: 0
        )
        XCTAssertTrue(first.hasMoreChanges)

        do {
            _ = try await coordinator.sync(
                source: source,
                authorization: authorization,
                now: Date(timeIntervalSince1970: 0),
                dataClasses: ["essential_timeseries"],
                maxChangePages: 1,
                maxDocumentUploads: 0
            )
            XCTFail("Expected rejected snapshot tombstone")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageError,
                .invalidConfiguration
            )
        }

        let checkpoint = await state.currentSnapshotCheckpoint()
        let currentSequence = await state.currentSequence()
        let capabilityVersion = await state.currentChangeFeedCapabilityVersion()
        let includeDeletedValues = await transport.snapshotIncludeDeletedValues()
        let restoreIncludeDeletedValues =
            await transport.restoreIncludeDeletedValues()
        XCTAssertNil(checkpoint?.documentCursor)
        XCTAssertEqual(checkpoint?.deliveredObjects, 0)
        XCTAssertEqual(currentSequence, 0)
        XCTAssertEqual(capabilityVersion, 0)
        XCTAssertEqual(includeDeletedValues, [true])
        XCTAssertEqual(restoreIncludeDeletedValues, [true])
    }

    func testFailedCapabilityUpgradeSnapshotDoesNotAdvanceCursorOrVersion() async throws {
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
        let state = CoordinatorState(changeFeedCapabilityVersion: 0)
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
            maxChangePages: 1,
            maxDocumentUploads: 0
        )

        let currentSequence = await state.currentSequence()
        let capabilityVersion = await state.currentChangeFeedCapabilityVersion()
        let checkpointVersion = await state.currentSnapshotCheckpoint()?
            .changeFeedCapabilityVersion
        XCTAssertTrue(result.hasMoreChanges)
        XCTAssertEqual(currentSequence, 0)
        XCTAssertEqual(capabilityVersion, 0)
        XCTAssertEqual(
            checkpointVersion,
            ManagedSyncCoordinator.changeFeedCapabilityVersion
        )
    }

    func testUnappliedDocumentDoesNotAdvanceChangeCursor() async throws {
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
        let ciphertext = Data(repeating: 0x2a, count: 32)
        let document = ManagedDocument(
            documentKind: .journal,
            documentID: UUID(),
            revision: 1,
            originInstallationID: "remote-installation",
            contentMode: "client_encrypted",
            clientKeyID: UUID(),
            contentSHA256: ManagedDigest.sha256(ciphertext),
            payloadJSON: nil,
            payloadCiphertextBase64: ciphertext.base64EncodedString(),
            updatedAt: "2026-09-12T00:00:00.000Z",
            deletedAt: nil,
            duplicate: false
        )
        let metadata = document.changeMetadata
        let change = ManagedChangeFeed.Change(
            sequence: 1,
            resourceKind: metadata.resourceKind,
            resourceID: metadata.resourceID,
            operation: metadata.operation,
            contentSHA256: metadata.contentSHA256,
            dataClass: metadata.dataClass,
            eventStart: metadata.eventStart,
            eventEnd: metadata.eventEnd,
            chunk: metadata.chunk,
            document: metadata.document
        )
        let state = CoordinatorState()
        let coordinator = ManagedSyncCoordinator(
            transport: CoordinatorTransport(
                changes: [change],
                remoteDocuments: [document.documentID: document]
            ),
            extractor: CoordinatorExtractor(),
            state: state,
            restore: RejectingDocumentRestore()
        )

        do {
            _ = try await coordinator.sync(
                source: source,
                authorization: authorization,
                now: Date(timeIntervalSince1970: 0),
                dataClasses: [],
                maxChangePages: 1
            )
            XCTFail("Expected unapplied document to stop the feed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidConfiguration)
        }
        let currentSequence = await state.currentSequence()
        XCTAssertEqual(currentSequence, 0)
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
                changeFeedCapabilityVersion:
                    ManagedSyncCoordinator.changeFeedCapabilityVersion,
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
    func changeFeedCapabilityVersion() async throws -> Int {
        ManagedSyncCoordinator.changeFeedCapabilityVersion
    }
    func saveChangeSequence(_ sequence: Int64) async throws {}
    func isChangeApplied(_ change: ManagedChangeFeed.Change) async throws -> Bool { false }
    func recordAppliedChange(_ change: ManagedChangeFeed.Change) async throws {}

    func finishSnapshotRestore(
        changeSequence: Int64,
        changeFeedCapabilityVersion: Int
    ) async throws {}
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
            minimumSequence: 1,
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
    private var capabilityVersion: Int
    private var generation: Int64 = 0
    private let localChunkIDs: Set<UUID>
    private var acknowledgements = 0
    private var snapshotCheckpoint: ManagedSnapshotRestoreCheckpoint?
    private var snapshotClears = 0
    private var pruneCutoffs: [String: Int64] = [:]
    private var shouldBlockCheckpointSave: Bool
    private var checkpointSaveStarted = false
    private var checkpointSaveWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var checkpointSaveRelease: CheckedContinuation<Void, Never>?

    init(
        localChunkIDs: Set<UUID> = [],
        snapshotCheckpoint: ManagedSnapshotRestoreCheckpoint? = nil,
        changeFeedCapabilityVersion: Int =
            ManagedSyncCoordinator.changeFeedCapabilityVersion,
        blockCheckpointSave: Bool = false
    ) {
        self.localChunkIDs = localChunkIDs
        self.snapshotCheckpoint = snapshotCheckpoint
        capabilityVersion = changeFeedCapabilityVersion
        shouldBlockCheckpointSave = blockCheckpointSave
    }

    func currentCheckpoint() -> ManagedUploadCheckpoint { checkpoint }
    func currentWindow() -> ManagedWindowUpload? { window }
    func currentSequence() -> Int64 { sequence }
    func currentChangeFeedCapabilityVersion() -> Int { capabilityVersion }
    func acknowledgementCount() -> Int { acknowledgements }
    func currentSnapshotCheckpoint() -> ManagedSnapshotRestoreCheckpoint? {
        snapshotCheckpoint
    }
    func snapshotClearCount() -> Int { snapshotClears }
    func recordedPruneCutoffs() -> [String: Int64] { pruneCutoffs }
    func waitForCheckpointSave() async {
        guard !checkpointSaveStarted else { return }
        await withCheckedContinuation { continuation in
            checkpointSaveWaiters.append(continuation)
        }
    }
    func releaseCheckpointSave() {
        checkpointSaveRelease?.resume()
        checkpointSaveRelease = nil
    }
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
        if shouldBlockCheckpointSave {
            shouldBlockCheckpointSave = false
            checkpointSaveStarted = true
            let waiters = checkpointSaveWaiters
            checkpointSaveWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                checkpointSaveRelease = continuation
            }
        }
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
        pruneCutoffs[dataClass] = endingBeforeMs
        return ManagedPruneResult(prunedWindows: 0, deletedRows: 0)
    }

    func changeSequence() async throws -> Int64 { sequence }

    func changeFeedCapabilityVersion() async throws -> Int {
        capabilityVersion
    }

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

    func finishSnapshotRestore(
        changeSequence: Int64,
        changeFeedCapabilityVersion: Int
    ) async throws {
        sequence = max(sequence, changeSequence)
        capabilityVersion = changeFeedCapabilityVersion
        snapshotCheckpoint = nil
    }
}

private actor CoordinatorRestore: ManagedRestoreApplying {
    private var appliedChunks = 0
    private var documentOperations: [String] = []

    func appliedChunkCount() -> Int { appliedChunks }
    func appliedDocumentOperations() -> [String] { documentOperations }

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
    ) async throws {
        documentOperations.append(change.operation)
    }
}

private actor OperationValidityGate {
    private var valid = true

    func invalidate() {
        valid = false
    }

    func validate() throws {
        guard valid else { throw CancellationError() }
    }
}

private actor RejectingDocumentRestore: ManagedRestoreApplying {
    func apply(
        chunk: ManagedChunkPayload,
        change: ManagedChangeFeed.Change
    ) async throws {}

    func hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor
    ) async throws {}

    func apply(
        document: ManagedDocument,
        change: ManagedChangeFeed.Change
    ) async throws {
        throw ManagedStorageError.invalidConfiguration
    }
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

private struct CoordinatorDownloadFixture: Sendable {
    let compressed: Data
    let uncompressedBytes: Int
}

private actor CoordinatorTransport: ManagedStorageTransport {
    private let failFirstCompletion: Bool
    private let feedChanges: [ManagedChangeFeed.Change]
    private let snapshotChunks: [ManagedAvailableChunk]
    private let snapshotDocuments: [ManagedDocument]
    private let remoteDocuments: [UUID: ManagedDocument]
    private let expireFirstChangeCursor: Bool
    private let failSnapshotNotFound: Bool
    private let feedHighWatermark: Int64?
    private let downloadableChunks: [UUID: CoordinatorDownloadFixture]
    private let restoreJobID = UUID()
    private var uploads = 0
    private var completions = 0
    private var changeRequests = 0
    private var restoreCreations = 0
    private var restoreCompletions = 0
    private var documentUploads = 0
    private var sourceRegistrations = 0
    private var chunkReservations = 0
    private var downloads = 0
    private var snapshotCursors: [ManagedChunkPage.Cursor?] = []
    private var snapshotIncludeDeleted: [Bool] = []
    private var restoreIncludeDeleted: [Bool] = []
    private let onDownload: (@Sendable () async -> Void)?

    init(
        failFirstCompletion: Bool = false,
        changes: [ManagedChangeFeed.Change] = [],
        snapshotChunks: [ManagedAvailableChunk] = [],
        snapshotDocuments: [ManagedDocument] = [],
        remoteDocuments: [UUID: ManagedDocument] = [:],
        expireFirstChangeCursor: Bool = false,
        failSnapshotNotFound: Bool = false,
        feedHighWatermark: Int64? = nil,
        downloadableChunks: [UUID: CoordinatorDownloadFixture] = [:],
        onDownload: (@Sendable () async -> Void)? = nil
    ) {
        self.failFirstCompletion = failFirstCompletion
        feedChanges = changes
        self.snapshotChunks = snapshotChunks
        self.snapshotDocuments = snapshotDocuments
        self.remoteDocuments = remoteDocuments
        self.expireFirstChangeCursor = expireFirstChangeCursor
        self.failSnapshotNotFound = failSnapshotNotFound
        self.feedHighWatermark = feedHighWatermark
        self.downloadableChunks = downloadableChunks
        self.onDownload = onDownload
    }

    func uploadCount() -> Int { uploads }
    func completionCount() -> Int { completions }
    func restoreCreationCount() -> Int { restoreCreations }
    func restoreCompletionCount() -> Int { restoreCompletions }
    func documentUploadCount() -> Int { documentUploads }
    func sourceRegistrationCount() -> Int { sourceRegistrations }
    func chunkReservationCount() -> Int { chunkReservations }
    func downloadCount() -> Int { downloads }
    func snapshotCursorChunkIDs() -> [UUID?] {
        snapshotCursors.map { $0?.afterChunkID }
    }
    func snapshotIncludeDeletedValues() -> [Bool] { snapshotIncludeDeleted }
    func restoreIncludeDeletedValues() -> [Bool] { restoreIncludeDeleted }

    func registerSource(
        _ source: ManagedSourceRegistration,
        authorization: ManagedAuthorization
    ) async throws -> ManagedSourceResponse {
        sourceRegistrations += 1
        return ManagedSourceResponse(
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
        chunkReservations += 1
        return ManagedChunkReservationResponse(
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
        let highWatermark = max(
            sequence,
            feedHighWatermark ?? feedChanges.last?.sequence ?? sequence
        )
        let hasMore = feedChanges.contains {
            $0.sequence > (selected.last?.sequence ?? sequence)
        }
        return ManagedChangeFeed(
            changes: selected,
            minimumSequence: 1,
            highWatermark: highWatermark,
            nextSequence: hasMore
                ? (selected.last?.sequence ?? sequence)
                : highWatermark,
            hasMore: hasMore
        )
    }

    func createRestore(
        requestID: UUID,
        dataClasses: [String],
        includeDeletedDocuments: Bool,
        authorization: ManagedAuthorization
    ) async throws -> ManagedRestoreJob {
        restoreIncludeDeleted.append(includeDeletedDocuments)
        restoreCreations += 1
        return ManagedRestoreJob(
            restoreJobID: restoreJobID,
            status: "running",
            snapshotAt: "2026-09-01T02:00:00Z",
            changeSequence: 42,
            selectedObjects: snapshotChunks.count + snapshotDocuments.count,
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
            selectedObjects: snapshotChunks.count + snapshotDocuments.count,
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
        guard let fixture = downloadableChunks[chunkID] else {
            throw ManagedStorageError.invalidResponse
        }
        return ManagedDownloadCapability(
            grantID: UUID(),
            method: "GET",
            url: URL(string: "https://storage.googleapis.com/bucket/object")!,
            headers: [:],
            expiresAt: "2026-09-19T12:10:00Z",
            chunk: .init(
                chunkID: chunkID,
                expectedSHA256: ManagedDigest.sha256(fixture.compressed),
                compression: "gzip",
                contentType: "application/vnd.noop.chunk+json",
                expectedUncompressedBytes: fixture.uncompressedBytes
            )
        )
    }

    func download(using capability: ManagedDownloadCapability) async throws -> Data {
        guard let fixture = downloadableChunks[capability.chunk.chunkID] else {
            throw ManagedStorageError.invalidResponse
        }
        downloads += 1
        await onDownload?()
        return fixture.compressed
    }

    func document(
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Int64?,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocument {
        guard let document = remoteDocuments[id],
              document.documentKind == kind,
              revision.map({ document.revision == $0 }) ?? true else {
            throw ManagedStorageError.invalidResponse
        }
        return document
    }

    func documents(
        snapshotAt: String,
        after cursor: ManagedDocumentPage.Cursor?,
        limit: Int,
        includeDeleted: Bool,
        authorization: ManagedAuthorization
    ) async throws -> ManagedDocumentPage {
        snapshotIncludeDeleted.append(includeDeleted)
        let ordered = snapshotDocuments
            .filter { includeDeleted || $0.deletedAt == nil }
            .sorted {
                ($0.updatedAt, $0.documentKind.rawValue, $0.documentID.uuidString)
                    < ($1.updatedAt, $1.documentKind.rawValue, $1.documentID.uuidString)
            }
        let remaining = ordered.filter { document in
            guard let cursor else { return true }
            return (
                document.updatedAt,
                document.documentKind.rawValue,
                document.documentID.uuidString
            ) > (
                cursor.afterUpdatedAt,
                cursor.afterDocumentKind.rawValue,
                cursor.afterDocumentID.uuidString
            )
        }
        let selected = Array(remaining.prefix(limit))
        let next = remaining.count > selected.count
            ? selected.last?.pageCursor
            : nil
        return ManagedDocumentPage(documents: selected, nextCursor: next)
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
