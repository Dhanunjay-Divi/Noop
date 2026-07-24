package com.noop.sync

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
import com.noop.NoopApplication
import com.noop.ble.WhoopBleClient
import java.util.concurrent.TimeUnit

/** WorkManager scheduling for default-off automatic uploads and launch catch-up. */
object RemoteSyncScheduler {
    private const val PERIODIC_WORK = "noop_remote_sync_periodic"
    private const val CATCH_UP_WORK = "noop_remote_sync_catch_up"
    private const val CATCH_UP_INTERVAL_MS = 5L * 60L * 1_000L

    private val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .build()

    fun reschedule(context: Context) {
        RemoteSyncService.initialize(context)
        val workManager = WorkManager.getInstance(context.applicationContext)
        if (!RemoteSyncPrefs.automatic() || !RemoteSyncPrefs.isConfigured()) {
            workManager.cancelUniqueWork(PERIODIC_WORK)
            workManager.cancelUniqueWork(CATCH_UP_WORK)
            return
        }
        val request = PeriodicWorkRequestBuilder<RemoteSyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        workManager.enqueueUniquePeriodicWork(
            PERIODIC_WORK,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }

    /** Deferred launch catch-up; never performs database/network I/O on the activity startup path. */
    fun enqueueCatchUpIfDue(context: Context, nowMs: Long = System.currentTimeMillis()) {
        RemoteSyncService.initialize(context)
        if (!RemoteSyncPrefs.automatic() || !RemoteSyncPrefs.isConfigured()) return
        if (nowMs - RemoteSyncPrefs.lastAttemptMs() < CATCH_UP_INTERVAL_MS) return
        val request = OneTimeWorkRequestBuilder<RemoteSyncWorker>()
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork(CATCH_UP_WORK, ExistingWorkPolicy.KEEP, request)
    }

}

class RemoteSyncWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        RemoteSyncService.initialize(applicationContext)
        if (!RemoteSyncPrefs.automatic() || !RemoteSyncPrefs.isConfigured()) return Result.success()

        val app = applicationContext as? NoopApplication
        val activeDeviceId = runCatching { app?.deviceRegistry?.activeDeviceId() }
            .getOrNull()
            ?: app?.activeDeviceId
            ?: WhoopBleClient.DEFAULT_DEVICE_ID
        return try {
            val result = RemoteSyncService.sync(applicationContext, activeDeviceId)
            // A bounded page succeeded but the durable outbox still has rows. Retry this same work
            // with WorkManager's backoff instead of spinning in-process or waiting for the next period.
            if (result.hasMoreRawRows || result.hasMoreDerivedRows) {
                Result.retry()
            } else {
                Result.success()
            }
        } catch (error: RemoteSyncException.Network) {
            Result.retry()
        } catch (error: RemoteSyncException.Server) {
            if (error.statusCode >= 500 || error.statusCode == 429) Result.retry() else Result.failure()
        } catch (_: Throwable) {
            Result.failure()
        }
    }
}
