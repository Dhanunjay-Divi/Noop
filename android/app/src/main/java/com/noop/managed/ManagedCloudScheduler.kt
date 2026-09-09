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
import androidx.work.workDataOf
import com.google.firebase.FirebaseNetworkException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException

/** Network-constrained, bounded catch-up for an already enrolled NOOP+ account. */
object ManagedCloudScheduler {
    private const val PERIODIC_WORK = "noop_managed_cloud_periodic_v1"
    private const val CATCH_UP_WORK = "noop_managed_cloud_catch_up_v1"
    private const val PUSH_REGISTRATION_WORK = "noop_managed_push_registration_v1"
    private const val SAFETY_PUSH_WORK_PREFIX = "noop_managed_safety_push_v1:"
    internal const val SAFETY_PUSH_INCIDENT_ID = "incident_id"
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
        if (!ManagedRuntimeGate.isAuthorized(appContext)) return
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
        if (!ManagedRuntimeGate.isAuthorized(appContext)) return
        val service = ManagedCloudService.get(appContext)
        if (!service.shouldSchedule()) return
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
        if (!ManagedRuntimeGate.isAuthorized(appContext)) return
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
}

class ManagedCloudWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {
            return Result.success()
        }
        val service = ManagedCloudService.get(applicationContext)
        service.bootstrap()
        if (!service.shouldSchedule()) return Result.success()
        return try {
            if (service.shouldSyncForWorker()) {
                val summary = service.syncForWorker()
                if (ManagedCloudScheduler.successfulPassNeedsContinuation(summary.hasMore)) {
                    ManagedCloudScheduler.enqueueContinuation(applicationContext)
                }
            }
            if (service.shouldRunSocialForWorker()) {
                service.socialCatchUpForWorker()
            }
            if (service.shouldRunSafetyForWorker()) {
                service.safetyCatchUpForWorker()
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
