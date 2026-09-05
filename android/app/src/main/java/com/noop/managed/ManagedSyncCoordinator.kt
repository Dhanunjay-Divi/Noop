package com.noop.managed

import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.UUID

data class ManagedSourceDescriptor(
    val localSourceId: String,
    val sourceKind: String,
    val installationId: String,
) {
    val sourceId: UUID
    val logicalSourceHash: String

    init {
        require(localSourceId.isNotBlank())
        require(sourceKind.matches(Regex("^[a-z][a-z0-9_]{1,63}$")))
        require(installationId.isNotBlank())
        val seed = "android\u0000$installationId\u0000$localSourceId"
            .toByteArray(StandardCharsets.UTF_8)
        sourceId = ManagedStableIdentifier.uuid(
            "noop-managed-source-v1\u0000".toByteArray(StandardCharsets.UTF_8) + seed,
        )
        logicalSourceHash = ManagedDigest.sha256(seed)
    }
}

data class ManagedSyncWindow(
    val startMs: Long,
    val endExclusiveMs: Long,
) {
    init {
        require(startMs >= 0L && endExclusiveMs > startMs)
    }

    val reservationEndMs: Long get() = endExclusiveMs - 1
}

data class ManagedUploadCheckpoint(
    val nextWindowStartMs: Long? = null,
    val repairWindowStartMs: Long? = null,
)

data class ManagedSnapshotRestoreCheckpoint(
    val requestId: UUID,
    val dataClasses: List<String>,
    val restoreJobId: UUID? = null,
    val snapshotAt: String? = null,
    val changeSequence: Long? = null,
    val selectedObjects: Int? = null,
    val selectedBytes: Long? = null,
    val dataClassIndex: Int = 0,
    val cursor: ManagedChunkCursor? = null,
    val documentCursor: ManagedDocumentCursor? = null,
    val documentsComplete: Boolean = false,
    val deliveredObjects: Int = 0,
    val deliveredBytes: Long = 0,
)

enum class ManagedWindowUploadPhase {
    PENDING_COMPLETION,
    AWAITING_VALIDATION,
    AVAILABLE,
}

data class ManagedWindowUpload(
    val windowEndMs: Long,
    val chunkId: UUID,
    val rowCount: Int,
    val phase: ManagedWindowUploadPhase,
    val receipt: ManagedObjectUploadReceipt? = null,
    val snapshotGeneration: Long = 0L,
    val validatedAtMs: Long? = null,
    val localPrunedAtMs: Long? = null,
) {
    init {
        require(windowEndMs >= 0L && rowCount >= 0)
        require((phase == ManagedWindowUploadPhase.PENDING_COMPLETION) == (receipt != null))
        require(snapshotGeneration >= 0L)
        require((phase == ManagedWindowUploadPhase.AVAILABLE) == (validatedAtMs != null))
        require(localPrunedAtMs == null || phase == ManagedWindowUploadPhase.AVAILABLE)
    }
}

data class ManagedDirtyWindow(
    val startMs: Long,
    val endExclusiveMs: Long,
    val generation: Long,
)

data class ManagedPruneResult(
    val prunedWindows: Int,
    val deletedRows: Int,
)

data class ManagedPendingDocument(
    val localIdentifier: String,
    val generation: Long,
    val mutation: ManagedDocumentMutation,
)

interface ManagedDocumentOutbox {
    suspend fun pendingDocuments(limit: Int): List<ManagedPendingDocument>
    suspend fun acknowledge(pending: ManagedPendingDocument, remote: ManagedDocument)
}

interface ManagedChunkExtracting {
    suspend fun nextEventTime(
        source: ManagedSourceDescriptor,
        dataClass: String,
        atOrAfterMs: Long,
        beforeMs: Long,
    ): Long?

    suspend fun streams(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow,
    ): List<ManagedChunkStreamPayload>
}

interface ManagedSyncStateStoring {
    suspend fun uploadCheckpoint(sourceId: UUID, dataClass: String): ManagedUploadCheckpoint
    suspend fun saveUploadCheckpoint(
        checkpoint: ManagedUploadCheckpoint,
        sourceId: UUID,
        dataClass: String,
    )

    suspend fun windowUpload(
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
    ): ManagedWindowUpload?

    suspend fun saveWindowUpload(
        upload: ManagedWindowUpload,
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
    )

    suspend fun claimWindowGeneration(
        sourceId: UUID,
        localSourceId: String,
        dataClass: String,
        window: ManagedSyncWindow,
    ): Long

    suspend fun claimNextDirtyWindow(
        sourceId: UUID,
        localSourceId: String,
        dataClass: String,
        endingAtOrBeforeMs: Long,
    ): ManagedDirtyWindow?

    suspend fun acknowledgeAvailableChunk(
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        chunkId: UUID,
    ): Boolean

    suspend fun markWindowHydrated(
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        chunkId: UUID,
    ): Boolean

    suspend fun pruneAvailableWindows(
        sourceId: UUID,
        localSourceId: String,
        dataClass: String,
        endingBeforeMs: Long,
        limit: Int,
    ): ManagedPruneResult

    suspend fun changeSequence(): Long
    suspend fun saveChangeSequence(sequence: Long)
    suspend fun isChangeApplied(change: ManagedChange): Boolean
    suspend fun recordAppliedChange(change: ManagedChange)

    suspend fun snapshotRestoreCheckpoint(): ManagedSnapshotRestoreCheckpoint? = null
    suspend fun saveSnapshotRestoreCheckpoint(
        checkpoint: ManagedSnapshotRestoreCheckpoint,
    ) {
        throw ManagedStorageException.InvalidResponse()
    }
    suspend fun clearSnapshotRestoreCheckpoint() = Unit
    suspend fun finishSnapshotRestore(changeSequence: Long) {
        saveChangeSequence(changeSequence)
        clearSnapshotRestoreCheckpoint()
    }
}

interface ManagedRestoreApplying {
    suspend fun apply(chunk: ManagedChunkPayload, change: ManagedChange)
    suspend fun hydrate(chunk: ManagedChunkPayload, source: ManagedSourceDescriptor)
    suspend fun apply(document: ManagedDocument, change: ManagedChange) {
        throw ManagedStorageException.InvalidResponse()
    }
    suspend fun applyMetadataOnly(change: ManagedChange) = Unit
}

interface ManagedStorageTransport {
    suspend fun registerSource(
        authorization: ManagedAuthorization,
        sourceId: UUID,
        sourceKind: String,
        logicalSourceHash: String,
    )

    suspend fun reserveChunk(
        authorization: ManagedAuthorization,
        reservation: ManagedChunkReservation,
    ): ManagedChunkReservationResult

    suspend fun upload(
        bytes: ByteArray,
        capability: ManagedUploadCapability,
    ): ManagedObjectUploadReceipt

    suspend fun completeChunk(
        authorization: ManagedAuthorization,
        chunkId: UUID,
        receipt: ManagedObjectUploadReceipt,
    )

    suspend fun changes(
        authorization: ManagedAuthorization,
        afterSequence: Long,
        limit: Int = 200,
    ): ManagedChangeFeed

    suspend fun createRestore(
        authorization: ManagedAuthorization,
        requestId: UUID,
        dataClasses: List<String>,
    ): ManagedRestoreJob = throw ManagedStorageException.InvalidResponse()

    suspend fun availableChunks(
        authorization: ManagedAuthorization,
        dataClass: String,
        snapshotAt: String,
        after: ManagedChunkCursor?,
        limit: Int,
    ): ManagedChunkPage = throw ManagedStorageException.InvalidResponse()

    suspend fun completeRestore(
        authorization: ManagedAuthorization,
        restoreJobId: UUID,
        deliveredObjects: Int,
        deliveredBytes: Long,
    ): ManagedRestoreJob = throw ManagedStorageException.InvalidResponse()

    suspend fun putDocument(
        authorization: ManagedAuthorization,
        mutation: ManagedDocumentMutation,
    ): ManagedDocument = throw ManagedStorageException.InvalidResponse()

    suspend fun document(
        authorization: ManagedAuthorization,
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Long?,
    ): ManagedDocument = throw ManagedStorageException.InvalidResponse()

    suspend fun documents(
        authorization: ManagedAuthorization,
        snapshotAt: String,
        after: ManagedDocumentCursor?,
        limit: Int,
    ): ManagedDocumentPage = throw ManagedStorageException.InvalidResponse()

    suspend fun downloadCapability(
        authorization: ManagedAuthorization,
        chunkId: UUID,
        requestId: UUID,
    ): ManagedDownloadCapability

    suspend fun download(capability: ManagedDownloadCapability): ByteArray
}

data class ManagedSyncPolicy(
    val windowMilliseconds: Long,
    val settleMilliseconds: Long,
    val repairLookbackMilliseconds: Long,
    val compression: ManagedChunkCompression,
    val maximumCompressedBytes: Int,
) {
    init {
        require(windowMilliseconds > 0)
        require(settleMilliseconds >= 0)
        require(repairLookbackMilliseconds >= windowMilliseconds)
        require(maximumCompressedBytes > 0)
    }

    companion object {
        fun standard(dataClass: String): ManagedSyncPolicy {
            val minute = 60_000L
            val hour = 60 * minute
            val day = 24 * hour
            return when (dataClass) {
                "essential_timeseries" -> ManagedSyncPolicy(
                    6 * hour,
                    5 * minute,
                    14 * day,
                    ManagedChunkCompression.GZIP,
                    16 * 1024 * 1024,
                )
                "raw_auxiliary", "raw_ppg", "raw_motion" -> ManagedSyncPolicy(
                    hour,
                    5 * minute,
                    14 * day,
                    ManagedChunkCompression.GZIP,
                    16 * 1024 * 1024,
                )
                "derived_summaries" -> ManagedSyncPolicy(
                    7 * day,
                    5 * minute,
                    90 * day,
                    ManagedChunkCompression.GZIP,
                    4 * 1024 * 1024,
                )
                else -> throw IllegalArgumentException("Unsupported managed data class")
            }
        }
    }
}

object ManagedLocalRetentionPolicy {
    const val RAW_HISTORY_DAYS = 7L
    const val ESSENTIAL_HISTORY_DAYS = 30L
    private const val DAY_MS = 86_400_000L

    fun retainedDays(dataClass: String): Long? = when (dataClass) {
        "essential_timeseries" -> ESSENTIAL_HISTORY_DAYS
        "raw_auxiliary", "raw_ppg", "raw_motion" -> RAW_HISTORY_DAYS
        else -> null
    }

    fun cutoff(nowMs: Long, dataClass: String): Long? {
        val retainedMs = retainedDays(dataClass)?.times(DAY_MS) ?: return null
        return if (nowMs > retainedMs) nowMs - retainedMs else 0L
    }
}

data class ManagedSyncRunResult(
    val uploadedChunks: Int,
    val uploadedBytes: Int,
    val uploadedDocuments: Int,
    val advancedEmptyWindows: Int,
    val repairedWindows: Int,
    val appliedChanges: Int,
    val hasMoreChanges: Boolean,
    /**
     * A bounded local budget was exhausted or known local work remains. A confirmation pass may
     * discover an exactly-full budget, but scheduling it avoids stranding a large first backup.
     */
    val hasMoreLocalWork: Boolean,
    val prunedWindows: Int,
    val prunedRows: Int,
) {
    val hasMoreWork: Boolean get() = hasMoreChanges || hasMoreLocalWork
}

class ManagedSyncCoordinator(
    private val transport: ManagedStorageTransport,
    private val extractor: ManagedChunkExtracting,
    private val state: ManagedSyncStateStoring,
    private val restore: ManagedRestoreApplying,
    private val documents: ManagedDocumentOutbox? = null,
) {
    suspend fun sync(
        source: ManagedSourceDescriptor,
        authorization: ManagedAuthorization,
        nowMs: Long = System.currentTimeMillis(),
        dataClasses: List<String> = DATA_CLASSES,
        maxForwardWindowsPerClass: Int = 4,
        maxDirtyWindowsPerClass: Int = 4,
        maxChangePages: Int = 2,
        changePageSize: Int = 100,
        maxSnapshotRestoreObjects: Int = 16,
        maxSnapshotRestoreBytes: Int = 32 * 1_024 * 1_024,
        maxDocumentUploads: Int = 16,
        localPruneNowMs: Long? = null,
        maxPruneWindowsPerClass: Int = 4,
    ): ManagedSyncRunResult {
        require(maxForwardWindowsPerClass in 1..100)
        require(maxDirtyWindowsPerClass in 1..100)
        require(maxChangePages in 0..20)
        require(changePageSize in 1..500)
        require(maxSnapshotRestoreObjects in 1..200)
        require(maxSnapshotRestoreBytes > 0)
        require(maxDocumentUploads in 0..100)
        require(maxPruneWindowsPerClass in 0..16)
        require(localPruneNowMs == null || localPruneNowMs >= 0L)
        require(dataClasses.distinct().size == dataClasses.size)
        transport.registerSource(
            authorization,
            source.sourceId,
            source.sourceKind,
            source.logicalSourceHash,
        )

        var uploadedChunks = 0
        var uploadedBytes = 0
        var emptyWindows = 0
        var repairedWindows = 0
        var prunedWindows = 0
        var prunedRows = 0
        var hasMoreLocalWork = false
        val changes = applyChanges(
            authorization,
            maxChangePages,
            changePageSize,
            dataClasses.sorted(),
            maxSnapshotRestoreObjects,
            maxSnapshotRestoreBytes,
        )
        val documentUpload = uploadPendingDocuments(
            authorization,
            if (changes.second) 0 else maxDocumentUploads,
        )
        hasMoreLocalWork = documentUpload.hasMore
        for (dataClass in dataClasses.sorted()) {
            val policy = ManagedSyncPolicy.standard(dataClass)
            var checkpoint = state.uploadCheckpoint(source.sourceId, dataClass)
            val cutoff = alignedFloor(
                (nowMs - policy.settleMilliseconds).coerceAtLeast(0L),
                policy.windowMilliseconds,
            )
            var dirtyProcessed = 0
            while (dirtyProcessed < maxDirtyWindowsPerClass) {
                val dirty = state.claimNextDirtyWindow(
                    source.sourceId,
                    source.localSourceId,
                    dataClass,
                    cutoff,
                ) ?: break
                if (dirty.startMs % policy.windowMilliseconds != 0L ||
                    dirty.endExclusiveMs != dirty.startMs + policy.windowMilliseconds ||
                    dirty.generation <= 0L
                ) {
                    throw ManagedStorageException.InvalidResponse()
                }
                val transfer = transferWindow(
                    source,
                    dataClass,
                    ManagedSyncWindow(dirty.startMs, dirty.endExclusiveMs),
                    policy,
                    authorization,
                    dirty.generation,
                )
                if (transfer.uploaded) uploadedChunks += 1
                uploadedBytes += transfer.bytes
                dirtyProcessed += 1
            }
            if (dirtyProcessed == maxDirtyWindowsPerClass) {
                hasMoreLocalWork = true
            }
            var next = checkpoint.nextWindowStartMs ?: (
                extractor.nextEventTime(source, dataClass, 0, cutoff)
                    ?.let { alignedFloor(it, policy.windowMilliseconds) }
                    ?: cutoff
                )
            var processed = 0
            while (next < cutoff && processed < maxForwardWindowsPerClass) {
                val event = extractor.nextEventTime(source, dataClass, next, cutoff)
                if (event == null) {
                    next = cutoff
                    break
                }
                val start = maxOf(next, alignedFloor(event, policy.windowMilliseconds))
                val end = minOf(cutoff, start + policy.windowMilliseconds)
                val transfer = transferWindow(
                    source,
                    dataClass,
                    ManagedSyncWindow(start, end),
                    policy,
                    authorization,
                )
                if (transfer.uploaded) uploadedChunks += 1
                uploadedBytes += transfer.bytes
                if (!transfer.hadRows) emptyWindows += 1
                next = end
                checkpoint = checkpoint.copy(nextWindowStartMs = end)
                state.saveUploadCheckpoint(checkpoint, source.sourceId, dataClass)
                processed += 1
            }
            if (next < cutoff) {
                hasMoreLocalWork = true
            }
            checkpoint = checkpoint.copy(nextWindowStartMs = next)

            if (next == cutoff && cutoff > 0L) {
                val lower = alignedFloor(
                    (cutoff - policy.repairLookbackMilliseconds).coerceAtLeast(0L),
                    policy.windowMilliseconds,
                )
                var repairStart = checkpoint.repairWindowStartMs ?: lower
                if (repairStart < lower || repairStart >= cutoff) repairStart = lower
                if (repairStart < cutoff) {
                    val repairEnd = minOf(cutoff, repairStart + policy.windowMilliseconds)
                    val hasEvent = extractor.nextEventTime(
                        source,
                        dataClass,
                        repairStart,
                        repairEnd,
                    ) != null
                    val priorUpload = state.windowUpload(
                        source.sourceId,
                        dataClass,
                        repairStart,
                    )
                    if (hasEvent || priorUpload != null) {
                        val transfer = transferWindow(
                            source,
                            dataClass,
                            ManagedSyncWindow(repairStart, repairEnd),
                            policy,
                            authorization,
                        )
                        if (transfer.uploaded) uploadedChunks += 1
                        uploadedBytes += transfer.bytes
                        repairedWindows += 1
                    }
                    checkpoint = checkpoint.copy(
                        repairWindowStartMs = if (repairEnd >= cutoff) lower else repairEnd,
                    )
                }
            }
            state.saveUploadCheckpoint(checkpoint, source.sourceId, dataClass)
            val localPruneBeforeMs = localPruneNowMs?.let {
                ManagedLocalRetentionPolicy.cutoff(it, dataClass)
            }
            if (localPruneBeforeMs != null &&
                maxPruneWindowsPerClass > 0
            ) {
                val result = state.pruneAvailableWindows(
                    source.sourceId,
                    source.localSourceId,
                    dataClass,
                    localPruneBeforeMs,
                    maxPruneWindowsPerClass,
                )
                prunedWindows = Math.addExact(prunedWindows, result.prunedWindows)
                prunedRows = Math.addExact(prunedRows, result.deletedRows)
                if (result.prunedWindows == maxPruneWindowsPerClass) {
                    hasMoreLocalWork = true
                }
            }
        }

        return ManagedSyncRunResult(
            uploadedChunks,
            uploadedBytes,
            documentUpload.uploaded,
            emptyWindows,
            repairedWindows,
            changes.first,
            changes.second,
            hasMoreLocalWork,
            prunedWindows,
            prunedRows,
        )
    }

    private suspend fun uploadPendingDocuments(
        authorization: ManagedAuthorization,
        limit: Int,
    ): DocumentUploadResult {
        val outbox = documents ?: return DocumentUploadResult(0, false)
        if (limit == 0) return DocumentUploadResult(0, false)
        val pending = outbox.pendingDocuments(limit + 1)
        if (pending.size > limit + 1 ||
            pending.map { it.localIdentifier }.distinct().size != pending.size
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        for (item in pending.take(limit)) {
            val mutation = item.mutation
            if (item.generation <= 0L ||
                item.localIdentifier.isBlank() ||
                mutation.baseRevision < 0L ||
                runCatching { Instant.parse(mutation.updatedAt) }.isFailure
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            val remote = transport.putDocument(authorization, mutation)
            if (remote.documentKind != mutation.documentKind ||
                remote.documentId != mutation.documentId ||
                remote.revision != mutation.baseRevision + 1 ||
                remote.originInstallationId != authorization.installationId ||
                remote.contentMode != mutation.contentMode ||
                remote.clientKeyId != mutation.clientKeyId ||
                !sameJson(remote.payloadJson, mutation.payloadJson) ||
                remote.payloadCiphertextBase64 != mutation.payloadCiphertextBase64 ||
                (remote.deletedAt != null) != mutation.deleted ||
                runCatching { Instant.parse(remote.updatedAt) }.isFailure ||
                !remote.contentSha256.matches(SHA256) ||
                (mutation.contentSha256 != null &&
                    mutation.contentSha256 != remote.contentSha256)
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            outbox.acknowledge(item, remote)
        }
        return DocumentUploadResult(minOf(pending.size, limit), pending.size > limit)
    }

    private data class DocumentUploadResult(
        val uploaded: Int,
        val hasMore: Boolean,
    )

    private fun sameJson(left: org.json.JSONObject?, right: org.json.JSONObject?): Boolean =
        when {
            left == null || right == null -> left == null && right == null
            else -> ManagedCanonicalJson.encode(left) == ManagedCanonicalJson.encode(right)
        }

    private suspend fun transferWindow(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow,
        policy: ManagedSyncPolicy,
        authorization: ManagedAuthorization,
        suppliedGeneration: Long? = null,
    ): TransferResult {
        var previous = state.windowUpload(source.sourceId, dataClass, window.startMs)
        if (previous != null && previous.windowEndMs != window.reservationEndMs) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (previous?.phase == ManagedWindowUploadPhase.PENDING_COMPLETION) {
            val receipt = previous.receipt ?: throw ManagedStorageException.InvalidResponse()
            transport.completeChunk(authorization, previous.chunkId, receipt)
            previous = previous.copy(
                phase = ManagedWindowUploadPhase.AWAITING_VALIDATION,
                receipt = null,
            )
            state.saveWindowUpload(
                previous,
                source.sourceId,
                dataClass,
                window.startMs,
            )
            return TransferResult(false, 0, previous.rowCount > 0)
        }
        if (previous?.phase == ManagedWindowUploadPhase.AWAITING_VALIDATION) {
            return TransferResult(false, 0, previous.rowCount > 0)
        }
        if (previous?.localPrunedAtMs != null) {
            // Periodic repair must not undo the user's local-retention choice. Reconstruct only
            // when a real post-prune mutation has claimed this window.
            if (suppliedGeneration == null) {
                return TransferResult(false, 0, previous.rowCount > 0)
            }
            hydratePrunedWindow(
                source,
                dataClass,
                window,
                previous,
                authorization,
            )
            previous = state.windowUpload(source.sourceId, dataClass, window.startMs)
            if (previous?.localPrunedAtMs != null) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
        val streams = extractor.streams(source, dataClass, window)
        val rowCount = streams.sumOf { it.rows.size }
        val prepared = ManagedPreparedChunk.prepare(
            source.sourceId,
            dataClass,
            window.startMs,
            window.reservationEndMs,
            streams,
        ) ?: return TransferResult(false, 0, false)
        if (previous?.phase == ManagedWindowUploadPhase.AVAILABLE &&
            previous.chunkId == prepared.chunkId
        ) {
            val generation = suppliedGeneration ?: state.claimWindowGeneration(
                source.sourceId,
                source.localSourceId,
                dataClass,
                window,
            )
            state.saveWindowUpload(
                previous.copy(
                    rowCount = rowCount,
                    snapshotGeneration = generation,
                ),
                source.sourceId,
                dataClass,
                window.startMs,
            )
            return TransferResult(false, 0, rowCount > 0)
        }
        if (rowCount == 0 && previous == null) {
            return TransferResult(false, 0, false)
        }
        val snapshotGeneration = suppliedGeneration ?: state.claimWindowGeneration(
            source.sourceId,
            source.localSourceId,
            dataClass,
            window,
        )
        val encoded = ManagedChunkCodec.encode(prepared.uncompressed, policy.compression)
        if (encoded.size > policy.maximumCompressedBytes) {
            throw ManagedStorageException.QuotaExceeded()
        }
        val reservation = prepared.reservation(encoded, policy.compression.wireValue)
        val response = transport.reserveChunk(authorization, reservation)
        val capability = response.upload
        if (capability == null) {
            if (response.chunkId != prepared.chunkId ||
                response.state !in setOf("uploaded", "validating", "available")
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            state.saveWindowUpload(
                ManagedWindowUpload(
                    windowEndMs = window.reservationEndMs,
                    chunkId = prepared.chunkId,
                    rowCount = rowCount,
                    phase = ManagedWindowUploadPhase.AWAITING_VALIDATION,
                    snapshotGeneration = snapshotGeneration,
                ),
                source.sourceId,
                dataClass,
                window.startMs,
            )
            return TransferResult(false, 0, rowCount > 0)
        }
        val receipt = transport.upload(encoded, capability)
        state.saveWindowUpload(
            ManagedWindowUpload(
                windowEndMs = window.reservationEndMs,
                chunkId = prepared.chunkId,
                rowCount = rowCount,
                phase = ManagedWindowUploadPhase.PENDING_COMPLETION,
                receipt = receipt,
                snapshotGeneration = snapshotGeneration,
            ),
            source.sourceId,
            dataClass,
            window.startMs,
        )
        transport.completeChunk(authorization, prepared.chunkId, receipt)
        state.saveWindowUpload(
            ManagedWindowUpload(
                windowEndMs = window.reservationEndMs,
                chunkId = prepared.chunkId,
                rowCount = rowCount,
                phase = ManagedWindowUploadPhase.AWAITING_VALIDATION,
                snapshotGeneration = snapshotGeneration,
            ),
            source.sourceId,
            dataClass,
            window.startMs,
        )
        return TransferResult(true, encoded.size, rowCount > 0)
    }

    private suspend fun hydratePrunedWindow(
        source: ManagedSourceDescriptor,
        dataClass: String,
        window: ManagedSyncWindow,
        upload: ManagedWindowUpload,
        authorization: ManagedAuthorization,
    ) {
        if (upload.phase != ManagedWindowUploadPhase.AVAILABLE ||
            upload.validatedAtMs == null ||
            upload.localPrunedAtMs == null ||
            upload.windowEndMs != window.reservationEndMs
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val capability = transport.downloadCapability(
            authorization,
            upload.chunkId,
            ManagedStableIdentifier.uuid(
                "noop-managed-hydration-v1\u0000${upload.chunkId}"
                    .toByteArray(StandardCharsets.UTF_8),
            ),
        )
        val expectedBytes = capability.expectedUncompressedBytes
            ?: throw ManagedStorageException.InvalidResponse()
        if (capability.chunkId != upload.chunkId ||
            !capability.expectedSha256.matches(SHA256) ||
            capability.contentType != "application/vnd.noop.chunk+json" ||
            expectedBytes <= 0
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val compressed = transport.download(capability)
        val decoded = ManagedChunkCodec.decode(
            compressed,
            capability.compression,
            expectedBytes,
        )
        val payload = ManagedChunkCodec.decodePayload(decoded)
        val canonical = ManagedChunkCodec.verifyCanonical(payload)
        if (payload.chunkId != upload.chunkId ||
            payload.sourceId != source.sourceId ||
            payload.dataClass != dataClass ||
            payload.eventStartMs != window.startMs ||
            payload.eventEndMs != window.reservationEndMs ||
            !canonical.uncompressed.contentEquals(decoded)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        restore.hydrate(payload, source)
        if (!state.markWindowHydrated(
                source.sourceId,
                dataClass,
                window.startMs,
                window.reservationEndMs,
                upload.chunkId,
            )
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private suspend fun applyChanges(
        authorization: ManagedAuthorization,
        maxPages: Int,
        pageSize: Int,
        dataClasses: List<String>,
        maxSnapshotObjects: Int,
        maxSnapshotBytes: Int,
    ): Pair<Int, Boolean> {
        if (maxPages == 0) return 0 to false
        var sequence = state.changeSequence()
        var applied = 0
        var hasMore = false

        var checkpoint = state.snapshotRestoreCheckpoint()
        if (checkpoint != null) {
            if (checkpoint.dataClasses != dataClasses) {
                state.clearSnapshotRestoreCheckpoint()
                checkpoint = ManagedSnapshotRestoreCheckpoint(
                    UUID.randomUUID(),
                    dataClasses,
                )
                state.saveSnapshotRestoreCheckpoint(checkpoint)
            }
            val snapshot = resumeSnapshotRestoreRecoveringInvalidation(
                checkpoint,
                authorization,
                maxPages,
                minOf(pageSize, 200),
                maxSnapshotObjects,
                maxSnapshotBytes,
            )
            applied += snapshot.first
            if (!snapshot.second) return applied to true
            sequence = state.changeSequence()
        }

        repeat(maxPages) {
            val feed = try {
                transport.changes(authorization, sequence, pageSize)
            } catch (_: ManagedStorageException.CursorExpired) {
                val initial = ManagedSnapshotRestoreCheckpoint(
                    UUID.randomUUID(),
                    dataClasses,
                )
                state.saveSnapshotRestoreCheckpoint(initial)
                val snapshot = resumeSnapshotRestoreRecoveringInvalidation(
                    initial,
                    authorization,
                    maxPages,
                    minOf(pageSize, 200),
                    maxSnapshotObjects,
                    maxSnapshotBytes,
                )
                return applied + snapshot.first to true
            }
            for (change in feed.changes) {
                if (change.sequence <= sequence) throw ManagedStorageException.InvalidResponse()
                if (state.isChangeApplied(change)) {
                    acknowledgeAvailableChange(change)
                    sequence = change.sequence
                    state.saveChangeSequence(sequence)
                    applied += 1
                    continue
                }
                val isLocalUpload = acknowledgeAvailableChange(change)
                val changedChunk = change.chunk
                if (change.resourceKind == "chunk" &&
                    change.operation == "available" &&
                    changedChunk != null
                ) {
                    if (!isLocalUpload) {
                        applyChunkChange(
                            change,
                            changedChunk,
                            authorization,
                            ManagedStableIdentifier.uuid(
                                "noop-managed-download-v1\u0000${change.sequence}"
                                    .toByteArray(StandardCharsets.UTF_8),
                            ),
                        )
                    }
                } else if (change.resourceKind == "document" &&
                    change.document != null
                ) {
                    val metadata = change.document
                    val document = transport.document(
                        authorization = authorization,
                        kind = metadata.documentKind,
                        id = metadata.documentId,
                        revision = metadata.revision,
                    )
                    restore.apply(document, change)
                } else {
                    restore.applyMetadataOnly(change)
                }
                state.recordAppliedChange(change)
                sequence = change.sequence
                state.saveChangeSequence(sequence)
                applied += 1
            }
            hasMore = feed.hasMore
            if (!hasMore) return applied to false
        }
        return applied to hasMore
    }

    private suspend fun resumeSnapshotRestoreRecoveringInvalidation(
        checkpoint: ManagedSnapshotRestoreCheckpoint,
        authorization: ManagedAuthorization,
        maxPages: Int,
        pageSize: Int,
        maxObjects: Int,
        maxBytes: Int,
    ): Pair<Int, Boolean> = try {
        resumeSnapshotRestore(
            checkpoint,
            authorization,
            maxPages,
            pageSize,
            maxObjects,
            maxBytes,
        )
    } catch (error: ManagedStorageException) {
        if (error !is ManagedStorageException.NotFound &&
            error !is ManagedStorageException.Conflict
        ) {
            throw error
        }
        // Restore jobs and immutable objects can expire between background runs.
        // Reset only restore progress; local data and the anchored cursor stay put.
        state.clearSnapshotRestoreCheckpoint()
        state.saveSnapshotRestoreCheckpoint(
            ManagedSnapshotRestoreCheckpoint(
                UUID.randomUUID(),
                checkpoint.dataClasses,
            ),
        )
        0 to false
    }

    private suspend fun resumeSnapshotRestore(
        initial: ManagedSnapshotRestoreCheckpoint,
        authorization: ManagedAuthorization,
        maxPages: Int,
        pageSize: Int,
        maxObjects: Int,
        maxBytes: Int,
    ): Pair<Int, Boolean> {
        var checkpoint = initial
        if (checkpoint.restoreJobId == null) {
            val restoreJob = transport.createRestore(
                authorization,
                checkpoint.requestId,
                checkpoint.dataClasses,
            )
            if (restoreJob.status != "running") {
                throw ManagedStorageException.InvalidResponse()
            }
            checkpoint = checkpoint.copy(
                restoreJobId = restoreJob.restoreJobId,
                snapshotAt = restoreJob.snapshotAt,
                changeSequence = restoreJob.changeSequence,
                selectedObjects = restoreJob.selectedObjects,
                selectedBytes = restoreJob.selectedBytes,
            )
            state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        val restoreJobId = checkpoint.restoreJobId
            ?: throw ManagedStorageException.InvalidResponse()
        val snapshotAt = checkpoint.snapshotAt
            ?: throw ManagedStorageException.InvalidResponse()
        val changeSequence = checkpoint.changeSequence
            ?: throw ManagedStorageException.InvalidResponse()
        val selectedObjects = checkpoint.selectedObjects
            ?: throw ManagedStorageException.InvalidResponse()
        val selectedBytes = checkpoint.selectedBytes
            ?: throw ManagedStorageException.InvalidResponse()
        if (changeSequence < 0 ||
            selectedObjects < 0 ||
            selectedBytes < 0 ||
            checkpoint.dataClassIndex !in 0..checkpoint.dataClasses.size ||
            checkpoint.deliveredObjects !in 0..selectedObjects ||
            checkpoint.deliveredBytes !in 0..selectedBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }

        var pages = 0
        var applied = 0
        var downloadedBytes = 0
        var processedObjects = 0
        while (checkpoint.dataClassIndex < checkpoint.dataClasses.size &&
            pages < maxPages &&
            processedObjects < maxObjects
        ) {
            val dataClass = checkpoint.dataClasses[checkpoint.dataClassIndex]
            val page = transport.availableChunks(
                authorization,
                dataClass,
                snapshotAt,
                checkpoint.cursor,
                minOf(pageSize, maxObjects - processedObjects),
            )
            if (page.chunks.isEmpty() && page.nextCursor != null) {
                throw ManagedStorageException.InvalidResponse()
            }
            var consumedPage = true
            for (available in page.chunks) {
                if (processedObjects >= maxObjects) {
                    consumedPage = false
                    break
                }
                val change = available.asChange()
                val localUpload = acknowledgeAvailableChange(change)
                val expectedDownload = if (localUpload) 0 else available.expectedCompressedBytes
                if (processedObjects > 0 && expectedDownload > maxBytes - downloadedBytes) {
                    consumedPage = false
                    break
                }
                val deliveredBytes = if (localUpload) {
                    0
                } else {
                    val metadata = change.chunk
                        ?: throw ManagedStorageException.InvalidResponse()
                    applyChunkChange(
                        change,
                        metadata,
                        authorization,
                        ManagedStableIdentifier.uuid(
                            (
                                "noop-managed-snapshot-download-v1\u0000" +
                                    "$restoreJobId\u0000${available.chunkId}"
                                ).toByteArray(StandardCharsets.UTF_8),
                        ),
                    )
                }
                val nextBytes = runCatching {
                    Math.addExact(checkpoint.deliveredBytes, deliveredBytes.toLong())
                }.getOrElse { throw ManagedStorageException.InvalidResponse() }
                if (nextBytes > selectedBytes) {
                    throw ManagedStorageException.InvalidResponse()
                }
                checkpoint = checkpoint.copy(
                    cursor = ManagedChunkCursor(available.eventStart, available.chunkId),
                    deliveredObjects = checkpoint.deliveredObjects + 1,
                    deliveredBytes = nextBytes,
                )
                state.saveSnapshotRestoreCheckpoint(checkpoint)
                downloadedBytes += deliveredBytes
                processedObjects += 1
                applied += 1
            }
            pages += 1
            if (!consumedPage) return applied to false
            checkpoint = if (page.nextCursor == null) {
                checkpoint.copy(
                    dataClassIndex = checkpoint.dataClassIndex + 1,
                    cursor = null,
                )
            } else {
                checkpoint.copy(cursor = page.nextCursor)
            }
            state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        if (checkpoint.dataClassIndex != checkpoint.dataClasses.size) {
            return applied to false
        }
        if (checkpoint.deliveredObjects == selectedObjects) {
            checkpoint = checkpoint.copy(
                documentCursor = null,
                documentsComplete = true,
            )
            state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        while (!checkpoint.documentsComplete &&
            pages < maxPages &&
            processedObjects < maxObjects
        ) {
            val page = transport.documents(
                authorization = authorization,
                snapshotAt = snapshotAt,
                after = checkpoint.documentCursor,
                limit = minOf(pageSize, maxObjects - processedObjects),
            )
            if (page.documents.isEmpty() && page.nextCursor != null) {
                throw ManagedStorageException.InvalidResponse()
            }
            var consumedPage = true
            for (document in page.documents) {
                if (processedObjects >= maxObjects) {
                    consumedPage = false
                    break
                }
                restore.apply(document, document.asChange())
                val deliveredObjects = checkpoint.deliveredObjects + 1
                if (deliveredObjects > selectedObjects) {
                    throw ManagedStorageException.InvalidResponse()
                }
                checkpoint = checkpoint.copy(
                    documentCursor = document.pageCursor(),
                    deliveredObjects = deliveredObjects,
                )
                state.saveSnapshotRestoreCheckpoint(checkpoint)
                processedObjects += 1
                applied += 1
            }
            pages += 1
            if (!consumedPage) return applied to false
            checkpoint = if (page.nextCursor == null) {
                checkpoint.copy(
                    documentCursor = null,
                    documentsComplete = true,
                )
            } else {
                checkpoint.copy(documentCursor = page.nextCursor)
            }
            state.saveSnapshotRestoreCheckpoint(checkpoint)
        }
        if (!checkpoint.documentsComplete) {
            return applied to false
        }
        if (checkpoint.deliveredObjects != selectedObjects) {
            throw ManagedStorageException.InvalidResponse()
        }
        val completed = transport.completeRestore(
            authorization,
            restoreJobId,
            checkpoint.deliveredObjects,
            checkpoint.deliveredBytes,
        )
        if (completed.status != "completed" ||
            completed.changeSequence != changeSequence ||
            completed.selectedObjects != selectedObjects ||
            completed.selectedBytes != selectedBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        state.finishSnapshotRestore(changeSequence)
        return applied to true
    }

    private suspend fun acknowledgeAvailableChange(change: ManagedChange): Boolean {
        if (change.resourceKind != "chunk" || change.operation != "available") return false
        val chunk = change.chunk ?: throw ManagedStorageException.InvalidResponse()
        val sourceId = chunk.sourceId ?: throw ManagedStorageException.InvalidResponse()
        val dataClass = change.dataClass ?: throw ManagedStorageException.InvalidResponse()
        val startMs = parseInstant(change.eventStart)
        val endMs = parseInstant(change.eventEnd)
        if (chunk.chunkId != change.resourceId ||
            chunk.state != "available" ||
            startMs < 0L ||
            endMs < startMs
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return state.acknowledgeAvailableChunk(
            sourceId,
            dataClass,
            startMs,
            endMs,
            chunk.chunkId,
        )
    }

    private suspend fun applyChunkChange(
        change: ManagedChange,
        metadata: ManagedChangedChunk,
        authorization: ManagedAuthorization,
        requestId: UUID,
    ): Int {
        val sourceId = metadata.sourceId ?: throw ManagedStorageException.InvalidResponse()
        val schemaVersion = metadata.schemaVersion ?: throw ManagedStorageException.InvalidResponse()
        val expectedBytes = metadata.expectedUncompressedBytes
            ?: throw ManagedStorageException.InvalidResponse()
        val expectedCompressedBytes = metadata.expectedCompressedBytes
            ?: throw ManagedStorageException.InvalidResponse()
        if (metadata.chunkId != change.resourceId ||
            metadata.state != "available" ||
            metadata.contentMode != "server_readable" ||
            expectedBytes <= 0 ||
            expectedCompressedBytes <= 0 ||
            change.contentSha256?.matches(SHA256) != true
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val capability = transport.downloadCapability(
            authorization,
            metadata.chunkId,
            requestId,
        )
        if (capability.chunkId != metadata.chunkId ||
            capability.expectedSha256 != change.contentSha256 ||
            capability.compression != metadata.compression ||
            capability.contentType != metadata.contentType
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val compressed = transport.download(capability)
        if (compressed.size != expectedCompressedBytes) {
            throw ManagedStorageException.InvalidResponse()
        }
        val decoded = ManagedChunkCodec.decode(
            compressed,
            capability.compression,
            expectedBytes,
        )
        val payload = ManagedChunkCodec.decodePayload(decoded)
        val canonical = ManagedChunkCodec.verifyCanonical(payload)
        val startMs = parseInstant(change.eventStart)
        val endMs = parseInstant(change.eventEnd)
        if (payload.chunkId != metadata.chunkId ||
            payload.sourceId != sourceId ||
            payload.schemaVersion != schemaVersion ||
            payload.dataClass != change.dataClass ||
            payload.eventStartMs != startMs ||
            payload.eventEndMs != endMs ||
            canonical.uncompressed.size != expectedBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        restore.apply(payload, change)
        return compressed.size
    }

    private fun parseInstant(value: String?): Long =
        try {
            Instant.parse(value ?: throw ManagedStorageException.InvalidResponse()).toEpochMilli()
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Exception) {
            throw ManagedStorageException.InvalidResponse()
        }

    private fun alignedFloor(value: Long, interval: Long): Long = value - value % interval

    private data class TransferResult(
        val uploaded: Boolean,
        val bytes: Int,
        val hadRows: Boolean,
    )

    companion object {
        val DATA_CLASSES = listOf(
            "essential_timeseries",
            "raw_auxiliary",
            "raw_ppg",
            "raw_motion",
            "derived_summaries",
        )
        private val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}
