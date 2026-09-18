package com.noop.managed

import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlin.coroutines.coroutineContext

enum class ManagedHistoryImportPhase {
    VALIDATING,
    IMPORTING,
    FINALIZING,
}

data class ManagedHistoryImportProgress(
    val phase: ManagedHistoryImportPhase,
    val completedObjects: Int,
    val totalObjects: Int,
    val completedChunkBytes: Long,
    val totalChunkBytes: Long,
)

data class ManagedHistoryImportCheckpoint(
    val format: String = "noop_managed_history_import_checkpoint",
    val formatVersion: Int = CURRENT_FORMAT_VERSION,
    val archiveSha256: String,
    var nextObjectIndex: Int = 0,
    var importedObjects: Int = 0,
    var importedChunkBytes: Long = 0,
    var completed: Boolean = false,
) {
    fun encoded(): ByteArray = JSONObject()
        .put("format", format)
        .put("format_version", formatVersion)
        .put("archive_sha256", archiveSha256)
        .put("next_object_index", nextObjectIndex)
        .put("imported_objects", importedObjects)
        .put("imported_chunk_bytes", importedChunkBytes)
        .put("completed", completed)
        .toString(2)
        .toByteArray(StandardCharsets.UTF_8)

    companion object {
        const val CURRENT_FORMAT_VERSION = 1

        fun decode(data: ByteArray): ManagedHistoryImportCheckpoint = try {
            val value = JSONObject(String(data, StandardCharsets.UTF_8))
            ManagedHistoryImportCheckpoint(
                format = value.getString("format"),
                formatVersion = value.getInt("format_version"),
                archiveSha256 = value.getString("archive_sha256"),
                nextObjectIndex = value.getInt("next_object_index"),
                importedObjects = value.getInt("imported_objects"),
                importedChunkBytes = value.getLong("imported_chunk_bytes"),
                completed = value.getBoolean("completed"),
            )
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Throwable) {
            throw ManagedStorageException.InvalidResponse()
        }
    }
}

data class ManagedHistoryImportSummary(
    val archiveSha256: String,
    val importedObjects: Int,
    val importedChunkBytes: Long,
    val resumed: Boolean,
)

class ManagedHistoryImporter {
    private sealed class ArchiveObject {
        abstract val path: String
        abstract val archiveBytes: Int
        abstract val chunkBytes: Long

        data class Chunk(
            val value: ManagedHistoryExportChunk,
        ) : ArchiveObject() {
            override val path: String = value.path
            override val archiveBytes: Int = value.compressedBytes
            override val chunkBytes: Long = value.compressedBytes.toLong()
        }

        data class Document(
            val value: ManagedHistoryExportDocument,
        ) : ArchiveObject() {
            override val path: String = value.path
            override val archiveBytes: Int = value.archiveBytes
            override val chunkBytes: Long = 0
        }
    }

    suspend fun importArchive(
        manifestData: ByteArray,
        entryPaths: List<String>,
        resumeFrom: ManagedHistoryImportCheckpoint? = null,
        restore: ManagedRestoreApplying,
        progress: suspend (ManagedHistoryImportProgress) -> Unit = {},
        saveCheckpoint: suspend (ManagedHistoryImportCheckpoint) -> Unit = {},
        read: suspend (path: String, maximumBytes: Int) -> ByteArray,
    ): ManagedHistoryImportSummary {
        val manifest = ManagedHistoryExportManifest.decode(manifestData)
        val objects = validateManifest(manifest, manifestData, entryPaths)
        val archiveSha256 = ManagedDigest.sha256(manifest.encoded())
        val resumed = resumeFrom != null
        val checkpoint = if (resumeFrom != null) {
            validateCheckpoint(resumeFrom, archiveSha256, objects)
            resumeFrom
        } else {
            ManagedHistoryImportCheckpoint(archiveSha256 = archiveSha256)
                .also { saveCheckpoint(it) }
        }

        report(progress, ManagedHistoryImportPhase.VALIDATING, checkpoint, manifest)
        objects.forEach { archiveObject ->
            coroutineContext.ensureActive()
            val data = read(archiveObject.path, archiveObject.archiveBytes)
            when (archiveObject) {
                is ArchiveObject.Chunk ->
                    validatedChunk(archiveObject.value, manifest, data)
                is ArchiveObject.Document ->
                    validatedDocument(archiveObject.value, data)
            }
        }

        if (checkpoint.completed) {
            report(progress, ManagedHistoryImportPhase.FINALIZING, checkpoint, manifest)
            return ManagedHistoryImportSummary(
                archiveSha256,
                checkpoint.importedObjects,
                checkpoint.importedChunkBytes,
                resumed,
            )
        }

        report(progress, ManagedHistoryImportPhase.IMPORTING, checkpoint, manifest)
        while (checkpoint.nextObjectIndex < objects.size) {
            coroutineContext.ensureActive()
            val archiveObject = objects[checkpoint.nextObjectIndex]
            val data = read(archiveObject.path, archiveObject.archiveBytes)
            when (archiveObject) {
                is ArchiveObject.Chunk -> {
                    val value = validatedChunk(archiveObject.value, manifest, data)
                    restore.apply(value.first, value.second)
                }
                is ArchiveObject.Document -> {
                    val document = validatedDocument(archiveObject.value, data)
                    restore.apply(document, document.asChange())
                }
            }
            checkpoint.nextObjectIndex += 1
            checkpoint.importedObjects += 1
            checkpoint.importedChunkBytes = addExact(
                checkpoint.importedChunkBytes,
                archiveObject.chunkBytes,
            )
            saveCheckpoint(checkpoint)
            report(progress, ManagedHistoryImportPhase.IMPORTING, checkpoint, manifest)
        }

        if (checkpoint.importedObjects != manifest.exportedObjects ||
            checkpoint.importedChunkBytes != manifest.exportedChunkBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        checkpoint.completed = true
        saveCheckpoint(checkpoint)
        report(progress, ManagedHistoryImportPhase.FINALIZING, checkpoint, manifest)
        return ManagedHistoryImportSummary(
            archiveSha256,
            checkpoint.importedObjects,
            checkpoint.importedChunkBytes,
            resumed,
        )
    }

    private fun validateManifest(
        manifest: ManagedHistoryExportManifest,
        manifestData: ByteArray,
        entryPaths: List<String>,
    ): List<ArchiveObject> {
        val objects = manifest.chunks.map(ArchiveObject::Chunk) +
            manifest.documents.map(ArchiveObject::Document)
        val paths = objects.map(ArchiveObject::path)
        val expectedPaths = (paths + "manifest.json").toSet()
        val actualPaths = entryPaths.toSet()
        val chunkBytes = manifest.chunks.sumOf {
            it.compressedBytes.toLong()
        }
        if (manifestData.size > MAX_MANIFEST_BYTES ||
            manifest.format != "noop_managed_history" ||
            manifest.formatVersion !in 1..2 ||
            runCatching { Instant.parse(manifest.createdAt) }.isFailure ||
            runCatching { Instant.parse(manifest.snapshotAt) }.isFailure ||
            manifest.changeSequence < 0 ||
            manifest.dataClasses.isEmpty() ||
            manifest.dataClasses != manifest.dataClasses.sorted() ||
            manifest.dataClasses.toSet().size != manifest.dataClasses.size ||
            manifest.dataClasses.any { !it.matches(DATA_CLASS) } ||
            manifest.selectedObjects != manifest.exportedObjects ||
            manifest.exportedObjects != objects.size ||
            manifest.exportedObjects > MAX_OBJECTS ||
            manifest.selectedChunkBytes != manifest.exportedChunkBytes ||
            manifest.exportedChunkBytes != chunkBytes ||
            manifest.exportedChunkBytes < 0 ||
            paths.toSet().size != paths.size ||
            entryPaths.size != actualPaths.size ||
            actualPaths != expectedPaths ||
            manifest.chunks.any { !validChunk(it, manifest.dataClasses) } ||
            manifest.documents.any { !validDocument(it) }
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (manifest.formatVersion == 2) {
            val expected = ManagedHistoryArchiveIntegrity.entriesSha256(
                manifest.chunks,
                manifest.documents,
            )
            val integrity = manifest.integrity
                ?: throw ManagedStorageException.DigestMismatch()
            val cursor = manifest.snapshotCursor
                ?: throw ManagedStorageException.DigestMismatch()
            if (integrity.algorithm != "sha256" ||
                integrity.entryCount != manifest.exportedObjects ||
                integrity.entriesSha256 != expected ||
                cursor.formatVersion != 1 ||
                cursor.snapshotAt != manifest.snapshotAt ||
                cursor.changeSequence != manifest.changeSequence
            ) {
                throw ManagedStorageException.DigestMismatch()
            }
        }
        return objects
    }

    private fun validateCheckpoint(
        checkpoint: ManagedHistoryImportCheckpoint,
        archiveSha256: String,
        objects: List<ArchiveObject>,
    ) {
        val expectedBytes = objects.take(checkpoint.nextObjectIndex.coerceAtLeast(0))
            .sumOf(ArchiveObject::chunkBytes)
        if (checkpoint.archiveSha256 != archiveSha256) {
            throw ManagedStorageException.Conflict()
        }
        if (checkpoint.format != "noop_managed_history_import_checkpoint" ||
            checkpoint.formatVersion != ManagedHistoryImportCheckpoint.CURRENT_FORMAT_VERSION ||
            checkpoint.nextObjectIndex !in 0..objects.size ||
            checkpoint.importedObjects != checkpoint.nextObjectIndex ||
            checkpoint.importedChunkBytes != expectedBytes ||
            checkpoint.completed && checkpoint.nextObjectIndex != objects.size
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun validatedChunk(
        record: ManagedHistoryExportChunk,
        manifest: ManagedHistoryExportManifest,
        data: ByteArray,
    ): Pair<ManagedChunkPayload, ManagedChange> {
        if (data.size != record.compressedBytes ||
            ManagedDigest.sha256(data) != record.sha256
        ) {
            throw ManagedStorageException.DigestMismatch()
        }
        val decoded = ManagedChunkCodec.decode(
            data,
            record.compression,
            record.uncompressedBytes,
        )
        val payload = ManagedChunkCodec.decodePayload(decoded)
        val canonical = ManagedChunkCodec.verifyCanonical(payload)
        val start = runCatching { Instant.parse(record.eventStart).toEpochMilli() }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        val end = runCatching { Instant.parse(record.eventEnd).toEpochMilli() }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if (!canonical.uncompressed.contentEquals(decoded) ||
            payload.chunkId != record.chunkId ||
            payload.sourceId != record.sourceId ||
            payload.dataClass != record.dataClass ||
            payload.schemaVersion != record.schemaVersion ||
            payload.eventStartMs != start ||
            payload.eventEndMs != end
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val available = ManagedAvailableChunk(
            chunkId = record.chunkId,
            sourceId = record.sourceId,
            dataClass = record.dataClass,
            schemaVersion = record.schemaVersion,
            contentMode = "server_readable",
            state = "available",
            eventStart = record.eventStart,
            eventEnd = record.eventEnd,
            compression = record.compression,
            contentType = record.contentType,
            expectedSha256 = record.sha256,
            expectedCompressedBytes = record.compressedBytes,
            expectedUncompressedBytes = record.uncompressedBytes,
            objectGeneration = record.objectGeneration,
            expiresAt = manifest.createdAt,
        )
        return payload to available.asChange()
    }

    private fun validatedDocument(
        record: ManagedHistoryExportDocument,
        data: ByteArray,
    ): ManagedDocument {
        if (data.size != record.archiveBytes ||
            ManagedDigest.sha256(data) != record.archiveSha256
        ) {
            throw ManagedStorageException.DigestMismatch()
        }
        val value = try {
            JSONObject(String(data, StandardCharsets.UTF_8))
        } catch (_: Throwable) {
            throw ManagedStorageException.InvalidResponse()
        }
        val document = try {
            ManagedDocument(
                documentKind = ManagedDocumentKind.fromWire(
                    value.getString("document_kind"),
                ),
                documentId = UUID.fromString(value.getString("document_id")),
                revision = value.getLong("revision"),
                originInstallationId = value.getString("origin_installation_id"),
                contentMode = value.getString("content_mode"),
                clientKeyId = value.nullableString("client_key_id")?.let(UUID::fromString),
                contentSha256 = value.getString("content_sha256"),
                payloadJson = value.optJSONObject("payload_json"),
                payloadCiphertextBase64 = value.nullableString(
                    "payload_ciphertext_base64",
                ),
                updatedAt = value.getString("updated_at"),
                deletedAt = value.nullableString("deleted_at"),
                duplicate = false,
            )
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Throwable) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (document.documentKind != record.documentKind ||
            document.documentId != record.documentId ||
            document.revision != record.revision ||
            document.contentMode != record.contentMode ||
            document.contentSha256 != record.contentSha256 ||
            document.updatedAt != record.updatedAt ||
            document.deletedAt != null ||
            document.originInstallationId.isBlank() ||
            document.originInstallationId.toByteArray(StandardCharsets.UTF_8).size > 64
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        validateDocumentContent(document)
        return document
    }

    private fun validateDocumentContent(document: ManagedDocument) {
        if (document.contentMode == "server_readable") {
            val payload = document.payloadJson
                ?: throw ManagedStorageException.InvalidResponse()
            if (document.clientKeyId != null ||
                document.payloadCiphertextBase64 != null
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            val canonical = ManagedCanonicalJson.encode(payload)
            if (ManagedDigest.sha256(
                    canonical.toByteArray(StandardCharsets.UTF_8),
                ) != document.contentSha256 ||
                documentId(document.documentKind, payload) != document.documentId
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            return
        }
        val encoded = document.payloadCiphertextBase64
            ?: throw ManagedStorageException.InvalidResponse()
        val ciphertext = runCatching { Base64.getDecoder().decode(encoded) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if (document.contentMode != "client_encrypted" ||
            document.payloadJson != null ||
            document.clientKeyId == null ||
            Base64.getEncoder().encodeToString(ciphertext) != encoded ||
            ciphertext.size !in MIN_ENCRYPTED_BYTES..MAX_ENCRYPTED_BYTES ||
            ManagedDigest.sha256(ciphertext) != document.contentSha256
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun documentId(
        kind: ManagedDocumentKind,
        payload: JSONObject,
    ): UUID {
        if (kind == ManagedDocumentKind.PREFERENCES) {
            return RoomManagedDocumentAdapter.documentId(
                kind,
                "preferences",
                """{"scope":"global"}""",
            )
        }
        val table = payload.optString("table")
        val key = payload.optJSONObject("key")
            ?: throw ManagedStorageException.InvalidResponse()
        if (table.isBlank()) throw ManagedStorageException.InvalidResponse()
        return RoomManagedDocumentAdapter.documentId(
            kind,
            table,
            ManagedCanonicalJson.encode(key),
        )
    }

    private fun validChunk(
        chunk: ManagedHistoryExportChunk,
        dataClasses: List<String>,
    ): Boolean =
        chunk.path == chunkPath(chunk) &&
            validPath(chunk.path) &&
            chunk.dataClass in dataClasses &&
            chunk.schemaVersion == 1 &&
            runCatching { Instant.parse(chunk.eventStart) }.isSuccess &&
            runCatching { Instant.parse(chunk.eventEnd) }.isSuccess &&
            chunk.compression in setOf("gzip", "none") &&
            chunk.contentType == "application/vnd.noop.chunk+json" &&
            chunk.sha256.matches(SHA256) &&
            chunk.compressedBytes in 1..MAX_COMPRESSED_BYTES &&
            chunk.uncompressedBytes > 0 &&
            chunk.objectGeneration > 0

    private fun validDocument(document: ManagedHistoryExportDocument): Boolean =
        document.path == documentPath(document) &&
            validPath(document.path) &&
            document.revision > 0 &&
            document.contentMode in setOf("server_readable", "client_encrypted") &&
            document.contentSha256.matches(SHA256) &&
            document.archiveSha256.matches(SHA256) &&
            document.archiveBytes in 1..MAX_DOCUMENT_ARCHIVE_BYTES &&
            runCatching { Instant.parse(document.updatedAt) }.isSuccess

    private fun chunkPath(chunk: ManagedHistoryExportChunk): String {
        val suffix = when (chunk.compression) {
            "gzip" -> "json.gz"
            "zstd" -> "json.zst"
            else -> "json"
        }
        return "chunks/${chunk.dataClass}/${chunk.chunkId.toString().lowercase()}.$suffix"
    }

    private fun documentPath(document: ManagedHistoryExportDocument): String =
        "documents/${document.documentKind.wireValue}/" +
            "${document.documentId.toString().lowercase()}.json"

    private fun validPath(path: String): Boolean =
        path.isNotEmpty() &&
            !path.startsWith("/") &&
            !path.endsWith("/") &&
            !path.contains('\\') &&
            !path.contains('\u0000') &&
            path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

    private suspend fun report(
        consumer: suspend (ManagedHistoryImportProgress) -> Unit,
        phase: ManagedHistoryImportPhase,
        checkpoint: ManagedHistoryImportCheckpoint,
        manifest: ManagedHistoryExportManifest,
    ) {
        consumer(
            ManagedHistoryImportProgress(
                phase,
                checkpoint.importedObjects,
                manifest.exportedObjects,
                checkpoint.importedChunkBytes,
                manifest.exportedChunkBytes,
            ),
        )
    }

    private fun addExact(left: Long, right: Long): Long =
        try {
            Math.addExact(left, right)
        } catch (_: ArithmeticException) {
            throw ManagedStorageException.InvalidResponse()
        }

    private companion object {
        const val MAX_MANIFEST_BYTES = 8 * 1_024 * 1_024
        const val MAX_OBJECTS = 1_000_000
        const val MAX_COMPRESSED_BYTES = 16 * 1_024 * 1_024
        const val MAX_DOCUMENT_ARCHIVE_BYTES = 2 * 1_024 * 1_024
        const val MIN_ENCRYPTED_BYTES = 17
        const val MAX_ENCRYPTED_BYTES = 1_048_576
        val DATA_CLASS = Regex("^[a-z][a-z0-9_]{1,63}$")
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

private fun JSONObject.nullableString(key: String): String? =
    if (!has(key) || isNull(key)) null else getString(key)
