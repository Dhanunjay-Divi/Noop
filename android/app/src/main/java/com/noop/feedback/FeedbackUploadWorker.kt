package com.noop.feedback

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.noop.AppDiagnosticsRecorder
import com.noop.BuildConfig
import java.util.LinkedHashMap
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

internal data class FeedbackRuntimeStatus(
    val record: FeedbackRecord,
    val progressPercent: Int,
    val receipt: String? = record.receipt,
)

/** Process-local presentation only. Progress never enters the durable outbox or logs. */
internal object FeedbackRuntimeStatusBus {
    private const val MAX_STATUSES = 8
    private val lock = Any()
    private val mutableStatuses =
        MutableStateFlow<Map<String, FeedbackRuntimeStatus>>(emptyMap())
    val statuses: StateFlow<Map<String, FeedbackRuntimeStatus>> =
        mutableStatuses.asStateFlow()

    fun publish(
        record: FeedbackRecord,
        progressPercent: Int,
        receipt: String? = record.receipt,
    ) {
        val safeReceipt = receipt?.takeIf {
            it.matches(Regex("^NF-[A-Z2-7]{16}$"))
        }
        synchronized(lock) {
            val next = LinkedHashMap(mutableStatuses.value)
            if (!FeedbackRuntimeStatusPolicy.shouldPublish(next[record.localId]?.record, record)) {
                return
            }
            next.remove(record.localId)
            next[record.localId] = FeedbackRuntimeStatus(
                record = record,
                progressPercent = progressPercent.coerceIn(0, 100),
                receipt = safeReceipt,
            )
            while (next.size > MAX_STATUSES) {
                next.remove(next.keys.first())
            }
            mutableStatuses.value = next.toMap()
        }
    }

    fun forget(localId: String) {
        synchronized(lock) {
            if (localId !in mutableStatuses.value) return
            mutableStatuses.value = mutableStatuses.value - localId
        }
    }
}

internal object FeedbackRuntimeStatusPolicy {
    fun shouldPublish(current: FeedbackRecord?, incoming: FeedbackRecord): Boolean {
        if (current == null) return true
        if (current.state.terminal && incoming.state != current.state) return false
        if (current.state.isCancellationState() &&
            !incoming.state.isCancellationState() &&
            incoming.state != FeedbackState.CANCELED
        ) {
            return false
        }
        if (incoming.state.isCancellationState() &&
            !current.state.isCancellationState()
        ) {
            return true
        }
        if (incoming.updatedAtMillis < current.updatedAtMillis) return false
        return true
    }
}

internal data class FeedbackRetryDecision(
    val category: FeedbackFailureCategory,
    val retryAutomatically: Boolean,
)

internal object FeedbackRetryPolicy {
    fun classify(error: Throwable): FeedbackRetryDecision = when (error) {
        is FeedbackProtocolException.Network ->
            FeedbackRetryDecision(FeedbackFailureCategory.NETWORK, true)
        is FeedbackProtocolException.Attestation ->
            FeedbackRetryDecision(FeedbackFailureCategory.ATTESTATION, true)
        is FeedbackProtocolException.Identity ->
            FeedbackRetryDecision(FeedbackFailureCategory.IDENTITY, true)
        is FeedbackProtocolException.Configuration ->
            FeedbackRetryDecision(FeedbackFailureCategory.CONFIGURATION, false)
        is FeedbackProtocolException.InvalidResponse ->
            FeedbackRetryDecision(FeedbackFailureCategory.INVALID_RESPONSE, false)
        is FeedbackProtocolException.Http -> when {
            error.statusCode in setOf(401, 403, 408, 409, 412, 425, 429) ||
                error.statusCode >= 500 ->
                FeedbackRetryDecision(FeedbackFailureCategory.SERVER_RETRYABLE, true)
            else ->
                FeedbackRetryDecision(FeedbackFailureCategory.SERVER_REJECTED, false)
        }
        is FeedbackArchiveException ->
            FeedbackRetryDecision(FeedbackFailureCategory.ARCHIVE_INVALID, false)
        is FeedbackOutboxException ->
            FeedbackRetryDecision(FeedbackFailureCategory.UNKNOWN, false)
        else -> FeedbackRetryDecision(FeedbackFailureCategory.UNKNOWN, false)
    }

    fun uploadProgress(uploadedBytes: Long, totalBytes: Long): Int {
        if (totalBytes <= 0L) return 10
        val fraction = (uploadedBytes.coerceIn(0L, totalBytes).toDouble() / totalBytes.toDouble())
        return (10.0 + fraction * 80.0).roundToInt().coerceIn(10, 90)
    }

    fun shouldRetry(decision: FeedbackRetryDecision, attempt: Int): Boolean =
        decision.retryAutomatically && attempt < FeedbackOutbox.MAX_ATTEMPTS

    fun shouldRetryCancellation(
        decision: FeedbackRetryDecision,
        attempt: Int,
    ): Boolean = decision.retryAutomatically && attempt < FeedbackOutbox.MAX_ATTEMPTS

    fun nextCancellationAttempt(persistedAttempt: Int): Int = persistedAttempt + 1
}

internal enum class FeedbackStateReadOutcome(val wireValue: String) {
    DEFERRED("deferred"),
    EXHAUSTED("exhausted"),
    REJECTED("rejected"),
}

internal data class FeedbackStateReadDecision(
    val outcome: FeedbackStateReadOutcome,
    val retry: Boolean,
)

internal object FeedbackWorkerStateReadPolicy {
    fun decide(
        reason: FeedbackOutboxException.Reason,
        runAttemptCount: Int,
    ): FeedbackStateReadDecision {
        if (reason != FeedbackOutboxException.Reason.STATE_UNAVAILABLE) {
            return FeedbackStateReadDecision(
                outcome = FeedbackStateReadOutcome.REJECTED,
                retry = false,
            )
        }
        val retry = runAttemptCount + 1 < FeedbackOutbox.MAX_ATTEMPTS
        return FeedbackStateReadDecision(
            outcome = if (retry) {
                FeedbackStateReadOutcome.DEFERRED
            } else {
                FeedbackStateReadOutcome.EXHAUSTED
            },
            retry = retry,
        )
    }
}

internal object FeedbackIdentityContinuityPolicy {
    fun canContactRemote(record: FeedbackRecord): Boolean =
        record.serverReportId == null || record.identitySubjectSha256 != null
}

/**
 * One authorization context per worker attempt. Cached credentials are replayed once with a forced
 * Firebase refresh only after an API 401/403; a second rejection is returned to the normal retry policy.
 */
internal class FeedbackAuthorizedSession(
    private val provider: FeedbackAuthorizationProvider,
    expectedIdentitySubjectSha256: String? = null,
) {
    private var current: FeedbackAuthorization? = null
    private var identitySubjectSha256: String? = expectedIdentitySubjectSha256
    private var refreshedAfterRejection = false

    suspend fun identitySubjectSha256(): String {
        val authorization = current ?: accept(provider.authorization(forceRefresh = false))
        return feedbackIdentitySubjectSha256(authorization.identitySubject)
    }

    suspend fun <T> request(
        operation: suspend (FeedbackAuthorization) -> T,
    ): T {
        val authorization = current ?: accept(provider.authorization(forceRefresh = false))
        try {
            return operation(authorization)
        } catch (error: FeedbackProtocolException.Http) {
            if (error.statusCode !in setOf(401, 403) || refreshedAfterRejection) {
                throw error
            }
        }

        refreshedAfterRejection = true
        val refreshed = accept(provider.authorization(forceRefresh = true))
        return operation(refreshed)
    }

    private fun accept(authorization: FeedbackAuthorization): FeedbackAuthorization {
        val subject = authorization.identitySubject
        val subjectSha256 = feedbackIdentitySubjectSha256(subject)
        if (subject.isBlank() ||
            subject.length > MAX_IDENTITY_SUBJECT_LENGTH ||
            identitySubjectSha256?.let { it != subjectSha256 } == true
        ) {
            throw FeedbackProtocolException.Identity()
        }
        identitySubjectSha256 = subjectSha256
        current = authorization
        return authorization
    }

    private companion object {
        const val MAX_IDENTITY_SUBJECT_LENGTH = 256
    }
}

internal class FeedbackAttemptClient(
    provider: FeedbackAuthorizationProvider,
    private val transport: FeedbackTransport,
    expectedIdentitySubjectSha256: String? = null,
) {
    private val authorization = FeedbackAuthorizedSession(
        provider = provider,
        expectedIdentitySubjectSha256 = expectedIdentitySubjectSha256,
    )

    suspend fun identitySubjectSha256(): String = authorization.identitySubjectSha256()

    suspend fun reserve(
        idempotencyKey: UUID,
        request: FeedbackReservationRequest,
    ): FeedbackReservation = authorization.request {
        transport.reserve(it, idempotencyKey, request)
    }

    suspend fun complete(
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus = authorization.request {
        transport.complete(it, reportId, reportToken)
    }

    suspend fun status(
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus = authorization.request {
        transport.status(it, reportId, reportToken)
    }

    suspend fun cancel(
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus = authorization.request {
        transport.cancel(it, reportId, reportToken)
    }

    suspend fun upload(
        archive: java.io.File,
        expectedBytes: Long,
        expectedSha256: String,
        capability: FeedbackUploadCapability,
        progress: (uploadedBytes: Long, totalBytes: Long) -> Unit,
    ) {
        transport.upload(
            archive = archive,
            expectedBytes = expectedBytes,
            expectedSha256 = expectedSha256,
            capability = capability,
            progress = progress,
        )
    }
}

/**
 * Signed-object authorization is independent from Firebase authorization. Refresh the signed upload
 * capability once after Cloud Storage rejects it; the second upload result is authoritative.
 */
internal suspend fun uploadWithSingleCapabilityRefresh(
    initialCapability: FeedbackUploadCapability,
    upload: suspend (FeedbackUploadCapability) -> Unit,
    refreshCapability: suspend () -> FeedbackUploadCapability,
): FeedbackUploadCapability {
    try {
        upload(initialCapability)
        return initialCapability
    } catch (error: FeedbackProtocolException.Http) {
        if (error.statusCode !in setOf(401, 403)) throw error
    }

    val refreshed = refreshCapability()
    upload(refreshed)
    return refreshed
}

internal class FeedbackProgressThrottler(
    private val minimumPercentDelta: Int = 5,
    private val minimumIntervalMillis: Long = 1_000L,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private var lastPercent = -1
    private var lastPublishedAt = Long.MIN_VALUE

    fun shouldPublish(percent: Int): Boolean {
        val bounded = percent.coerceIn(0, 100)
        if (bounded == lastPercent) return false
        val now = nowMillis()
        val first = lastPercent < 0
        val advanced = bounded - lastPercent >= minimumPercentDelta
        val elapsed = lastPublishedAt != Long.MIN_VALUE &&
            now - lastPublishedAt >= minimumIntervalMillis
        if (!first && !advanced && !elapsed && bounded !in setOf(90, 100)) return false
        lastPercent = bounded
        lastPublishedAt = now
        return true
    }
}

internal enum class FeedbackRemoteAction {
    CONTINUE_UPLOAD,
    MARK_SENT,
    REJECT,
    REQUEST_DELETE,
    WAIT_FOR_DELETE,
    MARK_DELETED,
}

internal object FeedbackRemoteStatusPolicy {
    fun recoverUpload(status: String): FeedbackRemoteAction = when (status) {
        "reserved" -> FeedbackRemoteAction.CONTINUE_UPLOAD
        "sent" -> FeedbackRemoteAction.MARK_SENT
        "rejected" -> FeedbackRemoteAction.REJECT
        "deleting" -> FeedbackRemoteAction.REQUEST_DELETE
        "deleted" -> FeedbackRemoteAction.MARK_DELETED
        else -> throw FeedbackProtocolException.InvalidResponse()
    }

    fun recoverCancellation(status: String): FeedbackRemoteAction = when (status) {
        "deleting" -> FeedbackRemoteAction.WAIT_FOR_DELETE
        "deleted" -> FeedbackRemoteAction.MARK_DELETED
        "reserved",
        "sent",
        "rejected",
        -> FeedbackRemoteAction.REQUEST_DELETE
        else -> throw FeedbackProtocolException.InvalidResponse()
    }
}

internal object FeedbackCancellationPolicy {
    fun requiresReservationReconciliation(record: FeedbackRecord): Boolean =
        record.serverReportId == null && record.attempt > 0
}

internal object FeedbackCancellationReconciler {
    suspend fun reconcile(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
        appVersion: String,
    ): FeedbackRecord {
        if (!FeedbackCancellationPolicy.requiresReservationReconciliation(record)) return record
        val identityBound = outbox.bindIdentity(
            localId = record.localId,
            identitySubjectSha256 = client.identitySubjectSha256(),
        )
        val reservation = client.reserve(
            idempotencyKey = UUID.fromString(identityBound.requestId),
            request = FeedbackReservationRequest(
                appVersion = appVersion,
                archiveBytes = identityBound.archiveBytes,
                archiveSha256 = identityBound.archiveSha256,
                includesUserNote = identityBound.includesUserNote,
                includesScreenshot = identityBound.includesScreenshot,
            ),
        )
        return outbox.saveReservation(
            localId = identityBound.localId,
            serverReportId = reservation.reportId,
            serverReportToken = reservation.reportToken,
        )
    }
}

internal object FeedbackScheduler {
    internal const val INPUT_LOCAL_ID = "local_id"
    internal const val PROGRESS_STAGE = "stage"
    internal const val PROGRESS_PERCENT = "percent"
    private const val WORK_PREFIX = "noop_feedback_upload_v1:"

    private val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun enqueue(context: Context, record: FeedbackRecord, replace: Boolean = false) {
        FeedbackRuntimeStatusBus.publish(record, progressFor(record.state))
        val request = OneTimeWorkRequestBuilder<FeedbackUploadWorker>()
            .setInputData(workDataOf(INPUT_LOCAL_ID to record.localId))
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            workName(record.localId),
            if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            request,
        )
    }

    fun retry(context: Context, localId: String): FeedbackRecord {
        val record = FeedbackOutbox.from(context).retry(localId)
        enqueue(context, record, replace = true)
        return record
    }

    fun cancel(context: Context, localId: String): FeedbackRecord {
        val record = FeedbackOutbox.from(context).requestCancel(localId)
        enqueue(context, record, replace = true)
        return record
    }

    /** Repairs the narrow crash window between atomic staging and WorkManager enqueue. */
    fun reconcile(context: Context) {
        FeedbackOutbox.from(context).recover().forEach { record ->
            when (record.state) {
                FeedbackState.QUEUED,
                FeedbackState.UPLOADING,
                FeedbackState.RETRY_SCHEDULED,
                FeedbackState.CANCELING,
                FeedbackState.CANCEL_RETRY_SCHEDULED,
                -> enqueue(context, record)
                FeedbackState.FAILED,
                FeedbackState.CANCEL_FAILED,
                FeedbackState.SENT,
                FeedbackState.CANCELED,
                -> FeedbackRuntimeStatusBus.publish(record, progressFor(record.state))
            }
        }
    }

    internal fun workName(localId: String): String =
        "$WORK_PREFIX${UUID.fromString(localId).toString().lowercase(Locale.US)}"

    internal fun progressFor(state: FeedbackState): Int = when (state) {
        FeedbackState.QUEUED,
        FeedbackState.RETRY_SCHEDULED,
        FeedbackState.CANCELING,
        FeedbackState.CANCEL_RETRY_SCHEDULED,
        FeedbackState.FAILED,
        FeedbackState.CANCEL_FAILED,
        FeedbackState.CANCELED,
        -> 0
        FeedbackState.UPLOADING -> 5
        FeedbackState.SENT -> 100
    }
}

class FeedbackUploadWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val localId = inputData.getString(FeedbackScheduler.INPUT_LOCAL_ID)
            ?.let { runCatching { UUID.fromString(it).toString().lowercase(Locale.US) }.getOrNull() }
            ?: return@withContext Result.failure()
        val outbox = FeedbackOutbox.from(applicationContext)
        val initial = try {
            outbox.load(localId)
        } catch (error: FeedbackOutboxException) {
            val decision = FeedbackWorkerStateReadPolicy.decide(
                reason = error.reason,
                runAttemptCount = runAttemptCount,
            )
            AppDiagnosticsRecorder.record(
                "feedback.worker_state_read",
                fields = mapOf(
                    "outcome" to decision.outcome.wireValue,
                ),
            )
            return@withContext if (decision.retry) {
                Result.retry()
            } else {
                Result.failure()
            }
        } ?: return@withContext Result.success()
        when (initial.state) {
            FeedbackState.SENT,
            FeedbackState.CANCELED,
            FeedbackState.FAILED,
            FeedbackState.CANCEL_FAILED,
            -> {
                FeedbackRuntimeStatusBus.publish(
                    initial,
                    FeedbackScheduler.progressFor(initial.state),
                )
                return@withContext Result.success()
            }
            FeedbackState.CANCELING,
            FeedbackState.CANCEL_RETRY_SCHEDULED,
            -> return@withContext cancelReport(outbox, initial)
            else -> uploadReport(outbox, initial)
        }
    }

    private suspend fun uploadReport(
        outbox: FeedbackOutbox,
        initial: FeedbackRecord,
    ): Result {
        val attempt = maxOf(initial.attempt + 1, runAttemptCount + 1)
        if (attempt > FeedbackOutbox.MAX_ATTEMPTS) {
            return failPermanently(
                outbox,
                initial.localId,
                FeedbackFailureCategory.UNKNOWN,
                cancel = false,
            )
        }
        val uploading = try {
            outbox.beginUpload(initial.localId, attempt)
        } catch (error: Throwable) {
            return handleFailure(outbox, initial.localId, attempt, error, cancel = false)
        }
        publishProgress(uploading, "reserving", 5)
        if (!FeedbackIdentityContinuityPolicy.canContactRemote(uploading)) {
            return failPermanently(
                outbox = outbox,
                localId = uploading.localId,
                category = FeedbackFailureCategory.IDENTITY,
                cancel = false,
            )
        }

        return try {
            val archive = outbox.archive(uploading)
            FeedbackArchive.validate(
                archive = archive,
                expectedBytes = uploading.archiveBytes,
                expectedSha256 = uploading.archiveSha256,
                includesUserNote = uploading.includesUserNote,
                includesScreenshot = uploading.includesScreenshot,
            )
            val configuration = FeedbackConfiguration.load()
                ?: throw FeedbackProtocolException.Configuration()
            val client = feedbackClient(uploading, configuration)
            val reservationRequest = reservationRequest(uploading)
            val idempotencyKey = UUID.fromString(uploading.requestId)

            if (uploading.serverReportId != null) {
                reconcileExistingReservation(
                    outbox = outbox,
                    record = uploading,
                    client = client,
                )?.let { return it }
            }

            val currentBeforeReservation = outbox.load(uploading.localId)
                ?: return Result.success()
            if (currentBeforeReservation.state.isCancellationState()) {
                return cancelReport(outbox, currentBeforeReservation, client)
            }
            val identityBound = bindIdentity(outbox, currentBeforeReservation, client)
            if (identityBound.state.isCancellationState()) {
                return cancelReport(outbox, identityBound, client)
            }
            val currentBeforeRemoteReservation = outbox.load(identityBound.localId)
                ?: return Result.success()
            if (currentBeforeRemoteReservation.state.isCancellationState()) {
                return cancelReport(outbox, currentBeforeRemoteReservation, client)
            }

            val reservation = client.reserve(
                idempotencyKey = idempotencyKey,
                request = reservationRequest,
            )
            val reserved = outbox.saveReservation(
                uploading.localId,
                reservation.reportId,
                reservation.reportToken,
            )
            if (reserved.state.isCancellationState()) {
                return cancelReport(outbox, reserved, client)
            }

            if (reservation.status != "reserved") {
                val remote = client.status(
                    reportId = reservation.reportId,
                    reportToken = reservation.reportToken,
                )
                return when (FeedbackRemoteStatusPolicy.recoverUpload(remote.status)) {
                    FeedbackRemoteAction.MARK_SENT ->
                        commitRemoteSent(outbox, reserved.localId, remote, client)
                    FeedbackRemoteAction.MARK_DELETED -> {
                        val canceling = outbox.requestCancel(reserved.localId)
                        val canceled = outbox.markCanceled(canceling.localId)
                        publishProgress(canceled, "canceled", 0)
                        Result.success()
                    }
                    FeedbackRemoteAction.REJECT ->
                        failPermanently(
                            outbox,
                            reserved.localId,
                            FeedbackFailureCategory.SERVER_REJECTED,
                            cancel = false,
                        )
                    FeedbackRemoteAction.REQUEST_DELETE -> {
                        val canceling = outbox.requestCancel(reserved.localId)
                        cancelReport(outbox, canceling, client)
                    }
                    FeedbackRemoteAction.CONTINUE_UPLOAD ->
                        throw FeedbackProtocolException.InvalidResponse()
                    FeedbackRemoteAction.WAIT_FOR_DELETE ->
                        throw FeedbackProtocolException.InvalidResponse()
                }
            }
            val upload = reservation.upload
                ?: throw FeedbackProtocolException.InvalidResponse()
            publishProgress(reserved, "uploading", 10)
            val progressThrottler = FeedbackProgressThrottler()
            uploadWithSingleCapabilityRefresh(
                initialCapability = upload,
                upload = { capability ->
                    client.upload(
                        archive = archive,
                        expectedBytes = reserved.archiveBytes,
                        expectedSha256 = reserved.archiveSha256,
                        capability = capability,
                    ) { sent, total ->
                        val percent = FeedbackRetryPolicy.uploadProgress(sent, total)
                        if (progressThrottler.shouldPublish(percent)) {
                            publishTransientProgress(outbox, reserved.localId, percent)
                        }
                    }
                },
                refreshCapability = {
                    val refreshed = client.reserve(
                        idempotencyKey = idempotencyKey,
                        request = reservationRequest,
                    )
                    if (refreshed.status != "reserved" || refreshed.upload == null) {
                        throw FeedbackProtocolException.InvalidResponse()
                    }
                    outbox.saveReservation(
                        reserved.localId,
                        refreshed.reportId,
                        refreshed.reportToken,
                    )
                    refreshed.upload
                },
            )
            val beforeComplete = outbox.load(reserved.localId) ?: return Result.success()
            if (beforeComplete.state.isCancellationState()) {
                return cancelReport(outbox, beforeComplete, client)
            }

            publishProgress(beforeComplete, "finalizing", 95)
            val completed = client.complete(
                reportId = reservation.reportId,
                reportToken = reservation.reportToken,
            )
            commitRemoteSent(outbox, reserved.localId, completed, client)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            handleFailure(outbox, uploading.localId, attempt, error, cancel = false)
        }
    }

    private suspend fun reconcileExistingReservation(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
    ): Result? {
        val reportId = record.serverReportId
            ?: throw FeedbackProtocolException.InvalidResponse()
        val reportToken = record.serverReportToken
            ?: throw FeedbackProtocolException.InvalidResponse()
        val current = client.status(reportId, reportToken)
        applyRemoteStatus(outbox, record, current, client)?.let { return it }

        val completed = try {
            client.complete(reportId, reportToken)
        } catch (error: FeedbackProtocolException.Http) {
            if (error.statusCode != 409) throw error
            val refreshed = client.status(reportId, reportToken)
            return applyRemoteStatus(outbox, record, refreshed, client)
        }
        return applyRemoteStatus(outbox, record, completed, client)
            ?: throw FeedbackProtocolException.InvalidResponse()
    }

    private suspend fun applyRemoteStatus(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        remote: FeedbackRemoteStatus,
        client: FeedbackAttemptClient,
    ): Result? = when (FeedbackRemoteStatusPolicy.recoverUpload(remote.status)) {
        FeedbackRemoteAction.MARK_SENT ->
            commitRemoteSent(outbox, record.localId, remote, client)
        FeedbackRemoteAction.MARK_DELETED -> {
            val canceling = outbox.requestCancel(record.localId)
            val canceled = outbox.markCanceled(canceling.localId)
            publishProgress(canceled, "canceled", 0)
            Result.success()
        }
        FeedbackRemoteAction.REJECT ->
            failPermanently(
                outbox,
                record.localId,
                FeedbackFailureCategory.SERVER_REJECTED,
                cancel = false,
            )
        FeedbackRemoteAction.REQUEST_DELETE -> {
            val canceling = outbox.requestCancel(record.localId)
            cancelReport(outbox, canceling, client)
        }
        FeedbackRemoteAction.WAIT_FOR_DELETE ->
            throw FeedbackProtocolException.InvalidResponse()
        FeedbackRemoteAction.CONTINUE_UPLOAD -> null
    }

    private suspend fun commitRemoteSent(
        outbox: FeedbackOutbox,
        localId: String,
        remote: FeedbackRemoteStatus,
        client: FeedbackAttemptClient,
    ): Result {
        val receipt = remote.receipt
            ?: throw FeedbackProtocolException.InvalidResponse()
        val retainedUntil = remote.retainedUntil
            ?: throw FeedbackProtocolException.InvalidResponse()
        return when (
            val commit = outbox.commitCompletion(
                localId = localId,
                receipt = receipt,
                retainedUntil = retainedUntil,
            )
        ) {
            is FeedbackCompletionCommit.Sent -> {
                publishProgress(commit.record, "sent", 100, receipt)
                Result.success()
            }
            is FeedbackCompletionCommit.CancellationRequired ->
                cancelReport(outbox, commit.record, client)
        }
    }

    private suspend fun cancelReport(
        outbox: FeedbackOutbox,
        initial: FeedbackRecord,
        existingClient: FeedbackAttemptClient? = null,
    ): Result {
        val attempt = FeedbackRetryPolicy.nextCancellationAttempt(initial.cancellationAttempt)
        if (attempt > FeedbackOutbox.MAX_ATTEMPTS) {
            return failPermanently(
                outbox = outbox,
                localId = initial.localId,
                category = FeedbackFailureCategory.DELETION_PENDING,
                cancel = true,
            )
        }
        var canceling = try {
            outbox.noteCancelAttempt(
                initial.localId,
                attempt,
            )
        } catch (error: Throwable) {
            return handleFailure(outbox, initial.localId, attempt, error, cancel = true)
        }
        publishProgress(canceling, "canceling", 0)
        if (!FeedbackIdentityContinuityPolicy.canContactRemote(canceling)) {
            return failPermanently(
                outbox = outbox,
                localId = canceling.localId,
                category = FeedbackFailureCategory.IDENTITY,
                cancel = true,
            )
        }
        return try {
            var client = existingClient
            if (FeedbackCancellationPolicy.requiresReservationReconciliation(canceling)) {
                client = client ?: feedbackClient(canceling)
                canceling = FeedbackCancellationReconciler.reconcile(
                    outbox = outbox,
                    record = canceling,
                    client = client,
                    appVersion = BuildConfig.VERSION_NAME,
                )
            }
            val reportId = canceling.serverReportId
            val reportToken = canceling.serverReportToken
            if (reportId != null && reportToken != null) {
                client = client ?: feedbackClient(canceling)
                bindIdentity(outbox, canceling, client)
                val current = client.status(
                    reportId = reportId,
                    reportToken = reportToken,
                )
                when (FeedbackRemoteStatusPolicy.recoverCancellation(current.status)) {
                    FeedbackRemoteAction.MARK_DELETED -> {
                        val canceled = outbox.markCanceled(canceling.localId)
                        publishProgress(canceled, "canceled", 0)
                        return Result.success()
                    }
                    FeedbackRemoteAction.WAIT_FOR_DELETE ->
                        return scheduleDeletionPoll(outbox, canceling.localId)
                    FeedbackRemoteAction.REQUEST_DELETE -> Unit
                    else -> throw FeedbackProtocolException.InvalidResponse()
                }
                val deletion = client.cancel(
                    reportId = reportId,
                    reportToken = reportToken,
                )
                return when (FeedbackRemoteStatusPolicy.recoverCancellation(deletion.status)) {
                    FeedbackRemoteAction.MARK_DELETED -> {
                        val canceled = outbox.markCanceled(canceling.localId)
                        publishProgress(canceled, "canceled", 0)
                        Result.success()
                    }
                    FeedbackRemoteAction.WAIT_FOR_DELETE ->
                        scheduleDeletionPoll(outbox, canceling.localId)
                    FeedbackRemoteAction.REQUEST_DELETE ->
                        scheduleDeletionPoll(outbox, canceling.localId)
                    else -> throw FeedbackProtocolException.InvalidResponse()
                }
            }
            val canceled = outbox.markCanceled(canceling.localId)
            publishProgress(canceled, "canceled", 0)
            Result.success()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            handleFailure(outbox, canceling.localId, attempt, error, cancel = true)
        }
    }

    private suspend fun scheduleDeletionPoll(
        outbox: FeedbackOutbox,
        localId: String,
    ): Result {
        val current = outbox.load(localId) ?: return Result.success()
        if (current.cancellationAttempt >= FeedbackOutbox.MAX_ATTEMPTS) {
            return failPermanently(
                outbox = outbox,
                localId = localId,
                category = FeedbackFailureCategory.DELETION_PENDING,
                cancel = true,
            )
        }
        val retry = outbox.scheduleCancelRetry(
            localId,
            FeedbackFailureCategory.DELETION_PENDING,
        )
        publishProgress(retry, "cancel_retry_scheduled", 0)
        return Result.retry()
    }

    private suspend fun handleFailure(
        outbox: FeedbackOutbox,
        localId: String,
        attempt: Int,
        error: Throwable,
        cancel: Boolean,
    ): Result {
        val decision = FeedbackRetryPolicy.classify(error)
        val shouldRetry = if (cancel) {
            FeedbackRetryPolicy.shouldRetryCancellation(decision, attempt)
        } else {
            FeedbackRetryPolicy.shouldRetry(decision, attempt)
        }
        return if (shouldRetry) {
            val record = if (cancel) {
                outbox.scheduleCancelRetry(localId, decision.category)
            } else {
                outbox.scheduleRetry(localId, decision.category)
            }
            publishProgress(
                record,
                if (cancel) "cancel_retry_scheduled" else "retry_scheduled",
                0,
            )
            Result.retry()
        } else {
            failPermanently(outbox, localId, decision.category, cancel)
        }
    }

    private suspend fun failPermanently(
        outbox: FeedbackOutbox,
        localId: String,
        category: FeedbackFailureCategory,
        cancel: Boolean,
    ): Result {
        val record = if (cancel) {
            outbox.markCancelFailed(localId, category)
        } else {
            outbox.markFailed(localId, category)
        }
        publishProgress(record, if (cancel) "cancel_failed" else "failed", 0)
        return Result.failure(
            workDataOf("failure_category" to category.wireValue),
        )
    }

    private suspend fun publishProgress(
        record: FeedbackRecord,
        stage: String,
        percent: Int,
        receipt: String? = null,
    ) {
        val boundedPercent = percent.coerceIn(0, 100)
        runCatching {
            setProgress(
                workDataOf(
                    FeedbackScheduler.PROGRESS_STAGE to stage,
                    FeedbackScheduler.PROGRESS_PERCENT to boundedPercent,
                ),
            )
        }
        FeedbackRuntimeStatusBus.publish(record, boundedPercent, receipt)
    }

    private fun publishTransientProgress(
        outbox: FeedbackOutbox,
        localId: String,
        percent: Int,
    ) {
        val current = runCatching { outbox.load(localId) }.getOrNull() ?: return
        if (current.state != FeedbackState.UPLOADING) return
        FeedbackRuntimeStatusBus.publish(current, percent.coerceIn(0, 100))
    }

    private fun feedbackClient(
        record: FeedbackRecord,
        configuration: FeedbackConfiguration? = null,
    ): FeedbackAttemptClient {
        if (!FeedbackIdentityContinuityPolicy.canContactRemote(record)) {
            throw FeedbackProtocolException.Identity()
        }
        val resolvedConfiguration = configuration
            ?: FeedbackConfiguration.load()
            ?: throw FeedbackProtocolException.Configuration()
        return FeedbackAttemptClient(
            provider = FirebaseFeedbackAuthorizationProvider(
                context = applicationContext,
                allowIdentityReplacement =
                    record.identitySubjectSha256 == null && record.serverReportId == null,
            ),
            transport = FeedbackApiClient(resolvedConfiguration),
            expectedIdentitySubjectSha256 = record.identitySubjectSha256,
        )
    }

    private suspend fun bindIdentity(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
    ): FeedbackRecord {
        val identitySubjectSha256 = client.identitySubjectSha256()
        return outbox.bindIdentity(record.localId, identitySubjectSha256)
    }

    private fun reservationRequest(record: FeedbackRecord): FeedbackReservationRequest =
        FeedbackReservationRequest(
            appVersion = BuildConfig.VERSION_NAME,
            archiveBytes = record.archiveBytes,
            archiveSha256 = record.archiveSha256,
            includesUserNote = record.includesUserNote,
            includesScreenshot = record.includesScreenshot,
        )
}

private fun FeedbackState.isCancellationState(): Boolean =
    this == FeedbackState.CANCELING ||
        this == FeedbackState.CANCEL_RETRY_SCHEDULED ||
        this == FeedbackState.CANCEL_FAILED
