package com.noop.managed

import android.content.Context
import android.net.Uri
import android.util.AtomicFile
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
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

    fun add(path: String, data: ByteArray) {
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

internal class ManagedHistoryFileArchiveReader(
    private val source: File,
) {
    init {
        if (!source.isFile) throw IOException("Managed history archive is unavailable.")
    }

    fun entryPaths(): List<String> = ZipFile(source).use { zip ->
        val paths = zip.entries().asSequence()
            .filterNot { it.isDirectory }
            .map { it.name }
            .toList()
        if (paths.size != paths.toSet().size ||
            paths.any { !validPath(it) } ||
            "manifest.json" !in paths
        ) {
            throw IOException("Managed history archive is invalid.")
        }
        paths
    }

    fun manifestData(): ByteArray = data("manifest.json", MAX_MANIFEST_BYTES)

    fun data(path: String, maximumBytes: Int): ByteArray {
        if (!validPath(path) || maximumBytes < 0) {
            throw IOException("Managed history archive path is invalid.")
        }
        return ZipFile(source).use { zip ->
            val entry = zip.getEntry(path)
                ?: throw IOException("Managed history archive entry is missing.")
            if (entry.isDirectory || entry.size < 0 || entry.size > maximumBytes) {
                throw IOException("Managed history archive entry is too large.")
            }
            zip.getInputStream(entry).use { input ->
                readCapped(input, maximumBytes)
            }
        }
    }

    private companion object {
        const val MAX_MANIFEST_BYTES = 8 * 1_024 * 1_024
    }
}

internal class ManagedHistoryTransferStore(
    context: Context,
    accountScopeHash: String,
) {
    private val appContext = context.applicationContext
    private val root: File
    private val exportEntries: File
    private val exportCheckpoint: AtomicFile
    private val importArchive: File
    private val importArchiveBackup: File
    private val importCheckpoint: AtomicFile

    init {
        if (!accountScopeHash.matches(SHA256)) {
            throw IOException("Managed history transfer scope is invalid.")
        }
        root = File(
            appContext.noBackupFilesDir,
            "managed-history-transfers/$accountScopeHash",
        )
        exportEntries = File(root, "export-entries")
        exportCheckpoint = AtomicFile(File(root, "export-checkpoint.json"))
        importArchive = File(root, "import.zip")
        importArchiveBackup = File(root, "import.zip.previous")
        importCheckpoint = AtomicFile(File(root, "import-checkpoint.json"))
        if (!root.exists() && !root.mkdirs()) {
            throw IOException("Managed history transfer storage is unavailable.")
        }
        if (!importArchive.isFile && importArchiveBackup.isFile) {
            if (!importArchiveBackup.renameTo(importArchive)) {
                throw IOException("Managed history import recovery failed.")
            }
        } else {
            importArchiveBackup.delete()
        }
    }

    fun add(entry: ManagedHistoryExportEntry) {
        val destination = entryFile(entry.path)
        if (destination.isFile) {
            val existing = FileInputStream(destination).use {
                readCapped(it, entry.data.size)
            }
            if (!existing.contentEquals(entry.data)) {
                throw ManagedStorageException.Conflict()
            }
            return
        }
        destination.parentFile?.let {
            if (!it.exists() && !it.mkdirs()) {
                throw IOException("Managed history transfer storage is unavailable.")
            }
        }
        val temporary = File(destination.parentFile, "${destination.name}.tmp")
        try {
            FileOutputStream(temporary).use { output ->
                output.write(entry.data)
                output.fd.sync()
            }
            if (!temporary.renameTo(destination)) {
                throw IOException("Managed history transfer entry was not committed.")
            }
        } finally {
            temporary.delete()
        }
    }

    fun readExport(path: String, maximumBytes: Int): ByteArray {
        val source = entryFile(path)
        if (!source.isFile || source.length() > maximumBytes) {
            throw IOException("Managed history transfer entry is unavailable.")
        }
        return FileInputStream(source).use { readCapped(it, maximumBytes) }
    }

    fun loadExportCheckpoint(): ManagedHistoryExportCheckpoint? =
        readAtomic(exportCheckpoint)?.let(ManagedHistoryExportCheckpoint::decode)

    fun saveExportCheckpoint(checkpoint: ManagedHistoryExportCheckpoint) {
        writeAtomic(exportCheckpoint, checkpoint.encoded())
    }

    fun loadImportCheckpoint(): ManagedHistoryImportCheckpoint? =
        readAtomic(importCheckpoint)?.let(ManagedHistoryImportCheckpoint::decode)

    fun saveImportCheckpoint(checkpoint: ManagedHistoryImportCheckpoint) {
        writeAtomic(importCheckpoint, checkpoint.encoded())
    }

    fun publishExport(
        destination: Uri,
        manifest: ManagedHistoryExportManifest,
    ) {
        val expected = (
            manifest.chunks.map(ManagedHistoryExportChunk::path) +
                manifest.documents.map(ManagedHistoryExportDocument::path)
            ).toSet()
        val actual = if (exportEntries.isDirectory) {
            exportEntries.walkTopDown()
                .filter(File::isFile)
                .map { it.relativeTo(exportEntries).invariantSeparatorsPath }
                .toSet()
        } else {
            emptySet()
        }
        if (expected.size != manifest.exportedObjects || actual != expected) {
            throw ManagedHistoryExportStateException(
                IOException("Managed history staged entries are inconsistent."),
            )
        }
        val writer = ManagedHistorySafArchiveWriter(appContext, destination)
        try {
            manifest.chunks.forEach { chunk ->
                val data = try {
                    readExport(chunk.path, chunk.compressedBytes)
                } catch (error: Throwable) {
                    throw ManagedHistoryExportStateException(error)
                }
                if (data.size != chunk.compressedBytes ||
                    ManagedDigest.sha256(data) != chunk.sha256
                ) {
                    throw ManagedHistoryExportStateException(
                        IOException("Managed history staged entry failed validation."),
                    )
                }
                writer.add(
                    ManagedHistoryExportEntry(
                        ManagedHistoryExportEntryKind.CHUNK,
                        chunk.path,
                        data,
                    ),
                )
            }
            manifest.documents.forEach { document ->
                val data = try {
                    readExport(document.path, document.archiveBytes)
                } catch (error: Throwable) {
                    throw ManagedHistoryExportStateException(error)
                }
                if (data.size != document.archiveBytes ||
                    ManagedDigest.sha256(data) != document.archiveSha256
                ) {
                    throw ManagedHistoryExportStateException(
                        IOException("Managed history staged entry failed validation."),
                    )
                }
                writer.add(
                    ManagedHistoryExportEntry(
                        ManagedHistoryExportEntryKind.DOCUMENT,
                        document.path,
                        data,
                    ),
                )
            }
            writer.finish(manifest)
            clearExport()
        } catch (error: Throwable) {
            writer.abort()
            throw error
        }
    }

    fun stageImport(source: Uri): ManagedHistoryFileArchiveReader {
        val temporary = File(root, "import.zip.tmp")
        try {
            appContext.contentResolver.openInputStream(source)?.use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_ARCHIVE_BYTES) {
                            throw IOException("Managed history archive is too large.")
                        }
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            } ?: throw IOException("Managed history archive could not be opened.")
            val stagedReader = ManagedHistoryFileArchiveReader(temporary)
            val stagedManifest = ManagedHistoryExportManifest.decode(
                stagedReader.manifestData(),
            )
            val stagedDigest = ManagedDigest.sha256(stagedManifest.encoded())
            val checkpoint = loadImportCheckpoint()

            importArchiveBackup.delete()
            if (importArchive.isFile && !importArchive.renameTo(importArchiveBackup)) {
                throw IOException("Managed history import could not be replaced.")
            }
            if (!temporary.renameTo(importArchive)) {
                if (importArchiveBackup.isFile) {
                    importArchiveBackup.renameTo(importArchive)
                }
                throw IOException("Managed history import was not committed.")
            }
            importArchiveBackup.delete()
            if (checkpoint != null && checkpoint.archiveSha256 != stagedDigest) {
                importCheckpoint.delete()
            }
            return ManagedHistoryFileArchiveReader(importArchive)
        } finally {
            temporary.delete()
        }
    }

    fun clearExport() {
        exportEntries.deleteRecursively()
        exportCheckpoint.delete()
    }

    fun clearImport() {
        importCheckpoint.delete()
        importArchive.delete()
        importArchiveBackup.delete()
        File(root, "import.zip.tmp").delete()
    }

    private fun entryFile(path: String): File {
        if (!validPath(path) || path == "manifest.json") {
            throw IOException("Managed history transfer path is invalid.")
        }
        val candidate = File(exportEntries, path).canonicalFile
        val parent = exportEntries.canonicalFile
        if (!candidate.path.startsWith(parent.path + File.separator)) {
            throw IOException("Managed history transfer path is invalid.")
        }
        return candidate
    }

    private fun readAtomic(file: AtomicFile): ByteArray? {
        if (!file.baseFile.isFile) return null
        return file.openRead().use { readCapped(it, MAX_CHECKPOINT_BYTES) }
    }

    private fun writeAtomic(file: AtomicFile, data: ByteArray) {
        if (data.size > MAX_CHECKPOINT_BYTES) {
            throw IOException("Managed history checkpoint is too large.")
        }
        val output = file.startWrite()
        try {
            output.write(data)
            output.fd.sync()
            file.finishWrite(output)
        } catch (error: Throwable) {
            file.failWrite(output)
            throw error
        }
    }

    private companion object {
        val SHA256 = Regex("^[0-9a-f]{64}$")
        const val MAX_CHECKPOINT_BYTES = 8 * 1_024 * 1_024
        const val MAX_ARCHIVE_BYTES = 32L * 1_024 * 1_024 * 1_024
    }
}

private fun validPath(path: String): Boolean =
    path.isNotEmpty() &&
        !path.startsWith("/") &&
        !path.endsWith("/") &&
        !path.contains('\\') &&
        !path.contains('\u0000') &&
        path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

private fun readCapped(
    input: java.io.InputStream,
    maximumBytes: Int,
): ByteArray {
    val output = java.io.ByteArrayOutputStream(minOf(maximumBytes, DEFAULT_BUFFER_SIZE))
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) break
        if (output.size() > maximumBytes - count) {
            throw IOException("Managed history archive entry is too large.")
        }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
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
