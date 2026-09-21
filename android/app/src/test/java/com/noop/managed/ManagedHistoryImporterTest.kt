package com.noop.managed

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.util.UUID

class ManagedHistoryImporterTest {
    @Test
    fun validV2ArchiveImportsEveryChunkAndReportsIntegrityIdentity() = runTest {
        val fixture = fixture(listOf(68, 72))
        val restore = ImportRestoreRecorder()

        val summary = importFixture(fixture, restore = restore)

        assertEquals(2, summary.importedObjects)
        assertEquals(fixture.manifest.exportedChunkBytes, summary.importedChunkBytes)
        assertFalse(summary.resumed)
        assertEquals(
            ManagedDigest.sha256(fixture.manifest.encoded()),
            summary.archiveSha256,
        )
        assertEquals(
            fixture.manifest.chunks.map { it.chunkId },
            restore.chunkIds,
        )
    }

    @Test
    fun corruptLaterEntryFailsBeforeAnyLocalMutation() = runTest {
        val fixture = fixture(listOf(68, 72))
        fixture.entries[fixture.manifest.chunks[1].path] = "corrupt".toByteArray()
        val restore = ImportRestoreRecorder()

        try {
            importFixture(fixture, restore = restore)
            fail("Expected archive integrity failure")
        } catch (_: ManagedStorageException.DigestMismatch) {
            // Expected.
        }

        assertTrue(restore.chunkIds.isEmpty())
        assertEquals(0, restore.calls)
    }

    @Test
    fun importResumesAfterCheckpointAndCompletedReplayIsIdempotent() = runTest {
        val fixture = fixture(listOf(68, 72))
        val restore = ImportRestoreRecorder()
        var checkpoint: ManagedHistoryImportCheckpoint? = null
        var interrupt = true

        try {
            importFixture(
                fixture,
                restore = restore,
                saveCheckpoint = { value ->
                    checkpoint = value
                    if (interrupt && value.nextObjectIndex == 1) {
                        interrupt = false
                        throw ImportTestInterruption()
                    }
                },
            )
            fail("Expected interruption")
        } catch (_: ImportTestInterruption) {
            // Expected.
        }

        val durable = requireNotNull(checkpoint)
        assertEquals(1, durable.nextObjectIndex)
        assertEquals(1, restore.calls)

        val resumed = importFixture(
            fixture,
            resumeFrom = durable,
            restore = restore,
            saveCheckpoint = { checkpoint = it },
        )
        assertTrue(resumed.resumed)
        assertEquals(2, restore.calls)
        assertEquals(
            fixture.manifest.chunks.map { it.chunkId },
            restore.chunkIds,
        )

        val completed = requireNotNull(checkpoint)
        assertTrue(completed.completed)
        importFixture(
            fixture,
            resumeFrom = completed,
            restore = restore,
        )
        assertEquals(2, restore.calls)
    }

    @Test
    fun checkpointFromDifferentArchiveFailsWithConflict() = runTest {
        val first = fixture(listOf(68, 72))
        val second = fixture(listOf(68, 73))
        val checkpoint = ManagedHistoryImportCheckpoint(
            archiveSha256 = ManagedDigest.sha256(first.manifest.encoded()),
        )
        val restore = ImportRestoreRecorder()

        try {
            importFixture(
                second,
                resumeFrom = checkpoint,
                restore = restore,
            )
            fail("Expected checkpoint conflict")
        } catch (_: ManagedStorageException.Conflict) {
            // Expected.
        }
        assertEquals(0, restore.calls)
    }

    @Test
    fun accountFenceStopsImportBeforeAnyLocalMutation() = runTest {
        val fixture = fixture(listOf(68, 72))
        val restore = ImportRestoreRecorder()
        var validations = 0

        try {
            ManagedHistoryImporter().importArchive(
                manifestData = fixture.manifest.encoded(),
                entryPaths = fixture.entries.keys.toList() + "manifest.json",
                restore = restore,
                operationValidator = {
                    validations += 1
                    if (validations == 3) {
                        throw CancellationException("account changed")
                    }
                },
                read = { path, maximumBytes ->
                    fixture.entries[path]
                        ?.takeIf { it.size <= maximumBytes }
                        ?: throw ManagedStorageException.InvalidResponse()
                },
            )
            fail("Expected account-fence cancellation")
        } catch (_: CancellationException) {
            // Expected.
        }

        assertEquals(0, restore.calls)
    }

    @Test
    fun legacyV1ManifestRemainsImportable() = runTest {
        val fixture = fixture(listOf(68), formatVersion = 1)
        val restore = ImportRestoreRecorder()

        val summary = importFixture(fixture, restore = restore)

        assertEquals(1, summary.importedObjects)
        assertEquals(1, restore.calls)
    }

    private suspend fun importFixture(
        fixture: ImportFixture,
        resumeFrom: ManagedHistoryImportCheckpoint? = null,
        restore: ManagedRestoreApplying,
        saveCheckpoint: suspend (ManagedHistoryImportCheckpoint) -> Unit = {},
    ): ManagedHistoryImportSummary =
        ManagedHistoryImporter().importArchive(
            manifestData = fixture.manifest.encoded(),
            entryPaths = fixture.entries.keys.toList() + "manifest.json",
            resumeFrom = resumeFrom,
            restore = restore,
            saveCheckpoint = saveCheckpoint,
            read = { path, maximumBytes ->
                fixture.entries[path]
                    ?.takeIf { it.size <= maximumBytes }
                    ?: throw ManagedStorageException.InvalidResponse()
            },
        )

    private fun fixture(
        bpms: List<Int>,
        formatVersion: Int = 2,
    ): ImportFixture {
        val sourceId = UUID.fromString("fe5d19f4-b8ea-4c97-9c3f-e6532f083883")
        val records = mutableListOf<ManagedHistoryExportChunk>()
        val entries = linkedMapOf<String, ByteArray>()
        bpms.forEachIndexed { index, bpm ->
            val start = 1_788_436_800_000L + index * 3_600_000L
            val prepared = requireNotNull(
                ManagedPreparedChunk.prepare(
                    sourceId = sourceId,
                    dataClass = "essential_timeseries",
                    eventStartMs = start,
                    eventEndMs = start + 999,
                    streams = listOf(
                        ManagedChunkStreamPayload(
                            streamKey = "heart_rate",
                            columns = listOf(
                                "event_at_ms",
                                "bpm",
                                "quality",
                                "provenance",
                            ),
                            rows = listOf(
                                listOf(
                                    ManagedJsonValue.IntegerValue(start),
                                    ManagedJsonValue.IntegerValue(bpm.toLong()),
                                    ManagedJsonValue.NullValue,
                                    ManagedJsonValue.StringValue("sensor"),
                                ),
                            ),
                        ),
                    ),
                ),
            )
            val path = "chunks/essential_timeseries/" +
                "${prepared.chunkId.toString().lowercase()}.json"
            entries[path] = prepared.uncompressed
            records += ManagedHistoryExportChunk(
                path = path,
                chunkId = prepared.chunkId,
                sourceId = prepared.sourceId,
                dataClass = prepared.dataClass,
                schemaVersion = 1,
                eventStart = Instant.ofEpochMilli(start).toString(),
                eventEnd = Instant.ofEpochMilli(start + 999).toString(),
                compression = "none",
                contentType = "application/vnd.noop.chunk+json",
                sha256 = ManagedDigest.sha256(prepared.uncompressed),
                compressedBytes = prepared.uncompressed.size,
                uncompressedBytes = prepared.uncompressed.size,
                objectGeneration = 1,
            )
        }
        val bytes = records.sumOf { it.compressedBytes.toLong() }
        val integrity = if (formatVersion == 2) {
            ManagedHistoryExportIntegrity(
                algorithm = "sha256",
                entryCount = records.size,
                entriesSha256 = ManagedHistoryArchiveIntegrity.entriesSha256(
                    records,
                    emptyList(),
                ),
            )
        } else {
            null
        }
        val cursor = if (formatVersion == 2) {
            ManagedHistorySnapshotCursor(
                formatVersion = 1,
                snapshotAt = "2026-09-04T11:59:00Z",
                changeSequence = 42,
            )
        } else {
            null
        }
        val manifest = ManagedHistoryExportManifest(
            format = "noop_managed_history",
            formatVersion = formatVersion,
            createdAt = "2026-09-04T12:00:00Z",
            snapshotAt = "2026-09-04T11:59:00Z",
            changeSequence = 42,
            dataClasses = listOf("essential_timeseries"),
            selectedObjects = records.size,
            selectedChunkBytes = bytes,
            exportedObjects = records.size,
            exportedChunkBytes = bytes,
            chunks = records,
            documents = emptyList(),
            integrity = integrity,
            snapshotCursor = cursor,
        )
        return ImportFixture(manifest, entries)
    }
}

private data class ImportFixture(
    val manifest: ManagedHistoryExportManifest,
    val entries: MutableMap<String, ByteArray>,
)

private class ImportTestInterruption : RuntimeException()

private class ImportRestoreRecorder : ManagedRestoreApplying {
    val chunkIds = mutableListOf<UUID>()
    var calls = 0

    override suspend fun apply(
        chunk: ManagedChunkPayload,
        change: ManagedChange,
    ) {
        @Suppress("UNUSED_VARIABLE")
        val ignored = change
        calls += 1
        if (chunk.chunkId !in chunkIds) {
            chunkIds += chunk.chunkId
        }
    }

    override suspend fun hydrate(
        chunk: ManagedChunkPayload,
        source: ManagedSourceDescriptor,
    ) {
        @Suppress("UNUSED_VARIABLE")
        val ignored = chunk to source
    }

    override suspend fun apply(
        document: ManagedDocument,
        change: ManagedChange,
    ) {
        @Suppress("UNUSED_VARIABLE")
        val ignored = document to change
        calls += 1
    }
}
