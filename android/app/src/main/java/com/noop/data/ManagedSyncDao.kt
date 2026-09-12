package com.noop.data

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert

@Dao
interface ManagedSyncDao {
    /**
     * Every local source represented by a stream that NOOP+ can currently encode. This is a
     * discovery query only; the sync service removes cloud-import projections before constructing
     * upload descriptors so restored data can never be echoed back as a new source.
     */
    @Query(
        "SELECT id AS localSourceId FROM pairedDevice " +
            "UNION SELECT deviceId FROM hrSample " +
            "UNION SELECT deviceId FROM rrInterval " +
            "UNION SELECT deviceId FROM event " +
            "UNION SELECT deviceId FROM battery " +
            "UNION SELECT deviceId FROM stepSample " +
            "UNION SELECT deviceId FROM ppgHrSample " +
            "UNION SELECT deviceId FROM bodyMeasurement " +
            "UNION SELECT deviceId FROM skinTempSample " +
            "UNION SELECT deviceId FROM respSample " +
            "UNION SELECT deviceId FROM sleepStateSample " +
            "UNION SELECT deviceId FROM spo2Sample " +
            "UNION SELECT deviceId FROM ppgWaveformSample " +
            "UNION SELECT deviceId FROM gravitySample " +
            "UNION SELECT deviceId FROM rawImuSample " +
            "UNION SELECT deviceId FROM dailyMetric " +
            "UNION SELECT deviceId FROM appleDaily " +
            "UNION SELECT deviceId FROM metricSeries " +
            "UNION SELECT deviceId FROM sleepSession " +
            "UNION SELECT deviceId FROM workout " +
            "UNION SELECT deviceId FROM liveSession " +
            "ORDER BY localSourceId"
    )
    suspend fun managedLocalSourceIds(): List<String>

    @Upsert
    suspend fun upsertSource(source: ManagedSyncSourceEntity)

    @Query(
        "SELECT * FROM managedSyncSource WHERE localSourceId = :localSourceId " +
            "ORDER BY updatedAtMs DESC, sourceId ASC LIMIT 1"
    )
    suspend fun source(localSourceId: String): ManagedSyncSourceEntity?

    @Query("SELECT * FROM managedSyncSource WHERE sourceId = :sourceId LIMIT 1")
    suspend fun sourceById(sourceId: String): ManagedSyncSourceEntity?

    @Upsert
    suspend fun upsertCheckpoint(checkpoint: ManagedSyncCheckpointEntity)

    @Query(
        "SELECT * FROM managedSyncCheckpoint " +
            "WHERE accountScopeHash = :accountScopeHash " +
            "AND sourceId = :sourceId AND dataClass = :dataClass"
    )
    suspend fun checkpoint(
        accountScopeHash: String,
        sourceId: String,
        dataClass: String,
    ): ManagedSyncCheckpointEntity?

    @Upsert
    suspend fun upsertWindowUpload(upload: ManagedWindowUploadEntity)

    @Query(
        "SELECT * FROM managedWindowUpload " +
            "WHERE accountScopeHash = :accountScopeHash AND sourceId = :sourceId " +
            "AND dataClass = :dataClass AND windowStartMs = :windowStartMs LIMIT 1"
    )
    suspend fun windowUpload(
        accountScopeHash: String,
        sourceId: String,
        dataClass: String,
        windowStartMs: Long,
    ): ManagedWindowUploadEntity?

    @Query(
        "SELECT * FROM managedDirtyWindow WHERE localSourceId = :localSourceId " +
            "AND dataClass = :dataClass AND windowStartMs = :windowStartMs LIMIT 1"
    )
    suspend fun dirtyWindow(
        localSourceId: String,
        dataClass: String,
        windowStartMs: Long,
    ): ManagedDirtyWindowEntity?

    @Query(
        "INSERT OR IGNORE INTO managedDirtyWindow (" +
            "localSourceId, dataClass, windowStartMs, windowEndMs, generation, " +
            "claimedGeneration, updatedAtMs) VALUES (" +
            ":localSourceId, :dataClass, :windowStartMs, :windowEndMs, 1, NULL, :updatedAtMs)"
    )
    suspend fun ensureDirtyWindow(
        localSourceId: String,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        updatedAtMs: Long,
    ): Long

    @Query(
        "UPDATE managedDirtyWindow SET claimedGeneration = :generation, " +
            "updatedAtMs = :updatedAtMs WHERE localSourceId = :localSourceId " +
            "AND dataClass = :dataClass AND windowStartMs = :windowStartMs " +
            "AND generation = :generation"
    )
    suspend fun claimDirtyGeneration(
        localSourceId: String,
        dataClass: String,
        windowStartMs: Long,
        generation: Long,
        updatedAtMs: Long,
    ): Int

    @Query(
        "SELECT d.* FROM managedDirtyWindow AS d " +
            "WHERE d.localSourceId = :localSourceId AND d.dataClass = :dataClass " +
            "AND d.windowEndMs <= :cutoff " +
            "AND NOT EXISTS (SELECT 1 FROM managedWindowUpload AS active " +
            "WHERE active.accountScopeHash = :accountScopeHash " +
            "AND active.sourceId = :sourceId AND active.dataClass = d.dataClass " +
            "AND active.windowStartMs = d.windowStartMs " +
            "AND active.phase IN ('pending_completion', 'awaiting_validation')) " +
            "AND (d.claimedGeneration IS NULL OR d.claimedGeneration < d.generation " +
            "OR NOT EXISTS (SELECT 1 FROM managedWindowUpload AS claimed " +
            "WHERE claimed.accountScopeHash = :accountScopeHash " +
            "AND claimed.sourceId = :sourceId AND claimed.dataClass = d.dataClass " +
            "AND claimed.windowStartMs = d.windowStartMs " +
            "AND claimed.snapshotGeneration = d.claimedGeneration)) " +
            "ORDER BY d.windowStartMs LIMIT 1"
    )
    suspend fun nextDirtyWindow(
        accountScopeHash: String,
        sourceId: String,
        localSourceId: String,
        dataClass: String,
        cutoff: Long,
    ): ManagedDirtyWindowEntity?

    @Query(
        "UPDATE managedWindowUpload SET phase = 'available', objectGeneration = NULL, " +
            "objectMetageneration = NULL, objectCRC32C = NULL, " +
            "validatedAtMs = :validatedAtMs, updatedAtMs = :validatedAtMs " +
            "WHERE accountScopeHash = :accountScopeHash AND sourceId = :sourceId " +
            "AND dataClass = :dataClass AND windowStartMs = :windowStartMs " +
            "AND windowEndMs = :windowEndMs AND chunkId = :chunkId"
    )
    suspend fun markWindowAvailable(
        accountScopeHash: String,
        sourceId: String,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        chunkId: String,
        validatedAtMs: Long,
    ): Int

    @Query(
        "UPDATE managedWindowUpload SET localPrunedAtMs = NULL, updatedAtMs = :updatedAtMs " +
            "WHERE accountScopeHash = :accountScopeHash AND sourceId = :sourceId " +
            "AND dataClass = :dataClass AND windowStartMs = :windowStartMs " +
            "AND windowEndMs = :windowEndMs AND chunkId = :chunkId " +
            "AND phase = 'available' AND validatedAtMs IS NOT NULL"
    )
    suspend fun markWindowHydrated(
        accountScopeHash: String,
        sourceId: String,
        dataClass: String,
        windowStartMs: Long,
        windowEndMs: Long,
        chunkId: String,
        updatedAtMs: Long,
    ): Int

    @Query(
        "DELETE FROM managedDirtyWindow WHERE localSourceId = :localSourceId " +
            "AND dataClass = :dataClass AND windowStartMs = :windowStartMs " +
            "AND windowEndMs = :windowEndExclusiveMs AND generation = :generation " +
            "AND claimedGeneration = :generation"
    )
    suspend fun clearValidatedDirtyWindow(
        localSourceId: String,
        dataClass: String,
        windowStartMs: Long,
        windowEndExclusiveMs: Long,
        generation: Long,
    ): Int

    @Query("SELECT * FROM managedChangeCursor WHERE accountScopeHash = :accountScopeHash")
    suspend fun changeCursor(accountScopeHash: String): ManagedChangeCursorEntity?

    @Upsert
    suspend fun upsertChangeCursor(cursor: ManagedChangeCursorEntity)

    /** Ordered feeds only advance. A stale worker cannot move a newer worker's cursor backward. */
    @Transaction
    suspend fun advanceChangeCursor(
        accountScopeHash: String,
        sequence: Long,
        updatedAtMs: Long,
    ) {
        val current = changeCursor(accountScopeHash)
        if (current == null || sequence >= current.sequence) {
            upsertChangeCursor(
                ManagedChangeCursorEntity(
                    accountScopeHash = accountScopeHash,
                    sequence = sequence.coerceAtLeast(0),
                    changeFeedCapabilityVersion =
                        current?.changeFeedCapabilityVersion ?: 0,
                    updatedAtMs = updatedAtMs,
                )
            )
        }
    }

    @Query(
        "SELECT EXISTS(SELECT 1 FROM managedAppliedChange " +
            "WHERE accountScopeHash = :accountScopeHash AND sequence = :sequence)"
    )
    suspend fun hasAppliedChange(accountScopeHash: String, sequence: Long): Boolean

    @Query(
        "SELECT * FROM managedAppliedChange " +
            "WHERE accountScopeHash = :accountScopeHash AND sequence = :sequence LIMIT 1"
    )
    suspend fun appliedChange(
        accountScopeHash: String,
        sequence: Long,
    ): ManagedAppliedChangeEntity?

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertAppliedChange(change: ManagedAppliedChangeEntity): Long

    @Query(
        "DELETE FROM managedAppliedChange WHERE accountScopeHash = :accountScopeHash " +
            "AND sequence < COALESCE((SELECT sequence FROM managedAppliedChange " +
            "WHERE accountScopeHash = :accountScopeHash ORDER BY sequence DESC " +
            "LIMIT 1 OFFSET :offset), 0)"
    )
    suspend fun pruneAppliedChanges(accountScopeHash: String, offset: Int): Int

    @Transaction
    suspend fun recordAppliedChange(
        change: ManagedAppliedChangeEntity,
        retainingLatest: Int = 512,
    ) {
        insertAppliedChange(change)
        pruneAppliedChanges(
            accountScopeHash = change.accountScopeHash,
            offset = retainingLatest.coerceIn(32, 4_096) - 1,
        )
    }

    @Query(
        "SELECT * FROM managedSnapshotRestore " +
            "WHERE accountScopeHash = :accountScopeHash LIMIT 1"
    )
    suspend fun snapshotRestore(accountScopeHash: String): ManagedSnapshotRestoreEntity?

    @Upsert
    suspend fun upsertSnapshotRestore(checkpoint: ManagedSnapshotRestoreEntity)

    @Query("DELETE FROM managedSnapshotRestore WHERE accountScopeHash = :accountScopeHash")
    suspend fun deleteSnapshotRestore(accountScopeHash: String): Int

    @Transaction
    suspend fun finishSnapshotRestore(
        accountScopeHash: String,
        changeSequence: Long,
        changeFeedCapabilityVersion: Int,
        updatedAtMs: Long,
    ) {
        val current = changeCursor(accountScopeHash)
        if (current == null || changeSequence >= current.sequence) {
            upsertChangeCursor(
                ManagedChangeCursorEntity(
                    accountScopeHash = accountScopeHash,
                    sequence = changeSequence.coerceAtLeast(0),
                    changeFeedCapabilityVersion =
                        changeFeedCapabilityVersion.coerceAtLeast(0),
                    updatedAtMs = updatedAtMs,
                )
            )
        }
        deleteSnapshotRestore(accountScopeHash)
    }

    @Query("DELETE FROM managedAppliedChange WHERE accountScopeHash = :accountScopeHash")
    suspend fun deleteAppliedChanges(accountScopeHash: String): Int

    @Query("DELETE FROM managedChangeCursor WHERE accountScopeHash = :accountScopeHash")
    suspend fun deleteChangeCursor(accountScopeHash: String): Int

    @Transaction
    suspend fun resetChangeState(accountScopeHash: String) {
        deleteAppliedChanges(accountScopeHash)
        deleteChangeCursor(accountScopeHash)
    }
}
