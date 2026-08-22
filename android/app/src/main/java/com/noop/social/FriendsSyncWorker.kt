package com.noop.social

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.NoopApplication
import com.noop.ble.WhoopBleClient
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException

class FriendsSyncWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        val app = applicationContext as? NoopApplication ?: return Result.failure()
        return try {
            // The process-level BLE seed is intentionally stable for a live connection, but a worker
            // may run hours after the user changed their active source. Resolve the registry at
            // execution time so the social projection never follows a stale startup id.
            val activeDeviceId =
                app.deviceRegistry.activeDeviceId()
                    ?: app.activeDeviceId.takeIf(String::isNotBlank)
                    ?: WhoopBleClient.DEFAULT_DEVICE_ID
            val refresh = FriendsService.automaticRefreshIfDue(
                context = app,
                repository = app.repository,
                activeDeviceId = activeDeviceId,
            )
            if (refresh?.summaryRetryable == true) Result.retry() else Result.success()
        } catch (error: FriendsException.Network) {
            Result.retry()
        } catch (error: FriendsException.Server) {
            if (error.statusCode == 429 || error.statusCode >= 500) Result.retry() else Result.success()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            Result.success()
        }
    }
}

object FriendsSyncScheduler {
    private const val UNIQUE_WORK = "noop-friends-summary-sync"

    fun reconcile(context: Context) {
        val workManager = WorkManager.getInstance(context.applicationContext)
        if (FriendsPreferences.memberContext(context) == null) {
            workManager.cancelUniqueWork(UNIQUE_WORK)
            return
        }
        val request = PeriodicWorkRequestBuilder<FriendsSyncWorker>(6, TimeUnit.HOURS)
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .build()
        workManager.enqueueUniquePeriodicWork(
            UNIQUE_WORK,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }
}
