package com.noop.managed

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.await
import androidx.work.workDataOf
import com.google.firebase.FirebaseNetworkException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlinx.coroutines.CancellationException

/** Network-constrained, bounded catch-up for an already enrolled NOOP+ account. */
object ManagedCloudScheduler {
    private const val PERIODIC_WORK = "noop_managed_cloud_periodic_v1"
    private const val CATCH_UP_WORK = "noop_managed_cloud_catch_up_v1"
    private const val LEGACY_RETRY_WORK = "noop_managed_cloud_retry_v1"
    private const val RETRY_WORK_PREFIX = "noop_managed_cloud_retry_v2:"
    private const val PUSH_REGISTRATION_WORK = "noop_managed_push_registration_v1"
    private const val SAFETY_PUSH_WORK_PREFIX = "noop_managed_safety_push_v1:"
    internal const val SAFETY_PUSH_INCIDENT_ID = "incident_id"
    internal const val RETRY_SCOPE = "retry_scope"
    private const val CATCH_UP_INTERVAL_MS = 15L * 60L * 1_000L

    internal val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(true)
        .setRequiresStorageNotLow(true)
        .build()

    internal val urgentNetworkConstraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val workManager = WorkManager.getInstance(appContext)
        if (!ManagedRuntimeGate.isAuthorized(appContext)) {
            cancelManagedWork(workManager)
            ManagedCloudRetryStore(appContext).clearAll()
            return
        }
        val service = ManagedCloudService.get(appContext)
        if (!service.shouldSchedule()) {
            cancelManagedWork(workManager)
            ManagedCloudRetryStore(appContext).clearAll()
            return
        }
        val request = PeriodicWorkRequestBuilder<ManagedCloudWorker>(
            15,
            TimeUnit.MINUTES,
        )
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        workManager.enqueueUniquePeriodicWork(
            PERIODIC_WORK,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    private fun cancelManagedWork(workManager: WorkManager) {
        workManager.cancelUniqueWork(PERIODIC_WORK)
        workManager.cancelUniqueWork(CATCH_UP_WORK)
        workManager.cancelUniqueWork(LEGACY_RETRY_WORK)
        CatchUpScope.entries.forEach { scope ->
            workManager.cancelUniqueWork(retryWorkSpec(scope).workName)
        }
    }

    /** Called after launch/foreground work is deferred; never blocks the first app frame. */
    fun enqueueCatchUpIfDue(
        context: Context,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val appContext = context.applicationContext
        if (!ManagedRuntimeGate.isAuthorized(appContext)) {
            ManagedCloudRetryStore(appContext).clearAll()
            return
        }
        val service = ManagedCloudService.get(appContext)
        if (!service.shouldSchedule()) return
        val retryStore = ManagedCloudRetryStore(appContext)
        val enabledScopes = buildSet {
            if (service.shouldSyncForWorker()) add(CatchUpScope.CORE)
            if (service.shouldRunSocialForWorker()) add(CatchUpScope.SOCIAL)
            if (service.shouldRunSafetyForWorker()) add(CatchUpScope.SAFETY)
        }
        if (enabledScopes.none { retryStore.state(it).shouldAttempt(nowMs) }) return
        if (nowMs - service.schedulerLastAttemptMs() < CATCH_UP_INTERVAL_MS) return
        val request = OneTimeWorkRequestBuilder<ManagedCloudWorker>()
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(
            CATCH_UP_WORK,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }

    /** Continue a bounded manual pass without waiting for the next periodic 15-minute window. */
    fun enqueueContinuation(context: Context) {
        val appContext = context.applicationContext
        if (!ManagedRuntimeGate.isAuthorized(appContext)) {
            ManagedCloudRetryStore(appContext).clearAll()
            return
        }
        val service = ManagedCloudService.get(appContext)
        if (!service.shouldSchedule()) return
        val request = OneTimeWorkRequestBuilder<ManagedCloudWorker>()
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(
            CATCH_UP_WORK,
            // Append behind an in-flight pass instead of canceling it. Each successful bounded pass
            // becomes fresh work, so WorkManager's exponential retry counter is reserved for real
            // network/server failures rather than making a healthy large-history catch-up slower.
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            request,
        )
    }

    fun enqueueSafetyPush(context: Context, incidentId: UUID): Boolean = runCatching {
        val appContext = context.applicationContext
        if (!ManagedRuntimeGate.isAuthorized(appContext)) return@runCatching false
        val request = OneTimeWorkRequestBuilder<ManagedSafetyPushWorker>()
            .setInputData(
                workDataOf(
                    SAFETY_PUSH_INCIDENT_ID to incidentId.toString().lowercase(),
                ),
            )
            .setConstraints(urgentNetworkConstraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(
            safetyPushWorkName(incidentId),
            ExistingWorkPolicy.KEEP,
            request,
        )
        true
    }.getOrDefault(false)

    fun enqueuePushRegistration(context: Context): Boolean = runCatching {
        val appContext = context.applicationContext
        if (!ManagedRuntimeGate.isAuthorized(appContext)) return@runCatching false
        val request = OneTimeWorkRequestBuilder<ManagedPushRegistrationWorker>()
            .setConstraints(urgentNetworkConstraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(
            PUSH_REGISTRATION_WORK,
            ExistingWorkPolicy.REPLACE,
            request,
        )
        true
    }.getOrDefault(false)

    internal fun safetyPushWorkName(incidentId: UUID): String =
        "$SAFETY_PUSH_WORK_PREFIX${incidentId.toString().lowercase()}"

    internal fun safetyPushIncidentId(value: String?): UUID? =
        value?.let { runCatching { UUID.fromString(it) }.getOrNull() }

    internal fun successfulPassNeedsContinuation(hasMore: Boolean): Boolean = hasMore

    internal enum class CatchUpScope(
        val token: String,
    ) {
        CORE("core"),
        SOCIAL("social"),
        SAFETY("safety"),
    }

    internal data class CatchUpFailure(
        val scope: CatchUpScope,
        val error: Throwable,
    )

    internal data class RetryWorkSpec(
        val workName: String,
        val scopeToken: String,
        val constraints: Constraints,
    )

    internal data class RetrySchedule(
        val workSpec: RetryWorkSpec,
        val delayMillis: Long,
    )

    internal enum class RetryEnqueueOutcome(
        val diagnosticToken: String,
    ) {
        SCHEDULED("scheduled"),
        WORKER_RETRY("worker_retry"),
        DEADLINE_RELEASE_FAILED("deadline_release_failed"),
    }

    internal enum class RetryWorkerDecision {
        SUCCESS,
        RETRY,
        FAILURE,
    }

    internal fun retryWorkSpec(scope: CatchUpScope): RetryWorkSpec =
        RetryWorkSpec(
            workName = "$RETRY_WORK_PREFIX${scope.token}",
            scopeToken = scope.token,
            constraints = if (scope == CatchUpScope.SAFETY) {
                urgentNetworkConstraints
            } else {
                constraints
            },
        )

    internal fun retryScope(value: String?): CatchUpScope? =
        CatchUpScope.entries.firstOrNull { it.token == value }

    internal fun shouldAttemptScope(
        requestedScope: CatchUpScope?,
        candidateScope: CatchUpScope,
        retryState: ManagedCloudRetryState,
        nowMs: Long,
    ): Boolean =
        (requestedScope == null || requestedScope == candidateScope) &&
            retryState.shouldAttempt(nowMs)

    internal fun earlyScopedRetrySchedule(
        requestedScope: CatchUpScope?,
        retryState: ManagedCloudRetryState,
        nowMs: Long,
    ): RetrySchedule? {
        val scope = requestedScope ?: return null
        val boundedNowMs = nowMs.coerceAtLeast(0L)
        if (!retryState.pending || retryState.notBeforeMs <= boundedNowMs) {
            return null
        }
        return RetrySchedule(
            workSpec = retryWorkSpec(scope),
            delayMillis = retryState.notBeforeMs - boundedNowMs,
        )
    }

    internal suspend fun runCatchUpScopeAttempts(
        core: (suspend () -> Unit)? = null,
        social: (suspend () -> Unit)? = null,
        safety: (suspend () -> Unit)? = null,
    ): List<CatchUpFailure> {
        val failures = mutableListOf<CatchUpFailure>()

        suspend fun attempt(
            scope: CatchUpScope,
            operation: (suspend () -> Unit)?,
        ) {
            if (operation == null) return
            try {
                operation()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                failures += CatchUpFailure(scope, error)
            }
        }

        attempt(CatchUpScope.CORE, core)
        attempt(CatchUpScope.SOCIAL, social)
        attempt(CatchUpScope.SAFETY, safety)
        return failures
    }

    internal suspend fun scheduleRetries(
        context: Context,
        failures: List<CatchUpFailure>,
        nowMs: Long = System.currentTimeMillis(),
        jitterUnit: Double = Random.nextDouble(),
    ): RetryEnqueueOutcome {
        val appContext = context.applicationContext
        val retryableFailures = failures
            .filter { isAutomaticRetryable(it.error) }
            .distinctBy { it.scope }
        if (retryableFailures.isEmpty()) return RetryEnqueueOutcome.SCHEDULED
        val retryStore = ManagedCloudRetryStore(appContext)
        var aggregateOutcome = RetryEnqueueOutcome.SCHEDULED
        retryableFailures.forEach { failure ->
            val plan = retryStore.recordFailure(
                scope = failure.scope,
                nowMs = nowMs,
                retryAfterMillis = failure.error.managedRetryAfterMillis,
                jitterUnit = jitterUnit,
            )
            val schedule = RetrySchedule(
                workSpec = retryWorkSpec(failure.scope),
                delayMillis = plan.delayMillis,
            )
            val enqueueOutcome = scopedRetryEnqueueTransition(
                schedule = schedule,
                releasePersistedDeadline = {
                    retryStore.clear(failure.scope)
                },
            ) {
                enqueueRetryWork(appContext, it)
            }
            aggregateOutcome = aggregateRetryEnqueueOutcome(
                aggregateOutcome,
                enqueueOutcome,
            )
            com.noop.AppDiagnosticsRecorder.record(
                "managed_sync.retry_scheduled",
                fields = mapOf(
                    "attempt" to plan.failureCount.toString(),
                    "delay_bucket" to plan.delayBucket,
                    "delay_source" to if (plan.retryAfterApplied) "server" else "policy",
                    "failure_kind" to retryFailureKind(failure.error),
                    "scope" to failure.scope.token,
                    "enqueue_outcome" to enqueueOutcome.diagnosticToken,
                ),
            )
        }
        return aggregateOutcome
    }

    /**
     * Completes the persisted-deadline -> scoped-work transition atomically from the worker's
     * perspective. If WorkManager rejects the scoped enqueue, release that deadline before the
     * current unscoped worker returns [CoroutineWorker.Result.retry]; otherwise its retry would see
     * the future deadline, skip the scope, and finish successfully with no scoped work queued.
     */
    internal suspend fun scopedRetryEnqueueTransition(
        schedule: RetrySchedule,
        releasePersistedDeadline: () -> Boolean,
        enqueue: suspend (RetrySchedule) -> Unit,
    ): RetryEnqueueOutcome {
        if (retryScheduleEnqueueSucceeded(schedule, enqueue)) {
            return RetryEnqueueOutcome.SCHEDULED
        }
        return if (releasePersistedDeadline()) {
            RetryEnqueueOutcome.WORKER_RETRY
        } else {
            RetryEnqueueOutcome.DEADLINE_RELEASE_FAILED
        }
    }

    internal fun aggregateRetryEnqueueOutcome(
        current: RetryEnqueueOutcome,
        next: RetryEnqueueOutcome,
    ): RetryEnqueueOutcome = when {
        current == RetryEnqueueOutcome.DEADLINE_RELEASE_FAILED ||
            next == RetryEnqueueOutcome.DEADLINE_RELEASE_FAILED ->
            RetryEnqueueOutcome.DEADLINE_RELEASE_FAILED
        current == RetryEnqueueOutcome.WORKER_RETRY ||
            next == RetryEnqueueOutcome.WORKER_RETRY ->
            RetryEnqueueOutcome.WORKER_RETRY
        else -> RetryEnqueueOutcome.SCHEDULED
    }

    internal fun retryWorkerDecision(
        outcome: RetryEnqueueOutcome,
        failures: List<CatchUpFailure> = emptyList(),
    ): RetryWorkerDecision {
        if (outcome != RetryEnqueueOutcome.SCHEDULED) return RetryWorkerDecision.RETRY
        return if (failures.any {
                !isAutomaticRetryable(it.error) && !isHandledTerminalFailure(it.error)
            }
        ) {
            RetryWorkerDecision.FAILURE
        } else {
            RetryWorkerDecision.SUCCESS
        }
    }

    internal fun retryRecoverySchedules(
        requestedScope: CatchUpScope?,
        runAttemptCount: Int,
        retryStates: Map<CatchUpScope, ManagedCloudRetryState>,
        nowMs: Long,
    ): List<RetrySchedule> {
        if (requestedScope != null || runAttemptCount <= 0) return emptyList()
        val boundedNowMs = nowMs.coerceAtLeast(0L)
        return CatchUpScope.entries.mapNotNull { scope ->
            val state = retryStates[scope] ?: return@mapNotNull null
            if (!state.pending || state.notBeforeMs <= boundedNowMs) {
                return@mapNotNull null
            }
            RetrySchedule(
                workSpec = retryWorkSpec(scope),
                delayMillis = state.notBeforeMs - boundedNowMs,
            )
        }
    }

    internal suspend fun recoverPersistedRetrySchedules(
        schedules: List<RetrySchedule>,
        enqueue: suspend (RetrySchedule) -> Unit,
    ): Boolean {
        schedules.forEach { schedule ->
            if (!retryScheduleEnqueueSucceeded(schedule, enqueue)) return false
        }
        return true
    }

    internal suspend fun retryScheduleEnqueueSucceeded(
        schedule: RetrySchedule,
        enqueue: suspend (RetrySchedule) -> Unit,
    ): Boolean = retryEnqueueSucceeded {
        enqueue(schedule)
    }

    internal suspend fun enqueueRetryWork(
        context: Context,
        schedule: RetrySchedule,
        existingWorkPolicy: ExistingWorkPolicy = ExistingWorkPolicy.APPEND_OR_REPLACE,
    ) {
        val request = OneTimeWorkRequestBuilder<ManagedCloudWorker>()
            .setInputData(workDataOf(RETRY_SCOPE to schedule.workSpec.scopeToken))
            .setConstraints(schedule.workSpec.constraints)
            .setInitialDelay(schedule.delayMillis, TimeUnit.MILLISECONDS)
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                30,
                TimeUnit.SECONDS,
            )
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            schedule.workSpec.workName,
            existingWorkPolicy,
            request,
        ).await()
    }

    internal fun isAutomaticRetryable(error: Throwable): Boolean =
        error.isManagedAutomaticRetryable || error is FirebaseNetworkException

    internal suspend fun retryEnqueueSucceeded(
        action: suspend () -> Unit,
    ): Boolean = try {
        action()
        true
    } catch (error: CancellationException) {
        throw error
    } catch (_: Throwable) {
        false
    }

    internal fun isHandledTerminalFailure(error: Throwable): Boolean =
        error is ManagedStorageException.Authentication ||
            error is ManagedStorageException.PolicyChanged ||
            error is ManagedStorageException.QuotaExceeded

    internal fun retryFailureKind(error: Throwable): String = when (error) {
        is ManagedStorageException.Network,
        is FirebaseNetworkException,
        -> "network_transport"
        is ManagedStorageException.Server -> when (error.statusCode) {
            408, 504 -> "server_timeout"
            429 -> "rate_limited"
            else -> "server_unavailable"
        }
        else -> "other"
    }

    internal enum class RetryDeadlineClearReason(
        val diagnosticToken: String,
    ) {
        SCOPE_DISABLED("scope_disabled"),
        SCOPE_SUCCEEDED("scope_succeeded"),
        TERMINAL_FAILURE("terminal_failure"),
    }

    internal fun clearRetryDeadline(
        retryStore: ManagedCloudRetryStore,
        scope: CatchUpScope,
        reason: RetryDeadlineClearReason,
    ): Boolean {
        val cleared = retryStore.clear(scope)
        if (!cleared) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_sync.retry_deadline_clear_failed",
                fields = mapOf(
                    "reason" to reason.diagnosticToken,
                    "scope" to scope.token,
                ),
            )
        }
        return cleared
    }
}

class ManagedCloudWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {
            ManagedCloudRetryStore(applicationContext).clearAll()
            return Result.success()
        }
        val requestedScopeValue =
            inputData.getString(ManagedCloudScheduler.RETRY_SCOPE)
        val requestedScope = ManagedCloudScheduler.retryScope(requestedScopeValue)
        if (requestedScopeValue != null && requestedScope == null) {
            return Result.failure()
        }
        val service = ManagedCloudService.get(applicationContext)
        service.bootstrap()
        if (!service.shouldSchedule()) {
            ManagedCloudRetryStore(applicationContext).clearAll()
            return Result.success()
        }
        val retryStore = ManagedCloudRetryStore(applicationContext)
        val nowMs = System.currentTimeMillis()
        val retryStates = ManagedCloudScheduler.CatchUpScope.entries.associateWith {
            retryStore.state(it)
        }
        val recoverySchedules = ManagedCloudScheduler.retryRecoverySchedules(
            requestedScope = requestedScope,
            runAttemptCount = runAttemptCount,
            retryStates = retryStates,
            nowMs = nowMs,
        )
        if (recoverySchedules.isNotEmpty()) {
            val recovered = ManagedCloudScheduler.recoverPersistedRetrySchedules(
                recoverySchedules,
            ) {
                ManagedCloudScheduler.enqueueRetryWork(
                    applicationContext,
                    it,
                    ExistingWorkPolicy.KEEP,
                )
            }
            com.noop.AppDiagnosticsRecorder.record(
                "managed_sync.retry_recovery",
                fields = mapOf(
                    "enqueue_outcome" to if (recovered) "scheduled" else "failed",
                    "scope_count" to recoverySchedules.size.toString(),
                ),
            )
            if (!recovered) return Result.retry()
        }
        val earlyRetrySchedule =
            ManagedCloudScheduler.earlyScopedRetrySchedule(
                requestedScope,
                requestedScope?.let(retryStates::getValue)
                    ?: ManagedCloudRetryState(),
                nowMs,
            )
        if (earlyRetrySchedule != null) {
            // WorkManager can wake before a persisted Retry-After deadline.
            // Append fresh scoped work at the exact remaining delay instead of
            // replacing that deadline with WorkManager's exponential backoff.
            val enqueued = ManagedCloudScheduler.retryScheduleEnqueueSucceeded(
                earlyRetrySchedule,
            ) {
                ManagedCloudScheduler.enqueueRetryWork(applicationContext, it)
            }
            com.noop.AppDiagnosticsRecorder.record(
                "managed_sync.retry_rescheduled",
                fields = mapOf(
                    "delay_bucket" to ManagedStorageRetryPolicy.delayBucket(
                        earlyRetrySchedule.delayMillis,
                    ),
                    "scope" to earlyRetrySchedule.workSpec.scopeToken,
                    "enqueue_outcome" to if (enqueued) "scheduled" else "failed",
                ),
            )
            return if (enqueued) Result.success() else Result.retry()
        }
        val coreEnabled = service.shouldSyncForWorker()
        val socialEnabled = service.shouldRunSocialForWorker()
        val safetyEnabled = service.shouldRunSafetyForWorker()
        if (requestedScope != null &&
            when (requestedScope) {
                ManagedCloudScheduler.CatchUpScope.CORE -> !coreEnabled
                ManagedCloudScheduler.CatchUpScope.SOCIAL -> !socialEnabled
                ManagedCloudScheduler.CatchUpScope.SAFETY -> !safetyEnabled
            }
        ) {
            ManagedCloudScheduler.clearRetryDeadline(
                retryStore,
                requestedScope,
                ManagedCloudScheduler.RetryDeadlineClearReason.SCOPE_DISABLED,
            )
            return Result.success()
        }
        var continuationNeeded = false
        val attemptedScopes =
            mutableSetOf<ManagedCloudScheduler.CatchUpScope>()
        val failures = ManagedCloudScheduler.runCatchUpScopeAttempts(
            core = if (
                ManagedCloudScheduler.shouldAttemptScope(
                    requestedScope,
                    ManagedCloudScheduler.CatchUpScope.CORE,
                    retryStates.getValue(
                        ManagedCloudScheduler.CatchUpScope.CORE,
                    ),
                    nowMs,
                ) && coreEnabled
            ) {
                suspend {
                    attemptedScopes += ManagedCloudScheduler.CatchUpScope.CORE
                    val summary = service.syncForWorker()
                    continuationNeeded =
                        ManagedCloudScheduler.successfulPassNeedsContinuation(
                            summary.hasMore,
                        )
                }
            } else {
                null
            },
            social = if (
                ManagedCloudScheduler.shouldAttemptScope(
                    requestedScope,
                    ManagedCloudScheduler.CatchUpScope.SOCIAL,
                    retryStates.getValue(
                        ManagedCloudScheduler.CatchUpScope.SOCIAL,
                    ),
                    nowMs,
                ) && socialEnabled
            ) {
                suspend {
                    attemptedScopes += ManagedCloudScheduler.CatchUpScope.SOCIAL
                    service.socialCatchUpForWorker(
                        force =
                            requestedScope != null ||
                                retryStates.getValue(
                                    ManagedCloudScheduler.CatchUpScope.SOCIAL,
                                ).pending ||
                                runAttemptCount > 0,
                    )
                    Unit
                }
            } else {
                null
            },
            safety = if (
                ManagedCloudScheduler.shouldAttemptScope(
                    requestedScope,
                    ManagedCloudScheduler.CatchUpScope.SAFETY,
                    retryStates.getValue(
                        ManagedCloudScheduler.CatchUpScope.SAFETY,
                    ),
                    nowMs,
                ) && safetyEnabled
            ) {
                suspend {
                    attemptedScopes += ManagedCloudScheduler.CatchUpScope.SAFETY
                    service.safetyCatchUpForWorker(
                        force =
                            requestedScope != null ||
                                retryStates.getValue(
                                    ManagedCloudScheduler.CatchUpScope.SAFETY,
                                ).pending ||
                                runAttemptCount > 0,
                    )
                    Unit
                }
            } else {
                null
            },
        )
        val failedScopes = failures.mapTo(mutableSetOf()) { it.scope }
        (attemptedScopes - failedScopes).forEach {
            ManagedCloudScheduler.clearRetryDeadline(
                retryStore,
                it,
                ManagedCloudScheduler.RetryDeadlineClearReason.SCOPE_SUCCEEDED,
            )
        }
        failures
            .filterNot { ManagedCloudScheduler.isAutomaticRetryable(it.error) }
            .forEach {
                ManagedCloudScheduler.clearRetryDeadline(
                    retryStore,
                    it.scope,
                    ManagedCloudScheduler.RetryDeadlineClearReason.TERMINAL_FAILURE,
                )
            }
        if (continuationNeeded) {
            ManagedCloudScheduler.enqueueContinuation(applicationContext)
        }
        if (failures.isNotEmpty()) {
            val retryOutcome = ManagedCloudScheduler.scheduleRetries(
                applicationContext,
                failures,
            )
            return when (
                ManagedCloudScheduler.retryWorkerDecision(retryOutcome, failures)
            ) {
                ManagedCloudScheduler.RetryWorkerDecision.SUCCESS -> Result.success()
                ManagedCloudScheduler.RetryWorkerDecision.RETRY -> Result.retry()
                ManagedCloudScheduler.RetryWorkerDecision.FAILURE -> Result.failure()
            }
        }
        return Result.success()
    }
}

class ManagedSafetyPushWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {
            return Result.success()
        }
        val incidentId = ManagedCloudScheduler.safetyPushIncidentId(
            inputData.getString(ManagedCloudScheduler.SAFETY_PUSH_INCIDENT_ID),
        ) ?: return Result.failure()
        val service = ManagedCloudService.get(applicationContext)
        service.bootstrap()
        if (!service.shouldSchedule() || !service.shouldRunSafetyForWorker()) {
            return Result.success()
        }
        return try {
            if (service.handleManagedSafetyPush(incidentId)) {
                Result.success()
            } else if (runAttemptCount < 3) {
                Result.retry()
            } else {
                Result.failure()
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }
}

class ManagedPushRegistrationWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {
            return Result.success()
        }
        val service = ManagedCloudService.get(applicationContext)
        service.bootstrap()
        if (!service.shouldSchedule() || !service.shouldRunSafetyForWorker()) {
            return Result.success()
        }
        return try {
            if (service.registerCurrentManagedPushToken()) {
                Result.success()
            } else if (runAttemptCount < 3) {
                Result.retry()
            } else {
                Result.failure()
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }
}
