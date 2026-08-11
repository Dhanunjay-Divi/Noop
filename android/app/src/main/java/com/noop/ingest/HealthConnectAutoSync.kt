package com.noop.ingest

import android.content.Context
import android.os.Build
import android.os.ext.SdkExtensions
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.data.WhoopRepository
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import java.util.concurrent.TimeUnit

/**
 * Pure permission/scheduling policy for Health Connect automatic catch-up.
 *
 * Android 15+ (or Android 14 with U extension 13) exposes the dedicated background-health permission
 * carried by the project's pinned Health Connect client. Older releases remain manual/on-open only:
 * NOOP never pretends a periodic worker can read health data when the platform cannot grant access.
 */
internal object HealthConnectBackgroundPolicy {
    // The platform permission is API 35, backported to Android 14 in U extension 13. The pinned
    // connect-client predates HealthConnectFeatures, so use the equivalent platform extension gate.
    const val MIN_BACKGROUND_API = 35
    const val MIN_ANDROID_14_EXTENSION = 13
    const val BACKGROUND_PERMISSION = HealthPermission.PERMISSION_READ_HEALTH_DATA_IN_BACKGROUND

    fun supportsBackground(apiLevel: Int, android14Extension: Int = 0): Boolean =
        apiLevel >= MIN_BACKGROUND_API ||
            (apiLevel == Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                android14Extension >= MIN_ANDROID_14_EXTENSION)

    fun runtimeAndroid14Extension(): Int =
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            SdkExtensions.getExtensionVersion(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        } else {
            0
        }

    fun runtimeSupportsBackground(): Boolean =
        supportsBackground(Build.VERSION.SDK_INT, runtimeAndroid14Extension())

    /** Partial data-type permission remains valid; request the full set only when no type is granted. */
    fun missingPermissionsForAutoSync(
        apiLevel: Int,
        granted: Set<String>,
        android14Extension: Int = 0,
    ): Set<String> = buildSet {
        if (granted.none { it in HealthConnectImporter.PERMISSIONS }) {
            addAll(HealthConnectImporter.PERMISSIONS)
        }
        if (supportsBackground(apiLevel, android14Extension) && BACKGROUND_PERMISSION !in granted) {
            add(BACKGROUND_PERMISSION)
        }
    }

    fun runtimeMissingPermissionsForAutoSync(granted: Set<String>): Set<String> =
        missingPermissionsForAutoSync(
            Build.VERSION.SDK_INT,
            granted,
            runtimeAndroid14Extension(),
        )

    fun canRunInBackground(
        apiLevel: Int,
        granted: Set<String>,
        android14Extension: Int = 0,
    ): Boolean =
        supportsBackground(apiLevel, android14Extension) &&
            BACKGROUND_PERMISSION in granted &&
            granted.any { it in HealthConnectImporter.PERMISSIONS }

    fun runtimeCanRunInBackground(granted: Set<String>): Boolean =
        canRunInBackground(Build.VERSION.SDK_INT, granted, runtimeAndroid14Extension())

    fun intervalHours(raw: Int): Long = when (raw) {
        6, 12, 24 -> raw.toLong()
        else -> 12L
    }
}

/** Best-effort periodic Health Connect import, enabled only by the user's Auto-sync toggle. */
object HealthConnectSyncScheduler {
    private const val WORK_NAME = "noop_health_connect_auto_sync"

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val manager = WorkManager.getInstance(appContext)
        if (!NoopPrefs.hcAutoSync(appContext) ||
            !HealthConnectBackgroundPolicy.runtimeSupportsBackground() ||
            HealthConnectImporter.sdkStatus(appContext) != HealthConnectClient.SDK_AVAILABLE
        ) {
            manager.cancelUniqueWork(WORK_NAME)
            return
        }

        val request = PeriodicWorkRequestBuilder<HealthConnectSyncWorker>(
            HealthConnectBackgroundPolicy.intervalHours(NoopPrefs.hcSyncHours(appContext)),
            TimeUnit.HOURS,
        ).build()
        manager.enqueueUniquePeriodicWork(
            WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }
}

class HealthConnectSyncWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        if (!NoopPrefs.hcAutoSync(applicationContext)) return Result.success()
        if (HealthConnectImporter.sdkStatus(applicationContext) != HealthConnectClient.SDK_AVAILABLE) {
            return Result.success()
        }

        val granted = try {
            HealthConnectImporter.client(applicationContext)
                .permissionController.getGrantedPermissions()
        } catch (_: Throwable) {
            return Result.retry()
        }
        if (!HealthConnectBackgroundPolicy.runtimeCanRunInBackground(granted)) {
            // Permission was never granted or was revoked. Foreground/on-open sync remains available;
            // a background worker must not keep retrying a user decision.
            return Result.success()
        }

        return try {
            val summary = HealthConnectImporter.import(
                context = applicationContext,
                repo = WhoopRepository.from(applicationContext),
                heightCm = ProfileStore.from(applicationContext).heightCm,
                lookbackDays = HealthConnectImporter.AUTOMATIC_LOOKBACK_DAYS,
            )
            if (summary.succeeded) {
                NoopPrefs.setHcLastSync(applicationContext, System.currentTimeMillis())
                Result.success()
            } else {
                // Do not stamp a failed read/save as a successful sync; WorkManager applies backoff.
                Result.retry()
            }
        } catch (_: Throwable) {
            Result.retry()
        }
    }
}
