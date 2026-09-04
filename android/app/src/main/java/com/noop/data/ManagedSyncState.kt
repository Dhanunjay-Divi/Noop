package com.noop.data

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/** Compact operational state for optional NOOP+ sync. No health samples are duplicated here. */
@Entity(tableName = "managedSyncSource", primaryKeys = ["sourceId"])
data class ManagedSyncSourceEntity(
    val sourceId: String,
    val localSourceId: String,
    val sourceKind: String,
    val platform: String,
    val logicalSourceHash: String,
    val createdAtMs: Long,
    val updatedAtMs: Long,
)

@Entity(
    tableName = "managedSyncCheckpoint",
    primaryKeys = ["accountScopeHash", "sourceId", "dataClass"],
)
data class ManagedSyncCheckpointEntity(
    val accountScopeHash: String,
    val sourceId: String,
    val dataClass: String,
    val nextWindowStartMs: Long?,
    val repairWindowStartMs: Long?,
    val updatedAtMs: Long,
)

/**
 * Last accepted snapshot for one fixed upload window. A pending receipt survives process death so a
 * retry completes the already uploaded object instead of attempting a second generation-zero PUT.
 */
@Entity(
    tableName = "managedWindowUpload",
    primaryKeys = ["accountScopeHash", "sourceId", "dataClass", "windowStartMs"],
    indices = [
        Index(
            name = "idx_managedWindowUpload_chunk",
            value = ["accountScopeHash", "chunkId"],
        ),
        Index(
            name = "idx_managedWindowUpload_prune",
            value = [
                "accountScopeHash",
                "sourceId",
                "dataClass",
                "phase",
                "localPrunedAtMs",
                "windowEndMs",
            ],
        ),
    ],
)
data class ManagedWindowUploadEntity(
    val accountScopeHash: String,
    val sourceId: String,
    val dataClass: String,
    val windowStartMs: Long,
    val windowEndMs: Long,
    val chunkId: String,
    val rowCount: Int,
    val phase: String,
    val objectGeneration: Long?,
    val objectMetageneration: Long?,
    @ColumnInfo(name = "objectCRC32C")
    val objectCrc32c: String?,
    @ColumnInfo(defaultValue = "0")
    val snapshotGeneration: Long = 0,
    val validatedAtMs: Long? = null,
    val localPrunedAtMs: Long? = null,
    val updatedAtMs: Long,
)

@Entity(
    tableName = "managedDirtyWindow",
    primaryKeys = ["localSourceId", "dataClass", "windowStartMs"],
    indices = [
        Index(
            name = "idx_managedDirtyWindow_pending",
            value = ["localSourceId", "dataClass", "windowEndMs", "windowStartMs"],
        ),
    ],
)
data class ManagedDirtyWindowEntity(
    val localSourceId: String,
    val dataClass: String,
    val windowStartMs: Long,
    val windowEndMs: Long,
    val generation: Long,
    val claimedGeneration: Long?,
    val updatedAtMs: Long,
)

@Entity(tableName = "managedPruneGuard")
data class ManagedPruneGuardEntity(
    @PrimaryKey
    val guardId: Int,
)

@Entity(tableName = "managedChangeCursor", primaryKeys = ["accountScopeHash"])
data class ManagedChangeCursorEntity(
    val accountScopeHash: String,
    val sequence: Long,
    val updatedAtMs: Long,
)

@Entity(tableName = "managedAppliedChange", primaryKeys = ["accountScopeHash", "sequence"])
data class ManagedAppliedChangeEntity(
    val accountScopeHash: String,
    val sequence: Long,
    val resourceKind: String,
    val resourceId: String,
    val contentSHA256: String?,
    val appliedAtMs: Long,
)

@Entity(
    tableName = "managedDocumentDirty",
    primaryKeys = ["tableName", "localKey"],
    indices = [
        Index(
            name = "idx_managedDocumentDirty_order",
            value = ["updatedAtMs", "tableName", "localKey"],
        ),
    ],
)
data class ManagedDocumentDirtyEntity(
    val tableName: String,
    val localKey: String,
    val documentKind: String,
    val generation: Long,
    val operation: String,
    val updatedAtMs: Long,
    val payloadJSON: String?,
)

@Entity(
    tableName = "managedDocumentState",
    primaryKeys = ["accountScopeHash", "tableName", "localKey"],
    indices = [
        Index(
            name = "idx_managedDocumentState_document",
            value = ["accountScopeHash", "documentKind", "documentId"],
            unique = true,
        ),
    ],
)
data class ManagedDocumentStateEntity(
    val accountScopeHash: String,
    val tableName: String,
    val localKey: String,
    val documentKind: String,
    val documentId: String,
    val keyJSON: String,
    val acknowledgedGeneration: Long,
    val remoteRevision: Long,
    val remoteContentSHA256: String,
    val updatedAtMs: Long,
)

@Entity(tableName = "managedDocumentApplyGuard")
data class ManagedDocumentApplyGuardEntity(
    @PrimaryKey
    val guardId: Int,
)

@Entity(tableName = "managedSnapshotRestore", primaryKeys = ["accountScopeHash"])
data class ManagedSnapshotRestoreEntity(
    val accountScopeHash: String,
    val requestId: String,
    val dataClassesJSON: String,
    val restoreJobId: String?,
    val snapshotAt: String?,
    val changeSequence: Long?,
    val selectedObjects: Int?,
    val selectedBytes: Long?,
    val dataClassIndex: Int,
    val afterEventStart: String?,
    val afterChunkId: String?,
    val deliveredObjects: Int,
    val deliveredBytes: Long,
    val updatedAtMs: Long,
    val afterDocumentUpdatedAt: String?,
    val afterDocumentKind: String?,
    val afterDocumentId: String?,
    @ColumnInfo(defaultValue = "0")
    val documentsComplete: Boolean,
)
