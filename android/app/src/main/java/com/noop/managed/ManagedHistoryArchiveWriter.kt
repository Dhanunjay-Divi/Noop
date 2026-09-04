package com.noop.managed

import android.content.Context
import android.net.Uri
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

internal class ManagedHistoryZipWriter(
    output: OutputStream,
) {
    private val zip = ZipOutputStream(BufferedOutputStream(output)).apply {
        setLevel(Deflater.NO_COMPRESSION)
    }
    private val entryPaths = linkedSetOf<String>()
    private var finished = false

    fun add(entry: ManagedHistoryExportEntry) {
        add(entry.path, entry.data)
    }

    fun finish(manifest: ManagedHistoryExportManifest): Set<String> {
        check(!finished) { "Managed history archive is already finalized." }
        try {
            add("manifest.json", manifest.encoded())
            zip.finish()
            zip.close()
            finished = true
            return entryPaths.toSet()
        } catch (error: Throwable) {
            abort()
            throw error
        }
    }

    fun abort() {
        if (!finished) {
            runCatching { zip.close() }
            finished = true
        }
    }

    private fun add(path: String, data: ByteArray) {
        check(!finished) { "Managed history archive is already finalized." }
        require(valid(path)) { "Invalid managed history archive path." }
        require(entryPaths.add(path)) { "Duplicate managed history archive path." }
        try {
            zip.putNextEntry(ZipEntry(path))
            zip.write(data)
            zip.closeEntry()
        } catch (error: Throwable) {
            entryPaths.remove(path)
            throw error
        }
    }

    private fun valid(path: String): Boolean =
        path.isNotEmpty() &&
            !path.startsWith("/") &&
            !path.endsWith("/") &&
            !path.contains('\\') &&
            !path.contains('\u0000') &&
            path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
}

internal class ManagedHistorySafArchiveWriter(
    private val context: Context,
    private val destination: Uri,
) {
    private val resolver = context.contentResolver
    private val writer = ManagedHistoryZipWriter(
        resolver.openOutputStream(destination, "wt")
            ?: throw IOException("The selected export file could not be opened."),
    )
    private var finished = false

    fun add(entry: ManagedHistoryExportEntry) {
        check(!finished)
        writer.add(entry)
    }

    fun finish(manifest: ManagedHistoryExportManifest) {
        check(!finished)
        val expected = writer.finish(manifest)
        finished = true
        val actual = verifyArchive()
        if (actual.size != expected.size || actual.toSet() != expected) {
            throw IOException("The exported archive did not pass its final integrity check.")
        }
    }

    fun abort() {
        writer.abort()
        finished = true
        removePartial(context, destination)
    }

    private fun verifyArchive(): List<String> {
        val input = resolver.openInputStream(destination)
            ?: throw IOException("The exported archive could not be reopened.")
        val names = mutableListOf<String>()
        ZipInputStream(BufferedInputStream(input)).use { zip ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val entry = zip.nextEntry ?: break
                if (!entry.isDirectory) {
                    names += entry.name
                    while (zip.read(buffer) >= 0) {
                        // Drain each entry so ZipInputStream verifies its CRC and structure.
                    }
                }
                zip.closeEntry()
            }
        }
        return names
    }

    companion object {
        fun removePartial(context: Context, destination: Uri) {
            val resolver = context.contentResolver
            runCatching {
                resolver.openOutputStream(destination, "wt")?.use { }
            }
            runCatching { resolver.delete(destination, null, null) }
        }
    }
}
