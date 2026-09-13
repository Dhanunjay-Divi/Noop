package com.noop.ble

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.AppDiagnosticsRecorder
import com.noop.NoopApplication
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException

internal object PostBackfillAnalysisRetryPolicy {
    private const val WORK_NAME_PREFIX = "noop_post_backfill_analysis_retry_v1:"
    private const val MIN_DELAY_MILLIS = 1_000L

    fun initialDelayMillis(
        retryAtEpochMillis: Long,
        nowEpochMillis: Long,
    ): Long {
        if (retryAtEpochMillis <= nowEpochMillis) return MIN_DELAY_MILLIS
        val remaining = retryAtEpochMillis - nowEpochMillis
        return if (remaining < 0L) Long.MAX_VALUE else remaining.coerceAtLeast(MIN_DELAY_MILLIS)
    }

    fun workName(retryAtEpochMillis: Long): String =
        WORK_NAME_PREFIX + retryAtEpochMillis.coerceAtLeast(0L).toString()
}

/**
 * Durable local wake for a late-only post-backfill claim. The unique name contains only the planned
 * boundary, never a device/source identifier. WorkManager can recreate the process without an Activity.
 */
internal object PostBackfillAnalysisRetryScheduler {
    fun schedule(
        context: Context,
        retryAtEpochMillis: Long,
        nowEpochMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        val request = OneTimeWorkRequestBuilder<PostBackfillAnalysisRetryWorker>()
            .setInitialDelay(
                PostBackfillAnalysisRetryPolicy.initialDelayMillis(
                    retryAtEpochMillis = retryAtEpochMillis,
                    nowEpochMillis = nowEpochMillis,
                ),
                TimeUnit.MILLISECONDS,
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        return runCatching {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                PostBackfillAnalysisRetryPolicy.workName(retryAtEpochMillis),
                // A clock/time-zone shift can make the running retry defer to the same boundary again.
                // Append behind that in-flight work instead of letting KEEP discard the only rearm.
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                request,
            )
            AppDiagnosticsRecorder.record(
                "analysis.post_backfill_retry",
                fields = mapOf("outcome" to "scheduled"),
            )
            true
        }.getOrElse {
            AppDiagnosticsRecorder.record(
                "analysis.post_backfill_retry",
                fields = mapOf("outcome" to "schedule_failed"),
            )
            false
        }
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
        val app = applicationContext as? NoopApplication
        if (app == null || !app.operationalRuntimeStarted) {
            AppDiagnosticsRecorder.endOperation(operation, outcome = "runtime_retry")
            return Result.retry()
        }

        return try {
            val outcomes = app.ble.retryPersistedHistoryFromScheduler()
            when {
                outcomes.isEmpty() -> {
                    AppDiagnosticsRecorder.endOperation(operation, outcome = "no_work")
                    Result.success()
                }
                outcomes.any {
                    it is BackfillAnalysisProcessResult.Deferred && !it.retryScheduled
                } -> {
                    AppDiagnosticsRecorder.endOperation(operation, outcome = "schedule_retry")
                    Result.retry()
                }
                outcomes.any { it is BackfillAnalysisProcessResult.Deferred } -> {
                    AppDiagnosticsRecorder.endOperation(operation, outcome = "deferred_rearmed")
                    Result.success()
                }
                else -> {
                    AppDiagnosticsRecorder.endOperation(operation, outcome = "completed")
                    Result.success()
                }
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
