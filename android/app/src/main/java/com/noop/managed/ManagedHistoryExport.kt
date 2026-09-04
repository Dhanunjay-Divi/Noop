package com.noop.managed

import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlin.coroutines.coroutineContext

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
        .toString(2)
        .toByteArray(StandardCharsets.UTF_8)
}

class ManagedHistoryExporter(
    private val transport: ManagedStorageTransport,
) {
    suspend fun export(
        dataClasses: List<String> = ManagedSyncCoordinator.DATA_CLASSES,
        pageSize: Int = 100,
        authorization: suspend (forceRefresh: Boolean) -> ManagedAuthorization,
        progress: suspend (ManagedHistoryExportProgress) -> Unit = {},
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
        val restore = authorized(authorization) { credential ->
            transport.createRestore(
                authorization = credential,
                requestId = UUID.randomUUID(),
                dataClasses = classes,
            )
        }
        if (restore.status != "running" ||
            restore.selectedObjects < 0 ||
            restore.selectedBytes < 0 ||
            restore.deliveredObjects != 0 ||
            restore.deliveredBytes != 0L ||
            runCatching { Instant.parse(restore.snapshotAt) }.isFailure
        ) {
            throw ManagedStorageException.InvalidResponse()
        }

        val chunkRecords = mutableListOf<ManagedHistoryExportChunk>()
        val documentRecords = mutableListOf<ManagedHistoryExportDocument>()
        val entryPaths = mutableSetOf<String>()
        var completedObjects = 0
        var completedBytes = 0L

        report(
            progress,
            ManagedHistoryExportPhase.CHUNKS,
            completedObjects,
            restore.selectedObjects,
            completedBytes,
            restore.selectedBytes,
        )
        classes.forEach { dataClass ->
            var cursor: ManagedChunkCursor? = null
            do {
                coroutineContext.ensureActive()
                val pageCursor = cursor
                val page = authorized(authorization) { credential ->
                    transport.availableChunks(
                        authorization = credential,
                        dataClass = dataClass,
                        snapshotAt = restore.snapshotAt,
                        after = pageCursor,
                        limit = pageSize,
                    )
                }
                if (page.chunks.isEmpty() && page.nextCursor != null) {
                    throw ManagedStorageException.InvalidResponse()
                }
                page.chunks.forEach { chunk ->
                    coroutineContext.ensureActive()
                    val capability = authorized(authorization) { credential ->
                        transport.downloadCapability(
                            authorization = credential,
                            chunkId = chunk.chunkId,
                            requestId = ManagedStableIdentifier.uuid(
                                (
                                    "noop-managed-history-export-v1\u0000" +
                                        restore.restoreJobId.toString().lowercase() +
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
                    chunkRecords += ManagedHistoryExportChunk(
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
                    completedObjects = addExact(completedObjects, 1)
                    completedBytes = addExact(
                        completedBytes,
                        chunk.expectedCompressedBytes.toLong(),
                    )
                    if (completedObjects > restore.selectedObjects ||
                        completedBytes > restore.selectedBytes
                    ) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    report(
                        progress,
                        ManagedHistoryExportPhase.CHUNKS,
                        completedObjects,
                        restore.selectedObjects,
                        completedBytes,
                        restore.selectedBytes,
                    )
                }
                cursor = page.nextCursor
            } while (cursor != null)
        }

        report(
            progress,
            ManagedHistoryExportPhase.DOCUMENTS,
            completedObjects,
            restore.selectedObjects,
            completedBytes,
            restore.selectedBytes,
        )
        var documentCursor: ManagedDocumentCursor? = null
        do {
            coroutineContext.ensureActive()
            val pageCursor = documentCursor
            val page = authorized(authorization) { credential ->
                transport.documents(
                    authorization = credential,
                    snapshotAt = restore.snapshotAt,
                    after = pageCursor,
                    limit = pageSize,
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
                documentRecords += ManagedHistoryExportDocument(
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
                completedObjects = addExact(completedObjects, 1)
                if (completedObjects > restore.selectedObjects) {
                    throw ManagedStorageException.InvalidResponse()
                }
                report(
                    progress,
                    ManagedHistoryExportPhase.DOCUMENTS,
                    completedObjects,
                    restore.selectedObjects,
                    completedBytes,
                    restore.selectedBytes,
                )
            }
            documentCursor = page.nextCursor
        } while (documentCursor != null)

        if (completedObjects != restore.selectedObjects ||
            completedBytes != restore.selectedBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        report(
            progress,
            ManagedHistoryExportPhase.FINALIZING,
            completedObjects,
            restore.selectedObjects,
            completedBytes,
            restore.selectedBytes,
        )
        val completed = authorized(authorization) { credential ->
            transport.completeRestore(
                authorization = credential,
                restoreJobId = restore.restoreJobId,
                deliveredObjects = completedObjects,
                deliveredBytes = completedBytes,
            )
        }
        if (completed.status != "completed" ||
            completed.restoreJobId != restore.restoreJobId ||
            completed.snapshotAt != restore.snapshotAt ||
            completed.changeSequence != restore.changeSequence ||
            completed.selectedObjects != restore.selectedObjects ||
            completed.selectedBytes != restore.selectedBytes ||
            completed.deliveredObjects != completedObjects ||
            completed.deliveredBytes != completedBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }

        return ManagedHistoryExportManifest(
            format = "noop_managed_history",
            formatVersion = 1,
            createdAt = Instant.now().truncatedTo(ChronoUnit.MILLIS).toString(),
            snapshotAt = restore.snapshotAt,
            changeSequence = restore.changeSequence,
            dataClasses = classes,
            selectedObjects = restore.selectedObjects,
            selectedChunkBytes = restore.selectedBytes,
            exportedObjects = completedObjects,
            exportedChunkBytes = completedBytes,
            chunks = chunkRecords,
            documents = documentRecords,
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

    private companion object {
        val DATA_CLASS = Regex("^[a-z][a-z0-9_]{1,63}$")
    }
}
