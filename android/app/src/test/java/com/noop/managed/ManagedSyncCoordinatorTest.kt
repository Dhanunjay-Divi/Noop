package com.noop.managed

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject
import java.util.UUID

class ManagedSyncCoordinatorTest {
    private val source = ManagedSourceDescriptor(
        localSourceId = "strap",
        sourceKind = "live_ble",
        installationId = "installation",
    )
    private val authorization = ManagedAuthorization(
        "identity",
        "app-check",
        "installation",
        "noopm_" + "a".repeat(43),
    )

    @Test
    fun localRetentionPolicyKeepsNinetyDaysAndClampsAtEpoch() {
        val dayMs = 86_400_000L
        assertEquals(90L, ManagedLocalRetentionPolicy.DETAILED_HISTORY_DAYS)
        assertEquals(10 * dayMs, ManagedLocalRetentionPolicy.cutoff(100 * dayMs))
        assertEquals(0L, ManagedLocalRetentionPolicy.cutoff(89 * dayMs))
    }

    @Test
    fun boundedForwardUploadReportsLocalContinuation() = runTest {
        val result = ManagedSyncCoordinator(
            FakeTransport(),
            MultiWindowExtractor(listOf(1_000L, WINDOW_MS + 1_000L)),
            FakeState(),
            FakeRestore(),
        ).sync(
            source = source,
            authorization = authorization,
            nowMs = 2 * WINDOW_MS + SETTLE_MS,
            dataClasses = listOf("essential_timeseries"),
            maxForwardWindowsPerClass = 1,
            maxChangePages = 0,
        )

        assertEquals(1, result.uploadedChunks)
        assertEquals(false, result.hasMoreChanges)
        assertTrue(result.hasMoreLocalWork)
        assertTrue(result.hasMoreWork)
    }

    @Test
    fun boundedDocumentUploadUsesLookAheadForLocalContinuation() = runTest {
        val first = pendingDocument()
        val second = first.copy(
            localIdentifier = "local-journal-2",
            mutation = first.mutation.copy(
                requestId = UUID.randomUUID(),
                documentId = UUID.randomUUID(),
            ),
        )
        val outbox = FakeDocumentOutbox(listOf(first, second))
        val result = ManagedSyncCoordinator(
            FakeTransport(),
            FakeExtractor(),
            FakeState(),
            FakeRestore(),
            outbox,
        ).sync(
            source = source,
            authorization = authorization,
            nowMs = 0,
            dataClasses = emptyList(),
            maxChangePages = 0,
            maxDocumentUploads = 1,
        )

        assertEquals(1, result.uploadedDocuments)
        assertTrue(result.hasMoreLocalWork)
        assertEquals(1, outbox.acknowledgements)
    }

    @Test
    fun completionFailurePersistsReceiptAndRetryDoesNotUploadAgain() = runTest {
        val extractor = FakeExtractor()
        val state = FakeState()
        val transport = FakeTransport(failFirstCompletion = true)
        val coordinator = ManagedSyncCoordinator(transport, extractor, state, FakeRestore())

        try {
            coordinator.sync(
                source,
                authorization,
                nowMs = WINDOW_MS + SETTLE_MS,
                dataClasses = listOf("essential_timeseries"),
                maxChangePages = 0,
            )
            throw AssertionError("Expected completion failure")
        } catch (_: ManagedStorageException.Network) {
            // Expected.
        }

        assertEquals(1, transport.uploads)
        assertEquals(1, transport.completions)
        assertNull(state.checkpoint.nextWindowStartMs)
        assertEquals(
            ManagedWindowUploadPhase.PENDING_COMPLETION,
            state.window?.phase,
        )

        val result = coordinator.sync(
            source,
            authorization,
            nowMs = WINDOW_MS + SETTLE_MS,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 0,
        )

        assertEquals(1, transport.uploads)
        assertEquals(2, transport.completions)
        assertEquals(WINDOW_MS, state.checkpoint.nextWindowStartMs)
        assertEquals(ManagedWindowUploadPhase.AWAITING_VALIDATION, state.window?.phase)
        assertEquals(0, result.uploadedChunks)
    }

    @Test
    fun repairUploadsAnEmptySnapshotAfterTheLastRowIsDeleted() = runTest {
        val extractor = FakeExtractor()
        val state = FakeState()
        val transport = FakeTransport()
        val coordinator = ManagedSyncCoordinator(transport, extractor, state, FakeRestore())

        coordinator.sync(
            source,
            authorization,
            nowMs = WINDOW_MS + SETTLE_MS,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 0,
        )
        val populatedChunk = state.window!!.chunkId
        state.markWindowAvailable()

        extractor.hasRow = false
        val result = coordinator.sync(
            source,
            authorization,
            nowMs = WINDOW_MS + SETTLE_MS,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 0,
        )

        assertEquals(2, transport.uploads)
        assertEquals(1, result.uploadedChunks)
        assertEquals(0, state.window!!.rowCount)
        assertNotEquals(populatedChunk, state.window!!.chunkId)
    }

    @Test
    fun alreadyAppliedChangeOnlyAdvancesTheCursor() = runTest {
        val state = FakeState()
        val change = metadataChange(sequence = 1)
        state.applied += change.sequence
        val transport = FakeTransport(changes = listOf(change))
        val restore = FakeRestore()
        val coordinator = ManagedSyncCoordinator(transport, FakeExtractor(), state, restore)

        val result = coordinator.sync(
            source,
            authorization,
            nowMs = WINDOW_MS + SETTLE_MS,
            dataClasses = emptyList(),
            maxChangePages = 1,
        )

        assertEquals(1L, state.sequence)
        assertEquals(1, result.appliedChanges)
        assertEquals(0, restore.metadataApplications)
    }

    @Test
    fun validatedLocalUploadAdvancesFeedWithoutDownloadingDuplicate() = runTest {
        val chunkId = UUID.randomUUID()
        val change = ManagedChange(
            sequence = 1,
            resourceKind = "chunk",
            resourceId = chunkId,
            operation = "available",
            contentSha256 = "a".repeat(64),
            dataClass = "essential_timeseries",
            eventStart = "1970-01-01T00:00:00Z",
            eventEnd = "1970-01-01T00:00:01Z",
            chunk = ManagedChangedChunk(
                chunkId = chunkId,
                sourceId = source.sourceId,
                schemaVersion = 1,
                contentMode = "server_readable",
                state = "available",
                compression = "gzip",
                contentType = "application/vnd.noop.chunk+json",
                expectedCompressedBytes = 100,
                expectedUncompressedBytes = 200,
                objectGeneration = 1,
                expiresAt = null,
            ),
        )
        val state = FakeState(localChunkIds = setOf(chunkId))
        val restore = FakeRestore()
        val coordinator = ManagedSyncCoordinator(
            FakeTransport(changes = listOf(change)),
            FakeExtractor(),
            state,
            restore,
        )

        val result = coordinator.sync(
            source,
            authorization,
            nowMs = 2_000,
            dataClasses = emptyList(),
            maxChangePages = 1,
        )

        assertEquals(1, result.appliedChanges)
        assertEquals(1L, state.sequence)
        assertEquals(1, state.acknowledgements)
        assertEquals(0, restore.chunkApplications)
    }

    @Test
    fun dirtyPrunedWindowHydratesCloudBaseBeforeReplacementUpload() = runTest {
        val columns = listOf("event_at_ms", "bpm", "quality", "provenance")
        val baseStream = ManagedChunkStreamPayload(
            streamKey = "heart_rate",
            columns = columns,
            rows = listOf(
                listOf(
                    ManagedJsonValue.IntegerValue(1_000),
                    ManagedJsonValue.IntegerValue(68),
                    ManagedJsonValue.NullValue,
                    ManagedJsonValue.StringValue("sensor"),
                ),
            ),
        )
        val base = requireNotNull(
            ManagedPreparedChunk.prepare(
                source.sourceId,
                "essential_timeseries",
                0,
                WINDOW_MS - 1,
                listOf(baseStream),
            ),
        )
        val compressedBase = ManagedChunkCodec.encode(
            base.uncompressed,
            ManagedChunkCompression.GZIP,
        )
        val extractor = PrunedExtractor(
            columns,
            listOf(
                listOf(
                    ManagedJsonValue.IntegerValue(2_000),
                    ManagedJsonValue.IntegerValue(72),
                    ManagedJsonValue.NullValue,
                    ManagedJsonValue.StringValue("sensor"),
                ),
            ),
        )
        val state = PrunedState(
            ManagedUploadCheckpoint(nextWindowStartMs = WINDOW_MS),
            ManagedWindowUpload(
                windowEndMs = WINDOW_MS - 1,
                chunkId = base.chunkId,
                rowCount = 1,
                phase = ManagedWindowUploadPhase.AVAILABLE,
                snapshotGeneration = 1,
                validatedAtMs = 10,
                localPrunedAtMs = 20,
            ),
            ManagedDirtyWindow(0, WINDOW_MS, 2),
        )
        val transport = PrunedTransport(
            base.chunkId,
            compressedBase,
            base.uncompressed.size,
        )
        val restore = PrunedRestore(extractor)
        val coordinator = ManagedSyncCoordinator(transport, extractor, state, restore)

        val result = coordinator.sync(
            source,
            authorization,
            nowMs = WINDOW_MS + SETTLE_MS,
            dataClasses = listOf("essential_timeseries"),
            maxDirtyWindowsPerClass = 1,
            maxChangePages = 0,
        )

        val replacement = transport.uploadedPayload()
        assertEquals(1, restore.hydrations)
        assertEquals(2, replacement?.streams?.first()?.rows?.size)
        assertEquals(
            listOf(1_000L, 2_000L),
            replacement?.streams?.first()?.rows?.map {
                (it.first() as ManagedJsonValue.IntegerValue).value
            },
        )
        assertEquals(1, result.uploadedChunks)
        assertNull(state.window.localPrunedAtMs)
    }

    @Test
    fun expiredCursorSnapshotResumesAfterProcessDeathAndAnchorsFeed() = runTest {
        val first = availableChunk(
            UUID.fromString("11111111-1111-5111-8111-111111111111"),
            "2026-09-01T00:00:00Z",
            "2026-09-01T00:59:59Z",
        )
        val second = availableChunk(
            UUID.fromString("22222222-2222-5222-8222-222222222222"),
            "2026-09-01T01:00:00Z",
            "2026-09-01T01:59:59Z",
        )
        val state = FakeState(localChunkIds = setOf(first.chunkId, second.chunkId))
        val transport = FakeTransport(
            snapshotChunks = listOf(first, second),
            expireFirstChangeCursor = true,
        )

        val firstRun = ManagedSyncCoordinator(
            transport,
            FakeExtractor(),
            state,
            FakeRestore(),
        ).sync(
            source,
            authorization,
            nowMs = 0,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 1,
            maxSnapshotRestoreObjects = 1,
        )

        val persisted = requireNotNull(state.restoreCheckpoint)
        assertEquals(1, firstRun.appliedChanges)
        assertTrue(firstRun.hasMoreChanges)
        assertEquals(1, persisted.deliveredObjects)
        assertEquals(first.chunkId, persisted.cursor?.afterChunkId)
        assertEquals(1, transport.restoreCreations)

        val secondRun = ManagedSyncCoordinator(
            transport,
            FakeExtractor(),
            state,
            FakeRestore(),
        ).sync(
            source,
            authorization,
            nowMs = 0,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 1,
        )

        assertEquals(1, secondRun.appliedChanges)
        assertEquals(false, secondRun.hasMoreChanges)
        assertEquals(42L, state.sequence)
        assertNull(state.restoreCheckpoint)
        assertEquals(1, transport.restoreCreations)
        assertEquals(1, transport.restoreCompletions)
        assertEquals(listOf(null, first.chunkId), transport.snapshotCursorChunkIds)
    }

    @Test
    fun missingSnapshotObjectRestartsOnlyRestoreCheckpoint() = runTest {
        val staleRequestId = UUID.randomUUID()
        val state = FakeState(
            restoreCheckpoint = ManagedSnapshotRestoreCheckpoint(
                requestId = staleRequestId,
                dataClasses = listOf("essential_timeseries"),
                restoreJobId = UUID.randomUUID(),
                snapshotAt = "2026-09-01T00:00:00Z",
                changeSequence = 7,
                selectedObjects = 1,
                selectedBytes = 100,
            ),
        )
        val transport = FakeTransport(failSnapshotNotFound = true)

        val result = ManagedSyncCoordinator(
            transport,
            FakeExtractor(),
            state,
            FakeRestore(),
        ).sync(
            source,
            authorization,
            nowMs = 0,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 1,
        )

        val restarted = requireNotNull(state.restoreCheckpoint)
        assertTrue(result.hasMoreChanges)
        assertNotEquals(staleRequestId, restarted.requestId)
        assertNull(restarted.restoreJobId)
        assertEquals(listOf("essential_timeseries"), restarted.dataClasses)
        assertEquals(0L, state.sequence)
        assertEquals(1, state.snapshotClears)
    }

    @Test
    fun remoteBacklogIsAppliedBeforeAnyLocalDocumentUpload() = runTest {
        val outbox = FakeDocumentOutbox(listOf(pendingDocument()))
        val transport = FakeTransport(
            changes = listOf(metadataChange(sequence = 1)),
            changeFeedHasMore = true,
        )
        val restore = FakeRestore()

        val result = ManagedSyncCoordinator(
            transport,
            FakeExtractor(),
            FakeState(),
            restore,
            outbox,
        ).sync(
            source,
            authorization,
            nowMs = 0,
            dataClasses = emptyList(),
            maxChangePages = 1,
        )

        assertEquals(1, result.appliedChanges)
        assertTrue(result.hasMoreChanges)
        assertEquals(1, restore.metadataApplications)
        assertEquals(0, result.uploadedDocuments)
        assertEquals(0, outbox.pendingRequests)
        assertEquals(0, transport.documentPuts)
    }

    @Test
    fun drainedFeedUploadsAndAcknowledgesPendingDocuments() = runTest {
        val outbox = FakeDocumentOutbox(listOf(pendingDocument()))
        val transport = FakeTransport()

        val result = ManagedSyncCoordinator(
            transport,
            FakeExtractor(),
            FakeState(),
            FakeRestore(),
            outbox,
        ).sync(
            source,
            authorization,
            nowMs = 0,
            dataClasses = emptyList(),
            maxChangePages = 1,
        )

        assertEquals(1, result.uploadedDocuments)
        assertEquals(1, outbox.pendingRequests)
        assertEquals(1, outbox.acknowledgements)
        assertEquals(1, transport.documentPuts)
    }

    @Test
    fun expiredCursorSnapshotRestoresDocumentsAndAnchorsFeed() = runTest {
        val document = snapshotDocument()
        val state = FakeState()
        val restore = FakeRestore()
        val transport = FakeTransport(
            snapshotDocuments = listOf(document),
            expireFirstChangeCursor = true,
        )

        val result = ManagedSyncCoordinator(
            transport,
            FakeExtractor(),
            state,
            restore,
        ).sync(
            source,
            authorization,
            nowMs = 0,
            dataClasses = listOf("essential_timeseries"),
            maxChangePages = 2,
        )

        assertEquals(1, result.appliedChanges)
        assertTrue(result.hasMoreChanges)
        assertEquals(1, restore.documentApplications)
        assertEquals(42L, state.sequence)
        assertNull(state.restoreCheckpoint)
        assertEquals(1, transport.restoreCreations)
        assertEquals(1, transport.restoreCompletions)
        assertEquals(listOf<UUID?>(null), transport.snapshotCursorDocumentIds)
    }

    private fun availableChunk(
        id: UUID,
        eventStart: String,
        eventEnd: String,
    ) = ManagedAvailableChunk(
        chunkId = id,
        sourceId = source.sourceId,
        dataClass = "essential_timeseries",
        schemaVersion = 1,
        contentMode = "server_readable",
        state = "available",
        eventStart = eventStart,
        eventEnd = eventEnd,
        compression = "gzip",
        contentType = "application/vnd.noop.chunk+json",
        expectedSha256 = "a".repeat(64),
        expectedCompressedBytes = 100,
        expectedUncompressedBytes = 200,
        objectGeneration = 1,
        expiresAt = "2026-10-01T00:00:00Z",
    )

    private class PrunedExtractor(
        private val columns: List<String>,
        localRows: List<List<ManagedJsonValue>>,
    ) : ManagedChunkExtracting {
        private var rows = localRows

        fun merge(cloudRows: List<List<ManagedJsonValue>>) {
            val byTimestamp = linkedMapOf<Long, List<ManagedJsonValue>>()
            cloudRows.forEach {
                byTimestamp[(it.first() as ManagedJsonValue.IntegerValue).value] = it
            }
            rows.forEach {
                byTimestamp[(it.first() as ManagedJsonValue.IntegerValue).value] = it
            }
            rows = byTimestamp.toSortedMap().values.toList()
        }

        override suspend fun nextEventTime(
            source: ManagedSourceDescriptor,
            dataClass: String,
            atOrAfterMs: Long,
            beforeMs: Long,
        ): Long? = rows
            .map { (it.first() as ManagedJsonValue.IntegerValue).value }
            .filter { it >= atOrAfterMs && it < beforeMs }
            .minOrNull()

        override suspend fun streams(
            source: ManagedSourceDescriptor,
            dataClass: String,
            window: ManagedSyncWindow,
        ) = listOf(ManagedChunkStreamPayload("heart_rate", columns, rows))
    }

    private class PrunedState(
        private var checkpoint: ManagedUploadCheckpoint,
        var window: ManagedWindowUpload,
        private var dirty: ManagedDirtyWindow?,
    ) : ManagedSyncStateStoring {
        override suspend fun uploadCheckpoint(
            sourceId: UUID,
            dataClass: String,
        ) = checkpoint

        override suspend fun saveUploadCheckpoint(
            checkpoint: ManagedUploadCheckpoint,
            sourceId: UUID,
            dataClass: String,
        ) {
            this.checkpoint = checkpoint
        }

        override suspend fun windowUpload(
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
        ) = window

        override suspend fun saveWindowUpload(
            upload: ManagedWindowUpload,
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
        ) {
            window = upload
        }

        override suspend fun claimWindowGeneration(
            sourceId: UUID,
            localSourceId: String,
            dataClass: String,
            window: ManagedSyncWindow,
        ) = 2L

        override suspend fun claimNextDirtyWindow(
            sourceId: UUID,
            localSourceId: String,
            dataClass: String,
            endingAtOrBeforeMs: Long,
        ): ManagedDirtyWindow? = dirty.also { dirty = null }

        override suspend fun acknowledgeAvailableChunk(
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
            windowEndMs: Long,
            chunkId: UUID,
        ) = false

        override suspend fun markWindowHydrated(
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
            windowEndMs: Long,
            chunkId: UUID,
        ): Boolean {
            if (window.windowEndMs != windowEndMs || window.chunkId != chunkId) return false
            window = window.copy(localPrunedAtMs = null)
            return true
        }

        override suspend fun pruneAvailableWindows(
            sourceId: UUID,
            localSourceId: String,
            dataClass: String,
            endingBeforeMs: Long,
            limit: Int,
        ) = ManagedPruneResult(0, 0)

        override suspend fun changeSequence() = 0L
        override suspend fun saveChangeSequence(sequence: Long) = Unit
        override suspend fun isChangeApplied(change: ManagedChange) = false
        override suspend fun recordAppliedChange(change: ManagedChange) = Unit
    }

    private class PrunedRestore(
        private val extractor: PrunedExtractor,
    ) : ManagedRestoreApplying {
        var hydrations = 0

        override suspend fun apply(chunk: ManagedChunkPayload, change: ManagedChange) = Unit

        override suspend fun hydrate(
            chunk: ManagedChunkPayload,
            source: ManagedSourceDescriptor,
        ) {
            hydrations += 1
            extractor.merge(chunk.streams.firstOrNull()?.rows.orEmpty())
        }
    }

    private class PrunedTransport(
        private val chunkId: UUID,
        private val compressedBase: ByteArray,
        private val uncompressedBaseBytes: Int,
    ) : ManagedStorageTransport {
        private var uploaded: ByteArray? = null
        private var uploadCompression: String? = null
        private var uploadUncompressedBytes: Int? = null

        fun uploadedPayload(): ManagedChunkPayload? {
            val bytes = uploaded ?: return null
            val compression = uploadCompression ?: return null
            val uncompressedBytes = uploadUncompressedBytes ?: return null
            return ManagedChunkCodec.decodePayload(
                ManagedChunkCodec.decode(bytes, compression, uncompressedBytes),
            )
        }

        override suspend fun registerSource(
            authorization: ManagedAuthorization,
            sourceId: UUID,
            sourceKind: String,
            logicalSourceHash: String,
        ) = Unit

        override suspend fun reserveChunk(
            authorization: ManagedAuthorization,
            reservation: ManagedChunkReservation,
        ): ManagedChunkReservationResult {
            uploadCompression = reservation.compression
            uploadUncompressedBytes = reservation.expectedUncompressedBytes
            return ManagedChunkReservationResult(
                reservation.chunkId,
                "reserved",
                false,
                ManagedUploadCapability(
                    UUID.randomUUID(),
                    "PUT",
                    "https://storage.googleapis.com/bucket/object",
                    emptyMap(),
                    "2026-09-04T12:10:00Z",
                ),
            )
        }

        override suspend fun upload(
            bytes: ByteArray,
            capability: ManagedUploadCapability,
        ): ManagedObjectUploadReceipt {
            uploaded = bytes
            return ManagedObjectUploadReceipt(42, 1, "AAAAAA==")
        }

        override suspend fun completeChunk(
            authorization: ManagedAuthorization,
            chunkId: UUID,
            receipt: ManagedObjectUploadReceipt,
        ) = Unit

        override suspend fun changes(
            authorization: ManagedAuthorization,
            afterSequence: Long,
            limit: Int,
        ) = ManagedChangeFeed(emptyList(), 0, afterSequence, afterSequence, false)

        override suspend fun downloadCapability(
            authorization: ManagedAuthorization,
            chunkId: UUID,
            requestId: UUID,
        ): ManagedDownloadCapability {
            check(chunkId == this.chunkId)
            return ManagedDownloadCapability(
                UUID.randomUUID(),
                "GET",
                "https://storage.googleapis.com/bucket/base",
                emptyMap(),
                "2026-09-04T12:10:00Z",
                chunkId,
                ManagedDigest.sha256(compressedBase),
                "gzip",
                "application/vnd.noop.chunk+json",
                uncompressedBaseBytes,
            )
        }

        override suspend fun download(capability: ManagedDownloadCapability) = compressedBase
    }

    private class FakeExtractor : ManagedChunkExtracting {
        var hasRow = true

        override suspend fun nextEventTime(
            source: ManagedSourceDescriptor,
            dataClass: String,
            atOrAfterMs: Long,
            beforeMs: Long,
        ): Long? = if (hasRow && atOrAfterMs <= 1_000L && beforeMs > 1_000L) 1_000L else null

        override suspend fun streams(
            source: ManagedSourceDescriptor,
            dataClass: String,
            window: ManagedSyncWindow,
        ): List<ManagedChunkStreamPayload> = listOf(
            ManagedChunkStreamPayload(
                streamKey = "heart_rate",
                columns = listOf("event_at_ms", "bpm", "quality", "provenance"),
                rows = if (hasRow) {
                    listOf(
                        listOf(
                            ManagedJsonValue.IntegerValue(1_000),
                            ManagedJsonValue.IntegerValue(68),
                            ManagedJsonValue.NullValue,
                            ManagedJsonValue.StringValue("sensor"),
                        ),
                    )
                } else {
                    emptyList()
                },
            ),
        )
    }

    private class MultiWindowExtractor(
        eventTimes: List<Long>,
    ) : ManagedChunkExtracting {
        private val eventTimes = eventTimes.sorted()

        override suspend fun nextEventTime(
            source: ManagedSourceDescriptor,
            dataClass: String,
            atOrAfterMs: Long,
            beforeMs: Long,
        ): Long? = eventTimes.firstOrNull { it >= atOrAfterMs && it < beforeMs }

        override suspend fun streams(
            source: ManagedSourceDescriptor,
            dataClass: String,
            window: ManagedSyncWindow,
        ) = listOf(
            ManagedChunkStreamPayload(
                streamKey = "heart_rate",
                columns = listOf("event_at_ms", "bpm", "quality", "provenance"),
                rows = eventTimes
                    .filter { it >= window.startMs && it < window.endExclusiveMs }
                    .map {
                        listOf(
                            ManagedJsonValue.IntegerValue(it),
                            ManagedJsonValue.IntegerValue(68),
                            ManagedJsonValue.NullValue,
                            ManagedJsonValue.StringValue("sensor"),
                        )
                    },
            ),
        )
    }

    private class FakeState(
        private val localChunkIds: Set<UUID> = emptySet(),
        var restoreCheckpoint: ManagedSnapshotRestoreCheckpoint? = null,
    ) : ManagedSyncStateStoring {
        var checkpoint = ManagedUploadCheckpoint()
        var window: ManagedWindowUpload? = null
        var sequence = 0L
        val applied = mutableSetOf<Long>()
        var acknowledgements = 0
        var snapshotClears = 0
        private var generation = 0L

        fun markWindowAvailable() {
            window = window?.copy(
                phase = ManagedWindowUploadPhase.AVAILABLE,
                validatedAtMs = 1L,
            )
        }

        override suspend fun uploadCheckpoint(
            sourceId: UUID,
            dataClass: String,
        ) = checkpoint

        override suspend fun saveUploadCheckpoint(
            checkpoint: ManagedUploadCheckpoint,
            sourceId: UUID,
            dataClass: String,
        ) {
            this.checkpoint = checkpoint
        }

        override suspend fun windowUpload(
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
        ) = window

        override suspend fun saveWindowUpload(
            upload: ManagedWindowUpload,
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
        ) {
            window = upload
        }

        override suspend fun claimWindowGeneration(
            sourceId: UUID,
            localSourceId: String,
            dataClass: String,
            window: ManagedSyncWindow,
        ): Long {
            generation += 1
            return generation
        }

        override suspend fun claimNextDirtyWindow(
            sourceId: UUID,
            localSourceId: String,
            dataClass: String,
            endingAtOrBeforeMs: Long,
        ): ManagedDirtyWindow? = null

        override suspend fun acknowledgeAvailableChunk(
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
            windowEndMs: Long,
            chunkId: UUID,
        ): Boolean {
            if (chunkId !in localChunkIds) return false
            acknowledgements += 1
            return true
        }

        override suspend fun markWindowHydrated(
            sourceId: UUID,
            dataClass: String,
            windowStartMs: Long,
            windowEndMs: Long,
            chunkId: UUID,
        ): Boolean {
            val current = window ?: return false
            if (current.windowEndMs != windowEndMs || current.chunkId != chunkId) return false
            window = current.copy(localPrunedAtMs = null)
            return true
        }

        override suspend fun pruneAvailableWindows(
            sourceId: UUID,
            localSourceId: String,
            dataClass: String,
            endingBeforeMs: Long,
            limit: Int,
        ) = ManagedPruneResult(0, 0)

        override suspend fun changeSequence() = sequence

        override suspend fun saveChangeSequence(sequence: Long) {
            this.sequence = maxOf(this.sequence, sequence)
        }

        override suspend fun isChangeApplied(change: ManagedChange) =
            change.sequence in applied

        override suspend fun recordAppliedChange(change: ManagedChange) {
            applied += change.sequence
        }

        override suspend fun snapshotRestoreCheckpoint() = restoreCheckpoint

        override suspend fun saveSnapshotRestoreCheckpoint(
            checkpoint: ManagedSnapshotRestoreCheckpoint,
        ) {
            restoreCheckpoint = checkpoint
        }

        override suspend fun clearSnapshotRestoreCheckpoint() {
            restoreCheckpoint = null
            snapshotClears += 1
        }

        override suspend fun finishSnapshotRestore(changeSequence: Long) {
            sequence = maxOf(sequence, changeSequence)
            restoreCheckpoint = null
        }
    }

    private class FakeRestore : ManagedRestoreApplying {
        var metadataApplications = 0
        var chunkApplications = 0
        var documentApplications = 0

        override suspend fun apply(chunk: ManagedChunkPayload, change: ManagedChange) {
            chunkApplications += 1
        }

        override suspend fun apply(document: ManagedDocument, change: ManagedChange) {
            documentApplications += 1
        }

        override suspend fun hydrate(
            chunk: ManagedChunkPayload,
            source: ManagedSourceDescriptor,
        ) = Unit

        override suspend fun applyMetadataOnly(change: ManagedChange) {
            metadataApplications += 1
        }
    }

    private class FakeTransport(
        private val failFirstCompletion: Boolean = false,
        private val changes: List<ManagedChange> = emptyList(),
        private val snapshotChunks: List<ManagedAvailableChunk> = emptyList(),
        private val snapshotDocuments: List<ManagedDocument> = emptyList(),
        private val changeFeedHasMore: Boolean = false,
        private val expireFirstChangeCursor: Boolean = false,
        private val failSnapshotNotFound: Boolean = false,
    ) : ManagedStorageTransport {
        var uploads = 0
        var completions = 0
        var restoreCreations = 0
        var restoreCompletions = 0
        var documentPuts = 0
        val snapshotCursorChunkIds = mutableListOf<UUID?>()
        val snapshotCursorDocumentIds = mutableListOf<UUID?>()
        private var changeRequests = 0
        private val restoreJobId = UUID.randomUUID()

        override suspend fun registerSource(
            authorization: ManagedAuthorization,
            sourceId: UUID,
            sourceKind: String,
            logicalSourceHash: String,
        ) = Unit

        override suspend fun reserveChunk(
            authorization: ManagedAuthorization,
            reservation: ManagedChunkReservation,
        ) = ManagedChunkReservationResult(
            chunkId = reservation.chunkId,
            state = "reserved",
            duplicate = false,
            upload = ManagedUploadCapability(
                UUID.randomUUID(),
                "PUT",
                "https://storage.googleapis.com/bucket/object",
                emptyMap(),
                "2026-09-03T12:10:00Z",
            ),
        )

        override suspend fun upload(
            bytes: ByteArray,
            capability: ManagedUploadCapability,
        ): ManagedObjectUploadReceipt {
            uploads += 1
            return ManagedObjectUploadReceipt(42, 1, "AAAAAA==")
        }

        override suspend fun completeChunk(
            authorization: ManagedAuthorization,
            chunkId: UUID,
            receipt: ManagedObjectUploadReceipt,
        ) {
            completions += 1
            if (failFirstCompletion && completions == 1) {
                throw ManagedStorageException.Network()
            }
        }

        override suspend fun changes(
            authorization: ManagedAuthorization,
            afterSequence: Long,
            limit: Int,
        ): ManagedChangeFeed {
            changeRequests += 1
            if (expireFirstChangeCursor && changeRequests == 1) {
                throw ManagedStorageException.CursorExpired(10)
            }
            return ManagedChangeFeed(
                changes = changes.filter { it.sequence > afterSequence },
                minimumSequence = 0,
                highWatermark = changes.maxOfOrNull { it.sequence } ?: 0,
                nextSequence = changes.maxOfOrNull { it.sequence } ?: afterSequence,
                hasMore = changeFeedHasMore,
            )
        }

        override suspend fun createRestore(
            authorization: ManagedAuthorization,
            requestId: UUID,
            dataClasses: List<String>,
        ): ManagedRestoreJob {
            restoreCreations += 1
            return ManagedRestoreJob(
                restoreJobId,
                "running",
                "2026-09-01T02:00:00Z",
                42,
                snapshotChunks.size + snapshotDocuments.size,
                snapshotChunks.sumOf { it.expectedCompressedBytes.toLong() },
                0,
                0,
                "2026-09-02T02:00:00Z",
                false,
            )
        }

        override suspend fun availableChunks(
            authorization: ManagedAuthorization,
            dataClass: String,
            snapshotAt: String,
            after: ManagedChunkCursor?,
            limit: Int,
        ): ManagedChunkPage {
            if (failSnapshotNotFound) throw ManagedStorageException.NotFound()
            snapshotCursorChunkIds += after?.afterChunkId
            val remaining = snapshotChunks
                .sortedWith(compareBy(ManagedAvailableChunk::eventStart, { it.chunkId.toString() }))
                .filter {
                    after == null ||
                        it.eventStart > after.afterEventStart ||
                        (
                            it.eventStart == after.afterEventStart &&
                                it.chunkId.toString() > after.afterChunkId.toString()
                            )
                }
            val selected = remaining.take(limit)
            val next = if (remaining.size > selected.size) {
                selected.last().let { ManagedChunkCursor(it.eventStart, it.chunkId) }
            } else {
                null
            }
            return ManagedChunkPage(selected, next)
        }

        override suspend fun putDocument(
            authorization: ManagedAuthorization,
            mutation: ManagedDocumentMutation,
        ): ManagedDocument {
            documentPuts += 1
            return ManagedDocument(
                documentKind = mutation.documentKind,
                documentId = mutation.documentId,
                revision = mutation.baseRevision + 1,
                originInstallationId = authorization.installationId,
                contentMode = mutation.contentMode,
                clientKeyId = mutation.clientKeyId,
                contentSha256 = mutation.contentSha256
                    ?: throw AssertionError("Expected document digest"),
                payloadJson = mutation.payloadJson,
                payloadCiphertextBase64 = mutation.payloadCiphertextBase64,
                updatedAt = mutation.updatedAt,
                deletedAt = null,
                duplicate = false,
            )
        }

        override suspend fun documents(
            authorization: ManagedAuthorization,
            snapshotAt: String,
            after: ManagedDocumentCursor?,
            limit: Int,
        ): ManagedDocumentPage {
            snapshotCursorDocumentIds += after?.afterDocumentId
            val remaining = snapshotDocuments
                .sortedWith(
                    compareBy(
                        ManagedDocument::updatedAt,
                        { it.documentKind.wireValue },
                        { it.documentId.toString() },
                    ),
                )
                .filter {
                    after == null ||
                        it.updatedAt > after.afterUpdatedAt ||
                        (
                            it.updatedAt == after.afterUpdatedAt &&
                                it.documentKind.wireValue >
                                after.afterDocumentKind.wireValue
                            ) ||
                        (
                            it.updatedAt == after.afterUpdatedAt &&
                                it.documentKind == after.afterDocumentKind &&
                                it.documentId.toString() > after.afterDocumentId.toString()
                            )
                }
            val selected = remaining.take(limit)
            val next = if (remaining.size > selected.size) {
                selected.last().pageCursor()
            } else {
                null
            }
            return ManagedDocumentPage(selected, next)
        }

        override suspend fun completeRestore(
            authorization: ManagedAuthorization,
            restoreJobId: UUID,
            deliveredObjects: Int,
            deliveredBytes: Long,
        ): ManagedRestoreJob {
            restoreCompletions += 1
            return ManagedRestoreJob(
                restoreJobId,
                "completed",
                "2026-09-01T02:00:00Z",
                42,
                snapshotChunks.size + snapshotDocuments.size,
                snapshotChunks.sumOf { it.expectedCompressedBytes.toLong() },
                deliveredObjects,
                deliveredBytes,
                "2026-09-02T02:00:00Z",
                false,
            )
        }

        override suspend fun downloadCapability(
            authorization: ManagedAuthorization,
            chunkId: UUID,
            requestId: UUID,
        ): ManagedDownloadCapability = throw AssertionError("Unexpected download")

        override suspend fun download(capability: ManagedDownloadCapability): ByteArray =
            throw AssertionError("Unexpected download")
    }

    private class FakeDocumentOutbox(
        private val documents: List<ManagedPendingDocument>,
    ) : ManagedDocumentOutbox {
        var pendingRequests = 0
        var acknowledgements = 0

        override suspend fun pendingDocuments(limit: Int): List<ManagedPendingDocument> {
            pendingRequests += 1
            return documents.take(limit)
        }

        override suspend fun acknowledge(
            pending: ManagedPendingDocument,
            remote: ManagedDocument,
        ) {
            acknowledgements += 1
        }
    }

    companion object {
        private const val WINDOW_MS = 6 * 60 * 60 * 1_000L
        private const val SETTLE_MS = 5 * 60 * 1_000L

        private fun metadataChange(sequence: Long) = ManagedChange(
            sequence = sequence,
            resourceKind = "subscription",
            resourceId = UUID.randomUUID(),
            operation = "updated",
            contentSha256 = null,
            dataClass = null,
            eventStart = null,
            eventEnd = null,
            chunk = null,
        )

        private fun pendingDocument(): ManagedPendingDocument {
            val documentId = UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500")
            val payload = JSONObject()
                .put("schema_version", 1)
                .put("table", "journal")
                .put(
                    "key",
                    JSONObject()
                        .put("deviceId", "strap")
                        .put("day", "2026-09-04")
                        .put("question", "late_caffeine"),
                )
                .put(
                    "record",
                    JSONObject()
                        .put("deviceId", "strap")
                        .put("day", "2026-09-04")
                        .put("question", "late_caffeine")
                        .put("answeredYes", 1)
                        .put("notes", "after lunch")
                        .put("numericValue", 2.5),
                )
            return ManagedPendingDocument(
                localIdentifier = "local-journal",
                generation = 1,
                mutation = ManagedDocumentMutation(
                    requestId = UUID.fromString("11111111-1111-5111-8111-111111111111"),
                    documentKind = ManagedDocumentKind.JOURNAL,
                    documentId = documentId,
                    baseRevision = 0,
                    contentMode = "server_readable",
                    payloadJson = payload,
                    contentSha256 = "a".repeat(64),
                    updatedAt = "2026-09-04T12:00:00Z",
                ),
            )
        }

        private fun snapshotDocument(): ManagedDocument {
            val pending = pendingDocument().mutation
            return ManagedDocument(
                documentKind = pending.documentKind,
                documentId = pending.documentId,
                revision = 1,
                originInstallationId = "ios-installation",
                contentMode = pending.contentMode,
                clientKeyId = null,
                contentSha256 = requireNotNull(pending.contentSha256),
                payloadJson = pending.payloadJson,
                payloadCiphertextBase64 = null,
                updatedAt = pending.updatedAt,
                deletedAt = null,
                duplicate = false,
            )
        }
    }
}
