package com.noop.managed

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ManagedHistoryArchiveStagingTest {
    @Test
    fun cancellationDuringCopyCleansTemporaryAndPreservesPreviousState() = runTest {
        val root = Files.createTempDirectory("noop-managed-stage-cancel-").toFile()
        try {
            val source = File(root, "selected.zip")
            writeArchive(source, payloadByte = 0x41, payloadSize = 64 * 1_024)
            val temporary = File(root, "import.zip.tmp")
            val importArchive = File(root, "import.zip").apply {
                writeBytes("previous archive".toByteArray())
            }
            val previousArchive = importArchive.readBytes()
            val importArchiveBackup = File(root, "import.zip.previous")
            val checkpointFile = File(root, "import-checkpoint.json")
            val checkpoint = ManagedHistoryImportCheckpoint(
                archiveSha256 = "a".repeat(64),
                nextObjectIndex = 1,
                importedObjects = 1,
                importedChunkBytes = 128,
            )
            checkpointFile.writeBytes(checkpoint.encoded())
            val previousCheckpoint = checkpointFile.readBytes()
            var copiedBytes = 0L

            lateinit var staging: Deferred<ManagedHistoryFileArchiveReader>
            val sourceInput = FileInputStream(source)
            val cancelingInput = object : InputStream() {
                override fun read(): Int {
                    val value = sourceInput.read()
                    return cancelAfterRead(if (value >= 0) 1 else value)
                }

                override fun read(
                    buffer: ByteArray,
                    offset: Int,
                    length: Int,
                ): Int {
                    val count = sourceInput.read(buffer, offset, length)
                    return cancelAfterRead(count)
                }

                override fun close() {
                    sourceInput.close()
                }

                private fun cancelAfterRead(count: Int): Int {
                    if (count > 0 && copiedBytes == 0L) {
                        copiedBytes = count.toLong()
                        staging.cancel()
                    }
                    return count
                }
            }
            staging = async(start = CoroutineStart.LAZY) {
                cancelingInput.use { input ->
                    stageManagedHistoryImportArchive(
                        input = input,
                        temporary = temporary,
                        importArchive = importArchive,
                        importArchiveBackup = importArchiveBackup,
                        loadCheckpoint = {
                            ManagedHistoryImportCheckpoint.decode(
                                checkpointFile.readBytes(),
                            )
                        },
                        clearCheckpoint = checkpointFile::delete,
                    )
                }
            }
            staging.start()

            try {
                staging.await()
                fail("Expected staging cancellation")
            } catch (_: CancellationException) {
                // Expected.
            }

            assertTrue(copiedBytes > 0)
            assertTrue(copiedBytes < source.length())
            assertFalse(temporary.exists())
            assertArrayEquals(previousArchive, importArchive.readBytes())
            assertFalse(importArchiveBackup.exists())
            assertArrayEquals(previousCheckpoint, checkpointFile.readBytes())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun committedArchiveKeepsMatchingCheckpointAndClearsDifferentCheckpoint() = runTest {
        val root = Files.createTempDirectory("noop-managed-stage-resume-").toFile()
        try {
            val firstSource = File(root, "first.zip")
            val firstManifest = writeArchive(
                firstSource,
                payloadByte = 0x31,
                payloadSize = 32 * 1_024,
                objectSuffix = 1,
            )
            val importArchive = File(root, "import.zip")
            val importArchiveBackup = File(root, "import.zip.previous")
            val checkpointFile = File(root, "import-checkpoint.json")
            val matchingCheckpoint = ManagedHistoryImportCheckpoint(
                archiveSha256 = ManagedDigest.sha256(firstManifest.encoded()),
                nextObjectIndex = 1,
                importedObjects = 1,
                importedChunkBytes = firstManifest.exportedChunkBytes,
            )
            checkpointFile.writeBytes(matchingCheckpoint.encoded())

            FileInputStream(firstSource).use { input ->
                stageManagedHistoryImportArchive(
                    input = input,
                    temporary = File(root, "first.tmp"),
                    importArchive = importArchive,
                    importArchiveBackup = importArchiveBackup,
                    loadCheckpoint = {
                        ManagedHistoryImportCheckpoint.decode(
                            checkpointFile.readBytes(),
                        )
                    },
                    clearCheckpoint = checkpointFile::delete,
                )
            }
            assertTrue(checkpointFile.isFile)
            assertEquals(
                matchingCheckpoint,
                ManagedHistoryImportCheckpoint.decode(checkpointFile.readBytes()),
            )

            val secondSource = File(root, "second.zip")
            writeArchive(
                secondSource,
                payloadByte = 0x32,
                payloadSize = 32 * 1_024,
                objectSuffix = 2,
            )
            FileInputStream(secondSource).use { input ->
                stageManagedHistoryImportArchive(
                    input = input,
                    temporary = File(root, "second.tmp"),
                    importArchive = importArchive,
                    importArchiveBackup = importArchiveBackup,
                    loadCheckpoint = {
                        ManagedHistoryImportCheckpoint.decode(
                            checkpointFile.readBytes(),
                        )
                    },
                    clearCheckpoint = checkpointFile::delete,
                )
            }

            assertFalse(checkpointFile.exists())
            assertFalse(importArchiveBackup.exists())
            assertArrayEquals(secondSource.readBytes(), importArchive.readBytes())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun writeArchive(
        destination: File,
        payloadByte: Int,
        payloadSize: Int,
        objectSuffix: Int = 1,
    ): ManagedHistoryExportManifest {
        val chunkId = UUID.fromString(
            "10000000-0000-5000-8000-${objectSuffix.toString().padStart(12, '0')}",
        )
        val sourceId = UUID.fromString("aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa")
        val payload = ByteArray(payloadSize) { payloadByte.toByte() }
        val path = "chunks/essential_timeseries/" +
            "${chunkId.toString().lowercase()}.json"
        val chunk = ManagedHistoryExportChunk(
            path = path,
            chunkId = chunkId,
            sourceId = sourceId,
            dataClass = "essential_timeseries",
            schemaVersion = 1,
            eventStart = Instant.parse("2026-09-04T11:00:00Z").toString(),
            eventEnd = Instant.parse("2026-09-04T11:01:00Z").toString(),
            compression = "none",
            contentType = "application/vnd.noop.chunk+json",
            sha256 = ManagedDigest.sha256(payload),
            compressedBytes = payload.size,
            uncompressedBytes = payload.size,
            objectGeneration = objectSuffix.toLong(),
        )
        val manifest = ManagedHistoryExportManifest(
            format = "noop_managed_history",
            formatVersion = 1,
            createdAt = "2026-09-04T12:00:00Z",
            snapshotAt = "2026-09-04T11:59:00Z",
            changeSequence = objectSuffix.toLong(),
            dataClasses = listOf("essential_timeseries"),
            selectedObjects = 1,
            selectedChunkBytes = payload.size.toLong(),
            exportedObjects = 1,
            exportedChunkBytes = payload.size.toLong(),
            chunks = listOf(chunk),
            documents = emptyList(),
        )
        FileOutputStream(destination).use { output ->
            val writer = ManagedHistoryZipWriter(output)
            writer.add(
                ManagedHistoryExportEntry(
                    kind = ManagedHistoryExportEntryKind.CHUNK,
                    path = path,
                    data = payload,
                ),
            )
            writer.finish(manifest)
        }
        return manifest
    }
}
