package com.noop.feedback

import com.noop.AppDiagnosticsRecorder
import com.noop.testcentre.DisplayScreenshot
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

internal data class FeedbackArchiveDescriptor(
    val bytes: Long,
    val sha256: String,
    val includesUserNote: Boolean,
    val includesScreenshot: Boolean,
)

internal class FeedbackArchiveException(
    val reason: Reason,
) : Exception("Feedback archive rejected: ${reason.wireValue}") {
    enum class Reason(val wireValue: String) {
        EMPTY("empty"),
        UNKNOWN_ENTRY("unknown_entry"),
        UNSAFE_ENTRY_NAME("unsafe_entry_name"),
        DUPLICATE_ENTRY("duplicate_entry"),
        RAW_HEALTH_OR_DATABASE("raw_health_or_database"),
        ENTRY_TOO_LARGE("entry_too_large"),
        ARCHIVE_TOO_LARGE("archive_too_large"),
        INVALID_TEXT("invalid_text"),
        INVALID_SCREENSHOT("invalid_screenshot"),
        CONSENT_MISMATCH("consent_mismatch"),
        REQUIRED_ENTRY_MISSING("required_entry_missing"),
        WRITE_FAILED("write_failed"),
        DIGEST_MISMATCH("digest_mismatch"),
    }
}

/**
 * The direct-feedback boundary is intentionally narrower than the existing local diagnostic exports.
 * Only these reviewed app-report files may enter the immutable outbox ZIP. Raw Android ANR traces are
 * deliberately omitted because the OS trace can contain arbitrary text that the user cannot review
 * inline; the bounded exit-history category remains available.
 */
internal object FeedbackArchive {
    const val MAX_ARCHIVE_BYTES = 20L * 1024L * 1024L
    const val MAX_ENTRY_COUNT = 10

    private const val MAX_TEXT_ENTRY_BYTES = 1024 * 1024
    private const val MAX_SCREENSHOT_BYTES = 8 * 1024 * 1024
    private val pngSignature =
        byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    private val sqliteSignature = "SQLite format 3\u0000".toByteArray(Charsets.US_ASCII)

    private val allowedEntries = setOf(
        "report.txt",
        "user-note.txt",
        AppDiagnosticsRecorder.CURRENT_SESSION_ENTRY,
        AppDiagnosticsRecorder.PREVIOUS_SESSION_ENTRY,
        AppDiagnosticsRecorder.EXIT_HISTORY_ENTRY,
        "last-crash.txt",
        DisplayScreenshot.BUNDLE_NAME,
        "meta.json",
    )
    private val deliberatelyExcludedEntries = setOf(
        AppDiagnosticsRecorder.LAST_ANR_ENTRY,
    )
    private val forbiddenNameFragments = setOf(
        "health",
        "sensor",
        "biometric",
        "raw-capture",
        "raw_capture",
        "raw-sensors",
        "raw_sensors",
    )
    private val forbiddenSuffixes = setOf(
        ".db",
        ".db3",
        ".sqlite",
        ".sqlite3",
        "-wal",
        "-shm",
    )

    data class PreparedEntries(
        val entries: List<Pair<String, ByteArray>>,
        val excludedUnsafeEntryCount: Int,
    )

    /**
     * Produces the exact attachment list shown in the review sheet. Unknown entries fail closed; only
     * the fixed raw-ANR attachment is intentionally removed before review and staging.
     */
    fun prepareForReview(entries: List<Pair<String, ByteArray>>): PreparedEntries {
        if (entries.isEmpty()) throw FeedbackArchiveException(FeedbackArchiveException.Reason.EMPTY)
        val seen = linkedSetOf<String>()
        var excluded = 0
        val prepared = ArrayList<Pair<String, ByteArray>>(entries.size)
        entries.forEach { (name, bytes) ->
            validateNameShape(name)
            val canonical = name.lowercase(Locale.US)
            if (!seen.add(canonical)) {
                throw FeedbackArchiveException(FeedbackArchiveException.Reason.DUPLICATE_ENTRY)
            }
            when {
                isForbiddenRawName(canonical) ->
                    throw FeedbackArchiveException(
                        FeedbackArchiveException.Reason.RAW_HEALTH_OR_DATABASE,
                    )
                name in deliberatelyExcludedEntries -> excluded += 1
                name !in allowedEntries ->
                    throw FeedbackArchiveException(FeedbackArchiveException.Reason.UNKNOWN_ENTRY)
                else -> {
                    val reviewedBytes = if (name == DisplayScreenshot.BUNDLE_NAME) {
                        FeedbackScreenshotSanitizer.sanitize(bytes)
                            ?: throw FeedbackArchiveException(
                                FeedbackArchiveException.Reason.INVALID_SCREENSHOT,
                            )
                    } else {
                        bytes.copyOf()
                    }
                    validateEntryBytes(name, reviewedBytes)
                    prepared += name to reviewedBytes
                }
            }
        }
        validatePreparedEntries(
            prepared,
            includesUserNote = prepared.any { it.first == "user-note.txt" },
            includesScreenshot = prepared.any { it.first == DisplayScreenshot.BUNDLE_NAME },
        )
        return PreparedEntries(prepared, excluded)
    }

    fun writeImmutable(
        destination: File,
        entries: List<Pair<String, ByteArray>>,
        includesUserNote: Boolean,
        includesScreenshot: Boolean,
    ): FeedbackArchiveDescriptor {
        validatePreparedEntries(entries, includesUserNote, includesScreenshot)
        if (destination.exists()) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.WRITE_FAILED)
        }
        val parent = destination.parentFile
            ?: throw FeedbackArchiveException(FeedbackArchiveException.Reason.WRITE_FAILED)
        if ((!parent.exists() && !parent.mkdirs()) || !parent.isDirectory) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.WRITE_FAILED)
        }
        val temporary = File(parent, ".archive-${UUID.randomUUID()}.tmp")
        try {
            FileOutputStream(temporary).use { fileOutput ->
                ZipOutputStream(fileOutput).use { zip ->
                    entries.forEach { (name, bytes) ->
                        val entry = ZipEntry(name).apply { time = 0L }
                        zip.putNextEntry(entry)
                        zip.write(bytes)
                        zip.closeEntry()
                    }
                    zip.finish()
                    zip.flush()
                    fileOutput.fd.sync()
                }
            }
            if (temporary.length() <= 0L || temporary.length() > MAX_ARCHIVE_BYTES) {
                throw FeedbackArchiveException(FeedbackArchiveException.Reason.ARCHIVE_TOO_LARGE)
            }
            validate(
                archive = temporary,
                expectedBytes = temporary.length(),
                expectedSha256 = null,
                includesUserNote = includesUserNote,
                includesScreenshot = includesScreenshot,
            )
            val digest = sha256(temporary)
            atomicMove(temporary, destination)
            destination.setReadOnly()
            return FeedbackArchiveDescriptor(
                bytes = destination.length(),
                sha256 = digest,
                includesUserNote = includesUserNote,
                includesScreenshot = includesScreenshot,
            )
        } catch (error: FeedbackArchiveException) {
            throw error
        } catch (_: Exception) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.WRITE_FAILED)
        } finally {
            temporary.delete()
        }
    }

    /**
     * Revalidates the sealed ZIP immediately before every upload. A changed file, duplicate/path entry,
     * unexpected attachment, zip bomb, consent mismatch, or raw health/database filename fails closed.
     */
    fun validate(
        archive: File,
        expectedBytes: Long,
        expectedSha256: String?,
        includesUserNote: Boolean,
        includesScreenshot: Boolean,
    ) {
        if (!archive.isFile ||
            archive.length() <= 0L ||
            archive.length() > MAX_ARCHIVE_BYTES ||
            archive.length() != expectedBytes
        ) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.ARCHIVE_TOO_LARGE)
        }
        if (expectedSha256 != null && sha256(archive) != expectedSha256) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.DIGEST_MISMATCH)
        }

        val seen = linkedSetOf<String>()
        var totalUncompressed = 0L
        var count = 0
        var hasNote = false
        var hasScreenshot = false
        var hasReport = false
        var hasMeta = false
        try {
            ZipInputStream(FileInputStream(archive).buffered()).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    count += 1
                    if (entry.isDirectory || count > MAX_ENTRY_COUNT) {
                        throw FeedbackArchiveException(
                            FeedbackArchiveException.Reason.UNKNOWN_ENTRY,
                        )
                    }
                    val name = entry.name
                    validateNameShape(name)
                    val canonical = name.lowercase(Locale.US)
                    if (!seen.add(canonical)) {
                        throw FeedbackArchiveException(
                            FeedbackArchiveException.Reason.DUPLICATE_ENTRY,
                        )
                    }
                    if (isForbiddenRawName(canonical)) {
                        throw FeedbackArchiveException(
                            FeedbackArchiveException.Reason.RAW_HEALTH_OR_DATABASE,
                        )
                    }
                    if (name !in allowedEntries) {
                        throw FeedbackArchiveException(
                            FeedbackArchiveException.Reason.UNKNOWN_ENTRY,
                        )
                    }
                    val maximum = maximumEntryBytes(name)
                    val bytes = ByteArrayOutputStream(minOf(maximum, 64 * 1024))
                    val buffer = ByteArray(16 * 1024)
                    var entryBytes = 0
                    while (true) {
                        val read = zip.read(buffer)
                        if (read < 0) break
                        entryBytes += read
                        totalUncompressed += read.toLong()
                        if (entryBytes > maximum || totalUncompressed > MAX_ARCHIVE_BYTES) {
                            throw FeedbackArchiveException(
                                FeedbackArchiveException.Reason.ENTRY_TOO_LARGE,
                            )
                        }
                        bytes.write(buffer, 0, read)
                    }
                    validateEntryBytes(name, bytes.toByteArray())
                    hasNote = hasNote || name == "user-note.txt"
                    hasScreenshot =
                        hasScreenshot || name == DisplayScreenshot.BUNDLE_NAME
                    hasReport = hasReport || name == "report.txt"
                    hasMeta = hasMeta || name == "meta.json"
                    zip.closeEntry()
                }
            }
        } catch (error: FeedbackArchiveException) {
            throw error
        } catch (_: Exception) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.WRITE_FAILED)
        }
        if (count == 0) throw FeedbackArchiveException(FeedbackArchiveException.Reason.EMPTY)
        if (!hasReport || !hasMeta) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.REQUIRED_ENTRY_MISSING)
        }
        if (hasNote != includesUserNote || hasScreenshot != includesScreenshot) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.CONSENT_MISMATCH)
        }
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(Locale.US, it) }
    }

    private fun validatePreparedEntries(
        entries: List<Pair<String, ByteArray>>,
        includesUserNote: Boolean,
        includesScreenshot: Boolean,
    ) {
        if (entries.isEmpty() || entries.size > MAX_ENTRY_COUNT) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.EMPTY)
        }
        val seen = linkedSetOf<String>()
        var total = 0L
        entries.forEach { (name, bytes) ->
            validateNameShape(name)
            val canonical = name.lowercase(Locale.US)
            if (!seen.add(canonical)) {
                throw FeedbackArchiveException(FeedbackArchiveException.Reason.DUPLICATE_ENTRY)
            }
            if (isForbiddenRawName(canonical)) {
                throw FeedbackArchiveException(
                    FeedbackArchiveException.Reason.RAW_HEALTH_OR_DATABASE,
                )
            }
            if (name !in allowedEntries) {
                throw FeedbackArchiveException(FeedbackArchiveException.Reason.UNKNOWN_ENTRY)
            }
            validateEntryBytes(name, bytes)
            total += bytes.size.toLong()
            if (total > MAX_ARCHIVE_BYTES) {
                throw FeedbackArchiveException(FeedbackArchiveException.Reason.ARCHIVE_TOO_LARGE)
            }
        }
        if (entries.none { it.first == "report.txt" } ||
            entries.none { it.first == "meta.json" }
        ) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.REQUIRED_ENTRY_MISSING)
        }
        if (entries.any { it.first == "user-note.txt" } != includesUserNote ||
            entries.any { it.first == DisplayScreenshot.BUNDLE_NAME } != includesScreenshot
        ) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.CONSENT_MISMATCH)
        }
    }

    private fun validateNameShape(name: String) {
        if (name.isBlank() ||
            name.length > 96 ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains("..") ||
            name.startsWith('.') ||
            name.any { it.code < 0x21 || it.code > 0x7E }
        ) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.UNSAFE_ENTRY_NAME)
        }
    }

    private fun isForbiddenRawName(canonicalName: String): Boolean =
        forbiddenNameFragments.any(canonicalName::contains) ||
            forbiddenSuffixes.any(canonicalName::endsWith)

    private fun maximumEntryBytes(name: String): Int = when (name) {
        DisplayScreenshot.BUNDLE_NAME -> MAX_SCREENSHOT_BYTES
        "last-crash.txt" -> 64 * 1024
        "user-note.txt" -> 8 * 1024
        else -> MAX_TEXT_ENTRY_BYTES
    }

    private fun validateEntryBytes(name: String, bytes: ByteArray) {
        if (bytes.isEmpty() || bytes.size > maximumEntryBytes(name)) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.ENTRY_TOO_LARGE)
        }
        if (bytes.size >= sqliteSignature.size &&
            sqliteSignature.indices.all { bytes[it] == sqliteSignature[it] }
        ) {
            throw FeedbackArchiveException(
                FeedbackArchiveException.Reason.RAW_HEALTH_OR_DATABASE,
            )
        }
        if (name == DisplayScreenshot.BUNDLE_NAME) {
            if (bytes.size < pngSignature.size ||
                pngSignature.indices.any { bytes[it] != pngSignature[it] } ||
                FeedbackScreenshotSanitizer.sanitize(bytes)
                    ?.contentEquals(bytes) != true
            ) {
                throw FeedbackArchiveException(
                    FeedbackArchiveException.Reason.INVALID_SCREENSHOT,
                )
            }
            return
        }
        val validText = runCatching {
            val decoded = StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
            decoded.none { character ->
                (character.code < 0x20 &&
                    character != '\n' &&
                    character != '\r' &&
                    character != '\t') ||
                    character.code == 0x7F
            }
        }.getOrDefault(false)
        if (!validText) {
            throw FeedbackArchiveException(FeedbackArchiveException.Reason.INVALID_TEXT)
        }
    }

    private fun atomicMove(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(source.toPath(), destination.toPath())
        }
    }
}
