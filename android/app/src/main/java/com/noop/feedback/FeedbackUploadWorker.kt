package com.noop.feedback

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.await
import androidx.work.workDataOf
import com.noop.AppDiagnosticsRecorder
import java.io.IOException
import java.time.Instant
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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
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
    val preservesAttemptBudget: Boolean = false,
    val allowsBoundIdentityContinuity: Boolean = false,
)

internal object FeedbackRetryPolicy {
    fun classify(error: Throwable): FeedbackRetryDecision = when (error) {
        is FeedbackProtocolException.Network ->
            FeedbackRetryDecision(FeedbackFailureCategory.NETWORK, true)
        is FeedbackProtocolException.Attestation ->
            FeedbackRetryDecision(FeedbackFailureCategory.ATTESTATION, true)
        is FeedbackProtocolException.Identity ->
            FeedbackRetryDecision(FeedbackFailureCategory.IDENTITY, true)
        is FeedbackProtocolException.ReservationContinuityPending ->
            FeedbackRetryDecision(
                category = FeedbackFailureCategory.IDENTITY,
                retryAutomatically = true,
                preservesAttemptBudget = true,
            )
        is FeedbackProtocolException.ReservationPending ->
            FeedbackRetryDecision(
                category = FeedbackFailureCategory.DELETION_PENDING,
                retryAutomatically = true,
                preservesAttemptBudget = true,
                allowsBoundIdentityContinuity = true,
            )
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
            if (feedbackArchiveValidationFailureIsRetryable(error)) {
                FeedbackRetryDecision(FeedbackFailureCategory.INTERRUPTED, true)
            } else {
                FeedbackRetryDecision(FeedbackFailureCategory.ARCHIVE_INVALID, false)
            }
        is IOException ->
            FeedbackRetryDecision(FeedbackFailureCategory.INTERRUPTED, true)
        is FeedbackOutboxException -> when (error.reason) {
            FeedbackOutboxException.Reason.STATE_UNAVAILABLE,
            FeedbackOutboxException.Reason.WRITE_FAILED,
            -> FeedbackRetryDecision(FeedbackFailureCategory.INTERRUPTED, true)
            else -> FeedbackRetryDecision(FeedbackFailureCategory.UNKNOWN, false)
        }
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

    fun nextDeliveryAttempt(persistedAttempt: Int): Int = persistedAttempt + 1

    fun nextCancellationAttempt(persistedAttempt: Int): Int = persistedAttempt + 1
}

internal data class FeedbackServerRetentionDecision(
    val retainedUntil: String,
    val accepted: Boolean,
)

internal object FeedbackServerRetentionResponsePolicy {
    fun evaluate(
        record: FeedbackRecord,
        retainedUntil: String,
        nowMillis: Long,
    ): FeedbackServerRetentionDecision {
        val retainedUntilMillis = runCatching {
            Instant.parse(retainedUntil).toEpochMilli()
        }.getOrElse {
            throw FeedbackProtocolException.InvalidResponse()
        }
        val accepted = FeedbackReservationContinuityPolicy.serverRetentionIsValid(
            record = record,
            retainedUntilMillis = retainedUntilMillis,
            nowMillis = nowMillis,
        )
        val bounded = FeedbackReservationContinuityPolicy
            .boundedServerRetainedUntilMillis(
                record = record,
                retainedUntilMillis = retainedUntilMillis,
                nowMillis = nowMillis,
            )
        return FeedbackServerRetentionDecision(
            retainedUntil = Instant.ofEpochMilli(bounded).toString(),
            accepted = accepted,
        )
    }
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

    suspend fun <T> bindIdentity(
        bind: suspend (identitySubjectSha256: String) -> T,
    ): T = provider.authorizationAndBind(forceRefresh = false) { authorization ->
        val accepted = accept(authorization)
        bind(feedbackIdentitySubjectSha256(accepted.identitySubject))
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

    suspend fun <T> bindIdentity(
        bind: suspend (identitySubjectSha256: String) -> T,
    ): T = authorization.bindIdentity(bind)

    suspend fun reserve(
        idempotencyKey: UUID,
        request: FeedbackReservationRequest,
    ): FeedbackReservation = authorization.request {
        transport.reserve(it, idempotencyKey, request)
    }

    suspend fun recoverReservation(
        idempotencyKey: UUID,
    ): FeedbackReservation? = authorization.request {
        transport.recoverReservation(it, idempotencyKey)
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

internal sealed interface FeedbackDeliveryReservationRecovery {
    data class Recovered(
        val reservation: FeedbackReservation,
    ) : FeedbackDeliveryReservationRecovery

    data class Retired(
        val record: FeedbackRecord,
    ) : FeedbackDeliveryReservationRecovery
}

internal object FeedbackDeliveryReservationReconciler {
    suspend fun reconcile(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
        idempotencyKey: UUID,
        expectedWorkerGeneration: String? = null,
    ): FeedbackDeliveryReservationRecovery {
        val reservation = try {
            client.recoverReservation(idempotencyKey)
        } catch (_: FeedbackProtocolException.ReservationGone) {
            val canceling = outbox.requestCancel(
                localId = record.localId,
                expectedWorkerGeneration = expectedWorkerGeneration,
            )
            return FeedbackDeliveryReservationRecovery.Retired(
                outbox.markCanceled(
                    localId = canceling.localId,
                    expectedWorkerGeneration = expectedWorkerGeneration,
                ),
            )
        } ?: throw FeedbackProtocolException.ReservationPending()
        return FeedbackDeliveryReservationRecovery.Recovered(reservation)
    }
}

internal object FeedbackCancellationReconciler {
    suspend fun reconcile(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
        expectedWorkerGeneration: String? = null,
    ): FeedbackRecord {
        if (!FeedbackCancellationPolicy.requiresReservationReconciliation(record)) return record
        val identityBound = client.bindIdentity { identitySubjectSha256 ->
            outbox.bindIdentity(
                localId = record.localId,
                identitySubjectSha256 = identitySubjectSha256,
                expectedWorkerGeneration = expectedWorkerGeneration,
            )
        }
        val reservation = try {
            client.recoverReservation(
                idempotencyKey = UUID.fromString(identityBound.requestId),
            )
        } catch (_: FeedbackProtocolException.ReservationGone) {
            return outbox.markCanceled(
                localId = identityBound.localId,
                expectedWorkerGeneration = expectedWorkerGeneration,
            )
        } ?: throw FeedbackProtocolException.ReservationPending()
        val retention = FeedbackServerRetentionResponsePolicy.evaluate(
            record = identityBound,
            retainedUntil = reservation.retainedUntil,
            nowMillis = System.currentTimeMillis(),
        )
        return outbox.saveReservation(
            localId = identityBound.localId,
            serverReportId = reservation.reportId,
            serverReportToken = reservation.reportToken,
            retainedUntil = retention.retainedUntil,
            expectedWorkerGeneration = expectedWorkerGeneration,
        )
    }
}

internal object FeedbackBoundCancellationReconciler {
    suspend fun reconcile(
        client: FeedbackAttemptClient,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus {
        val current = try {
            client.status(
                reportId = reportId,
                reportToken = reportToken,
            )
        } catch (_: FeedbackProtocolException.ReservationPending) {
            null
        }
        if (current != null) {
            when (FeedbackRemoteStatusPolicy.recoverCancellation(current.status)) {
                FeedbackRemoteAction.MARK_DELETED,
                FeedbackRemoteAction.WAIT_FOR_DELETE,
                -> return current
                FeedbackRemoteAction.REQUEST_DELETE -> Unit
                else -> throw FeedbackProtocolException.InvalidResponse()
            }
        }
        return client.cancel(
            reportId = reportId,
            reportToken = reportToken,
        )
    }
}

internal object FeedbackReservationRequestFactory {
    fun from(record: FeedbackRecord): FeedbackReservationRequest =
        FeedbackReservationRequest(
            appVersion = record.appVersion
                ?: throw FeedbackProtocolException.InvalidResponse(),
            archiveBytes = record.archiveBytes,
            archiveSha256 = record.archiveSha256,
            includesUserNote = record.includesUserNote,
            includesScreenshot = record.includesScreenshot,
        )
}

internal object FeedbackScheduler {
    internal const val INPUT_LOCAL_ID = "local_id"
    internal const val INPUT_WORKER_GENERATION = "worker_generation"
    internal const val PROGRESS_STAGE = "stage"
    internal const val PROGRESS_PERCENT = "percent"
    private const val WORK_PREFIX = "noop_feedback_upload_v1:"
    private const val GENERATION_TAG_PREFIX = "noop_feedback_generation:"

    private val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun enqueue(
        context: Context,
        record: FeedbackRecord,
        replace: Boolean = false,
    ): FeedbackRecord {
        val prepared = FeedbackOutbox.from(context).prepareWorker(
            localId = record.localId,
            replace = replace,
        )
        enqueuePrepared(
            context = context,
            record = prepared,
            policy = if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            delayMillis = remainingRetryDelayMillis(prepared),
        )
        return prepared
    }

    private fun enqueuePrepared(
        context: Context,
        record: FeedbackRecord,
        policy: ExistingWorkPolicy,
        delayMillis: Long,
    ) {
        val generation = record.workerGeneration
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        FeedbackRuntimeStatusBus.publish(record, progressFor(record.state))
        val request = OneTimeWorkRequestBuilder<FeedbackUploadWorker>()
            .setInputData(
                workDataOf(
                    INPUT_LOCAL_ID to record.localId,
                    INPUT_WORKER_GENERATION to generation,
                ),
            )
            .setConstraints(constraints)
            .setInitialDelay(delayMillis.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(generationTag(generation))
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            workName(record.localId),
            policy,
            request,
        )
    }

    suspend fun enqueueContinuityRetry(
        context: Context,
        record: FeedbackRecord,
        delayMillis: Long,
    ) {
        val generation = record.workerGeneration
            ?: throw FeedbackOutboxException(FeedbackOutboxException.Reason.INVALID_RECORD)
        val persistedDelay = remainingRetryDelayMillis(record)
        val effectiveDelay = if (record.retryNotBeforeMillis != null) {
            persistedDelay
        } else {
            delayMillis
        }
        val request = OneTimeWorkRequestBuilder<FeedbackUploadWorker>()
            .setInputData(
                workDataOf(
                    INPUT_LOCAL_ID to record.localId,
                    INPUT_WORKER_GENERATION to generation,
                ),
            )
            .setConstraints(constraints)
            .setInitialDelay(
                effectiveDelay.coerceAtLeast(0L),
                TimeUnit.MILLISECONDS,
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(generationTag(generation))
            .build()
        FeedbackRuntimeStatusBus.publish(record, progressFor(record.state))
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            workName(record.localId),
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            request,
        ).await()
    }

    fun retry(context: Context, localId: String): FeedbackRecord {
        val generation = UUID.randomUUID().toString().lowercase(Locale.US)
        val record = FeedbackOutbox.from(context).retry(
            localId = localId,
            replacementWorkerGeneration = generation,
        )
        enqueuePrepared(
            context = context,
            record = record,
            policy = ExistingWorkPolicy.REPLACE,
            delayMillis = 0L,
        )
        return record
    }

    fun cancel(context: Context, localId: String): FeedbackRecord {
        val generation = UUID.randomUUID().toString().lowercase(Locale.US)
        val record = FeedbackOutbox.from(context).requestCancel(
            localId = localId,
            replacementWorkerGeneration = generation,
        )
        enqueuePrepared(
            context = context,
            record = record,
            policy = ExistingWorkPolicy.REPLACE,
            delayMillis = 0L,
        )
        return record
    }

    /** Repairs the narrow crash window between atomic staging and WorkManager enqueue. */
    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val outbox = FeedbackOutbox.from(appContext)
        val workManager = WorkManager.getInstance(appContext)
        outbox.recover().forEach { record ->
            when (record.state) {
                FeedbackState.QUEUED,
                FeedbackState.UPLOADING,
                FeedbackState.RETRY_SCHEDULED,
                FeedbackState.CANCELING,
                FeedbackState.CANCEL_RETRY_SCHEDULED,
                -> {
                    val prepared = outbox.prepareWorker(
                        localId = record.localId,
                        replace = false,
                    )
                    if (!hasUnfinishedGeneration(workManager, prepared)) {
                        enqueuePrepared(
                            context = appContext,
                            record = prepared,
                            policy = ExistingWorkPolicy.APPEND_OR_REPLACE,
                            delayMillis = remainingRetryDelayMillis(prepared),
                        )
                    }
                }
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

    internal fun generationTag(generation: String): String =
        "$GENERATION_TAG_PREFIX${UUID.fromString(generation).toString().lowercase(Locale.US)}"

    internal fun remainingRetryDelayMillis(
        record: FeedbackRecord,
        nowMillis: Long = System.currentTimeMillis(),
    ): Long = record.retryNotBeforeMillis
        ?.let { retryAt ->
            if (retryAt <= nowMillis) 0L else retryAt - nowMillis
        }
        ?: 0L

    private fun hasUnfinishedGeneration(
        workManager: WorkManager,
        record: FeedbackRecord,
    ): Boolean {
        val generation = record.workerGeneration ?: return false
        val tag = generationTag(generation)
        return runCatching {
            runBlocking {
                workManager.getWorkInfosForUniqueWorkFlow(workName(record.localId))
                    .first()
            }.any { info ->
                    info.state !in setOf(
                        WorkInfo.State.SUCCEEDED,
                        WorkInfo.State.FAILED,
                        WorkInfo.State.CANCELLED,
                    ) && tag in info.tags
                }
        }.getOrDefault(false)
    }

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
        val workerGeneration = inputData.getString(FeedbackScheduler.INPUT_WORKER_GENERATION)
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
        if (initial.workerGeneration != workerGeneration) {
            AppDiagnosticsRecorder.record(
                "feedback.worker_generation",
                fields = mapOf("outcome" to "superseded"),
            )
            return@withContext Result.success()
        }
        try {
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
                -> return@withContext cancelReport(outbox, initial, workerGeneration)
                else -> uploadReport(outbox, initial, workerGeneration)
            }
        } catch (error: Throwable) {
            if (!error.isWorkerSuperseded()) throw error
            AppDiagnosticsRecorder.record(
                "feedback.worker_generation",
                fields = mapOf("outcome" to "superseded"),
            )
            Result.success()
        }
    }

    private suspend fun uploadReport(
        outbox: FeedbackOutbox,
        initial: FeedbackRecord,
        workerGeneration: String,
    ): Result {
        finishExpiredContinuityAsUnconfirmedDeletion(
            outbox,
            initial,
            workerGeneration,
        )?.let {
            return it
        }
        val attempt = FeedbackRetryPolicy.nextDeliveryAttempt(initial.attempt)
        if (attempt > FeedbackOutbox.MAX_ATTEMPTS) {
            return failPermanently(
                outbox,
                initial.localId,
                FeedbackFailureCategory.UNKNOWN,
                cancel = false,
                workerGeneration = workerGeneration,
            )
        }
        val uploading = try {
            outbox.beginUpload(
                localId = initial.localId,
                attempt = attempt,
                expectedWorkerGeneration = workerGeneration,
            )
        } catch (error: Throwable) {
            return handleFailure(
                outbox,
                initial.localId,
                attempt,
                error,
                cancel = false,
                workerGeneration = workerGeneration,
            )
        }
        publishProgress(uploading, "reserving", 5)
        if (!FeedbackIdentityContinuityPolicy.canContactRemote(uploading)) {
            return failPermanently(
                outbox = outbox,
                localId = uploading.localId,
                category = FeedbackFailureCategory.IDENTITY,
                cancel = false,
                workerGeneration = workerGeneration,
            )
        }

        var activeClient: FeedbackAttemptClient? = null
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
            val client = feedbackClient(
                outbox = outbox,
                record = uploading,
                configuration = configuration,
            )
            activeClient = client
            val reservationRequest = FeedbackReservationRequestFactory.from(uploading)
            val idempotencyKey = UUID.fromString(uploading.requestId)

            if (uploading.serverReportId != null) {
                reconcileExistingReservation(
                    outbox = outbox,
                    record = uploading,
                    client = client,
                    workerGeneration = workerGeneration,
                )?.let { return it }
            }

            val currentBeforeReservation = outbox.load(uploading.localId)
                ?: return Result.success()
            if (currentBeforeReservation.state.isCancellationState()) {
                return cancelReport(
                    outbox,
                    currentBeforeReservation,
                    workerGeneration,
                    client,
                )
            }
            val identityBound = bindIdentity(
                outbox,
                currentBeforeReservation,
                client,
                workerGeneration,
            )
            if (identityBound.state.isCancellationState()) {
                return cancelReport(outbox, identityBound, workerGeneration, client)
            }
            val currentBeforeRemoteReservation = outbox.load(identityBound.localId)
                ?: return Result.success()
            if (currentBeforeRemoteReservation.state.isCancellationState()) {
                return cancelReport(
                    outbox,
                    currentBeforeRemoteReservation,
                    workerGeneration,
                    client,
                )
            }
            if (!FeedbackReservationContinuityPolicy.permitsNewReservation(
                    currentBeforeRemoteReservation,
                    System.currentTimeMillis(),
                )
            ) {
                val recovered = when (
                    val recovery = FeedbackDeliveryReservationReconciler.reconcile(
                        outbox = outbox,
                        record = currentBeforeRemoteReservation,
                        client = client,
                        idempotencyKey = idempotencyKey,
                        expectedWorkerGeneration = workerGeneration,
                    )
                ) {
                    is FeedbackDeliveryReservationRecovery.Recovered ->
                        recovery.reservation
                    is FeedbackDeliveryReservationRecovery.Retired -> {
                        publishProgress(recovery.record, "canceled", 0)
                        return Result.success()
                    }
                }
                val retention = FeedbackServerRetentionResponsePolicy.evaluate(
                    record = currentBeforeRemoteReservation,
                    retainedUntil = recovered.retainedUntil,
                    nowMillis = System.currentTimeMillis(),
                )
                val canceling = outbox.requestCancel(
                    localId = currentBeforeRemoteReservation.localId,
                    expectedWorkerGeneration = workerGeneration,
                )
                val stored = outbox.saveReservation(
                    localId = currentBeforeRemoteReservation.localId,
                    serverReportId = recovered.reportId,
                    serverReportToken = recovered.reportToken,
                    retainedUntil = retention.retainedUntil,
                    expectedWorkerGeneration = workerGeneration,
                )
                return cancelReport(
                    outbox,
                    if (stored.state.isCancellationState()) stored else canceling,
                    workerGeneration,
                    client,
                )
            }

            val reservation = client.reserve(
                idempotencyKey = idempotencyKey,
                request = reservationRequest,
            )
            val retention = FeedbackServerRetentionResponsePolicy.evaluate(
                record = currentBeforeRemoteReservation,
                retainedUntil = reservation.retainedUntil,
                nowMillis = System.currentTimeMillis(),
            )
            if (!retention.accepted) {
                outbox.requestCancel(
                    localId = currentBeforeRemoteReservation.localId,
                    expectedWorkerGeneration = workerGeneration,
                )
                val stored = outbox.saveReservation(
                    localId = currentBeforeRemoteReservation.localId,
                    serverReportId = reservation.reportId,
                    serverReportToken = reservation.reportToken,
                    retainedUntil = retention.retainedUntil,
                    expectedWorkerGeneration = workerGeneration,
                )
                return cancelReport(outbox, stored, workerGeneration, client)
            }
            val reserved = outbox.saveReservation(
                localId = uploading.localId,
                serverReportId = reservation.reportId,
                serverReportToken = reservation.reportToken,
                retainedUntil = retention.retainedUntil,
                expectedWorkerGeneration = workerGeneration,
            )
            if (reserved.state.isCancellationState()) {
                return cancelReport(outbox, reserved, workerGeneration, client)
            }

            if (reservation.status != "reserved") {
                val remote = client.status(
                    reportId = reservation.reportId,
                    reportToken = reservation.reportToken,
                )
                return applyRemoteStatus(
                    outbox,
                    reserved,
                    remote,
                    client,
                    workerGeneration,
                )
                    ?: throw FeedbackProtocolException.InvalidResponse()
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
                            publishTransientProgress(
                                outbox,
                                reserved.localId,
                                workerGeneration,
                                percent,
                            )
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
                    val refreshedRetention =
                        FeedbackServerRetentionResponsePolicy.evaluate(
                            record = reserved,
                            retainedUntil = refreshed.retainedUntil,
                            nowMillis = System.currentTimeMillis(),
                        )
                    if (!refreshedRetention.accepted) {
                        outbox.requestCancel(
                            localId = reserved.localId,
                            expectedWorkerGeneration = workerGeneration,
                        )
                        outbox.saveReservation(
                            localId = reserved.localId,
                            serverReportId = refreshed.reportId,
                            serverReportToken = refreshed.reportToken,
                            retainedUntil = refreshedRetention.retainedUntil,
                            expectedWorkerGeneration = workerGeneration,
                        )
                        throw FeedbackProtocolException.ReservationPending()
                    }
                    outbox.saveReservation(
                        localId = reserved.localId,
                        serverReportId = refreshed.reportId,
                        serverReportToken = refreshed.reportToken,
                        retainedUntil = refreshedRetention.retainedUntil,
                        expectedWorkerGeneration = workerGeneration,
                    )
                    refreshed.upload
                },
            )
            val beforeComplete = outbox.load(reserved.localId) ?: return Result.success()
            if (beforeComplete.state.isCancellationState()) {
                return cancelReport(outbox, beforeComplete, workerGeneration, client)
            }

            publishProgress(beforeComplete, "finalizing", 95)
            val completed = client.complete(
                reportId = reservation.reportId,
                reportToken = reservation.reportToken,
            )
            commitRemoteSent(
                outbox,
                reserved.localId,
                completed,
                client,
                workerGeneration,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            val current = runCatching {
                outbox.load(uploading.localId)
            }.getOrNull()
            if (current?.state?.isCancellationState() == true) {
                return cancelReport(outbox, current, workerGeneration, activeClient)
            }
            handleFailure(
                outbox,
                uploading.localId,
                attempt,
                error,
                cancel = false,
                workerGeneration = workerGeneration,
            )
        }
    }

    private suspend fun reconcileExistingReservation(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
        workerGeneration: String,
    ): Result? {
        var activeRecord = record
        var reportId = record.serverReportId
            ?: throw FeedbackProtocolException.InvalidResponse()
        var reportToken = record.serverReportToken
            ?: throw FeedbackProtocolException.InvalidResponse()
        val current = try {
            client.status(reportId, reportToken)
        } catch (_: FeedbackProtocolException.ReservationPending) {
            when (
                val recovery = FeedbackDeliveryReservationReconciler.reconcile(
                    outbox = outbox,
                    record = record,
                    client = client,
                    idempotencyKey = UUID.fromString(record.requestId),
                    expectedWorkerGeneration = workerGeneration,
                )
            ) {
                is FeedbackDeliveryReservationRecovery.Retired -> {
                    publishProgress(recovery.record, "canceled", 0)
                    return Result.success()
                }
                is FeedbackDeliveryReservationRecovery.Recovered -> {
                    val reservation = recovery.reservation
                    val retention = FeedbackServerRetentionResponsePolicy.evaluate(
                        record = record,
                        retainedUntil = reservation.retainedUntil,
                        nowMillis = System.currentTimeMillis(),
                    )
                    if (!retention.accepted) {
                        outbox.requestCancel(
                            localId = record.localId,
                            expectedWorkerGeneration = workerGeneration,
                        )
                    }
                    activeRecord = outbox.saveReservation(
                        localId = record.localId,
                        serverReportId = reservation.reportId,
                        serverReportToken = reservation.reportToken,
                        retainedUntil = retention.retainedUntil,
                        expectedWorkerGeneration = workerGeneration,
                    )
                    if (activeRecord.state.isCancellationState()) {
                        return cancelReport(
                            outbox,
                            activeRecord,
                            workerGeneration,
                            client,
                        )
                    }
                    reportId = reservation.reportId
                    reportToken = reservation.reportToken
                    if (reservation.status == "reserved") {
                        FeedbackRemoteStatus(
                            status = "reserved",
                            receipt = null,
                            retainedUntil = retention.retainedUntil,
                        )
                    } else {
                        client.status(reportId, reportToken)
                    }
                }
            }
        }
        applyRemoteStatus(
            outbox,
            activeRecord,
            current,
            client,
            workerGeneration,
        )?.let { return it }

        val beforeComplete = outbox.load(activeRecord.localId)
            ?: return Result.success()
        if (beforeComplete.state.isCancellationState()) {
            return cancelReport(outbox, beforeComplete, workerGeneration, client)
        }
        reportId = beforeComplete.serverReportId
            ?: throw FeedbackProtocolException.InvalidResponse()
        reportToken = beforeComplete.serverReportToken
            ?: throw FeedbackProtocolException.InvalidResponse()
        val completed = try {
            client.complete(reportId, reportToken)
        } catch (error: FeedbackProtocolException.Http) {
            if (error.statusCode != 409) throw error
            val refreshed = client.status(reportId, reportToken)
            return applyRemoteStatus(
                outbox,
                record,
                refreshed,
                client,
                workerGeneration,
            )
        }
        return applyRemoteStatus(
            outbox,
            record,
            completed,
            client,
            workerGeneration,
        )
            ?: throw FeedbackProtocolException.InvalidResponse()
    }

    private suspend fun applyRemoteStatus(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        remote: FeedbackRemoteStatus,
        client: FeedbackAttemptClient,
        workerGeneration: String,
    ): Result? = when (FeedbackRemoteStatusPolicy.recoverUpload(remote.status)) {
        FeedbackRemoteAction.MARK_SENT ->
            commitRemoteSent(
                outbox,
                record.localId,
                remote,
                client,
                workerGeneration,
            )
        FeedbackRemoteAction.MARK_DELETED -> {
            val canceling = outbox.requestCancel(
                localId = record.localId,
                expectedWorkerGeneration = workerGeneration,
            )
            val canceled = outbox.markCanceled(
                localId = canceling.localId,
                expectedWorkerGeneration = workerGeneration,
            )
            publishProgress(canceled, "canceled", 0)
            Result.success()
        }
        FeedbackRemoteAction.REJECT -> {
            val latest = outbox.load(record.localId) ?: return Result.success()
            if (latest.state.isCancellationState()) {
                cancelReport(outbox, latest, workerGeneration, client)
            } else {
                failPermanently(
                    outbox,
                    record.localId,
                    FeedbackFailureCategory.SERVER_REJECTED,
                    cancel = false,
                    workerGeneration = workerGeneration,
                )
            }
        }
        FeedbackRemoteAction.REQUEST_DELETE -> {
            val canceling = outbox.requestCancel(
                localId = record.localId,
                expectedWorkerGeneration = workerGeneration,
            )
            cancelReport(outbox, canceling, workerGeneration, client)
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
        workerGeneration: String,
    ): Result {
        val receipt = remote.receipt
            ?: throw FeedbackProtocolException.InvalidResponse()
        val retainedUntil = remote.retainedUntil
            ?: throw FeedbackProtocolException.InvalidResponse()
        val current = outbox.load(localId)
            ?: throw FeedbackProtocolException.InvalidResponse()
        val retention = FeedbackServerRetentionResponsePolicy.evaluate(
            record = current,
            retainedUntil = retainedUntil,
            nowMillis = System.currentTimeMillis(),
        )
        if (!retention.accepted) {
            val canceling = if (current.state.isCancellationState()) {
                current
            } else {
                outbox.requestCancel(
                    localId = localId,
                    expectedWorkerGeneration = workerGeneration,
                )
            }
            return cancelReport(outbox, canceling, workerGeneration, client)
        }
        return when (
            val commit = outbox.commitCompletion(
                localId = localId,
                receipt = receipt,
                retainedUntil = retention.retainedUntil,
                expectedWorkerGeneration = workerGeneration,
            )
        ) {
            is FeedbackCompletionCommit.Sent -> {
                publishProgress(commit.record, "sent", 100, receipt)
                Result.success()
            }
            is FeedbackCompletionCommit.CancellationRequired ->
                cancelReport(outbox, commit.record, workerGeneration, client)
        }
    }

    private suspend fun cancelReport(
        outbox: FeedbackOutbox,
        initial: FeedbackRecord,
        workerGeneration: String,
        existingClient: FeedbackAttemptClient? = null,
    ): Result {
        val attempt = FeedbackRetryPolicy.nextCancellationAttempt(initial.cancellationAttempt)
        if (attempt > FeedbackOutbox.MAX_ATTEMPTS) {
            return failPermanently(
                outbox = outbox,
                localId = initial.localId,
                category = FeedbackFailureCategory.DELETION_PENDING,
                cancel = true,
                workerGeneration = workerGeneration,
            )
        }
        var canceling = try {
            outbox.noteCancelAttempt(
                localId = initial.localId,
                attempt = attempt,
                expectedWorkerGeneration = workerGeneration,
            )
        } catch (error: Throwable) {
            return handleFailure(
                outbox,
                initial.localId,
                attempt,
                error,
                cancel = true,
                workerGeneration = workerGeneration,
            )
        }
        publishProgress(canceling, "canceling", 0)
        if (!FeedbackIdentityContinuityPolicy.canContactRemote(canceling)) {
            return failPermanently(
                outbox = outbox,
                localId = canceling.localId,
                category = FeedbackFailureCategory.IDENTITY,
                cancel = true,
                workerGeneration = workerGeneration,
            )
        }
        return try {
            var client = existingClient
            if (FeedbackCancellationPolicy.requiresReservationReconciliation(canceling)) {
                client = client ?: feedbackClient(
                    outbox = outbox,
                    record = canceling,
                )
                canceling = FeedbackCancellationReconciler.reconcile(
                    outbox = outbox,
                    record = canceling,
                    client = client,
                    expectedWorkerGeneration = workerGeneration,
                )
            }
            val reportId = canceling.serverReportId
            val reportToken = canceling.serverReportToken
            if (reportId != null && reportToken != null) {
                client = client ?: feedbackClient(
                    outbox = outbox,
                    record = canceling,
                )
                bindIdentity(outbox, canceling, client, workerGeneration)
                val remote = FeedbackBoundCancellationReconciler.reconcile(
                    client = client,
                    reportId = reportId,
                    reportToken = reportToken,
                )
                return when (FeedbackRemoteStatusPolicy.recoverCancellation(remote.status)) {
                    FeedbackRemoteAction.MARK_DELETED -> {
                        val canceled = outbox.markCanceled(
                            localId = canceling.localId,
                            expectedWorkerGeneration = workerGeneration,
                        )
                        publishProgress(canceled, "canceled", 0)
                        Result.success()
                    }
                    FeedbackRemoteAction.WAIT_FOR_DELETE ->
                        scheduleDeletionPoll(
                            outbox,
                            canceling.localId,
                            workerGeneration,
                        )
                    FeedbackRemoteAction.REQUEST_DELETE ->
                        scheduleDeletionPoll(
                            outbox,
                            canceling.localId,
                            workerGeneration,
                        )
                    else -> throw FeedbackProtocolException.InvalidResponse()
                }
            }
            val canceled = outbox.markCanceled(
                localId = canceling.localId,
                expectedWorkerGeneration = workerGeneration,
            )
            publishProgress(canceled, "canceled", 0)
            Result.success()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            handleFailure(
                outbox,
                canceling.localId,
                attempt,
                error,
                cancel = true,
                workerGeneration = workerGeneration,
            )
        }
    }

    private suspend fun scheduleDeletionPoll(
        outbox: FeedbackOutbox,
        localId: String,
        workerGeneration: String,
    ): Result {
        val current = outbox.load(localId) ?: return Result.success()
        if (current.cancellationAttempt >= FeedbackOutbox.MAX_ATTEMPTS) {
            return failPermanently(
                outbox = outbox,
                localId = localId,
                category = FeedbackFailureCategory.DELETION_PENDING,
                cancel = true,
                workerGeneration = workerGeneration,
            )
        }
        val retry = outbox.scheduleCancelRetry(
            localId = localId,
            failure = FeedbackFailureCategory.DELETION_PENDING,
            expectedWorkerGeneration = workerGeneration,
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
        workerGeneration: String,
    ): Result {
        if (error.isWorkerSuperseded()) {
            AppDiagnosticsRecorder.record(
                "feedback.worker_generation",
                fields = mapOf("outcome" to "superseded"),
            )
            return Result.success()
        }
        val decision = FeedbackRetryPolicy.classify(error)
        if (decision.preservesAttemptBudget) {
            val current = outbox.load(localId)
            if (current != null &&
                FeedbackReservationContinuityPolicy.hasExpired(
                    current,
                    System.currentTimeMillis(),
                )
            ) {
                return finishExpiredContinuityAsUnconfirmedDeletion(
                    outbox,
                    current,
                    workerGeneration,
                ) ?: Result.success()
            }
            return try {
                val schedule = outbox.scheduleContinuityRetry(
                    localId = localId,
                    lane = if (cancel) {
                        FeedbackReservationAttemptLane.CANCELLATION
                    } else {
                        FeedbackReservationAttemptLane.DELIVERY
                    },
                    failure = decision.category,
                    allowBoundIdentity =
                        decision.allowsBoundIdentityContinuity,
                    expectedWorkerGeneration = workerGeneration,
                )
                val waitStage = if (decision.allowsBoundIdentityContinuity) {
                    "reservation_continuity_wait"
                } else {
                    "identity_continuity_wait"
                }
                publishProgress(
                    schedule.record,
                    waitStage,
                    0,
                )
                if (!cancel &&
                    !decision.allowsBoundIdentityContinuity &&
                    schedule.record.state.isCancellationState()
                ) {
                    val canceled = outbox.markCanceled(
                        localId = schedule.record.localId,
                        expectedWorkerGeneration =
                            schedule.record.workerGeneration,
                    )
                    publishProgress(canceled, "canceled", 0)
                    AppDiagnosticsRecorder.record(
                        "feedback.$waitStage",
                        fields = mapOf("outcome" to "cancelled"),
                    )
                    return Result.success()
                }
                FeedbackScheduler.enqueueContinuityRetry(
                    context = applicationContext,
                    record = schedule.record,
                    delayMillis = schedule.delayMillis,
                )
                AppDiagnosticsRecorder.record(
                    "feedback.$waitStage",
                    fields = mapOf("outcome" to "deferred"),
                )
                Result.success()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (scheduleError: Throwable) {
                if (scheduleError.isWorkerSuperseded()) {
                    AppDiagnosticsRecorder.record(
                        "feedback.worker_generation",
                        fields = mapOf("outcome" to "superseded"),
                    )
                    return Result.success()
                }
                runCatching {
                    FeedbackScheduler.reconcile(applicationContext)
                }
                val waitStage = if (decision.allowsBoundIdentityContinuity) {
                    "reservation_continuity_wait"
                } else {
                    "identity_continuity_wait"
                }
                AppDiagnosticsRecorder.record(
                    "feedback.$waitStage",
                    fields = mapOf("outcome" to "scheduler_repair_requested"),
                )
                Result.success()
            }
        }
        val shouldRetry = if (cancel) {
            FeedbackRetryPolicy.shouldRetryCancellation(decision, attempt)
        } else {
            FeedbackRetryPolicy.shouldRetry(decision, attempt)
        }
        return if (shouldRetry) {
            val record = if (cancel) {
                outbox.scheduleCancelRetry(
                    localId = localId,
                    failure = decision.category,
                    expectedWorkerGeneration = workerGeneration,
                )
            } else {
                outbox.scheduleRetry(
                    localId = localId,
                    failure = decision.category,
                    expectedWorkerGeneration = workerGeneration,
                )
            }
            publishProgress(
                record,
                if (cancel) "cancel_retry_scheduled" else "retry_scheduled",
                0,
            )
            Result.retry()
        } else {
            failPermanently(
                outbox,
                localId,
                decision.category,
                cancel,
                workerGeneration,
            )
        }
    }

    private suspend fun failPermanently(
        outbox: FeedbackOutbox,
        localId: String,
        category: FeedbackFailureCategory,
        cancel: Boolean,
        workerGeneration: String,
    ): Result {
        val record = if (cancel) {
            outbox.markCancelFailed(
                localId = localId,
                failure = category,
                expectedWorkerGeneration = workerGeneration,
            )
        } else {
            outbox.markFailed(
                localId = localId,
                failure = category,
                expectedWorkerGeneration = workerGeneration,
            )
        }
        publishProgress(record, if (cancel) "cancel_failed" else "failed", 0)
        return Result.failure(
            workDataOf("failure_category" to category.wireValue),
        )
    }

    private suspend fun finishExpiredContinuityAsUnconfirmedDeletion(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        workerGeneration: String,
    ): Result? {
        val unconfirmed = outbox.markUnconfirmedDeletionIfContinuityExpired(
            localId = record.localId,
            expectedWorkerGeneration = workerGeneration,
        )
            ?: return null
        publishProgress(unconfirmed, "cancel_failed", 0)
        return Result.success()
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
        workerGeneration: String,
        percent: Int,
    ) {
        val current = runCatching {
            outbox.loadForProgress(
                localId = localId,
                expectedWorkerGeneration = workerGeneration,
            )
        }.getOrNull() ?: return
        if (current.state != FeedbackState.UPLOADING) return
        FeedbackRuntimeStatusBus.publish(current, percent.coerceIn(0, 100))
    }

    private fun feedbackClient(
        outbox: FeedbackOutbox,
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
                enforceReservationIdentityLifetime =
                    FeedbackReservationContinuityPolicy
                        .requiresIdentityLifetimeCheck(record),
                reservationContinuityIdentitySubjectSha256s =
                    outbox::reservationContinuityIdentitySubjectSha256s,
            ),
            transport = FeedbackApiClient(resolvedConfiguration),
            expectedIdentitySubjectSha256 = record.identitySubjectSha256,
        )
    }

    private suspend fun bindIdentity(
        outbox: FeedbackOutbox,
        record: FeedbackRecord,
        client: FeedbackAttemptClient,
        workerGeneration: String,
    ): FeedbackRecord = client.bindIdentity { identitySubjectSha256 ->
        outbox.bindIdentity(
            localId = record.localId,
            identitySubjectSha256 = identitySubjectSha256,
            expectedWorkerGeneration = workerGeneration,
        )
    }

}

private fun FeedbackState.isCancellationState(): Boolean =
    this == FeedbackState.CANCELING ||
        this == FeedbackState.CANCEL_RETRY_SCHEDULED ||
        this == FeedbackState.CANCEL_FAILED

private fun Throwable.isWorkerSuperseded(): Boolean =
    this is FeedbackWorkerSupersededException
