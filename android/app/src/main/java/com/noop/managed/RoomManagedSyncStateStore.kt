package com.noop.managed

import androidx.sqlite.db.SimpleSQLiteQuery
import com.noop.data.ManagedAppliedChangeEntity
import com.noop.data.ManagedSnapshotRestoreEntity
import com.noop.data.ManagedSyncCheckpointEntity
import com.noop.data.ManagedSyncDao
import com.noop.data.ManagedWindowUploadEntity
import com.noop.data.WhoopDatabase
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray

class RoomManagedSyncStateStore(
    private val database: WhoopDatabase,
    private val accountScopeHash: String,
    private val clock: () -> Long = System::currentTimeMillis,
) : ManagedSyncStateStoring {
    private val dao: ManagedSyncDao get() = database.managedSyncDao()

    init {
        require(accountScopeHash.matches(Regex("^[0-9a-f]{64}$")))
    }

    override suspend fun uploadCheckpoint(
        sourceId: UUID,
        dataClass: String,
    ): ManagedUploadCheckpoint {
        val stored = dao.checkpoint(accountScopeHash, sourceId.toString(), dataClass)
            ?: return ManagedUploadCheckpoint()
        return ManagedUploadCheckpoint(
            nextWindowStartMs = stored.nextWindowStartMs,
            repairWindowStartMs = stored.repairWindowStartMs,
        )
    }

    override suspend fun saveUploadCheckpoint(
        checkpoint: ManagedUploadCheckpoint,
        sourceId: UUID,
        dataClass: String,
    ) {
        dao.upsertCheckpoint(
            ManagedSyncCheckpointEntity(
                accountScopeHash = accountScopeHash,
                sourceId = sourceId.toString(),
                dataClass = dataClass,
                nextWindowStartMs = checkpoint.nextWindowStartMs,
                repairWindowStartMs = checkpoint.repairWindowStartMs,
                updatedAtMs = clock(),
            ),
        )
    }

    override suspend fun windowUpload(
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
    ): ManagedWindowUpload? {
        val stored = dao.windowUpload(
            accountScopeHash,
            sourceId.toString(),
            dataClass,
            windowStartMs,
        ) ?: return null
        val phase = when (stored.phase) {
            "pending_completion" -> ManagedWindowUploadPhase.PENDING_COMPLETION
            "awaiting_validation" -> ManagedWindowUploadPhase.AWAITING_VALIDATION
            "available" -> ManagedWindowUploadPhase.AVAILABLE
            else -> throw ManagedStorageException.InvalidResponse()
        }
        val receipt = if (phase == ManagedWindowUploadPhase.PENDING_COMPLETION) {
            ManagedObjectUploadReceipt(
                objectGeneration = stored.objectGeneration
                    ?: throw ManagedStorageException.InvalidResponse(),
                objectMetageneration = stored.objectMetageneration
                    ?: throw ManagedStorageException.InvalidResponse(),
                objectCrc32c = stored.objectCrc32c
                    ?: throw ManagedStorageException.InvalidResponse(),
            )
        } else {
            if (stored.objectGeneration != null ||
                stored.objectMetageneration != null ||
                stored.objectCrc32c != null
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            null
        }
        return ManagedWindowUpload(
            windowEndMs = stored.windowEndMs,
            chunkId = runCatching { UUID.fromString(stored.chunkId) }
                .getOrElse { throw ManagedStorageException.InvalidResponse() },
            rowCount = stored.rowCount,
            phase = phase,
            receipt = receipt,
            snapshotGeneration = stored.snapshotGeneration,
            validatedAtMs = stored.validatedAtMs,
            localPrunedAtMs = stored.localPrunedAtMs,
        )
    }

    override suspend fun saveWindowUpload(
        upload: ManagedWindowUpload,
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
    ) {
        dao.upsertWindowUpload(
            ManagedWindowUploadEntity(
                accountScopeHash = accountScopeHash,
                sourceId = sourceId.toString(),
                dataClass = dataClass,
                windowStartMs = windowStartMs,
                windowEndMs = upload.windowEndMs,
                chunkId = upload.chunkId.toString(),
                rowCount = upload.rowCount,
                phase = when (upload.phase) {
                    ManagedWindowUploadPhase.PENDING_COMPLETION -> "pending_completion"
                    ManagedWindowUploadPhase.AWAITING_VALIDATION -> "awaiting_validation"
                    ManagedWindowUploadPhase.AVAILABLE -> "available"
                },
                objectGeneration = upload.receipt?.objectGeneration,
                objectMetageneration = upload.receipt?.objectMetageneration,
                objectCrc32c = upload.receipt?.objectCrc32c,
                snapshotGeneration = upload.snapshotGeneration,
                validatedAtMs = upload.validatedAtMs,
                localPrunedAtMs = upload.localPrunedAtMs,
                updatedAtMs = clock(),
            ),
        )
        if (upload.phase == ManagedWindowUploadPhase.AVAILABLE &&
            upload.snapshotGeneration > 0L
        ) {
            val localSource = dao.sourceById(sourceId.toString())?.localSourceId
            if (localSource != null) {
                dao.clearValidatedDirtyWindow(
                    localSource,
                    dataClass,
                    windowStartMs,
                    upload.windowEndMs + 1,
                    upload.snapshotGeneration,
                )
            }
        }
    }

    override suspend fun claimWindowGeneration(
        sourceId: UUID,
        localSourceId: String,
        dataClass: String,
        window: ManagedSyncWindow,
    ): Long {
        val now = clock()
        dao.ensureDirtyWindow(
            localSourceId,
            dataClass,
            window.startMs,
            window.endExclusiveMs,
            now,
        )
        val dirty = dao.dirtyWindow(localSourceId, dataClass, window.startMs)
            ?: throw ManagedStorageException.InvalidResponse()
        if (dirty.windowEndMs != window.endExclusiveMs || dirty.generation <= 0L) {
            throw ManagedStorageException.InvalidResponse()
        }
        dao.claimDirtyGeneration(
            localSourceId,
            dataClass,
            window.startMs,
            dirty.generation,
            now,
        )
        return dirty.generation
    }

    override suspend fun claimNextDirtyWindow(
        sourceId: UUID,
        localSourceId: String,
        dataClass: String,
        endingAtOrBeforeMs: Long,
    ): ManagedDirtyWindow? {
        val dirty = dao.nextDirtyWindow(
            accountScopeHash,
            sourceId.toString(),
            localSourceId,
            dataClass,
            endingAtOrBeforeMs,
        ) ?: return null
        if (dirty.generation <= 0L || dirty.windowEndMs <= dirty.windowStartMs) {
            throw ManagedStorageException.InvalidResponse()
        }
        dao.claimDirtyGeneration(
            localSourceId,
            dataClass,
            dirty.windowStartMs,
            dirty.generation,
            clock(),
        )
        return ManagedDirtyWindow(
            dirty.windowStartMs,
            dirty.windowEndMs,
            dirty.generation,
        )
    }

    override suspend fun acknowledgeAvailableChunk(
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        chunkId: UUID,
    ): Boolean {
        val upload = dao.windowUpload(
            accountScopeHash,
            sourceId.toString(),
            dataClass,
            windowStartMs,
        ) ?: return false
        if (upload.windowEndMs != windowEndMs ||
            !upload.chunkId.equals(chunkId.toString(), ignoreCase = true)
        ) {
            return false
        }
        val changed = dao.markWindowAvailable(
            accountScopeHash,
            sourceId.toString(),
            dataClass,
            windowStartMs,
            windowEndMs,
            chunkId.toString(),
            clock(),
        )
        if (changed != 1) throw ManagedStorageException.InvalidResponse()
        if (upload.snapshotGeneration > 0L) {
            val localSource = dao.sourceById(sourceId.toString())?.localSourceId
            if (localSource != null) {
                dao.clearValidatedDirtyWindow(
                    localSource,
                    dataClass,
                    windowStartMs,
                    windowEndMs + 1,
                    upload.snapshotGeneration,
                )
            }
        }
        return true
    }

    override suspend fun markWindowHydrated(
        sourceId: UUID,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        chunkId: UUID,
    ): Boolean = dao.markWindowHydrated(
        accountScopeHash,
        sourceId.toString(),
        dataClass,
        windowStartMs,
        windowEndMs,
        chunkId.toString(),
        clock(),
    ) == 1

    override suspend fun pruneAvailableWindows(
        sourceId: UUID,
        localSourceId: String,
        dataClass: String,
        endingBeforeMs: Long,
        limit: Int,
    ): ManagedPruneResult {
        if (dataClass == "derived_summaries") return ManagedPruneResult(0, 0)
        val boundedLimit = limit.coerceIn(1, 16)
        return withContext(Dispatchers.IO) {
            var result = ManagedPruneResult(0, 0)
            database.runInTransaction {
                val db = database.openHelper.writableDatabase
                val candidates = db.query(
                    SimpleSQLiteQuery(
                        """
                            SELECT windowStartMs, windowEndMs, chunkId, snapshotGeneration
                            FROM managedWindowUpload AS upload
                            WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                              AND phase = 'available' AND validatedAtMs IS NOT NULL
                              AND localPrunedAtMs IS NULL AND snapshotGeneration > 0
                              AND windowEndMs < ?
                              AND NOT EXISTS (
                                  SELECT 1 FROM managedDirtyWindow AS dirty
                                  WHERE dirty.localSourceId = ?
                                    AND dirty.dataClass = upload.dataClass
                                    AND dirty.windowStartMs = upload.windowStartMs
                              )
                            ORDER BY windowStartMs
                            LIMIT ?
                        """.trimIndent(),
                        arrayOf<Any?>(
                            accountScopeHash,
                            sourceId.toString(),
                            dataClass,
                            endingBeforeMs,
                            localSourceId,
                            boundedLimit,
                        ),
                    ),
                ).use { cursor ->
                    buildList {
                        while (cursor.moveToNext()) {
                            add(
                                PruneCandidate(
                                    cursor.getLong(0),
                                    cursor.getLong(1),
                                    cursor.getString(2),
                                    cursor.getLong(3),
                                ),
                            )
                        }
                    }
                }
                if (candidates.isEmpty()) return@runInTransaction
                db.execSQL("INSERT OR IGNORE INTO managedPruneGuard (guardId) VALUES (1)")
                var deleted = 0
                var windows = 0
                val now = clock()
                candidates.forEach { candidate ->
                    deleted += pruneSensorRows(
                        db,
                        localSourceId,
                        dataClass,
                        candidate.windowStartMs,
                        candidate.windowEndMs,
                    )
                    db.execSQL(
                        """
                            UPDATE managedWindowUpload
                            SET localPrunedAtMs = ?, updatedAtMs = ?
                            WHERE accountScopeHash = ? AND sourceId = ? AND dataClass = ?
                              AND windowStartMs = ? AND windowEndMs = ? AND chunkId = ?
                              AND snapshotGeneration = ? AND phase = 'available'
                              AND validatedAtMs IS NOT NULL AND localPrunedAtMs IS NULL
                              AND NOT EXISTS (
                                  SELECT 1 FROM managedDirtyWindow
                                  WHERE localSourceId = ? AND dataClass = ?
                                    AND windowStartMs = ?
                              )
                        """.trimIndent(),
                        arrayOf<Any?>(
                            now,
                            now,
                            accountScopeHash,
                            sourceId.toString(),
                            dataClass,
                            candidate.windowStartMs,
                            candidate.windowEndMs,
                            candidate.chunkId,
                            candidate.snapshotGeneration,
                            localSourceId,
                            dataClass,
                            candidate.windowStartMs,
                        ),
                    )
                    if (changes(db) != 1) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    windows += 1
                }
                db.execSQL("DELETE FROM managedPruneGuard WHERE guardId = 1")
                result = ManagedPruneResult(windows, deleted)
            }
            result
        }
    }

    private fun pruneSensorRows(
        db: androidx.sqlite.db.SupportSQLiteDatabase,
        localSourceId: String,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
    ): Int {
        val from = (windowStartMs + 999L) / 1_000L
        val through = windowEndMs / 1_000L
        val tables = when (dataClass) {
            "essential_timeseries" -> listOf(
                "hrSample",
                "rrInterval",
                "event",
                "battery",
                "stepSample",
                "ppgHrSample",
            )
            "raw_auxiliary" -> listOf(
                "skinTempSample",
                "respSample",
                "sleepStateSample",
            )
            "raw_ppg" -> listOf("spo2Sample", "ppgWaveformSample")
            "raw_motion" -> listOf("gravitySample", "rawImuSample")
            else -> emptyList()
        }
        var deleted = 0
        tables.forEach { table ->
            db.execSQL(
                "DELETE FROM $table WHERE deviceId = ? AND ts >= ? AND ts <= ?",
                arrayOf<Any?>(localSourceId, from, through),
            )
            deleted += changes(db)
        }
        return deleted
    }

    private fun changes(db: androidx.sqlite.db.SupportSQLiteDatabase): Int =
        db.query("SELECT changes()").use { cursor ->
            if (cursor.moveToFirst()) cursor.getInt(0) else 0
        }

    private data class PruneCandidate(
        val windowStartMs: Long,
        val windowEndMs: Long,
        val chunkId: String,
        val snapshotGeneration: Long,
    )

    override suspend fun changeSequence(): Long =
        dao.changeCursor(accountScopeHash)?.sequence ?: 0L

    override suspend fun changeFeedCapabilityVersion(): Int =
        dao.changeCursor(accountScopeHash)?.changeFeedCapabilityVersion ?: 0

    override suspend fun saveChangeSequence(sequence: Long) {
        dao.advanceChangeCursor(accountScopeHash, sequence, clock())
    }

    override suspend fun isChangeApplied(change: ManagedChange): Boolean {
        val stored = dao.appliedChange(accountScopeHash, change.sequence) ?: return false
        if (stored.resourceKind != change.resourceKind ||
            !stored.resourceId.equals(change.resourceId.toString(), ignoreCase = true) ||
            stored.contentSHA256 != change.contentSha256
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return true
    }

    override suspend fun recordAppliedChange(change: ManagedChange) {
        dao.recordAppliedChange(
            ManagedAppliedChangeEntity(
                accountScopeHash = accountScopeHash,
                sequence = change.sequence,
                resourceKind = change.resourceKind,
                resourceId = change.resourceId.toString(),
                contentSHA256 = change.contentSha256,
                appliedAtMs = clock(),
            ),
        )
    }

    override suspend fun snapshotRestoreCheckpoint(): ManagedSnapshotRestoreCheckpoint? {
        val stored = dao.snapshotRestore(accountScopeHash) ?: return null
        val classes = runCatching {
            val array = JSONArray(stored.dataClassesJSON)
            List(array.length()) { index -> array.getString(index) }
        }.getOrElse { throw ManagedStorageException.InvalidResponse() }
        val requestId = runCatching { UUID.fromString(stored.requestId) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if (classes != classes.sorted() || stored.changeFeedCapabilityVersion < 0) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (stored.restoreJobId == null) {
            if (stored.snapshotAt != null ||
                stored.changeSequence != null ||
                stored.selectedObjects != null ||
                stored.selectedBytes != null ||
                stored.dataClassIndex != 0 ||
                stored.afterEventStart != null ||
                stored.afterChunkId != null ||
                stored.afterDocumentUpdatedAt != null ||
                stored.afterDocumentKind != null ||
                stored.afterDocumentId != null ||
                stored.documentsComplete ||
                stored.deliveredObjects != 0 ||
                stored.deliveredBytes != 0L
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            return ManagedSnapshotRestoreCheckpoint(
                requestId,
                classes,
                stored.changeFeedCapabilityVersion,
            )
        }
        val restoreJobId = runCatching { UUID.fromString(stored.restoreJobId) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if ((stored.afterEventStart == null) != (stored.afterChunkId == null)) {
            throw ManagedStorageException.InvalidResponse()
        }
        val documentCursorFields = listOf(
            stored.afterDocumentUpdatedAt,
            stored.afterDocumentKind,
            stored.afterDocumentId,
        )
        if (documentCursorFields.any { it == null } && documentCursorFields.any { it != null }) {
            throw ManagedStorageException.InvalidResponse()
        }
        val cursor = stored.afterEventStart?.let { eventStart ->
            ManagedChunkCursor(
                eventStart,
                runCatching { UUID.fromString(stored.afterChunkId) }
                    .getOrElse { throw ManagedStorageException.InvalidResponse() },
            )
        }
        val documentCursor = stored.afterDocumentUpdatedAt?.let { updatedAt ->
            val documentId = stored.afterDocumentId
                ?: throw ManagedStorageException.InvalidResponse()
            ManagedDocumentCursor(
                afterUpdatedAt = updatedAt,
                afterDocumentKind = ManagedDocumentKind.fromWire(
                    stored.afterDocumentKind
                        ?: throw ManagedStorageException.InvalidResponse(),
                ),
                afterDocumentId = runCatching {
                    UUID.fromString(documentId)
                }.getOrElse { throw ManagedStorageException.InvalidResponse() },
            )
        }
        return ManagedSnapshotRestoreCheckpoint(
            requestId = requestId,
            dataClasses = classes,
            changeFeedCapabilityVersion = stored.changeFeedCapabilityVersion,
            restoreJobId = restoreJobId,
            snapshotAt = stored.snapshotAt
                ?: throw ManagedStorageException.InvalidResponse(),
            changeSequence = stored.changeSequence
                ?: throw ManagedStorageException.InvalidResponse(),
            selectedObjects = stored.selectedObjects
                ?: throw ManagedStorageException.InvalidResponse(),
            selectedBytes = stored.selectedBytes
                ?: throw ManagedStorageException.InvalidResponse(),
            dataClassIndex = stored.dataClassIndex,
            cursor = cursor,
            documentCursor = documentCursor,
            documentsComplete = stored.documentsComplete,
            deliveredObjects = stored.deliveredObjects,
            deliveredBytes = stored.deliveredBytes,
        )
    }

    override suspend fun saveSnapshotRestoreCheckpoint(
        checkpoint: ManagedSnapshotRestoreCheckpoint,
    ) {
        if (checkpoint.dataClasses != checkpoint.dataClasses.sorted() ||
            checkpoint.changeFeedCapabilityVersion < 0 ||
            (checkpoint.cursor != null && checkpoint.restoreJobId == null) ||
            (checkpoint.documentCursor != null && checkpoint.restoreJobId == null)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        dao.upsertSnapshotRestore(
            ManagedSnapshotRestoreEntity(
                accountScopeHash = accountScopeHash,
                requestId = checkpoint.requestId.toString(),
                dataClassesJSON = JSONArray(checkpoint.dataClasses).toString(),
                changeFeedCapabilityVersion = checkpoint.changeFeedCapabilityVersion,
                restoreJobId = checkpoint.restoreJobId?.toString(),
                snapshotAt = checkpoint.snapshotAt,
                changeSequence = checkpoint.changeSequence,
                selectedObjects = checkpoint.selectedObjects,
                selectedBytes = checkpoint.selectedBytes,
                dataClassIndex = checkpoint.dataClassIndex,
                afterEventStart = checkpoint.cursor?.afterEventStart,
                afterChunkId = checkpoint.cursor?.afterChunkId?.toString(),
                afterDocumentUpdatedAt = checkpoint.documentCursor?.afterUpdatedAt,
                afterDocumentKind = checkpoint.documentCursor?.afterDocumentKind?.wireValue,
                afterDocumentId = checkpoint.documentCursor?.afterDocumentId?.toString(),
                documentsComplete = checkpoint.documentsComplete,
                deliveredObjects = checkpoint.deliveredObjects,
                deliveredBytes = checkpoint.deliveredBytes,
                updatedAtMs = clock(),
            ),
        )
    }

    override suspend fun clearSnapshotRestoreCheckpoint() {
        dao.deleteSnapshotRestore(accountScopeHash)
    }

    override suspend fun finishSnapshotRestore(
        changeSequence: Long,
        changeFeedCapabilityVersion: Int,
    ) {
        dao.finishSnapshotRestore(
            accountScopeHash,
            changeSequence,
            changeFeedCapabilityVersion,
            clock(),
        )
    }
}
