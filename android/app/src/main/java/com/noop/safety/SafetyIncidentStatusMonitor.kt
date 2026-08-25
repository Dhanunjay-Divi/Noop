package com.noop.safety

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.ble.WhoopConnectionService
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException

internal enum class SafetyIncidentPollResult {
    ACTIVE,
    TERMINAL,
    RETRY,
}

internal data class SafetyIncidentNotificationMarker(
    val dispatchId: String,
    val status: String,
)

internal fun safetyNotificationMarkerAfterAttempt(
    previous: SafetyIncidentNotificationMarker?,
    candidate: SafetyIncidentNotificationMarker,
    postedSuccessfully: Boolean,
): SafetyIncidentNotificationMarker? = if (postedSuccessfully) candidate else previous

/**
 * Best-effort reconciliation for an active Safety page.
 *
 * The foreground BLE service polls promptly while it is alive. WorkManager is the process-death and
 * reboot fallback; Android owns its timing, so this is not represented as real-time delivery.
 */
internal object SafetyIncidentStatusMonitor {
    private const val PREFS_FILE = "noop_safety_incident_monitor"
    private const val DISPATCH_ID = "dispatch_id"
    private const val EXPIRES_AT = "expires_at"
    private const val LAST_NOTIFIED_DISPATCH_ID = "last_notified_dispatch_id"
    private const val LAST_NOTIFIED_STATUS = "last_notified_status"
    private const val WORK_NAME = "noop-safety-incident-status"
    internal const val MAXIMUM_MONITOR_SECONDS = 12L * 60L * 60L
    internal const val ACTIVE_POLL_DELAY_MILLIS = 15_000L
    internal const val RETRY_POLL_DELAY_MILLIS = 45_000L
    internal val workBackoffPolicy: BackoffPolicy = BackoffPolicy.LINEAR
    private val stateLock = Any()

    private val activeStatuses = setOf(
        SafetyIncidentStatus.OPEN,
        SafetyIncidentStatus.ACKNOWLEDGED,
        SafetyIncidentStatus.PENDING,
    )

    internal fun isActive(status: SafetyIncidentStatus): Boolean =
        status in activeStatuses

    internal fun notificationStatus(
        status: SafetyIncidentStatus,
    ): SafetyIncidentStatus? = when (status) {
        SafetyIncidentStatus.ACKNOWLEDGED -> SafetyIncidentStatus.ACKNOWLEDGED
        SafetyIncidentStatus.FAILED -> SafetyIncidentStatus.FAILED
        else -> null
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    internal fun boundedExpiryUnix(expiresAtUnix: Long?, nowUnix: Long): Long {
        val maximum = nowUnix + MAXIMUM_MONITOR_SECONDS
        return when {
            expiresAtUnix == null -> maximum
            expiresAtUnix <= nowUnix -> nowUnix
            else -> minOf(expiresAtUnix, maximum)
        }
    }

    internal fun nextPollDelayMillis(result: SafetyIncidentPollResult): Long? =
        when (result) {
            SafetyIncidentPollResult.ACTIVE -> ACTIVE_POLL_DELAY_MILLIS
            SafetyIncidentPollResult.RETRY -> RETRY_POLL_DELAY_MILLIS
            SafetyIncidentPollResult.TERMINAL -> null
        }

    fun start(
        context: Context,
        dispatchId: String,
        expiresAtUnix: Long?,
        nowUnix: Long = System.currentTimeMillis() / 1_000L,
    ) {
        val app = context.applicationContext
        synchronized(stateLock) {
            val state = prefs(app)
            val changed = state.getString(DISPATCH_ID, null) != dispatchId
            val boundedExpiry = boundedExpiryUnix(expiresAtUnix, nowUnix)
            val existingExpiry = state.getLong(EXPIRES_AT, 0L)
            val retainedExpiry = if (changed || existingExpiry <= 0L) {
                boundedExpiry
            } else {
                minOf(existingExpiry, boundedExpiry)
            }
            state.edit()
                .putString(DISPATCH_ID, dispatchId)
                .putLong(EXPIRES_AT, retainedExpiry)
                .apply {
                    if (changed) {
                        remove(LAST_NOTIFIED_DISPATCH_ID)
                        remove(LAST_NOTIFIED_STATUS)
                    }
                }
                .apply()
            enqueue(app, ExistingWorkPolicy.REPLACE)
        }
    }

    fun reconcile(context: Context) {
        val app = context.applicationContext
        val activeLocation = SafetyLiveLocationSession.state.value
        synchronized(stateLock) {
            if (prefs(app).getString(DISPATCH_ID, null).isNullOrBlank() &&
                !activeLocation.dispatchId.isNullOrBlank()
            ) {
                start(app, checkNotNull(activeLocation.dispatchId), activeLocation.expiresAtUnix)
                return
            }
            if (hasMonitorState(app)) {
                enqueue(app, ExistingWorkPolicy.KEEP)
            } else {
                clearLocked(app)
            }
        }
    }

    fun stop(context: Context, expectedDispatchId: String? = null) {
        val app = context.applicationContext
        synchronized(stateLock) {
            val active = prefs(app).getString(DISPATCH_ID, null)
            if (expectedDispatchId != null && active != expectedDispatchId) return
            clearLocked(app)
            WorkManager.getInstance(app).cancelUniqueWork(WORK_NAME)
        }
    }

    suspend fun poll(context: Context): SafetyIncidentPollResult {
        val app = context.applicationContext
        SafetyLiveLocationSession.initialize(app)
        val (dispatchId, expiry) = synchronized(stateLock) {
            val state = prefs(app)
            val id = state.getString(DISPATCH_ID, null)
                ?.takeIf(String::isNotBlank)
                ?: return SafetyIncidentPollResult.TERMINAL
            id to state.getLong(EXPIRES_AT, 0L)
        }
        val locallyExpired =
            expiry > 0L && expiry <= System.currentTimeMillis() / 1_000L
        if (locallyExpired) {
            SafetyLiveLocationSession.stop(app, expectedDispatchId = dispatchId)
        }
        return try {
            val dispatch = fetchSafetyIncident(app, dispatchId)
            val notificationReconciled = observe(app, dispatch)
            val activeLocation = SafetyLiveLocationSession.state.value
            if (
                !locallyExpired &&
                isActive(dispatch.status) &&
                activeLocation.dispatchId == dispatchId
            ) {
                SafetyLiveLocationSession.start(
                    app,
                    dispatchId,
                    expiresAtUnix = dispatch.expiresAt?.let(::parseIsoInstantUnix),
                    startingSequence = dispatch.latestLocation?.sequence ?: 0L,
                )
                WhoopConnectionService.start(app)
            }
            if (locallyExpired || !isActive(dispatch.status)) {
                SafetyLiveLocationSession.stop(app, expectedDispatchId = dispatchId)
            }
            val result = pollResultAfterObservation(
                status = dispatch.status,
                locallyExpired = locallyExpired,
                notificationReconciled = notificationReconciled,
            )
            if (result == SafetyIncidentPollResult.TERMINAL) {
                if (clear(app, expectedDispatchId = dispatchId)) {
                    SafetyLiveLocationSession.stop(app, expectedDispatchId = dispatchId)
                }
            }
            result
        } catch (error: SafetyPagingException.Server) {
            if (error.statusCode in setOf(401, 404, 409, 410)) {
                if (clear(app, expectedDispatchId = dispatchId)) {
                    SafetyLiveLocationSession.stop(app, expectedDispatchId = dispatchId)
                }
                SafetyIncidentPollResult.TERMINAL
            } else {
                SafetyIncidentPollResult.RETRY
            }
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            SafetyIncidentPollResult.RETRY
        }
    }

    internal fun pollResultAfterObservation(
        status: SafetyIncidentStatus,
        locallyExpired: Boolean,
        notificationReconciled: Boolean,
    ): SafetyIncidentPollResult = when {
        notificationStatus(status) != null && !notificationReconciled ->
            SafetyIncidentPollResult.RETRY
        locallyExpired -> SafetyIncidentPollResult.TERMINAL
        isActive(status) -> SafetyIncidentPollResult.ACTIVE
        else -> SafetyIncidentPollResult.TERMINAL
    }

    /**
     * Returns false only when a material status still needs a successful notification post.
     * The marker is committed after notify() returns, never when authorization or posting fails.
     */
    fun observe(context: Context, dispatch: SafetyPagingDispatch): Boolean {
        val app = context.applicationContext
        val notifiableStatus = notificationStatus(dispatch.status) ?: return true
        return synchronized(stateLock) {
            val state = prefs(app)
            if (state.getString(DISPATCH_ID, null) != dispatch.dispatchId) {
                return@synchronized true
            }
            val previousDispatch = state.getString(LAST_NOTIFIED_DISPATCH_ID, null)
            val previousStatus = state.getString(LAST_NOTIFIED_STATUS, null)
            val previous = if (previousDispatch != null && previousStatus != null) {
                SafetyIncidentNotificationMarker(previousDispatch, previousStatus)
            } else {
                null
            }
            val candidate = SafetyIncidentNotificationMarker(
                dispatch.dispatchId,
                notifiableStatus.name,
            )
            if (previous == candidate) return@synchronized true

            val posted = SafetyStatusNotifications.postIncident(app, notifiableStatus)
            val next = safetyNotificationMarkerAfterAttempt(
                previous = previous,
                candidate = candidate,
                postedSuccessfully = posted,
            )
            if (next == candidate) {
                state.edit()
                    .putString(LAST_NOTIFIED_DISPATCH_ID, candidate.dispatchId)
                    .putString(LAST_NOTIFIED_STATUS, candidate.status)
                    .apply()
            }
            posted
        }
    }

    private fun hasMonitorState(context: Context): Boolean =
        !prefs(context).getString(DISPATCH_ID, null).isNullOrBlank()

    private fun enqueue(context: Context, policy: ExistingWorkPolicy) {
        val request = OneTimeWorkRequestBuilder<SafetyIncidentStatusWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setInitialDelay(15, TimeUnit.SECONDS)
            .setBackoffCriteria(workBackoffPolicy, 15, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniqueWork(WORK_NAME, policy, request)
    }

    private fun clear(
        context: Context,
        expectedDispatchId: String,
    ): Boolean = synchronized(stateLock) {
        if (prefs(context).getString(DISPATCH_ID, null) != expectedDispatchId) {
            return@synchronized false
        }
        clearLocked(context)
        true
    }

    private fun clearLocked(context: Context) {
        prefs(context).edit()
            .remove(DISPATCH_ID)
            .remove(EXPIRES_AT)
            .apply()
    }
}

class SafetyIncidentStatusWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result =
        when (SafetyIncidentStatusMonitor.poll(applicationContext)) {
            SafetyIncidentPollResult.ACTIVE,
            SafetyIncidentPollResult.RETRY,
            -> Result.retry()
            SafetyIncidentPollResult.TERMINAL -> Result.success()
        }
}
