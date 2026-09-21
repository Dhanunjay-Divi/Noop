package com.noop.managed

import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.coroutines.coroutineContext

internal object ManagedHistoryTransferLimits {
    const val MAXIMUM_OBJECT_COUNT = 20_000
    const val MAXIMUM_ARCHIVE_ENTRY_COUNT = MAXIMUM_OBJECT_COUNT + 1
    const val MAXIMUM_MANIFEST_BYTES = 16 * 1_024 * 1_024
    const val MAXIMUM_IMPORT_CHECKPOINT_BYTES = 64L * 1_024L
    const val MAXIMUM_EXPORT_CHECKPOINT_BYTES = 16L * 1_024L * 1_024L
    const val MAXIMUM_PATH_BYTES = 512
}

enum class ManagedHistoryExportEntryKind {
    CHUNK,
    DOCUMENT,
}

data class ManagedHistoryExportEntry(
    val kind: ManagedHistoryExportEntryKind,
    val path: String,
    val data: ByteArray,
)

enum class ManagedHistoryExportPhase {
    PREPARING,
    CHUNKS,
    DOCUMENTS,
    FINALIZING,
}

data class ManagedHistoryExportProgress(
    val phase: ManagedHistoryExportPhase,
    val completedObjects: Int,
    val totalObjects: Int,
    val completedChunkBytes: Long,
    val totalChunkBytes: Long,
)

data class ManagedHistoryExportChunk(
    val path: String,
    val chunkId: UUID,
    val sourceId: UUID,
    val dataClass: String,
    val schemaVersion: Int,
    val eventStart: String,
    val eventEnd: String,
    val compression: String,
    val contentType: String,
    val sha256: String,
    val compressedBytes: Int,
    val uncompressedBytes: Int,
    val objectGeneration: Long,
)

data class ManagedHistoryExportDocument(
    val path: String,
    val documentKind: ManagedDocumentKind,
    val documentId: UUID,
    val revision: Long,
    val contentMode: String,
    val contentSha256: String,
    val archiveSha256: String,
    val archiveBytes: Int,
    val updatedAt: String,
)

data class ManagedHistoryExportIntegrity(
    val algorithm: String,
    val entryCount: Int,
    val entriesSha256: String,
)

data class ManagedHistorySnapshotCursor(
    val formatVersion: Int,
    val snapshotAt: String,
    val changeSequence: Long,
)

data class ManagedHistoryExportManifest(
    val format: String,
    val formatVersion: Int,
    val createdAt: String,
    val snapshotAt: String,
    val changeSequence: Long,
    val dataClasses: List<String>,
    val selectedObjects: Int,
    val selectedChunkBytes: Long,
    val exportedObjects: Int,
    val exportedChunkBytes: Long,
    val chunks: List<ManagedHistoryExportChunk>,
    val documents: List<ManagedHistoryExportDocument>,
    val integrity: ManagedHistoryExportIntegrity? = null,
    val snapshotCursor: ManagedHistorySnapshotCursor? = null,
) {
    fun encoded(): ByteArray = JSONObject()
        .put("format", format)
        .put("format_version", formatVersion)
        .put("created_at", createdAt)
        .put("snapshot_at", snapshotAt)
        .put("change_sequence", changeSequence)
        .put("data_classes", JSONArray(dataClasses))
        .put("selected_objects", selectedObjects)
        .put("selected_chunk_bytes", selectedChunkBytes)
        .put("exported_objects", exportedObjects)
        .put("exported_chunk_bytes", exportedChunkBytes)
        .put(
            "chunks",
            JSONArray().apply {
                chunks.forEach { chunk ->
                    put(
                        JSONObject()
                            .put("path", chunk.path)
                            .put("chunk_id", chunk.chunkId.toString().lowercase())
                            .put("source_id", chunk.sourceId.toString().lowercase())
                            .put("data_class", chunk.dataClass)
                            .put("schema_version", chunk.schemaVersion)
                            .put("event_start", chunk.eventStart)
                            .put("event_end", chunk.eventEnd)
                            .put("compression", chunk.compression)
                            .put("content_type", chunk.contentType)
                            .put("sha256", chunk.sha256)
                            .put("compressed_bytes", chunk.compressedBytes)
                            .put("uncompressed_bytes", chunk.uncompressedBytes)
                            .put("object_generation", chunk.objectGeneration),
                    )
                }
            },
        )
        .put(
            "documents",
            JSONArray().apply {
                documents.forEach { document ->
                    put(
                        JSONObject()
                            .put("path", document.path)
                            .put("document_kind", document.documentKind.wireValue)
                            .put("document_id", document.documentId.toString().lowercase())
                            .put("revision", document.revision)
                            .put("content_mode", document.contentMode)
                            .put("content_sha256", document.contentSha256)
                            .put("archive_sha256", document.archiveSha256)
                            .put("archive_bytes", document.archiveBytes)
                            .put("updated_at", document.updatedAt),
                    )
                }
            },
        )
        .apply {
            integrity?.let {
                put(
                    "integrity",
                    JSONObject()
                        .put("algorithm", it.algorithm)
                        .put("entry_count", it.entryCount)
                        .put("entries_sha256", it.entriesSha256),
                )
            }
            snapshotCursor?.let {
                put(
                    "snapshot_cursor",
                    JSONObject()
                        .put("format_version", it.formatVersion)
                        .put("snapshot_at", it.snapshotAt)
                        .put("change_sequence", it.changeSequence),
                )
            }
        }
        .toString(2)
        .toByteArray(StandardCharsets.UTF_8)

    companion object {
        fun decode(data: ByteArray): ManagedHistoryExportManifest = try {
            val value = JSONObject(String(data, StandardCharsets.UTF_8))
            val chunks = value.getJSONArray("chunks").objects().map { chunk ->
                ManagedHistoryExportChunk(
                    path = chunk.getString("path"),
                    chunkId = UUID.fromString(chunk.getString("chunk_id")),
                    sourceId = UUID.fromString(chunk.getString("source_id")),
                    dataClass = chunk.getString("data_class"),
                    schemaVersion = chunk.getInt("schema_version"),
                    eventStart = chunk.getString("event_start"),
                    eventEnd = chunk.getString("event_end"),
                    compression = chunk.getString("compression"),
                    contentType = chunk.getString("content_type"),
                    sha256 = chunk.getString("sha256"),
                    compressedBytes = chunk.getInt("compressed_bytes"),
                    uncompressedBytes = chunk.getInt("uncompressed_bytes"),
                    objectGeneration = chunk.getLong("object_generation"),
                )
            }
            val documents = value.getJSONArray("documents").objects().map { document ->
                ManagedHistoryExportDocument(
                    path = document.getString("path"),
                    documentKind = ManagedDocumentKind.fromWire(
                        document.getString("document_kind"),
                    ),
                    documentId = UUID.fromString(document.getString("document_id")),
                    revision = document.getLong("revision"),
                    contentMode = document.getString("content_mode"),
                    contentSha256 = document.getString("content_sha256"),
                    archiveSha256 = document.getString("archive_sha256"),
                    archiveBytes = document.getInt("archive_bytes"),
                    updatedAt = document.getString("updated_at"),
                )
            }
            val integrity = value.optJSONObject("integrity")?.let {
                ManagedHistoryExportIntegrity(
                    algorithm = it.getString("algorithm"),
                    entryCount = it.getInt("entry_count"),
                    entriesSha256 = it.getString("entries_sha256"),
                )
            }
            val cursor = value.optJSONObject("snapshot_cursor")?.let {
                ManagedHistorySnapshotCursor(
                    formatVersion = it.getInt("format_version"),
                    snapshotAt = it.getString("snapshot_at"),
                    changeSequence = it.getLong("change_sequence"),
                )
            }
            ManagedHistoryExportManifest(
                format = value.getString("format"),
                formatVersion = value.getInt("format_version"),
                createdAt = value.getString("created_at"),
                snapshotAt = value.getString("snapshot_at"),
                changeSequence = value.getLong("change_sequence"),
                dataClasses = value.getJSONArray("data_classes").strings(),
                selectedObjects = value.getInt("selected_objects"),
                selectedChunkBytes = value.getLong("selected_chunk_bytes"),
                exportedObjects = value.getInt("exported_objects"),
                exportedChunkBytes = value.getLong("exported_chunk_bytes"),
                chunks = chunks,
                documents = documents,
                integrity = integrity,
                snapshotCursor = cursor,
            )
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Throwable) {
            throw ManagedStorageException.InvalidResponse()
        }
    }
}

data class ManagedHistoryExportCheckpoint(
    val format: String = "noop_managed_history_export_checkpoint",
    val formatVersion: Int = CURRENT_FORMAT_VERSION,
    val createdAt: String,
    val requestId: UUID,
    val restoreJobId: UUID,
    val snapshotAt: String,
    val changeSequence: Long,
    val expiresAt: String,
    val dataClasses: List<String>,
    val pageSize: Int,
    val selectedObjects: Int,
    val selectedChunkBytes: Long,
    var dataClassIndex: Int = 0,
    var chunkCursor: ManagedChunkCursor? = null,
    var documentCursor: ManagedDocumentCursor? = null,
    var documentsComplete: Boolean = false,
    var serverCompleted: Boolean = false,
    var exportedObjects: Int = 0,
    var exportedChunkBytes: Long = 0,
    val chunks: MutableList<ManagedHistoryExportChunk> = mutableListOf(),
    val documents: MutableList<ManagedHistoryExportDocument> = mutableListOf(),
) {
    fun encoded(): ByteArray = JSONObject()
        .put("format", format)
        .put("format_version", formatVersion)
        .put("created_at", createdAt)
        .put("request_id", requestId.toString().lowercase())
        .put("restore_job_id", restoreJobId.toString().lowercase())
        .put("snapshot_at", snapshotAt)
        .put("change_sequence", changeSequence)
        .put("expires_at", expiresAt)
        .put("data_classes", JSONArray(dataClasses))
        .put("page_size", pageSize)
        .put("selected_objects", selectedObjects)
        .put("selected_chunk_bytes", selectedChunkBytes)
        .put("data_class_index", dataClassIndex)
        .put(
            "chunk_cursor",
            chunkCursor?.let {
                JSONObject()
                    .put("after_event_start", it.afterEventStart)
                    .put("after_chunk_id", it.afterChunkId.toString().lowercase())
            } ?: JSONObject.NULL,
        )
        .put(
            "document_cursor",
            documentCursor?.let {
                JSONObject()
                    .put("after_updated_at", it.afterUpdatedAt)
                    .put("after_document_kind", it.afterDocumentKind.wireValue)
                    .put("after_document_id", it.afterDocumentId.toString().lowercase())
            } ?: JSONObject.NULL,
        )
        .put("documents_complete", documentsComplete)
        .put("server_completed", serverCompleted)
        .put("exported_objects", exportedObjects)
        .put("exported_chunk_bytes", exportedChunkBytes)
        .put("chunks", ManagedHistoryExportManifest(
            format = "checkpoint",
            formatVersion = 0,
            createdAt = createdAt,
            snapshotAt = snapshotAt,
            changeSequence = changeSequence,
            dataClasses = emptyList(),
            selectedObjects = 0,
            selectedChunkBytes = 0,
            exportedObjects = 0,
            exportedChunkBytes = 0,
            chunks = chunks,
            documents = emptyList(),
        ).let { JSONObject(String(it.encoded())).getJSONArray("chunks") })
        .put("documents", ManagedHistoryExportManifest(
            format = "checkpoint",
            formatVersion = 0,
            createdAt = createdAt,
            snapshotAt = snapshotAt,
            changeSequence = changeSequence,
            dataClasses = emptyList(),
            selectedObjects = 0,
            selectedChunkBytes = 0,
            exportedObjects = 0,
            exportedChunkBytes = 0,
            chunks = emptyList(),
            documents = documents,
        ).let { JSONObject(String(it.encoded())).getJSONArray("documents") })
        .toString(2)
        .toByteArray(StandardCharsets.UTF_8)

    companion object {
        const val CURRENT_FORMAT_VERSION = 1

        fun decode(data: ByteArray): ManagedHistoryExportCheckpoint = try {
            val value = JSONObject(String(data, StandardCharsets.UTF_8))
            val manifest = ManagedHistoryExportManifest.decode(
                JSONObject()
                    .put("format", "noop_managed_history")
                    .put("format_version", 1)
                    .put("created_at", value.getString("created_at"))
                    .put("snapshot_at", value.getString("snapshot_at"))
                    .put("change_sequence", value.getLong("change_sequence"))
                    .put("data_classes", value.getJSONArray("data_classes"))
                    .put("selected_objects", value.getInt("selected_objects"))
                    .put("selected_chunk_bytes", value.getLong("selected_chunk_bytes"))
                    .put("exported_objects", value.getInt("exported_objects"))
                    .put("exported_chunk_bytes", value.getLong("exported_chunk_bytes"))
                    .put("chunks", value.getJSONArray("chunks"))
                    .put("documents", value.getJSONArray("documents"))
                    .toString()
                    .toByteArray(StandardCharsets.UTF_8),
            )
            ManagedHistoryExportCheckpoint(
                format = value.getString("format"),
                formatVersion = value.getInt("format_version"),
                createdAt = value.getString("created_at"),
                requestId = UUID.fromString(value.getString("request_id")),
                restoreJobId = UUID.fromString(value.getString("restore_job_id")),
                snapshotAt = value.getString("snapshot_at"),
                changeSequence = value.getLong("change_sequence"),
                expiresAt = value.getString("expires_at"),
                dataClasses = value.getJSONArray("data_classes").strings(),
                pageSize = value.getInt("page_size"),
                selectedObjects = value.getInt("selected_objects"),
                selectedChunkBytes = value.getLong("selected_chunk_bytes"),
                dataClassIndex = value.getInt("data_class_index"),
                chunkCursor = value.optJSONObject("chunk_cursor")?.let {
                    ManagedChunkCursor(
                        it.getString("after_event_start"),
                        UUID.fromString(it.getString("after_chunk_id")),
                    )
                },
                documentCursor = value.optJSONObject("document_cursor")?.let {
                    ManagedDocumentCursor(
                        afterUpdatedAt = it.getString("after_updated_at"),
                        afterDocumentKind = ManagedDocumentKind.fromWire(
                            it.getString("after_document_kind"),
                        ),
                        afterDocumentId = UUID.fromString(
                            it.getString("after_document_id"),
                        ),
                    )
                },
                documentsComplete = value.getBoolean("documents_complete"),
                serverCompleted = value.getBoolean("server_completed"),
                exportedObjects = value.getInt("exported_objects"),
                exportedChunkBytes = value.getLong("exported_chunk_bytes"),
                chunks = manifest.chunks.toMutableList(),
                documents = manifest.documents.toMutableList(),
            )
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Throwable) {
            throw ManagedStorageException.InvalidResponse()
        }
    }
}

object ManagedHistoryArchiveIntegrity {
    fun entriesSha256(
        chunks: List<ManagedHistoryExportChunk>,
        documents: List<ManagedHistoryExportDocument>,
    ): String {
        val entries = chunks.map {
            listOf("chunk", it.path, it.sha256, it.compressedBytes.toString())
        } + documents.map {
            listOf("document", it.path, it.archiveSha256, it.archiveBytes.toString())
        }
        val canonical = entries.sortedWith(
            compareBy<List<String>> { it[1] }.thenBy { it[0] },
        ).joinToString(separator = "") {
            "${it[0]}\u0000${it[1]}\u0000${it[2]}\u0000${it[3]}\n"
        }
        return ManagedDigest.sha256(canonical.toByteArray(StandardCharsets.UTF_8))
    }
}

class ManagedHistoryExporter(
    private val transport: ManagedStorageTransport,
) {
    suspend fun export(
        dataClasses: List<String> = ManagedSyncCoordinator.DATA_CLASSES,
        pageSize: Int = 100,
        resumeFrom: ManagedHistoryExportCheckpoint? = null,
        authorization: suspend (forceRefresh: Boolean) -> ManagedAuthorization,
        progress: suspend (ManagedHistoryExportProgress) -> Unit = {},
        saveCheckpoint: suspend (ManagedHistoryExportCheckpoint) -> Unit = {},
        now: () -> Instant = Instant::now,
        consume: suspend (ManagedHistoryExportEntry) -> Unit,
    ): ManagedHistoryExportManifest {
        val classes = dataClasses.sorted()
        if (classes.isEmpty() ||
            classes.size != dataClasses.size ||
            classes.toSet().size != classes.size ||
            classes.any { !it.matches(DATA_CLASS) } ||
            pageSize !in 1..200
        ) {
            throw IllegalArgumentException("Invalid managed-history export configuration")
        }

        report(
            progress,
            ManagedHistoryExportPhase.PREPARING,
            completedObjects = 0,
            totalObjects = 0,
            completedBytes = 0,
            totalBytes = 0,
        )
        val checkpoint = if (resumeFrom != null) {
            validateCheckpoint(resumeFrom, classes, pageSize, now())
            resumeFrom
        } else {
            val requestId = UUID.randomUUID()
            val restore = authorized(authorization) { credential ->
                transport.createRestore(
                    authorization = credential,
                    requestId = requestId,
                    dataClasses = classes,
                    includeDeletedDocuments = false,
                )
            }
            if (restore.status != "running" ||
                restore.selectedObjects < 0 ||
                restore.selectedObjects > ManagedHistoryTransferLimits.MAXIMUM_OBJECT_COUNT ||
                restore.selectedBytes < 0 ||
                restore.deliveredObjects != 0 ||
                restore.deliveredBytes != 0L ||
                runCatching { Instant.parse(restore.snapshotAt) }.isFailure ||
                runCatching { Instant.parse(restore.expiresAt) }.isFailure
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            ManagedHistoryExportCheckpoint(
                createdAt = now().truncatedTo(ChronoUnit.MILLIS).toString(),
                requestId = requestId,
                restoreJobId = restore.restoreJobId,
                snapshotAt = restore.snapshotAt,
                changeSequence = restore.changeSequence,
                expiresAt = restore.expiresAt,
                dataClasses = classes,
                pageSize = pageSize,
                selectedObjects = restore.selectedObjects,
                selectedChunkBytes = restore.selectedBytes,
            ).also { saveCheckpoint(it) }
        }
        val entryPaths = (
            checkpoint.chunks.map(ManagedHistoryExportChunk::path) +
                checkpoint.documents.map(ManagedHistoryExportDocument::path)
            ).toMutableSet()

        report(
            progress,
            ManagedHistoryExportPhase.CHUNKS,
            checkpoint.exportedObjects,
            checkpoint.selectedObjects,
            checkpoint.exportedChunkBytes,
            checkpoint.selectedChunkBytes,
        )
        while (checkpoint.dataClassIndex < classes.size) {
            val dataClass = classes[checkpoint.dataClassIndex]
            do {
                coroutineContext.ensureActive()
                val pageCursor = checkpoint.chunkCursor
                val page = authorized(authorization) { credential ->
                    transport.availableChunks(
                        authorization = credential,
                        dataClass = dataClass,
                        snapshotAt = checkpoint.snapshotAt,
                        after = pageCursor,
                        limit = pageSize,
                    )
                }
                if (page.chunks.isEmpty() && page.nextCursor != null) {
                    throw ManagedStorageException.InvalidResponse()
                }
                page.chunks.forEach { chunk ->
                    coroutineContext.ensureActive()
                    if (chunk.dataClass != dataClass ||
                        chunk.contentMode != "server_readable" ||
                        chunk.state != "available" ||
                        chunk.expectedCompressedBytes <= 0 ||
                        chunk.expectedUncompressedBytes <= 0 ||
                        !chunk.expectedSha256.matches(SHA256)
                    ) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    val capability = authorized(authorization) { credential ->
                        transport.downloadCapability(
                            authorization = credential,
                            chunkId = chunk.chunkId,
                            requestId = ManagedStableIdentifier.uuid(
                                (
                                    "noop-managed-history-export-v1\u0000" +
                                        checkpoint.restoreJobId.toString().lowercase() +
                                        "\u0000" +
                                        chunk.chunkId.toString().lowercase()
                                    ).toByteArray(StandardCharsets.UTF_8),
                            ),
                        )
                    }
                    val data = transport.download(capability)
                    if (data.size != chunk.expectedCompressedBytes ||
                        ManagedDigest.sha256(data) != chunk.expectedSha256
                    ) {
                        throw ManagedStorageException.DigestMismatch()
                    }
                    val path = chunkPath(chunk)
                    if (!entryPaths.add(path)) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    consume(
                        ManagedHistoryExportEntry(
                            kind = ManagedHistoryExportEntryKind.CHUNK,
                            path = path,
                            data = data,
                        ),
                    )
                    checkpoint.chunks += ManagedHistoryExportChunk(
                        path = path,
                        chunkId = chunk.chunkId,
                        sourceId = chunk.sourceId,
                        dataClass = chunk.dataClass,
                        schemaVersion = chunk.schemaVersion,
                        eventStart = chunk.eventStart,
                        eventEnd = chunk.eventEnd,
                        compression = chunk.compression,
                        contentType = chunk.contentType,
                        sha256 = chunk.expectedSha256,
                        compressedBytes = chunk.expectedCompressedBytes,
                        uncompressedBytes = chunk.expectedUncompressedBytes,
                        objectGeneration = chunk.objectGeneration,
                    )
                    checkpoint.exportedObjects = addExact(
                        checkpoint.exportedObjects,
                        1,
                    )
                    checkpoint.exportedChunkBytes = addExact(
                        checkpoint.exportedChunkBytes,
                        chunk.expectedCompressedBytes.toLong(),
                    )
                    checkpoint.chunkCursor = ManagedChunkCursor(
                        chunk.eventStart,
                        chunk.chunkId,
                    )
                    if (checkpoint.exportedObjects > checkpoint.selectedObjects ||
                        checkpoint.exportedChunkBytes > checkpoint.selectedChunkBytes
                    ) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    report(
                        progress,
                        ManagedHistoryExportPhase.CHUNKS,
                        checkpoint.exportedObjects,
                        checkpoint.selectedObjects,
                        checkpoint.exportedChunkBytes,
                        checkpoint.selectedChunkBytes,
                    )
                }
                if (page.nextCursor != null) {
                    if (checkpoint.chunkCursor != page.nextCursor) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                } else {
                    checkpoint.dataClassIndex += 1
                    checkpoint.chunkCursor = null
                }
                saveCheckpoint(checkpoint)
            } while (checkpoint.chunkCursor != null)
        }

        report(
            progress,
            ManagedHistoryExportPhase.DOCUMENTS,
            checkpoint.exportedObjects,
            checkpoint.selectedObjects,
            checkpoint.exportedChunkBytes,
            checkpoint.selectedChunkBytes,
        )
        while (!checkpoint.documentsComplete) {
            coroutineContext.ensureActive()
            val pageCursor = checkpoint.documentCursor
            val page = authorized(authorization) { credential ->
                transport.documents(
                    authorization = credential,
                    snapshotAt = checkpoint.snapshotAt,
                    after = pageCursor,
                    limit = pageSize,
                    includeDeleted = false,
                )
            }
            if (page.documents.isEmpty() && page.nextCursor != null) {
                throw ManagedStorageException.InvalidResponse()
            }
            page.documents.forEach { document ->
                coroutineContext.ensureActive()
                if (document.deletedAt != null) {
                    throw ManagedStorageException.InvalidResponse()
                }
                val data = encodeDocument(document)
                val path = documentPath(document)
                if (!entryPaths.add(path)) {
                    throw ManagedStorageException.InvalidResponse()
                }
                consume(
                    ManagedHistoryExportEntry(
                        kind = ManagedHistoryExportEntryKind.DOCUMENT,
                        path = path,
                        data = data,
                    ),
                )
                checkpoint.documents += ManagedHistoryExportDocument(
                    path = path,
                    documentKind = document.documentKind,
                    documentId = document.documentId,
                    revision = document.revision,
                    contentMode = document.contentMode,
                    contentSha256 = document.contentSha256,
                    archiveSha256 = ManagedDigest.sha256(data),
                    archiveBytes = data.size,
                    updatedAt = document.updatedAt,
                )
                checkpoint.exportedObjects = addExact(
                    checkpoint.exportedObjects,
                    1,
                )
                checkpoint.documentCursor = document.pageCursor()
                if (checkpoint.exportedObjects > checkpoint.selectedObjects) {
                    throw ManagedStorageException.InvalidResponse()
                }
                report(
                    progress,
                    ManagedHistoryExportPhase.DOCUMENTS,
                    checkpoint.exportedObjects,
                    checkpoint.selectedObjects,
                    checkpoint.exportedChunkBytes,
                    checkpoint.selectedChunkBytes,
                )
            }
            if (page.nextCursor != null) {
                if (checkpoint.documentCursor != page.nextCursor) {
                    throw ManagedStorageException.InvalidResponse()
                }
            } else {
                checkpoint.documentCursor = null
                checkpoint.documentsComplete = true
            }
            saveCheckpoint(checkpoint)
        }

        if (checkpoint.exportedObjects != checkpoint.selectedObjects ||
            checkpoint.exportedChunkBytes != checkpoint.selectedChunkBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        report(
            progress,
            ManagedHistoryExportPhase.FINALIZING,
            checkpoint.exportedObjects,
            checkpoint.selectedObjects,
            checkpoint.exportedChunkBytes,
            checkpoint.selectedChunkBytes,
        )
        if (!checkpoint.serverCompleted) {
            val completed = authorized(authorization) { credential ->
                transport.completeRestore(
                    authorization = credential,
                    restoreJobId = checkpoint.restoreJobId,
                    deliveredObjects = checkpoint.exportedObjects,
                    deliveredBytes = checkpoint.exportedChunkBytes,
                )
            }
            if (completed.status != "completed" ||
                completed.restoreJobId != checkpoint.restoreJobId ||
                completed.snapshotAt != checkpoint.snapshotAt ||
                completed.changeSequence != checkpoint.changeSequence ||
                completed.selectedObjects != checkpoint.selectedObjects ||
                completed.selectedBytes != checkpoint.selectedChunkBytes ||
                completed.deliveredObjects != checkpoint.exportedObjects ||
                completed.deliveredBytes != checkpoint.exportedChunkBytes
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            checkpoint.serverCompleted = true
            saveCheckpoint(checkpoint)
        }

        val entriesSha256 = ManagedHistoryArchiveIntegrity.entriesSha256(
            checkpoint.chunks,
            checkpoint.documents,
        )
        return ManagedHistoryExportManifest(
            format = "noop_managed_history",
            formatVersion = 2,
            createdAt = checkpoint.createdAt,
            snapshotAt = checkpoint.snapshotAt,
            changeSequence = checkpoint.changeSequence,
            dataClasses = classes,
            selectedObjects = checkpoint.selectedObjects,
            selectedChunkBytes = checkpoint.selectedChunkBytes,
            exportedObjects = checkpoint.exportedObjects,
            exportedChunkBytes = checkpoint.exportedChunkBytes,
            chunks = checkpoint.chunks,
            documents = checkpoint.documents,
            integrity = ManagedHistoryExportIntegrity(
                algorithm = "sha256",
                entryCount = checkpoint.exportedObjects,
                entriesSha256 = entriesSha256,
            ),
            snapshotCursor = ManagedHistorySnapshotCursor(
                formatVersion = 1,
                snapshotAt = checkpoint.snapshotAt,
                changeSequence = checkpoint.changeSequence,
            ),
        )
    }

    private suspend fun <T> authorized(
        provider: suspend (Boolean) -> ManagedAuthorization,
        operation: suspend (ManagedAuthorization) -> T,
    ): T = ManagedAuthenticationRetry.run(provider, operation)

    private suspend fun report(
        consumer: suspend (ManagedHistoryExportProgress) -> Unit,
        phase: ManagedHistoryExportPhase,
        completedObjects: Int,
        totalObjects: Int,
        completedBytes: Long,
        totalBytes: Long,
    ) {
        consumer(
            ManagedHistoryExportProgress(
                phase = phase,
                completedObjects = completedObjects,
                totalObjects = totalObjects,
                completedChunkBytes = completedBytes,
                totalChunkBytes = totalBytes,
            ),
        )
    }

    private fun chunkPath(chunk: ManagedAvailableChunk): String {
        val suffix = when (chunk.compression) {
            "gzip" -> "json.gz"
            "zstd" -> "json.zst"
            else -> "json"
        }
        return "chunks/${chunk.dataClass}/${chunk.chunkId.toString().lowercase()}.$suffix"
    }

    private fun documentPath(document: ManagedDocument): String =
        "documents/${document.documentKind.wireValue}/" +
            "${document.documentId.toString().lowercase()}.json"

    private fun encodeDocument(document: ManagedDocument): ByteArray =
        JSONObject()
            .put("document_kind", document.documentKind.wireValue)
            .put("document_id", document.documentId.toString().lowercase())
            .put("revision", document.revision)
            .put("origin_installation_id", document.originInstallationId)
            .put("content_mode", document.contentMode)
            .put("client_key_id", document.clientKeyId?.toString() ?: JSONObject.NULL)
            .put("content_sha256", document.contentSha256)
            .put("payload_json", document.payloadJson ?: JSONObject.NULL)
            .put(
                "payload_ciphertext_base64",
                document.payloadCiphertextBase64 ?: JSONObject.NULL,
            )
            .put("updated_at", document.updatedAt)
            .put("deleted_at", document.deletedAt ?: JSONObject.NULL)
            .toString(2)
            .toByteArray(StandardCharsets.UTF_8)

    private fun addExact(left: Int, right: Int): Int =
        try {
            Math.addExact(left, right)
        } catch (_: ArithmeticException) {
            throw ManagedStorageException.InvalidResponse()
        }

    private fun addExact(left: Long, right: Long): Long =
        try {
            Math.addExact(left, right)
        } catch (_: ArithmeticException) {
            throw ManagedStorageException.InvalidResponse()
        }

    private fun validateCheckpoint(
        checkpoint: ManagedHistoryExportCheckpoint,
        dataClasses: List<String>,
        pageSize: Int,
        now: Instant,
    ) {
        val paths = checkpoint.chunks.map(ManagedHistoryExportChunk::path) +
            checkpoint.documents.map(ManagedHistoryExportDocument::path)
        val chunkBytes = checkpoint.chunks.sumOf {
            it.compressedBytes.toLong()
        }
        val expiresAt = runCatching { Instant.parse(checkpoint.expiresAt) }.getOrNull()
        if (expiresAt != null && !expiresAt.isAfter(now)) {
            throw ManagedStorageException.CursorExpired(null)
        }
        if (checkpoint.format != "noop_managed_history_export_checkpoint" ||
            checkpoint.formatVersion != ManagedHistoryExportCheckpoint.CURRENT_FORMAT_VERSION ||
            checkpoint.dataClasses != dataClasses ||
            checkpoint.pageSize != pageSize ||
            checkpoint.changeSequence < 0 ||
            runCatching { Instant.parse(checkpoint.createdAt) }.isFailure ||
            runCatching { Instant.parse(checkpoint.snapshotAt) }.isFailure ||
            expiresAt == null ||
            checkpoint.selectedObjects < 0 ||
            checkpoint.selectedObjects > ManagedHistoryTransferLimits.MAXIMUM_OBJECT_COUNT ||
            checkpoint.selectedChunkBytes < 0 ||
            checkpoint.dataClassIndex !in 0..dataClasses.size ||
            checkpoint.exportedObjects != checkpoint.chunks.size +
            checkpoint.documents.size ||
            checkpoint.exportedObjects !in 0..checkpoint.selectedObjects ||
            checkpoint.exportedChunkBytes != chunkBytes ||
            checkpoint.exportedChunkBytes !in 0..checkpoint.selectedChunkBytes ||
            paths.toSet().size != paths.size ||
            checkpoint.chunks.any {
                !validPath(it.path) ||
                    !it.sha256.matches(SHA256) ||
                    it.compressedBytes <= 0 ||
                    it.uncompressedBytes <= 0 ||
                    it.dataClass !in dataClasses
            } ||
            checkpoint.documents.any {
                !validPath(it.path) ||
                    !it.contentSha256.matches(SHA256) ||
                    !it.archiveSha256.matches(SHA256) ||
                    it.archiveBytes <= 0 ||
                    it.revision <= 0
            } ||
            checkpoint.serverCompleted &&
            (!checkpoint.documentsComplete ||
                checkpoint.exportedObjects != checkpoint.selectedObjects ||
                checkpoint.exportedChunkBytes != checkpoint.selectedChunkBytes)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun validPath(path: String): Boolean =
        path.isNotEmpty() &&
            path.toByteArray(StandardCharsets.UTF_8).size <=
            ManagedHistoryTransferLimits.MAXIMUM_PATH_BYTES &&
            !path.startsWith("/") &&
            !path.endsWith("/") &&
            !path.contains('\\') &&
            !path.contains('\u0000') &&
            path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

    private companion object {
        val DATA_CLASS = Regex("^[a-z][a-z0-9_]{1,63}$")
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

private fun JSONArray.objects(): List<JSONObject> =
    (0 until length()).map { getJSONObject(it) }

private fun JSONArray.strings(): List<String> =
    (0 until length()).map { getString(it) }
