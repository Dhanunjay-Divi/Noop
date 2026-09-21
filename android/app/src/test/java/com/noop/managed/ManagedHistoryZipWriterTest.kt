package com.noop.managed

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.zip.ZipInputStream

class ManagedHistoryZipWriterTest {
    @Test
    fun streamsEntriesAndWritesManifestLast() {
        val output = ByteArrayOutputStream()
        val writer = ManagedHistoryZipWriter(output)
        val chunk = ManagedHistoryExportEntry(
            kind = ManagedHistoryExportEntryKind.CHUNK,
            path = "chunks/essential_timeseries/chunk.json.gz",
            data = "compressed".toByteArray(),
        )
        writer.add(chunk)
        val expected = writer.finish(manifest())

        val entries = linkedMapOf<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(output.toByteArray())).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                entries[entry.name] = zip.readBytes()
                zip.closeEntry()
            }
        }
        assertEquals(expected, entries.keys)
        assertArrayEquals(chunk.data, entries[chunk.path])
        assertEquals("manifest.json", entries.keys.last())
    }

    @Test
    fun rejectsTraversalAndDuplicatePaths() {
        val writer = ManagedHistoryZipWriter(ByteArrayOutputStream())
        try {
            writer.add(
                ManagedHistoryExportEntry(
                    ManagedHistoryExportEntryKind.DOCUMENT,
                    "../health.json",
                    ByteArray(0),
                ),
            )
            fail("Expected traversal rejection")
        } catch (_: IllegalArgumentException) {
            // Expected.
        }

        val valid = ManagedHistoryExportEntry(
            ManagedHistoryExportEntryKind.DOCUMENT,
            "documents/journal/entry.json",
            ByteArray(0),
        )
        writer.add(valid)
        try {
            writer.add(valid)
            fail("Expected duplicate rejection")
        } catch (_: IllegalArgumentException) {
            // Expected.
        } finally {
            writer.abort()
        }
    }

    @Test
    fun fileReaderReturnsExactEntriesAndEnforcesReadLimit() {
        val file = kotlin.io.path.createTempFile(
            "noop-managed-history-",
            ".zip",
        ).toFile()
        try {
            val chunk = ManagedHistoryExportEntry(
                kind = ManagedHistoryExportEntryKind.CHUNK,
                path = "chunks/essential_timeseries/chunk.json",
                data = "canonical".toByteArray(),
            )
            FileOutputStream(file).use { output ->
                val writer = ManagedHistoryZipWriter(output)
                writer.add(chunk)
                writer.finish(manifest())
            }

            val reader = ManagedHistoryFileArchiveReader(file)
            assertEquals(
                setOf(chunk.path, "manifest.json"),
                reader.entryPaths().toSet(),
            )
            assertArrayEquals(
                chunk.data,
                reader.data(chunk.path, chunk.data.size),
            )
            try {
                reader.data(chunk.path, chunk.data.size - 1)
                fail("Expected bounded read rejection")
            } catch (_: IOException) {
                // Expected.
            }
        } finally {
            file.delete()
        }
    }

    private fun manifest() = ManagedHistoryExportManifest(
        format = "noop_managed_history",
        formatVersion = 1,
        createdAt = "2026-09-04T12:00:00Z",
        snapshotAt = "2026-09-04T11:59:00Z",
        changeSequence = 42,
        dataClasses = listOf("essential_timeseries"),
        selectedObjects = 1,
        selectedChunkBytes = 10,
        exportedObjects = 1,
        exportedChunkBytes = 10,
        chunks = emptyList(),
        documents = emptyList(),
    )
}
