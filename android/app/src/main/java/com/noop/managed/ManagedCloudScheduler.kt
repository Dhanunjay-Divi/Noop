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
import com.google.firebase.FirebaseNetworkException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException

/** Network-constrained, bounded catch-up for an already enrolled NOOP+ account. */
object ManagedCloudScheduler {
    private const val PERIODIC_WORK = "noop_managed_cloud_periodic_v1"
    private const val CATCH_UP_WORK = "noop_managed_cloud_catch_up_v1"
    private const val CATCH_UP_INTERVAL_MS = 15L * 60L * 1_000L

    internal val constraints = Constraints.Builder()
        .setRequiredNetworkType(NetworkType.CONNECTED)
        .setRequiresBatteryNotLow(true)
        .setRequiresStorageNotLow(true)
        .build()

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val service = ManagedCloudService.get(appContext)
        val workManager = WorkManager.getInstance(appContext)
        if (!service.shouldSchedule()) {
            workManager.cancelUniqueWork(PERIODIC_WORK)
            workManager.cancelUniqueWork(CATCH_UP_WORK)
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

    /** Called after launch/foreground work is deferred; never blocks the first app frame. */
    fun enqueueCatchUpIfDue(
        context: Context,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val appContext = context.applicationContext
        val service = ManagedCloudService.get(appContext)
        if (!service.shouldSchedule()) return
        if (nowMs - service.lastAttemptMs() < CATCH_UP_INTERVAL_MS) return
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

    internal fun successfulPassNeedsContinuation(hasMore: Boolean): Boolean = hasMore
}

class ManagedCloudWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        val service = ManagedCloudService.get(applicationContext)
        service.bootstrap()
        if (!service.shouldSchedule()) return Result.success()
        return try {
            val summary = service.syncForWorker()
            if (ManagedCloudScheduler.successfulPassNeedsContinuation(summary.hasMore)) {
                ManagedCloudScheduler.enqueueContinuation(applicationContext)
            }
            Result.success()
        } catch (error: ManagedStorageException.Network) {
            Result.retry()
        } catch (error: ManagedStorageException.Server) {
            if (error.statusCode == 429 || error.statusCode >= 500) {
                Result.retry()
            } else {
                Result.failure()
            }
        } catch (_: FirebaseNetworkException) {
            Result.retry()
        } catch (error: CancellationException) {
            throw error
        } catch (_: ManagedStorageException.Authentication) {
            Result.success()
        } catch (_: ManagedStorageException.PolicyChanged) {
            Result.success()
        } catch (_: ManagedStorageException.QuotaExceeded) {
            Result.success()
        } catch (_: Throwable) {
            if (runAttemptCount < 3) Result.retry() else Result.failure()
        }
    }
}
