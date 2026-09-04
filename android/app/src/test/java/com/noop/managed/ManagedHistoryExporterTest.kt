package com.noop.managed

import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.UUID

class ManagedHistoryExporterTest {
    @Test
    fun completeExportPagesBothKindsAndRefreshesAuthentication() = runTest {
        val firstData = "first-chunk".toByteArray()
        val secondData = "second-chunk".toByteArray()
        val first = chunk(
            UUID.fromString("10000000-0000-5000-8000-000000000001"),
            firstData,
            "2026-09-01T00:00:00Z",
        )
        val second = chunk(
            UUID.fromString("10000000-0000-5000-8000-000000000002"),
            secondData,
            "2026-09-01T01:00:00Z",
        )
        val firstDocument = document(
            UUID.fromString("40000000-0000-5000-8000-000000000001"),
            "2026-09-04T10:00:00Z",
        )
        val secondDocument = document(
            UUID.fromString("40000000-0000-5000-8000-000000000002"),
            "2026-09-04T11:00:00Z",
        )
        val transport = ExportTransport(
            chunks = listOf(first, second),
            chunkData = mapOf(first.chunkId to firstData, second.chunkId to secondData),
            documents = listOf(firstDocument, secondDocument),
            forcePageSize = 1,
            failFirstChunkPageAuthentication = true,
        )
        val entries = mutableListOf<ManagedHistoryExportEntry>()
        val progress = mutableListOf<ManagedHistoryExportProgress>()
        val refreshes = mutableListOf<Boolean>()

        val manifest = ManagedHistoryExporter(transport).export(
            dataClasses = listOf("essential_timeseries"),
            pageSize = 25,
            authorization = { forceRefresh ->
                refreshes += forceRefresh
                authorization(if (forceRefresh) "fresh" else "cached")
            },
            progress = { progress += it },
            consume = { entries += it },
        )

        assertEquals(4, manifest.exportedObjects)
        assertEquals(23L, manifest.exportedChunkBytes)
        assertEquals(listOf(first.chunkId, second.chunkId), manifest.chunks.map { it.chunkId })
        assertEquals(
            listOf(firstDocument.documentId, secondDocument.documentId),
            manifest.documents.map { it.documentId },
        )
        assertEquals(4, entries.size)
        assertEquals(ExportTransport.Completion(4, 23), transport.completion)
        assertEquals(listOf(null, null, first.chunkId), transport.chunkStarts)
        assertEquals(listOf(null, firstDocument.documentId), transport.documentStarts)
        assertEquals(
            listOf(false, false, true, false, false, false, false, false, false),
            refreshes,
        )
        assertEquals(ManagedHistoryExportPhase.FINALIZING, progress.last().phase)
    }

    @Test
    fun digestMismatchPublishesNothingAndDoesNotCompleteSnapshot() = runTest {
        val expected = "expected".toByteArray()
        val chunk = chunk(
            UUID.fromString("20000000-0000-5000-8000-000000000001"),
            expected,
            "2026-09-01T00:00:00Z",
        )
        val transport = ExportTransport(
            chunks = listOf(chunk),
            chunkData = mapOf(chunk.chunkId to "tampered".toByteArray()),
        )
        val entries = mutableListOf<ManagedHistoryExportEntry>()

        try {
            ManagedHistoryExporter(transport).export(
                dataClasses = listOf("essential_timeseries"),
                authorization = { authorization() },
                consume = { entries += it },
            )
            fail("Expected digest mismatch")
        } catch (_: ManagedStorageException.DigestMismatch) {
            // Expected.
        }

        assertTrue(entries.isEmpty())
        assertNull(transport.completion)
    }

    @Test
    fun selectedCountMismatchFailsClosed() = runTest {
        val data = "only-chunk".toByteArray()
        val chunk = chunk(
            UUID.fromString("30000000-0000-5000-8000-000000000001"),
            data,
            "2026-09-01T00:00:00Z",
        )
        val transport = ExportTransport(
            chunks = listOf(chunk),
            chunkData = mapOf(chunk.chunkId to data),
            selectedObjectDelta = 1,
        )

        try {
            ManagedHistoryExporter(transport).export(
                dataClasses = listOf("essential_timeseries"),
                authorization = { authorization() },
                consume = {},
            )
            fail("Expected selected count mismatch")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }
        assertNull(transport.completion)
    }

    @Test
    fun manifestUsesPortableSnakeCaseKeys() {
        val manifest = ManagedHistoryExportManifest(
            format = "noop_managed_history",
            formatVersion = 1,
            createdAt = "2026-09-04T12:00:00Z",
            snapshotAt = "2026-09-04T11:59:00Z",
            changeSequence = 42,
            dataClasses = listOf("essential_timeseries"),
            selectedObjects = 1,
            selectedChunkBytes = 12,
            exportedObjects = 1,
            exportedChunkBytes = 12,
            chunks = emptyList(),
            documents = emptyList(),
        )
        val objectValue = JSONObject(String(manifest.encoded()))
        assertEquals(1, objectValue.getInt("format_version"))
        assertEquals(12L, objectValue.getLong("selected_chunk_bytes"))
        assertTrue(!objectValue.has("formatVersion"))
    }

    private fun chunk(
        id: UUID,
        data: ByteArray,
        start: String,
    ) = ManagedAvailableChunk(
        chunkId = id,
        sourceId = UUID.fromString("aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa"),
        dataClass = "essential_timeseries",
        schemaVersion = 1,
        contentMode = "server_readable",
        state = "available",
        eventStart = start,
        eventEnd = start,
        compression = "gzip",
        contentType = "application/vnd.noop.chunk+json",
        expectedSha256 = ManagedDigest.sha256(data),
        expectedCompressedBytes = data.size,
        expectedUncompressedBytes = data.size * 2,
        objectGeneration = 1,
        expiresAt = "2026-09-05T00:00:00Z",
    )

    private fun document(id: UUID, updatedAt: String) = ManagedDocument(
        documentKind = ManagedDocumentKind.JOURNAL,
        documentId = id,
        revision = 1,
        originInstallationId = "android-installation",
        contentMode = "server_readable",
        clientKeyId = null,
        contentSha256 = "b".repeat(64),
        payloadJson = JSONObject().put("day", "2026-09-04").put("answered", true),
        payloadCiphertextBase64 = null,
        updatedAt = updatedAt,
        deletedAt = null,
        duplicate = false,
    )

    private fun authorization(token: String = "identity") = ManagedAuthorization(
        identityToken = token,
        appCheckToken = "app-check",
        installationId = "android-installation",
        installationToken = "noopm_" + "a".repeat(43),
    )
}

private class ExportTransport(
    private val chunks: List<ManagedAvailableChunk>,
    private val chunkData: Map<UUID, ByteArray>,
    private val documents: List<ManagedDocument> = emptyList(),
    private val forcePageSize: Int? = null,
    private val selectedObjectDelta: Int = 0,
    private var failFirstChunkPageAuthentication: Boolean = false,
) : ManagedStorageTransport {
    data class Completion(val objects: Int, val bytes: Long)

    val chunkStarts = mutableListOf<UUID?>()
    val documentStarts = mutableListOf<UUID?>()
    var completion: Completion? = null
    private val restoreId = UUID.fromString("50000000-0000-5000-8000-000000000001")
    private val snapshot = "2026-09-04T12:00:00Z"

    override suspend fun registerSource(
        authorization: ManagedAuthorization,
        sourceId: UUID,
        sourceKind: String,
        logicalSourceHash: String,
    ) = unsupported()

    override suspend fun reserveChunk(
        authorization: ManagedAuthorization,
        reservation: ManagedChunkReservation,
    ): ManagedChunkReservationResult = unsupported()

    override suspend fun upload(
        bytes: ByteArray,
        capability: ManagedUploadCapability,
    ): ManagedObjectUploadReceipt = unsupported()

    override suspend fun completeChunk(
        authorization: ManagedAuthorization,
        chunkId: UUID,
        receipt: ManagedObjectUploadReceipt,
    ) = unsupported()

    override suspend fun changes(
        authorization: ManagedAuthorization,
        afterSequence: Long,
        limit: Int,
    ): ManagedChangeFeed = unsupported()

    override suspend fun createRestore(
        authorization: ManagedAuthorization,
        requestId: UUID,
        dataClasses: List<String>,
    ): ManagedRestoreJob = restore("running", 0, 0)

    override suspend fun availableChunks(
        authorization: ManagedAuthorization,
        dataClass: String,
        snapshotAt: String,
        after: ManagedChunkCursor?,
        limit: Int,
    ): ManagedChunkPage {
        chunkStarts += after?.afterChunkId
        if (failFirstChunkPageAuthentication) {
            failFirstChunkPageAuthentication = false
            throw ManagedStorageException.Authentication()
        }
        val start = after?.let { cursor ->
            chunks.indexOfFirst { it.chunkId == cursor.afterChunkId }
                .takeIf { it >= 0 }
                ?.plus(1)
        } ?: 0
        val page = chunks.drop(start).take(forcePageSize ?: limit)
        val hasMore = start + page.size < chunks.size
        return ManagedChunkPage(
            page,
            if (hasMore) {
                page.last().let { ManagedChunkCursor(it.eventStart, it.chunkId) }
            } else {
                null
            },
        )
    }

    override suspend fun completeRestore(
        authorization: ManagedAuthorization,
        restoreJobId: UUID,
        deliveredObjects: Int,
        deliveredBytes: Long,
    ): ManagedRestoreJob {
        completion = Completion(deliveredObjects, deliveredBytes)
        return restore("completed", deliveredObjects, deliveredBytes)
    }

    override suspend fun downloadCapability(
        authorization: ManagedAuthorization,
        chunkId: UUID,
        requestId: UUID,
    ): ManagedDownloadCapability {
        val chunk = chunks.first { it.chunkId == chunkId }
        return ManagedDownloadCapability(
            grantId = UUID.randomUUID(),
            method = "GET",
            url = "https://storage.googleapis.com/noop/$chunkId",
            headers = emptyMap(),
            expiresAt = "2026-09-05T00:00:00Z",
            chunkId = chunkId,
            expectedSha256 = chunk.expectedSha256,
            compression = chunk.compression,
            contentType = chunk.contentType,
            expectedUncompressedBytes = chunk.expectedUncompressedBytes,
        )
    }

    override suspend fun download(capability: ManagedDownloadCapability): ByteArray =
        chunkData[capability.chunkId] ?: throw ManagedStorageException.NotFound()

    override suspend fun documents(
        authorization: ManagedAuthorization,
        snapshotAt: String,
        after: ManagedDocumentCursor?,
        limit: Int,
    ): ManagedDocumentPage {
        documentStarts += after?.afterDocumentId
        val start = after?.let { cursor ->
            documents.indexOfFirst { it.documentId == cursor.afterDocumentId }
                .takeIf { it >= 0 }
                ?.plus(1)
        } ?: 0
        val page = documents.drop(start).take(forcePageSize ?: limit)
        val hasMore = start + page.size < documents.size
        return ManagedDocumentPage(
            page,
            if (hasMore) page.last().pageCursor() else null,
        )
    }

    private fun restore(
        status: String,
        deliveredObjects: Int,
        deliveredBytes: Long,
    ) = ManagedRestoreJob(
        restoreJobId = restoreId,
        status = status,
        snapshotAt = snapshot,
        changeSequence = 42,
        selectedObjects = chunks.size + documents.size + selectedObjectDelta,
        selectedBytes = chunks.sumOf { it.expectedCompressedBytes.toLong() },
        deliveredObjects = deliveredObjects,
        deliveredBytes = deliveredBytes,
        expiresAt = "2026-09-05T00:00:00Z",
        duplicate = false,
    )

    private fun unsupported(): Nothing = throw ManagedStorageException.InvalidResponse()
}
