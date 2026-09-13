package com.noop.ble

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.await
import androidx.work.workDataOf
import com.noop.AppDiagnosticsRecorder
import com.noop.NoopApplication
import com.noop.managed.ManagedRuntimeGate
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

internal object PostBackfillAnalysisRetryPolicy {
    const val WORK_NAME = "noop_post_backfill_analysis_retry_v2"
    const val RETRY_AT_EPOCH_MILLIS_KEY = "retry_at_epoch_millis"
    const val PROTOCOL_VERSION_KEY = "retry_protocol_version"
    const val PROTOCOL_VERSION = 2
    private const val MIN_DELAY_MILLIS = 1_000L

    fun initialDelayMillis(
        retryAtEpochMillis: Long,
        nowEpochMillis: Long,
    ): Long {
        if (retryAtEpochMillis <= nowEpochMillis) return MIN_DELAY_MILLIS
        val remaining = retryAtEpochMillis - nowEpochMillis
        return if (remaining < 0L) Long.MAX_VALUE else remaining.coerceAtLeast(MIN_DELAY_MILLIS)
    }

    fun workSpec(
        retryAtEpochMillis: Long,
        nowEpochMillis: Long,
        workId: String = UUID.randomUUID().toString(),
    ): PostBackfillRetryWorkSpec = PostBackfillRetryWorkSpec(
        workId = workId,
        retryAtEpochMillis = retryAtEpochMillis,
        initialDelayMillis = initialDelayMillis(retryAtEpochMillis, nowEpochMillis),
        requiresBatteryNotLow = true,
        requiresStorageNotLow = true,
        protocolVersion = PROTOCOL_VERSION,
    )

    fun handlesClockChange(action: String?): Boolean = when (action) {
        Intent.ACTION_TIMEZONE_CHANGED,
        Intent.ACTION_TIME_CHANGED,
        Intent.ACTION_DATE_CHANGED,
        -> true
        else -> false
    }
}

internal data class PostBackfillRetryWorkSpec(
    val workId: String,
    val retryAtEpochMillis: Long,
    val initialDelayMillis: Long,
    val requiresBatteryNotLow: Boolean,
    val requiresStorageNotLow: Boolean,
    val protocolVersion: Int,
)

internal enum class PostBackfillRetryWorkerEntryDecision {
    RUN_V2,
    EXIT_LEGACY,
}

internal fun postBackfillRetryWorkerEntryDecision(
    protocolVersion: Int,
    retryAtEpochMillis: Long,
): PostBackfillRetryWorkerEntryDecision =
    if (
        protocolVersion == PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION &&
        retryAtEpochMillis != Long.MIN_VALUE
    ) {
        PostBackfillRetryWorkerEntryDecision.RUN_V2
    } else {
        PostBackfillRetryWorkerEntryDecision.EXIT_LEGACY
    }

internal data class PostBackfillScheduledRetry(
    val workId: String,
    val retryAtEpochMillis: Long,
)

internal sealed interface PostBackfillRetryStateRead {
    data object Empty : PostBackfillRetryStateRead
    data object Corrupt : PostBackfillRetryStateRead
    data object Failed : PostBackfillRetryStateRead
    data class Present(val value: PostBackfillScheduledRetry) : PostBackfillRetryStateRead
}

internal sealed interface PostBackfillPendingSourcesRead {
    data class Available(val sourceIds: Set<String>) : PostBackfillPendingSourcesRead
    data object Failed : PostBackfillPendingSourcesRead

    fun state(): PostBackfillPendingSourceRead = when (this) {
        is Available ->
            if (sourceIds.isEmpty()) {
                PostBackfillPendingSourceRead.EMPTY
            } else {
                PostBackfillPendingSourceRead.PRESENT
            }
        Failed -> PostBackfillPendingSourceRead.FAILED
    }
}

internal enum class PostBackfillPendingSourceRead {
    PRESENT,
    EMPTY,
    FAILED,
}

internal enum class PostBackfillRetryWorkState {
    WAITING,
    RUNNING,
    FINISHED,
    MISSING,
    UNAVAILABLE,
}

internal interface PostBackfillRetryStateStore {
    fun load(): PostBackfillRetryStateRead
    fun save(value: PostBackfillScheduledRetry): Boolean
    fun clear(expectedWorkId: String? = null): Boolean
}

internal interface PostBackfillRetryWorkBackend {
    suspend fun state(workId: String): PostBackfillRetryWorkState
    suspend fun enqueueReplacement(spec: PostBackfillRetryWorkSpec): Boolean
    suspend fun cancelUnique(): Boolean
}

internal enum class PostBackfillRetryScheduleOutcome {
    SCHEDULED,
    DEDUPLICATED,
    RESCHEDULED,
    RECOVERY_PENDING,
    CLEARED,
    SOURCE_READ_FAILED,
    FAILED,
    ;

    val succeeded: Boolean
        get() = when (this) {
            SCHEDULED,
            DEDUPLICATED,
            RESCHEDULED,
            RECOVERY_PENDING,
            CLEARED,
            -> true
            SOURCE_READ_FAILED,
            FAILED,
            -> false
        }
}

internal enum class PostBackfillRetryExecutionDecision {
    ACCEPTED,
    RECOVERED,
    STALE,
    LEGACY,
    RETRY,
}

/**
 * Serializes one v2 durable boundary. Replacement is one WorkManager REPLACE transaction: the previous
 * wake remains viable until WorkManager durably inserts its successor. SharedPreferences is recovery
 * metadata, not the source of enqueue durability, so a process death after enqueue can be repaired by
 * the running v2 work without accepting legacy or concurrently superseded work.
 */
internal class PostBackfillRetryCoordinator(
    private val stateStore: PostBackfillRetryStateStore,
    private val backend: PostBackfillRetryWorkBackend,
    private val publicationTimeoutMillis: Long = 5_000L,
) {
    private val mutex = Mutex()

    init {
        require(publicationTimeoutMillis > 0L)
    }

    suspend fun schedule(
        retryAtEpochMillis: Long,
        nowEpochMillis: Long,
    ): PostBackfillRetryScheduleOutcome = mutex.withLock {
        scheduleLocked(
            retryAtEpochMillis = retryAtEpochMillis,
            nowEpochMillis = nowEpochMillis,
            forceReplace = false,
        )
    }

    suspend fun beginExecution(
        workId: String,
        retryAtEpochMillis: Long,
        protocolVersion: Int,
    ): PostBackfillRetryExecutionDecision = mutex.withLock {
        if (protocolVersion != PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION) {
            return@withLock PostBackfillRetryExecutionDecision.LEGACY
        }
        val running = PostBackfillScheduledRetry(
            workId = workId,
            retryAtEpochMillis = retryAtEpochMillis,
        )
        when (val stored = stateStore.load()) {
            PostBackfillRetryStateRead.Failed ->
                PostBackfillRetryExecutionDecision.RETRY
            PostBackfillRetryStateRead.Corrupt -> {
                if (stateStore.clear()) {
                    recoverExecutionLocked(running)
                } else {
                    PostBackfillRetryExecutionDecision.RETRY
                }
            }
            PostBackfillRetryStateRead.Empty ->
                recoverExecutionLocked(running)
            is PostBackfillRetryStateRead.Present -> {
                if (stored.value.workId == workId) {
                    when (backend.state(workId)) {
                        PostBackfillRetryWorkState.WAITING,
                        PostBackfillRetryWorkState.RUNNING,
                        -> PostBackfillRetryExecutionDecision.ACCEPTED
                        PostBackfillRetryWorkState.FINISHED,
                        PostBackfillRetryWorkState.MISSING,
                        -> PostBackfillRetryExecutionDecision.STALE
                        PostBackfillRetryWorkState.UNAVAILABLE ->
                            PostBackfillRetryExecutionDecision.RETRY
                    }
                } else {
                    when (backend.state(stored.value.workId)) {
                        PostBackfillRetryWorkState.WAITING,
                        PostBackfillRetryWorkState.RUNNING,
                        -> PostBackfillRetryExecutionDecision.STALE
                        PostBackfillRetryWorkState.FINISHED,
                        PostBackfillRetryWorkState.MISSING,
                        -> recoverExecutionLocked(running)
                        PostBackfillRetryWorkState.UNAVAILABLE ->
                            PostBackfillRetryExecutionDecision.RETRY
                    }
                }
            }
        }
    }

    suspend fun finishExecution(workId: String): Boolean = mutex.withLock {
        when (val stored = stateStore.load()) {
            PostBackfillRetryStateRead.Failed -> false
            PostBackfillRetryStateRead.Corrupt -> false
            PostBackfillRetryStateRead.Empty -> true
            is PostBackfillRetryStateRead.Present -> {
                if (stored.value.workId != workId) {
                    true
                } else {
                    stateStore.clear(expectedWorkId = workId)
                }
            }
        }
    }

    suspend fun reconcileClockChange(
        pendingSources: PostBackfillPendingSourceRead,
        nowEpochMillis: Long,
    ): PostBackfillRetryScheduleOutcome = mutex.withLock {
        when (pendingSources) {
            PostBackfillPendingSourceRead.FAILED ->
                PostBackfillRetryScheduleOutcome.SOURCE_READ_FAILED
            PostBackfillPendingSourceRead.PRESENT ->
                scheduleLocked(
                    retryAtEpochMillis = nowEpochMillis,
                    nowEpochMillis = nowEpochMillis,
                    forceReplace = true,
                )
            PostBackfillPendingSourceRead.EMPTY -> {
                when (stateStore.load()) {
                    PostBackfillRetryStateRead.Failed ->
                        return@withLock PostBackfillRetryScheduleOutcome.FAILED
                    PostBackfillRetryStateRead.Corrupt,
                    PostBackfillRetryStateRead.Empty,
                    is PostBackfillRetryStateRead.Present,
                    -> Unit
                }
                if (!backend.cancelUnique()) {
                    return@withLock PostBackfillRetryScheduleOutcome.FAILED
                }
                if (!stateStore.clear()) {
                    return@withLock PostBackfillRetryScheduleOutcome.FAILED
                }
                PostBackfillRetryScheduleOutcome.CLEARED
            }
        }
    }

    private suspend fun scheduleLocked(
        retryAtEpochMillis: Long,
        nowEpochMillis: Long,
        forceReplace: Boolean,
    ): PostBackfillRetryScheduleOutcome {
        var replaced = false
        var selectedRetryAtEpochMillis = retryAtEpochMillis
        when (val stored = stateStore.load()) {
            PostBackfillRetryStateRead.Failed ->
                return PostBackfillRetryScheduleOutcome.FAILED
            PostBackfillRetryStateRead.Corrupt -> {
                if (!stateStore.clear()) {
                    return PostBackfillRetryScheduleOutcome.FAILED
                }
            }
            PostBackfillRetryStateRead.Empty -> Unit
            is PostBackfillRetryStateRead.Present -> {
                when (backend.state(stored.value.workId)) {
                    PostBackfillRetryWorkState.WAITING -> {
                        if (
                            !forceReplace &&
                            stored.value.retryAtEpochMillis <= retryAtEpochMillis
                        ) {
                            return PostBackfillRetryScheduleOutcome.DEDUPLICATED
                        }
                        if (!forceReplace) {
                            selectedRetryAtEpochMillis = minOf(
                                stored.value.retryAtEpochMillis,
                                retryAtEpochMillis,
                            )
                        }
                        replaced = true
                    }
                    PostBackfillRetryWorkState.RUNNING -> {
                        // A running worker must install a successor even when the wall-clock boundary is
                        // unchanged. Its stored boundary has already been consumed, so the successor uses
                        // the newly requested boundary. REPLACE atomically persists it, then cancels this run.
                        replaced = true
                    }
                    PostBackfillRetryWorkState.FINISHED,
                    PostBackfillRetryWorkState.MISSING,
                    -> Unit
                    PostBackfillRetryWorkState.UNAVAILABLE ->
                        return PostBackfillRetryScheduleOutcome.FAILED
                }
            }
        }

        val spec = PostBackfillAnalysisRetryPolicy.workSpec(
            retryAtEpochMillis = selectedRetryAtEpochMillis,
            nowEpochMillis = nowEpochMillis,
        )
        return when (publishReplacement(spec)) {
            ReplacementPublication.FAILED ->
                PostBackfillRetryScheduleOutcome.FAILED
            ReplacementPublication.RECOVERY_PENDING ->
                PostBackfillRetryScheduleOutcome.RECOVERY_PENDING
            ReplacementPublication.PUBLISHED ->
                if (replaced) {
                    PostBackfillRetryScheduleOutcome.RESCHEDULED
                } else {
                    PostBackfillRetryScheduleOutcome.SCHEDULED
                }
        }
    }

    /**
     * Once WorkManager replacement begins, caller cancellation must not split the durable enqueue from
     * selector publication. The explicit checks preserve prompt cancellation before and immediately after
     * that bounded critical section; the internal timeout still prevents an indefinitely stuck caller.
     */
    private suspend fun publishReplacement(
        spec: PostBackfillRetryWorkSpec,
    ): ReplacementPublication {
        currentCoroutineContext().ensureActive()
        val publication = withContext(NonCancellable) {
            withTimeoutOrNull(publicationTimeoutMillis) {
                if (!backend.enqueueReplacement(spec)) {
                    return@withTimeoutOrNull ReplacementPublication.FAILED
                }
                if (
                    stateStore.save(
                        PostBackfillScheduledRetry(
                            workId = spec.workId,
                            retryAtEpochMillis = spec.retryAtEpochMillis,
                        ),
                    )
                ) {
                    ReplacementPublication.PUBLISHED
                } else {
                    ReplacementPublication.RECOVERY_PENDING
                }
            } ?: ReplacementPublication.FAILED
        }
        currentCoroutineContext().ensureActive()
        return publication
    }

    private suspend fun recoverExecutionLocked(
        running: PostBackfillScheduledRetry,
    ): PostBackfillRetryExecutionDecision = when (backend.state(running.workId)) {
        PostBackfillRetryWorkState.WAITING,
        PostBackfillRetryWorkState.RUNNING,
        -> if (stateStore.save(running)) {
            PostBackfillRetryExecutionDecision.RECOVERED
        } else {
            PostBackfillRetryExecutionDecision.RETRY
        }
        PostBackfillRetryWorkState.FINISHED,
        PostBackfillRetryWorkState.MISSING,
        -> PostBackfillRetryExecutionDecision.STALE
        PostBackfillRetryWorkState.UNAVAILABLE ->
            PostBackfillRetryExecutionDecision.RETRY
    }
}

private enum class ReplacementPublication {
    PUBLISHED,
    RECOVERY_PENDING,
    FAILED,
}

internal class SharedPreferencesPostBackfillRetryStateStore(
    context: Context,
) : PostBackfillRetryStateStore {
    private val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    override fun load(): PostBackfillRetryStateRead {
        return try {
            val hasWorkId = preferences.contains(WORK_ID_KEY)
            val hasRetryAt = preferences.contains(RETRY_AT_KEY)
            if (!hasWorkId && !hasRetryAt) return PostBackfillRetryStateRead.Empty
            if (!hasWorkId || !hasRetryAt) return PostBackfillRetryStateRead.Corrupt
            val workId = preferences.getString(WORK_ID_KEY, null)?.takeIf(String::isNotBlank)
                ?: return PostBackfillRetryStateRead.Corrupt
            val parsedWorkId = runCatching { UUID.fromString(workId) }.getOrNull()
                ?: return PostBackfillRetryStateRead.Corrupt
            if (parsedWorkId.toString() != workId) {
                return PostBackfillRetryStateRead.Corrupt
            }
            val retryAt = preferences.getLong(RETRY_AT_KEY, Long.MIN_VALUE)
            if (retryAt == Long.MIN_VALUE) {
                PostBackfillRetryStateRead.Corrupt
            } else {
                PostBackfillRetryStateRead.Present(
                    PostBackfillScheduledRetry(workId, retryAt),
                )
            }
        } catch (_: ClassCastException) {
            PostBackfillRetryStateRead.Corrupt
        } catch (_: Throwable) {
            PostBackfillRetryStateRead.Failed
        }
    }

    override fun save(value: PostBackfillScheduledRetry): Boolean = runCatching {
        preferences.edit()
            .putString(WORK_ID_KEY, value.workId)
            .putLong(RETRY_AT_KEY, value.retryAtEpochMillis)
            .commit()
    }.getOrDefault(false)

    override fun clear(expectedWorkId: String?): Boolean = runCatching {
        if (expectedWorkId != null && preferences.getString(WORK_ID_KEY, null) != expectedWorkId) {
            return@runCatching true
        }
        preferences.edit()
            .remove(WORK_ID_KEY)
            .remove(RETRY_AT_KEY)
            .commit()
    }.getOrDefault(false)

    internal companion object {
        const val PREFS_NAME = "noop_post_backfill_retry_schedule"
        const val WORK_ID_KEY = "work_id"
        const val RETRY_AT_KEY = "retry_at_epoch_millis"
    }
}

internal class WorkManagerPostBackfillRetryBackend(
    context: Context,
) : PostBackfillRetryWorkBackend {
    private val workManager = WorkManager.getInstance(context.applicationContext)

    override suspend fun state(workId: String): PostBackfillRetryWorkState = try {
        val info = workManager.getWorkInfoByIdFlow(UUID.fromString(workId)).first()
        when (info?.state) {
            null -> PostBackfillRetryWorkState.MISSING
            WorkInfo.State.ENQUEUED,
            WorkInfo.State.BLOCKED,
            -> PostBackfillRetryWorkState.WAITING
            WorkInfo.State.RUNNING -> PostBackfillRetryWorkState.RUNNING
            WorkInfo.State.SUCCEEDED,
            WorkInfo.State.FAILED,
            WorkInfo.State.CANCELLED,
            -> PostBackfillRetryWorkState.FINISHED
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        PostBackfillRetryWorkState.UNAVAILABLE
    }

    override suspend fun enqueueReplacement(spec: PostBackfillRetryWorkSpec): Boolean =
        verifiedOperation {
            val constraints = Constraints.Builder()
                .setRequiresBatteryNotLow(spec.requiresBatteryNotLow)
                .setRequiresStorageNotLow(spec.requiresStorageNotLow)
                .build()
            val request = OneTimeWorkRequestBuilder<PostBackfillAnalysisRetryWorker>()
                .setId(UUID.fromString(spec.workId))
                .setInputData(
                    workDataOf(
                        PostBackfillAnalysisRetryPolicy.RETRY_AT_EPOCH_MILLIS_KEY to
                            spec.retryAtEpochMillis,
                        PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION_KEY to
                            spec.protocolVersion,
                    ),
                )
                .setInitialDelay(spec.initialDelayMillis, TimeUnit.MILLISECONDS)
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            workManager.enqueueUniqueWork(
                PostBackfillAnalysisRetryPolicy.WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            ).await()
        }

    override suspend fun cancelUnique(): Boolean = verifiedOperation {
        workManager.cancelUniqueWork(PostBackfillAnalysisRetryPolicy.WORK_NAME).await()
    }

    private suspend fun verifiedOperation(block: suspend () -> Unit): Boolean = try {
        block()
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        false
    }
}

/**
 * Durable local wake for a late-only post-backfill claim. Schedule state contains only a WorkManager
 * UUID and planned boundary in private app storage; diagnostics remain fixed categories.
 */
internal object PostBackfillAnalysisRetryScheduler {
    @Volatile
    private var coordinator: PostBackfillRetryCoordinator? = null

    suspend fun schedule(
        context: Context,
        retryAtEpochMillis: Long,
        nowEpochMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        val outcome = coordinator(context).schedule(retryAtEpochMillis, nowEpochMillis)
        record(outcome.name.lowercase())
        return outcome.succeeded
    }

    suspend fun beginExecution(
        context: Context,
        workId: String,
        retryAtEpochMillis: Long,
        protocolVersion: Int,
    ): PostBackfillRetryExecutionDecision =
        coordinator(context).beginExecution(workId, retryAtEpochMillis, protocolVersion)

    suspend fun finishExecution(context: Context, workId: String): Boolean {
        val finished = coordinator(context).finishExecution(workId)
        if (!finished) record("finish_state_retry")
        return finished
    }

    suspend fun reconcileClockChange(
        context: Context,
        pendingSources: PostBackfillPendingSourceRead,
        nowEpochMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        val outcome = coordinator(context).reconcileClockChange(
            pendingSources = pendingSources,
            nowEpochMillis = nowEpochMillis,
        )
        record(outcome.name.lowercase())
        return outcome.succeeded
    }

    fun recordReceiverTimeout() = record("receiver_timeout")

    fun recordReceiverFailure() = record("receiver_failed")

    private fun coordinator(context: Context): PostBackfillRetryCoordinator {
        coordinator?.let { return it }
        return synchronized(this) {
            coordinator ?: PostBackfillRetryCoordinator(
                stateStore = SharedPreferencesPostBackfillRetryStateStore(
                    context.applicationContext,
                ),
                backend = WorkManagerPostBackfillRetryBackend(context.applicationContext),
            ).also { coordinator = it }
        }
    }

    private fun record(outcome: String) {
        AppDiagnosticsRecorder.record(
            "analysis.post_backfill_retry",
            fields = mapOf("outcome" to outcome),
        )
    }
}

class PostBackfillAnalysisRetryWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val operation = AppDiagnosticsRecorder.beginOperation(
            "analysis.post_backfill_retry",
        )
        val protocolVersion = inputData.getInt(
            PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION_KEY,
            0,
        )
        val retryAtEpochMillis = inputData.getLong(
            PostBackfillAnalysisRetryPolicy.RETRY_AT_EPOCH_MILLIS_KEY,
            Long.MIN_VALUE,
        )
        if (
            postBackfillRetryWorkerEntryDecision(
                protocolVersion = protocolVersion,
                retryAtEpochMillis = retryAtEpochMillis,
            ) == PostBackfillRetryWorkerEntryDecision.EXIT_LEGACY
        ) {
            AppDiagnosticsRecorder.endOperation(operation, outcome = "legacy_rejected")
            return Result.success()
        }

        when (
            PostBackfillAnalysisRetryScheduler.beginExecution(
                context = applicationContext,
                workId = id.toString(),
                retryAtEpochMillis = retryAtEpochMillis,
                protocolVersion = protocolVersion,
            )
        ) {
            PostBackfillRetryExecutionDecision.LEGACY -> {
                AppDiagnosticsRecorder.endOperation(operation, outcome = "legacy_rejected")
                return Result.success()
            }
            PostBackfillRetryExecutionDecision.STALE -> {
                AppDiagnosticsRecorder.endOperation(operation, outcome = "stale_rejected")
                return Result.success()
            }
            PostBackfillRetryExecutionDecision.RETRY -> {
                AppDiagnosticsRecorder.endOperation(operation, outcome = "state_retry")
                return Result.retry()
            }
            PostBackfillRetryExecutionDecision.ACCEPTED,
            PostBackfillRetryExecutionDecision.RECOVERED,
            -> Unit
        }

        val app = applicationContext as? NoopApplication
        if (app == null || !app.operationalRuntimeStarted) {
            AppDiagnosticsRecorder.endOperation(operation, outcome = "runtime_retry")
            return Result.retry()
        }
        return try {
            val outcomes = app.ble.retryPersistedHistoryFromScheduler()
            val outcome: String
            val result: Result
            val successful: Boolean
            when {
                outcomes.isEmpty() -> {
                    outcome = "no_work"
                    result = Result.success()
                    successful = true
                }
                outcomes.any { it is BackfillAnalysisProcessResult.RetryRequired } -> {
                    outcome = "work_retry"
                    result = Result.retry()
                    successful = false
                }
                outcomes.any {
                    it is BackfillAnalysisProcessResult.Deferred && !it.retryScheduled
                } -> {
                    outcome = "schedule_retry"
                    result = Result.retry()
                    successful = false
                }
                outcomes.any { it is BackfillAnalysisProcessResult.Deferred } -> {
                    outcome = "deferred_rearmed"
                    result = Result.success()
                    successful = true
                }
                else -> {
                    outcome = "completed"
                    result = Result.success()
                    successful = true
                }
            }
            if (
                successful &&
                !PostBackfillAnalysisRetryScheduler.finishExecution(
                    applicationContext,
                    id.toString(),
                )
            ) {
                AppDiagnosticsRecorder.endOperation(operation, outcome = "finish_state_retry")
                Result.retry()
            } else {
                AppDiagnosticsRecorder.endOperation(
                    operation,
                    outcome = outcome,
                )
                result
            }
        } catch (cancelled: CancellationException) {
            AppDiagnosticsRecorder.endOperation(operation, outcome = "cancelled")
            throw cancelled
        } catch (_: Throwable) {
            AppDiagnosticsRecorder.endOperation(operation, outcome = "retry")
            Result.retry()
        }
    }
}

/** Replaces the pending boundary after travel, manual clock changes, or local-date rollover. */
class PostBackfillAnalysisTimeChangeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (!PostBackfillAnalysisRetryPolicy.handlesClockChange(intent?.action)) return
        if (!ManagedRuntimeGate.isAuthorized(context)) return
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val completed = withTimeoutOrNull(RECEIVER_TIMEOUT_MILLIS) {
                    PostBackfillAnalysisRetryScheduler.reconcileClockChange(
                        context = context,
                        pendingSources =
                            WhoopBleClient.readPersistedPostBackfillSourceState(context),
                    )
                    true
                }
                if (completed != true) {
                    PostBackfillAnalysisRetryScheduler.recordReceiverTimeout()
                }
            } catch (_: Throwable) {
                PostBackfillAnalysisRetryScheduler.recordReceiverFailure()
            } finally {
                pendingResult.finish()
            }
        }
    }

    private companion object {
        const val RECEIVER_TIMEOUT_MILLIS = 8_000L
    }
}
