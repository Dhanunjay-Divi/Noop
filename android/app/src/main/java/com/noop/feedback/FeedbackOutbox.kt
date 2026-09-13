package com.noop.feedback

import android.content.Context
import com.noop.AppDiagnosticsRecorder
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.time.Instant
import java.util.Locale
import java.util.UUID
import org.json.JSONObject

internal enum class FeedbackState(
    val wireValue: String,
    val terminal: Boolean = false,
) {
    QUEUED("queued"),
    UPLOADING("uploading"),
    RETRY_SCHEDULED("retry_scheduled"),
    FAILED("failed"),
    CANCELING("canceling"),
    CANCEL_RETRY_SCHEDULED("cancel_retry_scheduled"),
    CANCEL_FAILED("cancel_failed"),
    SENT("sent", terminal = true),
    CANCELED("canceled", terminal = true),
}

internal enum class FeedbackFailureCategory(val wireValue: String) {
    NONE("none"),
    NETWORK("network"),
    ATTESTATION("attestation"),
    IDENTITY("identity"),
    SERVER_RETRYABLE("server_retryable"),
    SERVER_REJECTED("server_rejected"),
    INVALID_RESPONSE("invalid_response"),
    ARCHIVE_INVALID("archive_invalid"),
    CONFIGURATION("configuration"),
    INTERRUPTED("interrupted"),
    DELETION_PENDING("deletion_pending"),
    OUTBOX_FULL("outbox_full"),
    UNKNOWN("unknown"),
}

internal data class FeedbackRecord(
    val localId: String,
    val requestId: String,
    val serverReportId: String?,
    val serverReportToken: String?,
    val identitySubjectSha256: String?,
    val archiveSha256: String,
    val archiveBytes: Long,
    val includesUserNote: Boolean,
    val includesScreenshot: Boolean,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val state: FeedbackState,
    val attempt: Int,
    val cancellationAttempt: Int,
    val failureCategory: FeedbackFailureCategory,
    val retainedUntil: String?,
    val receipt: String?,
    val localArchiveRemoved: Boolean,
)

internal sealed interface FeedbackCompletionCommit {
    val record: FeedbackRecord

    data class Sent(
        override val record: FeedbackRecord,
    ) : FeedbackCompletionCommit

    data class CancellationRequired(
        override val record: FeedbackRecord,
    ) : FeedbackCompletionCommit
}

internal data class FeedbackStateFileMetadata(
    val isRegularFile: Boolean,
    val size: Long,
)

internal class FeedbackOutboxException(
    val reason: Reason,
) : Exception("Feedback outbox rejected: ${reason.wireValue}") {
    enum class Reason(val wireValue: String) {
        FULL("full"),
        INVALID_RECORD("invalid_record"),
        RECORD_NOT_FOUND("record_not_found"),
        INVALID_TRANSITION("invalid_transition"),
        STATE_UNAVAILABLE("state_unavailable"),
        WRITE_FAILED("write_failed"),
    }
}

internal object FeedbackStateMachine {
    fun canTransition(from: FeedbackState, to: FeedbackState): Boolean =
        from == to || when (from) {
            FeedbackState.QUEUED ->
                to in setOf(
                    FeedbackState.UPLOADING,
                    FeedbackState.CANCELING,
                    FeedbackState.FAILED,
                )
            FeedbackState.UPLOADING ->
                to in setOf(
                    FeedbackState.RETRY_SCHEDULED,
                    FeedbackState.SENT,
                    FeedbackState.CANCELING,
                    FeedbackState.FAILED,
                )
            FeedbackState.RETRY_SCHEDULED ->
                to in setOf(
                    FeedbackState.UPLOADING,
                    FeedbackState.QUEUED,
                    FeedbackState.CANCELING,
                    FeedbackState.FAILED,
                )
            FeedbackState.FAILED ->
                to in setOf(
                    FeedbackState.QUEUED,
                    FeedbackState.CANCELING,
                )
            FeedbackState.CANCELING ->
                to in setOf(
                    FeedbackState.CANCEL_RETRY_SCHEDULED,
                    FeedbackState.CANCELED,
                    FeedbackState.CANCEL_FAILED,
                )
            FeedbackState.CANCEL_RETRY_SCHEDULED ->
                to in setOf(
                    FeedbackState.CANCELING,
                    FeedbackState.CANCEL_FAILED,
                )
            FeedbackState.CANCEL_FAILED ->
                to in setOf(
                    FeedbackState.CANCELING,
                    FeedbackState.QUEUED,
                )
            FeedbackState.SENT,
            FeedbackState.CANCELED,
            -> false
        }
}

/**
 * App-private durable feedback queue. Each report owns a sealed `archive.zip` and a small atomic
 * `state.json`; the state document contains only the fields explicitly allowed by the feedback
 * protocol. No note, screenshot bytes, file path, signed URL, response body, health value, or
 * arbitrary failure text is persisted in metadata. The server-issued support receipt and retention
 * deadline are retained only for a successfully sent report.
 */
internal class FeedbackOutbox(
    filesDir: File,
    private val idFactory: () -> UUID = UUID::randomUUID,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val stateMetadataReader: (File) -> FeedbackStateFileMetadata? =
        ::readFeedbackStateFileMetadata,
    private val stateReader: (File) -> String = { it.readText(Charsets.UTF_8) },
    private val archiveDeleter: (File) -> Boolean = File::delete,
) {
    private val root = File(filesDir, "feedback/outbox")

    fun stage(
        entries: List<Pair<String, ByteArray>>,
        includesUserNote: Boolean,
        includesScreenshot: Boolean,
    ): FeedbackRecord = synchronized(lock) {
        ensureRoot()
        recoverLocked()
        pruneTerminalLocked()
        val current = loadRecordsLocked()
        val active = current.filter { !it.record.state.terminal }
        if (active.size >= MAX_RECORDS ||
            active.sumOf { storedArchiveBytes(it.record) } >= MAX_TOTAL_ARCHIVE_BYTES
        ) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.FULL)
        }

        val stagedAt = nowMillis()
        val localId = canonicalUuid(idFactory())
        val requestId = canonicalUuid(idFactory())
        val directory = reportDirectory(localId)
        if (directory.exists() || !directory.mkdirs()) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.WRITE_FAILED)
        }
        try {
            val descriptor = FeedbackArchive.writeImmutable(
                destination = File(directory, ARCHIVE_FILE),
                entries = entries,
                includesUserNote = includesUserNote,
                includesScreenshot = includesScreenshot,
            )
            val projectedBytes =
                loadRecordsLocked()
                    .filter { !it.record.state.terminal }
                    .sumOf { storedArchiveBytes(it.record) } + descriptor.bytes
            if (projectedBytes > MAX_TOTAL_ARCHIVE_BYTES) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.FULL)
            }
            val record = FeedbackRecord(
                localId = localId,
                requestId = requestId,
                serverReportId = null,
                serverReportToken = null,
                identitySubjectSha256 = null,
                archiveSha256 = descriptor.sha256,
                archiveBytes = descriptor.bytes,
                includesUserNote = descriptor.includesUserNote,
                includesScreenshot = descriptor.includesScreenshot,
                createdAtMillis = stagedAt,
                updatedAtMillis = stagedAt,
                state = FeedbackState.QUEUED,
                attempt = 0,
                cancellationAttempt = 0,
                failureCategory = FeedbackFailureCategory.NONE,
                retainedUntil = null,
                receipt = null,
                localArchiveRemoved = false,
            )
            writeRecordLocked(record)
            recordTransition(null, record)
            record
        } catch (error: Exception) {
            directory.deleteRecursively()
            throw error
        }
    }

    fun recover(): List<FeedbackRecord> = synchronized(lock) {
        ensureRoot()
        recoverLocked()
        pruneTerminalLocked()
        loadRecordsLocked()
            .sortedByDescending { it.record.updatedAtMillis }
            .map { it.record }
    }

    fun latestVisible(): FeedbackRecord? = synchronized(lock) {
        ensureRoot()
        recoverLocked()
        pruneTerminalLocked()
        loadRecordsLocked()
            .filter { !it.record.state.terminal }
            .maxByOrNull { it.record.updatedAtMillis }
            ?.record
    }

    fun load(localId: String): FeedbackRecord? = synchronized(lock) {
        canonicalUuid(localId) ?: return@synchronized null
        loadRecordLocked(reportDirectory(localId))?.record
    }

    fun archive(record: FeedbackRecord): File = File(reportDirectory(record.localId), ARCHIVE_FILE)

    fun beginUpload(localId: String, attempt: Int): FeedbackRecord = update(localId) {
        it.copy(
            state = FeedbackState.UPLOADING,
            attempt = attempt.coerceIn(1, MAX_ATTEMPTS),
            failureCategory = FeedbackFailureCategory.NONE,
        )
    }

    fun noteCancelAttempt(localId: String, attempt: Int): FeedbackRecord = update(localId) {
        val target = when (it.state) {
            FeedbackState.CANCEL_RETRY_SCHEDULED,
            FeedbackState.CANCEL_FAILED,
            -> FeedbackState.CANCELING
            FeedbackState.CANCELING -> FeedbackState.CANCELING
            else -> throw FeedbackOutboxException(
                FeedbackOutboxException.Reason.INVALID_TRANSITION,
            )
        }
        it.copy(
            state = target,
            cancellationAttempt = attempt.coerceIn(1, MAX_ATTEMPTS),
            failureCategory = FeedbackFailureCategory.NONE,
        )
    }

    fun bindIdentity(localId: String, identitySubjectSha256: String): FeedbackRecord =
        update(localId) {
            if (it.identitySubjectSha256 != null &&
                it.identitySubjectSha256 != identitySubjectSha256
            ) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
            }
            it.copy(identitySubjectSha256 = identitySubjectSha256)
        }

    fun saveReservation(
        localId: String,
        serverReportId: String,
        serverReportToken: String,
    ): FeedbackRecord = update(localId) {
        if (it.identitySubjectSha256 == null) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        if ((it.serverReportId != null && it.serverReportId != serverReportId) ||
            (it.serverReportToken != null && it.serverReportToken != serverReportToken)
        ) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        it.copy(
            serverReportId = serverReportId,
            serverReportToken = serverReportToken,
        )
    }

    fun scheduleRetry(
        localId: String,
        failure: FeedbackFailureCategory,
    ): FeedbackRecord = update(localId) {
        it.copy(
            state = FeedbackState.RETRY_SCHEDULED,
            failureCategory = failure,
        )
    }

    fun scheduleCancelRetry(
        localId: String,
        failure: FeedbackFailureCategory,
    ): FeedbackRecord = update(localId) {
        it.copy(
            state = FeedbackState.CANCEL_RETRY_SCHEDULED,
            failureCategory = failure,
        )
    }

    fun markFailed(
        localId: String,
        failure: FeedbackFailureCategory,
    ): FeedbackRecord = update(localId) {
        it.copy(
            state = FeedbackState.FAILED,
            failureCategory = failure,
        )
    }

    fun markCancelFailed(
        localId: String,
        failure: FeedbackFailureCategory,
    ): FeedbackRecord = update(localId) {
        it.copy(
            state = FeedbackState.CANCEL_FAILED,
            failureCategory = failure,
        )
    }

    fun commitCompletion(
        localId: String,
        receipt: String,
        retainedUntil: String,
    ): FeedbackCompletionCommit {
        val commit = synchronized(lock) {
            ensureRoot()
            val current = recordForUpdateLocked(localId)
            if (current.state in cancellationStates) {
                FeedbackCompletionCommit.CancellationRequired(current)
            } else {
                FeedbackCompletionCommit.Sent(
                    updateLocked(current) {
                        it.copy(
                            serverReportToken = null,
                            state = FeedbackState.SENT,
                            failureCategory = FeedbackFailureCategory.NONE,
                            retainedUntil = retainedUntil,
                            receipt = receipt,
                        )
                    },
                )
            }
        }
        return when (commit) {
            is FeedbackCompletionCommit.CancellationRequired -> commit
            is FeedbackCompletionCommit.Sent -> {
                val cleaned = persistArchiveCleanupOutcome(commit.record)
                pruneTerminalBestEffort()
                FeedbackCompletionCommit.Sent(cleaned)
            }
        }
    }

    fun requestCancel(localId: String): FeedbackRecord {
        val record = update(localId) {
            if (it.state.terminal) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_TRANSITION)
            }
            it.copy(
                state = FeedbackState.CANCELING,
                cancellationAttempt = 0,
                failureCategory = FeedbackFailureCategory.NONE,
            )
        }
        return persistArchiveCleanupOutcome(record)
    }

    fun markCanceled(localId: String): FeedbackRecord {
        val record = update(localId) {
            it.copy(
                serverReportToken = null,
                state = FeedbackState.CANCELED,
                failureCategory = FeedbackFailureCategory.NONE,
                retainedUntil = null,
                receipt = null,
            )
        }
        val cleaned = persistArchiveCleanupOutcome(record)
        pruneTerminalBestEffort()
        return cleaned
    }

    fun retry(localId: String): FeedbackRecord = update(localId) {
        val state = when (it.state) {
            FeedbackState.FAILED,
            FeedbackState.RETRY_SCHEDULED,
            -> FeedbackState.QUEUED
            FeedbackState.CANCEL_FAILED,
            FeedbackState.CANCEL_RETRY_SCHEDULED,
            -> FeedbackState.CANCELING
            else -> throw FeedbackOutboxException(
                FeedbackOutboxException.Reason.INVALID_TRANSITION,
            )
        }
        val retryingCancellation = state == FeedbackState.CANCELING
        it.copy(
            state = state,
            attempt = if (retryingCancellation) it.attempt else 0,
            cancellationAttempt = if (retryingCancellation) 0 else it.cancellationAttempt,
            failureCategory = FeedbackFailureCategory.NONE,
        )
    }

    private fun update(
        localId: String,
        transform: (FeedbackRecord) -> FeedbackRecord,
    ): FeedbackRecord = synchronized(lock) {
        ensureRoot()
        updateLocked(recordForUpdateLocked(localId), transform)
    }

    private fun recordForUpdateLocked(localId: String): FeedbackRecord {
        val canonical = canonicalUuid(localId)
            ?: throw FeedbackOutboxException(
                FeedbackOutboxException.Reason.INVALID_RECORD,
            )
        return loadRecordLocked(reportDirectory(canonical))?.record
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.RECORD_NOT_FOUND)
    }

    private fun updateLocked(
        current: FeedbackRecord,
        transform: (FeedbackRecord) -> FeedbackRecord,
    ): FeedbackRecord {
        val updated = transform(current)
            .copy(updatedAtMillis = maxOf(nowMillis(), current.updatedAtMillis))
        validateRecord(updated)
        if (updated.localId != current.localId ||
            updated.requestId != current.requestId ||
            updated.archiveSha256 != current.archiveSha256 ||
            updated.archiveBytes != current.archiveBytes ||
            updated.includesUserNote != current.includesUserNote ||
            updated.includesScreenshot != current.includesScreenshot ||
            updated.createdAtMillis != current.createdAtMillis ||
            (current.identitySubjectSha256 != null &&
                updated.identitySubjectSha256 != current.identitySubjectSha256) ||
            !FeedbackStateMachine.canTransition(current.state, updated.state)
        ) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_TRANSITION)
        }
        writeRecordLocked(updated)
        if (current.state != updated.state) recordTransition(current, updated)
        return updated
    }

    private fun recoverLocked() {
        rootChildren()
            .filter { it.name.startsWith(".") || it.name.endsWith(".tmp") }
            .forEach(File::deleteRecursively)

        val loaded = mutableListOf<StoredRecord>()
        rootChildren()
            .filter(File::isDirectory)
            .forEach { directory ->
                val canonical = canonicalUuid(directory.name)
                if (canonical == null || canonical != directory.name) {
                    directory.deleteRecursively()
                    return@forEach
                }
                try {
                    val record = loadRecordLocked(directory)
                    if (record == null) {
                        AppDiagnosticsRecorder.record(
                            "feedback.outbox_record_rejected",
                            fields = mapOf("outcome" to "invalid_record"),
                        )
                        directory.deleteRecursively()
                    } else {
                        loaded += record
                    }
                } catch (error: FeedbackOutboxException) {
                    if (error.reason == FeedbackOutboxException.Reason.INVALID_RECORD) {
                        AppDiagnosticsRecorder.record(
                            "feedback.outbox_record_rejected",
                            fields = mapOf("outcome" to "invalid_record"),
                        )
                        directory.deleteRecursively()
                    } else {
                        AppDiagnosticsRecorder.record(
                            "feedback.outbox_record_deferred",
                            fields = mapOf("outcome" to "state_unavailable"),
                        )
                        throw error
                    }
                }
            }

        loaded.forEach { stored ->
            var record = stored.record
            if (record.state.terminal) {
                record = persistArchiveCleanupOutcome(record)
                if (record.localArchiveRemoved &&
                    nowMillis() - record.updatedAtMillis >= TERMINAL_RETENTION_MILLIS
                ) {
                    stored.directory.deleteRecursively()
                }
                return@forEach
            }
            if (record.state !in cancellationStates &&
                nowMillis() - record.createdAtMillis >= ACTIVE_RETENTION_MILLIS
            ) {
                if ((record.serverReportId != null && record.serverReportToken != null) ||
                    record.attempt > 0
                ) {
                    val canceling = record.copy(
                        updatedAtMillis = nowMillis(),
                        state = FeedbackState.CANCELING,
                        cancellationAttempt = 0,
                        failureCategory = FeedbackFailureCategory.NONE,
                    )
                    check(FeedbackStateMachine.canTransition(record.state, canceling.state))
                    writeRecordLocked(canceling)
                    persistArchiveCleanupOutcome(canceling)
                    recordTransition(record, canceling)
                } else {
                    stored.directory.deleteRecursively()
                }
                return@forEach
            }
            if (record.state in cancellationStates) {
                persistArchiveCleanupOutcome(record)
                return@forEach
            }
            val archive = archive(record)
            val validArchive = runCatching {
                FeedbackArchive.validate(
                    archive = archive,
                    expectedBytes = record.archiveBytes,
                    expectedSha256 = record.archiveSha256,
                    includesUserNote = record.includesUserNote,
                    includesScreenshot = record.includesScreenshot,
                )
            }.isSuccess
            if (!validArchive) {
                runCatching {
                    val failed = record.copy(
                        state = FeedbackState.FAILED,
                        failureCategory = FeedbackFailureCategory.ARCHIVE_INVALID,
                    )
                    if (FeedbackStateMachine.canTransition(record.state, failed.state)) {
                        writeRecordLocked(failed)
                        recordTransition(record, failed)
                        persistArchiveCleanupOutcome(failed)
                    } else {
                        stored.directory.deleteRecursively()
                    }
                }
            } else if (record.state == FeedbackState.UPLOADING) {
                val recovered = record.copy(
                    state = FeedbackState.RETRY_SCHEDULED,
                    failureCategory = FeedbackFailureCategory.INTERRUPTED,
                )
                writeRecordLocked(recovered)
                recordTransition(record, recovered)
            }
        }
    }

    private fun pruneTerminalLocked() {
        val records = loadRecordsLocked()
            .sortedByDescending { it.record.updatedAtMillis }
        records
            .filter { it.record.state.terminal && it.record.localArchiveRemoved }
            .drop(MAX_TERMINAL_RECORDS)
            .forEach { it.directory.deleteRecursively() }
    }

    private fun loadRecordsLocked(): List<StoredRecord> =
        rootChildren()
            .filter(File::isDirectory)
            .mapNotNull(::loadRecordLocked)

    private fun loadRecordLocked(directory: File): StoredRecord? {
        val stateFile = File(directory, STATE_FILE)
        val metadata = try {
            stateMetadataReader(stateFile)
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.STATE_UNAVAILABLE)
        } ?: return null
        if (!metadata.isRegularFile || metadata.size !in 2..MAX_STATE_BYTES) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        val serialized = try {
            stateReader(stateFile)
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.STATE_UNAVAILABLE)
        }
        val record = try {
            val json = JSONObject(serialized)
            val keys = json.keys().asSequence().toSet()
            val legacy = keys == legacyPersistedKeys
            if (!legacy && keys != persistedKeys) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
            }
            val storedAttempt = json.getInt("attempt")
            val state = FeedbackState.entries.first {
                it.wireValue == json.getString("state")
            }
            FeedbackRecord(
                localId = json.getString("local_id"),
                requestId = json.getString("request_id"),
                serverReportId = json.nullableString("server_report_id"),
                serverReportToken = json.nullableString("server_report_token"),
                identitySubjectSha256 = if (legacy) {
                    null
                } else {
                    json.nullableString("identity_subject_sha256")
                },
                archiveSha256 = json.getString("archive_sha256"),
                archiveBytes = json.getLong("archive_bytes"),
                includesUserNote = json.getBoolean("includes_user_note"),
                includesScreenshot = json.getBoolean("includes_screenshot"),
                createdAtMillis = json.getLong("created_at_millis"),
                updatedAtMillis = json.getLong("updated_at_millis"),
                state = state,
                attempt = if (legacy && state in cancellationStates) 0 else storedAttempt,
                cancellationAttempt = if (legacy) {
                    if (state in cancellationStates) storedAttempt else 0
                } else {
                    json.getInt("cancellation_attempt")
                },
                failureCategory = FeedbackFailureCategory.entries.first {
                    it.wireValue == json.getString("failure_category")
                },
                retainedUntil = json.nullableString("retained_until"),
                receipt = json.nullableString("receipt"),
                localArchiveRemoved = if (legacy) {
                    false
                } else {
                    json.getBoolean("local_archive_removed")
                },
            ).also(::validateRecord)
        } catch (error: FeedbackOutboxException) {
            throw error
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        if (record.localId != directory.name) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        return StoredRecord(directory, record)
    }

    private fun writeRecordLocked(record: FeedbackRecord) {
        validateRecord(record)
        val directory = reportDirectory(record.localId)
        if ((!directory.exists() && !directory.mkdirs()) || !directory.isDirectory) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.WRITE_FAILED)
        }
        val state = File(directory, STATE_FILE)
        val temporary = File(directory, ".$STATE_FILE.tmp")
        val json = JSONObject()
            .put("local_id", record.localId)
            .put("request_id", record.requestId)
            .put("server_report_id", record.serverReportId ?: JSONObject.NULL)
            .put("server_report_token", record.serverReportToken ?: JSONObject.NULL)
            .put("identity_subject_sha256", record.identitySubjectSha256 ?: JSONObject.NULL)
            .put("archive_sha256", record.archiveSha256)
            .put("archive_bytes", record.archiveBytes)
            .put("includes_user_note", record.includesUserNote)
            .put("includes_screenshot", record.includesScreenshot)
            .put("created_at_millis", record.createdAtMillis)
            .put("updated_at_millis", record.updatedAtMillis)
            .put("state", record.state.wireValue)
            .put("attempt", record.attempt)
            .put("cancellation_attempt", record.cancellationAttempt)
            .put("failure_category", record.failureCategory.wireValue)
            .put("retained_until", record.retainedUntil ?: JSONObject.NULL)
            .put("receipt", record.receipt ?: JSONObject.NULL)
            .put("local_archive_removed", record.localArchiveRemoved)
            .toString()
        try {
            FileOutputStream(temporary).use { output ->
                output.write(json.toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            atomicMove(temporary, state)
            directory.setLastModified(System.currentTimeMillis())
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.WRITE_FAILED)
        } finally {
            temporary.delete()
        }
    }

    private fun validateRecord(record: FeedbackRecord) {
        if (canonicalUuid(record.localId) != record.localId ||
            canonicalUuid(record.requestId) != record.requestId ||
            !record.archiveSha256.matches(SHA256) ||
            record.archiveBytes !in 1..FeedbackArchive.MAX_ARCHIVE_BYTES ||
            record.attempt !in 0..MAX_ATTEMPTS ||
            record.cancellationAttempt !in 0..MAX_ATTEMPTS ||
            record.createdAtMillis <= 0L ||
            record.updatedAtMillis < record.createdAtMillis ||
            record.serverReportId?.let(::canonicalUuid) != record.serverReportId ||
            record.serverReportToken?.matches(SERVER_TOKEN) == false ||
            record.identitySubjectSha256?.matches(SHA256) == false ||
            record.retainedUntil?.let(::validInstant) == false ||
            record.receipt?.matches(RECEIPT) == false ||
            !validTerminalCredentials(record)
        ) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
    }

    private fun ensureRoot() {
        if ((!root.exists() && !root.mkdirs()) || !root.isDirectory) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.WRITE_FAILED)
        }
    }

    private fun reportDirectory(localId: String): File = File(root, localId)

    private fun storedArchiveBytes(record: FeedbackRecord): Long =
        archive(record).takeIf(File::isFile)?.length() ?: 0L

    private fun cleanupLocalArchive(record: FeedbackRecord): Boolean {
        val archive = archive(record)
        val existsBefore = archiveExists(archive)
        if (existsBefore == false) return true
        val removed = if (existsBefore == null) {
            false
        } else {
            runCatching {
                archiveDeleter(archive) && archiveExists(archive) == false
            }.getOrDefault(false)
        }
        AppDiagnosticsRecorder.record(
            "feedback.local_archive_cleanup",
            fields = mapOf("outcome" to if (removed) "completed" else "failed"),
        )
        return removed
    }

    private fun persistArchiveCleanupOutcome(record: FeedbackRecord): FeedbackRecord {
        val removed = cleanupLocalArchive(record)
        if (removed == record.localArchiveRemoved) return record
        return try {
            update(record.localId) { current ->
                current.copy(localArchiveRemoved = removed)
            }
        } catch (_: FeedbackOutboxException) {
            record
        }
    }

    private fun archiveExists(file: File): Boolean? = try {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
        true
    } catch (_: NoSuchFileException) {
        false
    } catch (_: IOException) {
        null
    } catch (_: SecurityException) {
        null
    }

    private fun rootChildren(): Array<File> =
        root.listFiles()
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.STATE_UNAVAILABLE)

    private fun pruneTerminalBestEffort() {
        synchronized(lock) {
            runCatching { pruneTerminalLocked() }
                .onFailure {
                    AppDiagnosticsRecorder.record(
                        "feedback.terminal_prune",
                        fields = mapOf("outcome" to "deferred"),
                    )
                }
        }
    }

    private fun recordTransition(previous: FeedbackRecord?, current: FeedbackRecord) {
        val event = when (current.state) {
            FeedbackState.QUEUED -> "feedback.queued"
            FeedbackState.UPLOADING -> "feedback.uploading"
            FeedbackState.RETRY_SCHEDULED -> "feedback.retry_scheduled"
            FeedbackState.FAILED -> "feedback.failed"
            FeedbackState.CANCELING -> "feedback.canceling"
            FeedbackState.CANCEL_RETRY_SCHEDULED -> "feedback.cancel_retry_scheduled"
            FeedbackState.CANCEL_FAILED -> "feedback.cancel_failed"
            FeedbackState.SENT -> "feedback.sent"
            FeedbackState.CANCELED -> "feedback.canceled"
        }
        AppDiagnosticsRecorder.record(
            event,
            fields = mapOf(
                "previous_state" to (previous?.state?.wireValue ?: "none"),
                "state" to current.state.wireValue,
                "failure_category" to current.failureCategory.wireValue,
            ),
        )
    }

    private fun canonicalUuid(value: UUID): String =
        value.toString().lowercase(Locale.US)

    private fun canonicalUuid(value: String): String? =
        runCatching { canonicalUuid(UUID.fromString(value)) }.getOrNull()

    private fun atomicMove(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
    }

    private data class StoredRecord(
        val directory: File,
        val record: FeedbackRecord,
    )

    companion object {
        const val MAX_RECORDS = 3
        const val MAX_ATTEMPTS = 8
        const val MAX_TOTAL_ARCHIVE_BYTES = 64L * 1024L * 1024L
        private const val MAX_TERMINAL_RECORDS = 2
        private const val MAX_STATE_BYTES = 16L * 1024L
        private const val ACTIVE_RETENTION_MILLIS = 14L * 24L * 60L * 60L * 1_000L
        private const val TERMINAL_RETENTION_MILLIS = 24L * 60L * 60L * 1_000L
        private const val ARCHIVE_FILE = "archive.zip"
        private const val STATE_FILE = "state.json"
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val SERVER_TOKEN = Regex("^(?:v[0-9]{1,4}\\.)?[A-Za-z0-9_-]{43}$")
        private val RECEIPT = Regex("^NF-[A-Z2-7]{16}$")
        private val legacyPersistedKeys = setOf(
            "local_id",
            "request_id",
            "server_report_id",
            "server_report_token",
            "archive_sha256",
            "archive_bytes",
            "includes_user_note",
            "includes_screenshot",
            "created_at_millis",
            "updated_at_millis",
            "state",
            "attempt",
            "failure_category",
            "retained_until",
            "receipt",
        )
        private val persistedKeys = setOf(
            "local_id",
            "request_id",
            "server_report_id",
            "server_report_token",
            "identity_subject_sha256",
            "archive_sha256",
            "archive_bytes",
            "includes_user_note",
            "includes_screenshot",
            "created_at_millis",
            "updated_at_millis",
            "state",
            "attempt",
            "cancellation_attempt",
            "failure_category",
            "retained_until",
            "receipt",
            "local_archive_removed",
        )
        private val cancellationStates = setOf(
            FeedbackState.CANCELING,
            FeedbackState.CANCEL_RETRY_SCHEDULED,
            FeedbackState.CANCEL_FAILED,
        )
        private val lock = Any()

        fun from(context: Context): FeedbackOutbox =
            FeedbackOutbox(context.applicationContext.filesDir)
    }

    private fun validTerminalCredentials(record: FeedbackRecord): Boolean = when (record.state) {
        FeedbackState.SENT ->
            record.serverReportId != null &&
                record.serverReportToken == null &&
                record.receipt != null &&
                record.retainedUntil != null
        FeedbackState.CANCELED ->
            record.serverReportToken == null &&
                record.receipt == null &&
                record.retainedUntil == null
        else ->
            (record.serverReportId == null) == (record.serverReportToken == null) &&
                record.receipt == null &&
                record.retainedUntil == null
    }

    private fun validInstant(value: String): Boolean =
        value.length <= 64 && runCatching { Instant.parse(value) }.isSuccess
}

private fun JSONObject.nullableString(name: String): String? =
    if (isNull(name)) null else getString(name)

private fun readFeedbackStateFileMetadata(file: File): FeedbackStateFileMetadata? = try {
    val attributes = Files.readAttributes(
        file.toPath(),
        BasicFileAttributes::class.java,
        LinkOption.NOFOLLOW_LINKS,
    )
    FeedbackStateFileMetadata(
        isRegularFile = attributes.isRegularFile,
        size = attributes.size(),
    )
} catch (_: NoSuchFileException) {
    null
}
