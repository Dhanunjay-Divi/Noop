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
import java.util.zip.ZipException
import java.util.zip.ZipFile
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
    CAPABILITY_EXPIRED("capability_expired"),
    OUTBOX_FULL("outbox_full"),
    UNKNOWN("unknown"),
}

internal data class FeedbackRecord(
    val localId: String,
    val requestId: String,
    val appVersion: String?,
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
    val clockAnomalyObservedAtMillis: Long? = null,
    val reservationContinuityStartedAtMillis: Long? = null,
    val workerGeneration: String? = null,
    val retryNotBeforeMillis: Long? = null,
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

internal typealias FeedbackArchiveValidator =
    (File, Long, String?, Boolean, Boolean) -> Unit

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

internal class FeedbackWorkerSupersededException :
    Exception("Feedback worker was superseded.")

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

internal object FeedbackReservationContinuityPolicy {
    val maximumLocalDelayBeforeCancellationMillis = DAYS_14_MILLIS
    val maximumRemoteRetentionMillis = DAYS_28_MILLIS
    val expirySafetyMarginMillis = DAY_MILLIS
    val maximumAmbiguousBindingLifetimeMillis =
        maximumRemoteRetentionMillis +
            FeedbackAnonymousIdentityLifetimePolicy.maximumClockSkewMillis +
            expirySafetyMarginMillis
    val maximumRetryDelayMillis = 6L * 60L * 60L * 1_000L
    val minimumRetryDelayMillis = 1_000L
    val activeWorkLeaseMillis = 60L * 60L * 1_000L
    val maximumClockSkewMillis =
        FeedbackAnonymousIdentityLifetimePolicy.maximumClockSkewMillis

    // A nonterminal local binding may own an accepted reservation whose
    // response was lost, even when no server report ID has been persisted.
    fun identitySubjectSha256sRequiringContinuity(
        records: List<FeedbackRecord>,
        nowMillis: Long = System.currentTimeMillis(),
    ): Set<String> =
        records
            .asSequence()
            .filter(::requiresIdentityProtection)
            .mapNotNull(FeedbackRecord::identitySubjectSha256)
            .toSet()

    fun continuityDeadlineMillis(record: FeedbackRecord): Long? {
        if (!hasPossibleRemoteReservation(record)) return null
        val retainedDeadline = record.retainedUntil
            ?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
            ?.coerceAtMost(maximumServerRetainedUntilMillis(record))
            ?.let { boundedAdd(it, expirySafetyMarginMillis) }
        return retainedDeadline ?: boundedAdd(
            reservationContinuityStartMillis(record),
            maximumAmbiguousBindingLifetimeMillis,
        )
    }

    fun maximumServerRetainedUntilMillis(record: FeedbackRecord): Long =
        boundedAdd(
            reservationContinuityStartMillis(record),
            maximumRemoteRetentionMillis + maximumClockSkewMillis,
        )

    fun boundedServerRetainedUntilMillis(
        record: FeedbackRecord,
        retainedUntilMillis: Long,
        nowMillis: Long,
    ): Long =
        retainedUntilMillis.coerceAtMost(
            maximumAcceptedServerRetainedUntilMillis(record, nowMillis),
        )

    fun maximumAcceptedServerRetainedUntilMillis(
        record: FeedbackRecord,
        nowMillis: Long,
    ): Long =
        minOf(
            maximumServerRetainedUntilMillis(record),
            boundedAdd(
                nowMillis,
                maximumRemoteRetentionMillis + maximumClockSkewMillis,
            ),
        )

    fun serverRetentionIsValid(
        record: FeedbackRecord,
        retainedUntilMillis: Long,
        nowMillis: Long,
    ): Boolean =
        retainedUntilMillis >= boundedSubtract(
            nowMillis,
            maximumClockSkewMillis,
        ) &&
            retainedUntilMillis <=
            maximumAcceptedServerRetainedUntilMillis(record, nowMillis)

    fun permitsNewReservation(record: FeedbackRecord, nowMillis: Long): Boolean =
        !hasClockAnomaly(record, nowMillis) &&
            nowMillis >= boundedSubtract(
            record.createdAtMillis,
            maximumClockSkewMillis,
        ) &&
            nowMillis >= boundedSubtract(
                record.updatedAtMillis,
                maximumClockSkewMillis,
            ) &&
            nowMillis < boundedAdd(
                record.createdAtMillis,
                maximumLocalDelayBeforeCancellationMillis,
            )

    fun requiresContinuity(record: FeedbackRecord, nowMillis: Long): Boolean =
        record.identitySubjectSha256 != null &&
            continuityDeadlineMillis(record)?.let {
                nowMillis < it || hasActiveWorkLease(record, nowMillis)
            } == true

    fun requiresIdentityProtection(record: FeedbackRecord): Boolean =
        record.identitySubjectSha256 != null &&
            hasPossibleRemoteReservation(record)

    fun hasExpired(record: FeedbackRecord, nowMillis: Long): Boolean =
        continuityDeadlineMillis(record)?.let {
            nowMillis >= it && !hasActiveWorkLease(record, nowMillis)
        } == true

    fun retryDelayMillis(
        records: List<FeedbackRecord>,
        nowMillis: Long,
    ): Long {
        val protectedRecords = records.filter(::requiresIdentityProtection)
        val earliestRemaining = protectedRecords
            .asSequence()
            .filter { requiresContinuity(it, nowMillis) }
            .mapNotNull { effectiveRetryTargetMillis(it, nowMillis) }
            .map { it - nowMillis }
            .minOrNull()
            ?: return if (protectedRecords.isEmpty()) {
                minimumRetryDelayMillis
            } else {
                maximumRetryDelayMillis
            }
        return earliestRemaining
            .coerceAtLeast(minimumRetryDelayMillis)
            .coerceAtMost(maximumRetryDelayMillis)
    }

    fun requiresIdentityLifetimeCheck(record: FeedbackRecord): Boolean =
        record.identitySubjectSha256 == null

    fun hasPossibleRemoteReservation(record: FeedbackRecord): Boolean =
        !record.state.terminal &&
            (
                record.identitySubjectSha256 != null ||
                    record.serverReportId != null ||
                    record.serverReportToken != null ||
                    record.attempt > 0
                )

    fun hasActiveWorkLease(
        record: FeedbackRecord,
        nowMillis: Long,
    ): Boolean =
        record.clockAnomalyObservedAtMillis == null &&
            record.state in setOf(
            FeedbackState.UPLOADING,
            FeedbackState.CANCELING,
        ) &&
            record.updatedAtMillis <= boundedAdd(
                nowMillis,
                maximumClockSkewMillis,
            ) &&
            nowMillis < boundedAdd(
                record.updatedAtMillis,
                activeWorkLeaseMillis,
            )

    private fun effectiveRetryTargetMillis(
        record: FeedbackRecord,
        nowMillis: Long,
    ): Long? {
        val deadline = continuityDeadlineMillis(record) ?: return null
        if (!hasActiveWorkLease(record, nowMillis)) return deadline
        return maxOf(
            deadline,
            boundedAdd(record.updatedAtMillis, activeWorkLeaseMillis),
        )
    }

    fun needsClockAnomalyNormalization(
        record: FeedbackRecord,
        nowMillis: Long,
    ): Boolean =
        record.clockAnomalyObservedAtMillis == null &&
            (
                record.createdAtMillis > boundedAdd(nowMillis, maximumClockSkewMillis) ||
                    record.updatedAtMillis > boundedAdd(nowMillis, maximumClockSkewMillis)
                )

    fun hasClockAnomaly(
        record: FeedbackRecord,
        nowMillis: Long,
    ): Boolean =
        record.clockAnomalyObservedAtMillis != null ||
            needsClockAnomalyNormalization(record, nowMillis)

    fun hasSecondaryClockRollback(
        record: FeedbackRecord,
        nowMillis: Long,
    ): Boolean =
        record.clockAnomalyObservedAtMillis?.let {
            val highWater = maxOf(it, record.updatedAtMillis)
            nowMillis < boundedSubtract(highWater, maximumClockSkewMillis)
        } == true

    private fun reservationContinuityStartMillis(record: FeedbackRecord): Long =
        record.reservationContinuityStartedAtMillis
            ?: record.clockAnomalyObservedAtMillis
            ?: record.createdAtMillis

    private fun boundedSubtract(value: Long, decrement: Long): Long =
        if (value < Long.MIN_VALUE + decrement) Long.MIN_VALUE else value - decrement

    private fun boundedAdd(value: Long, increment: Long): Long =
        if (value > Long.MAX_VALUE - increment) Long.MAX_VALUE else value + increment

    private const val DAY_MILLIS = 24L * 60L * 60L * 1_000L
    private const val DAYS_14_MILLIS = 14L * DAY_MILLIS
    private const val DAYS_28_MILLIS = 28L * DAY_MILLIS
}

internal enum class FeedbackReservationAttemptLane {
    DELIVERY,
    CANCELLATION,
}

internal data class FeedbackContinuityRetrySchedule(
    val record: FeedbackRecord,
    val delayMillis: Long,
)

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
    private val archiveAppVersionReader: ((File) -> String?)? = null,
    private val archiveDeleter: (File) -> Boolean = File::delete,
    private val archiveValidator: FeedbackArchiveValidator =
        { archive, expectedBytes, expectedSha256, includesUserNote, includesScreenshot ->
            FeedbackArchive.validate(
                archive = archive,
                expectedBytes = expectedBytes,
                expectedSha256 = expectedSha256,
                includesUserNote = includesUserNote,
                includesScreenshot = includesScreenshot,
            )
        },
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
            val archive = File(directory, ARCHIVE_FILE)
            val descriptor = FeedbackArchive.writeImmutable(
                destination = archive,
                entries = entries,
                includesUserNote = includesUserNote,
                includesScreenshot = includesScreenshot,
            )
            val appVersion = archiveAppVersion(archive)
                ?: throw FeedbackOutboxException(
                    FeedbackOutboxException.Reason.INVALID_RECORD,
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
                appVersion = appVersion,
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
                clockAnomalyObservedAtMillis = null,
                reservationContinuityStartedAtMillis = null,
                workerGeneration = null,
                retryNotBeforeMillis = null,
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
        ensureRoot()
        recoverLocked()
        pruneTerminalLocked()
        loadRecordLocked(reportDirectory(localId))?.record
    }

    /**
     * Lightweight state-only read for transient UI progress. It deliberately skips archive recovery,
     * hashing, and pruning so an upload callback cannot repeatedly reread a large immutable ZIP.
     */
    fun loadForProgress(
        localId: String,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord? = synchronized(lock) {
        canonicalUuid(localId) ?: return@synchronized null
        ensureRoot()
        val record = loadRecordLocked(
            directory = reportDirectory(localId),
            readArchiveMetadata = false,
        )?.record ?: return@synchronized null
        if (expectedWorkerGeneration != null &&
            record.workerGeneration != canonicalUuid(expectedWorkerGeneration)
        ) {
            return@synchronized null
        }
        record
    }

    fun reservationContinuityIdentitySubjectSha256s(): Set<String> =
        synchronized(lock) {
            ensureRoot()
            recoverLocked()
            pruneTerminalLocked()
            val now = nowMillis()
            FeedbackReservationContinuityPolicy
                .identitySubjectSha256sRequiringContinuity(
                    loadRecordsLocked().map(StoredRecord::record),
                    nowMillis = now,
                )
        }

    fun archive(record: FeedbackRecord): File = File(reportDirectory(record.localId), ARCHIVE_FILE)

    fun prepareWorker(
        localId: String,
        replace: Boolean,
        generation: String = UUID.randomUUID().toString().lowercase(Locale.US),
    ): FeedbackRecord = synchronized(lock) {
        ensureRoot()
        val current = recordForUpdateLocked(localId)
        if (current.state.terminal) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_TRANSITION)
        }
        if (!replace && current.workerGeneration != null) {
            return@synchronized current
        }
        val canonicalGeneration = canonicalUuid(generation)
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        updateLocked(current) {
            it.copy(
                workerGeneration = canonicalGeneration,
                retryNotBeforeMillis = if (replace) null else it.retryNotBeforeMillis,
            )
        }
    }

    fun beginUpload(
        localId: String,
        attempt: Int,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
        if (FeedbackReservationContinuityPolicy.hasExpired(it, nowMillis())) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_TRANSITION)
        }
        it.copy(
            state = FeedbackState.UPLOADING,
            attempt = attempt.coerceIn(1, MAX_ATTEMPTS),
            failureCategory = FeedbackFailureCategory.NONE,
            retryNotBeforeMillis = null,
        )
    }

    fun noteCancelAttempt(
        localId: String,
        attempt: Int,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
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
            retryNotBeforeMillis = null,
        )
    }

    fun bindIdentity(
        localId: String,
        identitySubjectSha256: String,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord =
        update(localId, expectedWorkerGeneration) {
            if (it.identitySubjectSha256 != null &&
                it.identitySubjectSha256 != identitySubjectSha256
            ) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
            }
            it.copy(
                identitySubjectSha256 = identitySubjectSha256,
                reservationContinuityStartedAtMillis =
                    it.reservationContinuityStartedAtMillis ?: nowMillis(),
            )
        }

    fun saveReservation(
        localId: String,
        serverReportId: String,
        serverReportToken: String,
        retainedUntil: String? = null,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
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
            retainedUntil = retainedUntil ?: it.retainedUntil,
        )
    }

    fun scheduleRetry(
        localId: String,
        failure: FeedbackFailureCategory,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
        it.copy(
            state = FeedbackState.RETRY_SCHEDULED,
            failureCategory = failure,
            retryNotBeforeMillis = null,
        )
    }

    fun scheduleContinuityRetry(
        localId: String,
        lane: FeedbackReservationAttemptLane,
        failure: FeedbackFailureCategory = FeedbackFailureCategory.IDENTITY,
        allowBoundIdentity: Boolean = false,
        retryAfterMillis: Long? = null,
        expectedWorkerGeneration: String? = null,
        nextWorkerGeneration: String =
            UUID.randomUUID().toString().lowercase(Locale.US),
    ): FeedbackContinuityRetrySchedule = synchronized(lock) {
        ensureRoot()
        val current = recordForUpdateLocked(localId, expectedWorkerGeneration)
        val cancellationRaced =
            lane == FeedbackReservationAttemptLane.DELIVERY &&
                current.state == FeedbackState.CANCELING
        val validLaneState = when (lane) {
            FeedbackReservationAttemptLane.DELIVERY ->
                current.state == FeedbackState.UPLOADING || cancellationRaced
            FeedbackReservationAttemptLane.CANCELLATION ->
                current.state == FeedbackState.CANCELING &&
                    current.cancellationAttempt > 0
        }
        if (!validLaneState ||
            (
                allowBoundIdentity &&
                    current.identitySubjectSha256 == null
                ) ||
            (
                !allowBoundIdentity &&
                    current.identitySubjectSha256 != null
                ) ||
            (
                !allowBoundIdentity &&
                    (
                        current.serverReportId != null ||
                            current.serverReportToken != null
                        )
                ) ||
            (lane == FeedbackReservationAttemptLane.DELIVERY &&
                current.attempt <= 0)
        ) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_TRANSITION)
        }
        val now = nowMillis()
        val delay =
            FeedbackReservationAdmissionPolicy.boundedRetryAfterMillis(retryAfterMillis)
                ?: FeedbackReservationContinuityPolicy.retryDelayMillis(
                    records = loadRecordsLocked().map(StoredRecord::record),
                    nowMillis = now,
                )
        val canonicalNextGeneration = canonicalUuid(nextWorkerGeneration)
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        val retryNotBeforeMillis =
            if (now > Long.MAX_VALUE - delay) Long.MAX_VALUE else now + delay
        val updated = updateLocked(current) {
            it.copy(
                state = if (cancellationRaced ||
                    lane == FeedbackReservationAttemptLane.CANCELLATION
                ) {
                    FeedbackState.CANCEL_RETRY_SCHEDULED
                } else {
                    FeedbackState.RETRY_SCHEDULED
                },
                attempt = if (lane == FeedbackReservationAttemptLane.DELIVERY) {
                    (it.attempt - 1).coerceAtLeast(0)
                } else {
                    it.attempt
                },
                cancellationAttempt =
                if (lane == FeedbackReservationAttemptLane.CANCELLATION) {
                    (it.cancellationAttempt - 1).coerceAtLeast(0)
                } else {
                    it.cancellationAttempt
                },
                failureCategory = failure,
                workerGeneration = canonicalNextGeneration,
                retryNotBeforeMillis = retryNotBeforeMillis,
            )
        }
        FeedbackContinuityRetrySchedule(updated, delay)
    }

    fun markUnconfirmedDeletionIfContinuityExpired(
        localId: String,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord? {
        val expired = synchronized(lock) {
            ensureRoot()
            val current = recordForUpdateLocked(localId, expectedWorkerGeneration)
            val now = nowMillis()
            if (!FeedbackReservationContinuityPolicy.hasExpired(current, now)) {
                return@synchronized null
            }
            expireContinuityAsUnconfirmedDeletionLocked(current, now)
        } ?: return null
        return persistArchiveCleanupOutcome(expired)
    }

    fun scheduleCancelRetry(
        localId: String,
        failure: FeedbackFailureCategory,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
        it.copy(
            state = FeedbackState.CANCEL_RETRY_SCHEDULED,
            failureCategory = failure,
            retryNotBeforeMillis = null,
        )
    }

    fun markFailed(
        localId: String,
        failure: FeedbackFailureCategory,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
        it.copy(
            state = FeedbackState.FAILED,
            failureCategory = failure,
            workerGeneration = null,
            retryNotBeforeMillis = null,
        )
    }

    fun markCancelFailed(
        localId: String,
        failure: FeedbackFailureCategory,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord = update(localId, expectedWorkerGeneration) {
        it.copy(
            state = FeedbackState.CANCEL_FAILED,
            failureCategory = failure,
            workerGeneration = null,
            retryNotBeforeMillis = null,
        )
    }

    fun commitCompletion(
        localId: String,
        receipt: String,
        retainedUntil: String,
        expectedWorkerGeneration: String? = null,
    ): FeedbackCompletionCommit {
        val commit = synchronized(lock) {
            ensureRoot()
            val current = recordForUpdateLocked(localId, expectedWorkerGeneration)
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
                            workerGeneration = null,
                            retryNotBeforeMillis = null,
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

    fun requestCancel(
        localId: String,
        expectedWorkerGeneration: String? = null,
        replacementWorkerGeneration: String? = null,
    ): FeedbackRecord {
        val canonicalReplacement = replacementWorkerGeneration?.let {
            canonicalUuid(it)
                ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        val record = update(localId, expectedWorkerGeneration) {
            if (it.state.terminal) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_TRANSITION)
            }
            val alreadyCanceling = it.state in cancellationStates
            it.copy(
                state = FeedbackState.CANCELING,
                cancellationAttempt =
                    if (alreadyCanceling) it.cancellationAttempt else 0,
                failureCategory = FeedbackFailureCategory.NONE,
                workerGeneration = canonicalReplacement ?: it.workerGeneration,
                retryNotBeforeMillis = null,
            )
        }
        return persistArchiveCleanupOutcome(record)
    }

    fun markCanceled(
        localId: String,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord {
        val record = update(localId, expectedWorkerGeneration) {
            it.copy(
                serverReportToken = null,
                state = FeedbackState.CANCELED,
                failureCategory = FeedbackFailureCategory.NONE,
                retainedUntil = null,
                receipt = null,
                workerGeneration = null,
                retryNotBeforeMillis = null,
            )
        }
        val cleaned = persistArchiveCleanupOutcome(record)
        pruneTerminalBestEffort()
        return cleaned
    }

    fun retry(
        localId: String,
        replacementWorkerGeneration: String? = null,
    ): FeedbackRecord {
        val canonicalReplacement = replacementWorkerGeneration?.let {
            canonicalUuid(it)
                ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        return update(localId) {
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
                workerGeneration = canonicalReplacement ?: it.workerGeneration,
                retryNotBeforeMillis = null,
            )
        }
    }

    private fun update(
        localId: String,
        expectedWorkerGeneration: String? = null,
        transform: (FeedbackRecord) -> FeedbackRecord,
    ): FeedbackRecord = synchronized(lock) {
        ensureRoot()
        updateLocked(
            recordForUpdateLocked(localId, expectedWorkerGeneration),
            transform,
        )
    }

    private fun recordForUpdateLocked(
        localId: String,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord {
        val canonical = canonicalUuid(localId)
            ?: throw FeedbackOutboxException(
                FeedbackOutboxException.Reason.INVALID_RECORD,
            )
        val record = loadRecordLocked(reportDirectory(canonical))?.record
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.RECORD_NOT_FOUND)
        if (expectedWorkerGeneration != null) {
            val canonicalGeneration = canonicalUuid(expectedWorkerGeneration)
                ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
            if (record.workerGeneration != canonicalGeneration) {
                throw FeedbackWorkerSupersededException()
            }
        }
        return record
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
            updated.appVersion != current.appVersion ||
            updated.archiveSha256 != current.archiveSha256 ||
            updated.archiveBytes != current.archiveBytes ||
            updated.includesUserNote != current.includesUserNote ||
            updated.includesScreenshot != current.includesScreenshot ||
            updated.createdAtMillis != current.createdAtMillis ||
            (current.identitySubjectSha256 != null &&
                updated.identitySubjectSha256 != current.identitySubjectSha256) ||
            (current.clockAnomalyObservedAtMillis != null &&
                updated.clockAnomalyObservedAtMillis !=
                current.clockAnomalyObservedAtMillis) ||
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
            val now = nowMillis()
            if (record.identitySubjectSha256 != null &&
                record.reservationContinuityStartedAtMillis == null
            ) {
                record = record.copy(
                    reservationContinuityStartedAtMillis =
                        minOf(record.createdAtMillis, record.updatedAtMillis, now),
                )
            }
            if (stored.needsPersistenceMigration || record != stored.record) {
                writeRecordLocked(record)
            }
            if (FeedbackReservationContinuityPolicy.needsClockAnomalyNormalization(
                    record,
                    now,
                )
            ) {
                if (record.state.terminal) {
                    record = record.copy(
                        clockAnomalyObservedAtMillis = now,
                        updatedAtMillis = now,
                    )
                    writeRecordLocked(record)
                    AppDiagnosticsRecorder.record(
                        "feedback.clock_anomaly",
                        fields = mapOf("outcome" to "terminal_normalized"),
                    )
                } else if (
                    FeedbackReservationContinuityPolicy
                        .hasPossibleRemoteReservation(record)
                ) {
                    val canceling = record.copy(
                        clockAnomalyObservedAtMillis = now,
                        reservationContinuityStartedAtMillis =
                            minOf(
                                record.reservationContinuityStartedAtMillis ?: now,
                                now,
                            ),
                        updatedAtMillis = now,
                        state = FeedbackState.CANCELING,
                        cancellationAttempt =
                            if (record.state in cancellationStates) {
                                record.cancellationAttempt
                            } else {
                                0
                            },
                        failureCategory = FeedbackFailureCategory.NONE,
                    )
                    writeRecordLocked(canceling)
                    persistArchiveCleanupOutcome(canceling)
                    recordTransition(record, canceling)
                    AppDiagnosticsRecorder.record(
                        "feedback.clock_anomaly",
                        fields = mapOf("outcome" to "cancellation_required"),
                    )
                    return@forEach
                } else {
                    stored.directory.deleteRecursively()
                    AppDiagnosticsRecorder.record(
                        "feedback.clock_anomaly",
                        fields = mapOf("outcome" to "local_record_removed"),
                    )
                    return@forEach
                }
            }
            if (FeedbackReservationContinuityPolicy.hasSecondaryClockRollback(
                    record,
                    now,
                )
            ) {
                val normalized = record.copy(
                    clockAnomalyObservedAtMillis = now,
                    reservationContinuityStartedAtMillis =
                        record.reservationContinuityStartedAtMillis?.let {
                            minOf(it, now)
                        },
                    updatedAtMillis = now,
                )
                writeRecordLocked(normalized)
                AppDiagnosticsRecorder.record(
                    "feedback.clock_anomaly",
                    fields = mapOf("outcome" to "secondary_normalized"),
                )
                record = normalized
            }
            if (record.state.terminal) {
                record = persistArchiveCleanupOutcome(record)
                if (record.localArchiveRemoved &&
                    nowMillis() - record.updatedAtMillis >= TERMINAL_RETENTION_MILLIS
                ) {
                    stored.directory.deleteRecursively()
                }
                return@forEach
            }
            if (FeedbackReservationContinuityPolicy.hasExpired(record, now)) {
                persistArchiveCleanupOutcome(
                    expireContinuityAsUnconfirmedDeletionLocked(record, now),
                )
                return@forEach
            }
            if (record.state !in cancellationStates &&
                now - record.createdAtMillis >= ACTIVE_RETENTION_MILLIS &&
                !FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                    record,
                    now,
                )
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
            val validationFailure = try {
                archiveValidator(
                    archive,
                    record.archiveBytes,
                    record.archiveSha256,
                    record.includesUserNote,
                    record.includesScreenshot,
                )
                null
            } catch (error: Exception) {
                error
            }
            if (validationFailure != null &&
                feedbackArchiveValidationFailureIsRetryable(validationFailure)
            ) {
                AppDiagnosticsRecorder.record(
                    "feedback.archive_recovery",
                    fields = mapOf("outcome" to "deferred"),
                )
                return@forEach
            }
            if (validationFailure != null) {
                runCatching {
                    val failed = record.copy(
                        state = FeedbackState.FAILED,
                        failureCategory = FeedbackFailureCategory.ARCHIVE_INVALID,
                        workerGeneration = null,
                        retryNotBeforeMillis = null,
                    )
                    if (FeedbackStateMachine.canTransition(record.state, failed.state)) {
                        writeRecordLocked(failed)
                        recordTransition(record, failed)
                        persistArchiveCleanupOutcome(failed)
                    } else {
                        stored.directory.deleteRecursively()
                    }
                }
            } else if (
                record.state == FeedbackState.UPLOADING &&
                !FeedbackReservationContinuityPolicy.hasActiveWorkLease(
                    record,
                    now,
                )
            ) {
                val recovered = record.copy(
                    state = FeedbackState.RETRY_SCHEDULED,
                    failureCategory = FeedbackFailureCategory.INTERRUPTED,
                )
                writeRecordLocked(recovered)
                recordTransition(record, recovered)
            }
        }
    }

    private fun expireContinuityAsUnconfirmedDeletionLocked(
        record: FeedbackRecord,
        nowMillis: Long,
    ): FeedbackRecord {
        if (record.state == FeedbackState.CANCEL_FAILED &&
            record.failureCategory == FeedbackFailureCategory.CAPABILITY_EXPIRED
        ) {
            return record
        }
        val expired = record.copy(
            updatedAtMillis = maxOf(nowMillis, record.updatedAtMillis),
            state = FeedbackState.CANCEL_FAILED,
            failureCategory = FeedbackFailureCategory.CAPABILITY_EXPIRED,
            workerGeneration = null,
            retryNotBeforeMillis = null,
        )
        // A local continuity deadline cannot prove that the server copy was
        // deleted. Preserve the capability and fail closed until a retry gets
        // an explicit terminal response.
        writeRecordLocked(expired)
        recordTransition(record, expired)
        AppDiagnosticsRecorder.record(
            "feedback.identity_continuity_expired",
            fields = mapOf("outcome" to "deletion_unconfirmed"),
        )
        return expired
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

    private fun loadRecordLocked(
        directory: File,
        readArchiveMetadata: Boolean = true,
    ): StoredRecord? {
        var needsPersistenceMigration = false
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
            val legacy =
                keys == legacyPersistedKeys ||
                    keys == legacyWithClockAnomalyPersistedKeys
            val preAppVersion =
                keys == preAppVersionPersistedKeys ||
                    keys == preAppVersionWithClockAnomalyPersistedKeys
            val preClockAnomaly = keys == preClockAnomalyPersistedKeys
            val preReservationContinuity =
                keys == preReservationContinuityPersistedKeys
            val preWorkerGeneration =
                keys == preWorkerGenerationPersistedKeys
            if (!legacy &&
                !preAppVersion &&
                !preClockAnomaly &&
                !preReservationContinuity &&
                !preWorkerGeneration &&
                keys != persistedKeys
            ) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
            }
            val hasClockAnomalyField =
                keys == persistedKeys ||
                    keys == preWorkerGenerationPersistedKeys ||
                    keys == preReservationContinuityPersistedKeys ||
                    keys == preAppVersionWithClockAnomalyPersistedKeys ||
                    keys == legacyWithClockAnomalyPersistedKeys
            val hasReservationContinuityField =
                keys == persistedKeys ||
                    keys == preWorkerGenerationPersistedKeys
            val hasWorkerGenerationFields = keys == persistedKeys
            val storedAttempt = json.getInt("attempt")
            val state = FeedbackState.entries.first {
                it.wireValue == json.getString("state")
            }
            val storedAppVersion = if (
                preClockAnomaly ||
                preReservationContinuity ||
                preWorkerGeneration ||
                keys == persistedKeys
            ) {
                json.nullableString("app_version")
            } else {
                null
            }
            val archiveAppVersion = if (readArchiveMetadata) {
                archiveAppVersion(File(directory, ARCHIVE_FILE))
            } else {
                null
            }
            if (storedAppVersion != null &&
                archiveAppVersion != null &&
                storedAppVersion != archiveAppVersion
            ) {
                throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
            }
            FeedbackRecord(
                localId = json.getString("local_id"),
                requestId = json.getString("request_id"),
                appVersion = storedAppVersion ?: archiveAppVersion,
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
                clockAnomalyObservedAtMillis = if (hasClockAnomalyField) {
                    json.nullableLong("clock_anomaly_observed_at_millis")
                } else {
                    null
                },
                reservationContinuityStartedAtMillis =
                    if (hasReservationContinuityField) {
                        json.nullableLong(
                            "reservation_continuity_started_at_millis",
                        )
                    } else {
                        null
                    },
                workerGeneration = if (hasWorkerGenerationFields) {
                    json.nullableString("worker_generation")
                } else {
                    null
                },
                retryNotBeforeMillis = if (hasWorkerGenerationFields) {
                    json.nullableLong("retry_not_before_millis")
                } else {
                    null
                },
            ).also { record ->
                validateRecord(record)
                needsPersistenceMigration =
                    readArchiveMetadata &&
                        keys != persistedKeys &&
                        record.appVersion != null
            }
        } catch (error: FeedbackOutboxException) {
            throw error
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        if (record.localId != directory.name) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        return StoredRecord(
            directory = directory,
            record = record,
            needsPersistenceMigration = needsPersistenceMigration,
        )
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
            .put("app_version", record.appVersion ?: JSONObject.NULL)
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
            .put(
                "clock_anomaly_observed_at_millis",
                record.clockAnomalyObservedAtMillis ?: JSONObject.NULL,
            )
            .put(
                "reservation_continuity_started_at_millis",
                record.reservationContinuityStartedAtMillis ?: JSONObject.NULL,
            )
            .put(
                "worker_generation",
                record.workerGeneration ?: JSONObject.NULL,
            )
            .put(
                "retry_not_before_millis",
                record.retryNotBeforeMillis ?: JSONObject.NULL,
            )
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
            record.appVersion?.matches(APP_VERSION) == false ||
            (record.appVersion == null &&
                !record.state.terminal &&
                record.state !in cancellationStates) ||
            !record.archiveSha256.matches(SHA256) ||
            record.archiveBytes !in 1..FeedbackArchive.MAX_ARCHIVE_BYTES ||
            record.attempt !in 0..MAX_ATTEMPTS ||
            record.cancellationAttempt !in 0..MAX_ATTEMPTS ||
            record.createdAtMillis <= 0L ||
            (
                record.updatedAtMillis < record.createdAtMillis &&
                    record.clockAnomalyObservedAtMillis == null
                ) ||
            record.clockAnomalyObservedAtMillis?.let {
                it <= 0L || record.updatedAtMillis < it
            } == true ||
            record.reservationContinuityStartedAtMillis?.let {
                it <= 0L || record.identitySubjectSha256 == null
            } == true ||
            record.workerGeneration?.let(::canonicalUuid) != record.workerGeneration ||
            record.retryNotBeforeMillis?.let {
                it <= 0L ||
                    record.workerGeneration == null ||
                    record.state !in setOf(
                        FeedbackState.RETRY_SCHEDULED,
                        FeedbackState.CANCEL_RETRY_SCHEDULED,
                    )
            } == true ||
            (record.state.terminal &&
                (record.workerGeneration != null || record.retryNotBeforeMillis != null)) ||
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
        val needsPersistenceMigration: Boolean,
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
        private const val MAX_META_BYTES = 1024 * 1024
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val APP_VERSION = Regex("^[A-Za-z0-9][A-Za-z0-9.+_-]{0,31}$")
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
        private val preAppVersionPersistedKeys = setOf(
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
        private val preClockAnomalyPersistedKeys =
            preAppVersionPersistedKeys + "app_version"
        private val legacyWithClockAnomalyPersistedKeys =
            legacyPersistedKeys + "clock_anomaly_observed_at_millis"
        private val preAppVersionWithClockAnomalyPersistedKeys =
            preAppVersionPersistedKeys + "clock_anomaly_observed_at_millis"
        private val preReservationContinuityPersistedKeys =
            preClockAnomalyPersistedKeys + "clock_anomaly_observed_at_millis"
        private val preWorkerGenerationPersistedKeys =
            preReservationContinuityPersistedKeys +
                "reservation_continuity_started_at_millis"
        private val persistedKeys =
            preWorkerGenerationPersistedKeys +
                setOf(
                    "worker_generation",
                    "retry_not_before_millis",
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
                (record.retainedUntil == null || record.serverReportId != null)
    }

    private fun validInstant(value: String): Boolean =
        value.length <= 64 && runCatching { Instant.parse(value) }.isSuccess

    private fun archiveAppVersion(archive: File): String? =
        archiveAppVersionReader?.invoke(archive) ?: appVersionFromArchive(archive)

    private fun appVersionFromArchive(archive: File): String? {
        if (!archive.isFile) return null
        try {
            ZipFile(archive).use { zip ->
                val metaEntries = zip.entries().asSequence()
                    .filter { !it.isDirectory && it.name == "meta.json" }
                    .toList()
                if (metaEntries.size != 1) {
                    throw FeedbackOutboxException(
                        FeedbackOutboxException.Reason.INVALID_RECORD,
                    )
                }
                val entry = metaEntries.single()
                if (entry.size !in 1..MAX_META_BYTES.toLong()) {
                    throw FeedbackOutboxException(
                        FeedbackOutboxException.Reason.INVALID_RECORD,
                    )
                }
                val bytes = zip.getInputStream(entry).use { input ->
                    val output = java.io.ByteArrayOutputStream(entry.size.toInt())
                    val buffer = ByteArray(16 * 1024)
                    var total = 0
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_META_BYTES) {
                            throw FeedbackOutboxException(
                                FeedbackOutboxException.Reason.INVALID_RECORD,
                            )
                        }
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                }
                return appVersionFromMeta(bytes)
            }
        } catch (error: FeedbackOutboxException) {
            throw error
        } catch (_: ZipException) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        } catch (error: IOException) {
            throw FeedbackOutboxException(feedbackArchiveReadFailureReason(error))
        } catch (_: SecurityException) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.STATE_UNAVAILABLE)
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
    }

    private fun appVersionFromMeta(bytes: ByteArray): String {
        val appVersion = try {
            JSONObject(bytes.toString(Charsets.UTF_8)).getString("app_version")
        } catch (_: Exception) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        if (!appVersion.matches(APP_VERSION)) {
            throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        }
        return appVersion
    }
}

internal fun feedbackArchiveReadFailureReason(
    error: IOException,
): FeedbackOutboxException.Reason =
    if (error is ZipException) {
        FeedbackOutboxException.Reason.INVALID_RECORD
    } else {
        FeedbackOutboxException.Reason.STATE_UNAVAILABLE
    }

internal fun feedbackArchiveValidationFailureIsRetryable(
    error: Exception,
): Boolean =
    error !is FeedbackArchiveException ||
        error.reason == FeedbackArchiveException.Reason.WRITE_FAILED

private fun JSONObject.nullableString(name: String): String? =
    if (isNull(name)) null else getString(name)

private fun JSONObject.nullableLong(name: String): Long? =
    if (isNull(name)) null else getLong(name)

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
