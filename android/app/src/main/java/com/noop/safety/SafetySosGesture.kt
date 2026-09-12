package com.noop.safety

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.noop.R
import com.noop.managed.ManagedCloudService
import com.noop.managed.ManagedSafetyBandSosOutcome
import com.noop.notif.NotificationLifecycleCategory
import com.noop.notif.NotificationLifecycleId
import com.noop.notif.NotificationLifecycleLedger
import com.noop.notif.NotificationPlatformIdentity
import com.noop.notif.protectPrivateContent
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge

/**
 * The band emits one DOUBLE_TAP event, not individual tap counts. This policy therefore counts
 * repeated double-tap events and never represents them as a literal hardware triple tap.
 */
class SafetySosGestureAccumulator(
    private val maximumGapMs: Long = MAXIMUM_GAP_MS,
) {
    sealed interface Result {
        data class Progress(val count: Int) : Result
        data object Triggered : Result
    }

    private var eventCount = 0
    private var lastEventAtMs: Long? = null

    fun record(eventAtMs: Long, requiredEvents: Int): Result {
        val required = requiredEvents.coerceIn(MINIMUM_EVENTS, MAXIMUM_EVENTS)
        if (eventAtMs < 0L || maximumGapMs <= 0L) {
            reset()
            return Result.Progress(0)
        }
        lastEventAtMs?.let { previous ->
            val gap = eventAtMs - previous
            if (gap <= 0L || gap > maximumGapMs) eventCount = 0
        }
        lastEventAtMs = eventAtMs
        eventCount += 1
        if (eventCount >= required) {
            reset()
            return Result.Triggered
        }
        return Result.Progress(eventCount)
    }

    fun reset() {
        eventCount = 0
        lastEventAtMs = null
    }

    companion object {
        const val MINIMUM_EVENTS = 3
        const val MAXIMUM_EVENTS = 4
        const val MAXIMUM_GAP_MS = 2_750L
    }
}

object SafetySosGesturePrefs {
    private const val FILE = "noop_safety_sos_gesture"
    private const val ENABLED = "enabled"
    private const val REQUIRED_EVENTS = "required_events"
    private const val SHARE_LOCATION = "share_location"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean = prefs(context).getBoolean(ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(ENABLED, enabled).apply()
    }

    fun requiredEvents(context: Context): Int =
        prefs(context).getInt(REQUIRED_EVENTS, 4).coerceIn(
            SafetySosGestureAccumulator.MINIMUM_EVENTS,
            SafetySosGestureAccumulator.MAXIMUM_EVENTS,
        )

    fun setRequiredEvents(context: Context, count: Int) {
        prefs(context).edit().putInt(
            REQUIRED_EVENTS,
            count.coerceIn(
                SafetySosGestureAccumulator.MINIMUM_EVENTS,
                SafetySosGestureAccumulator.MAXIMUM_EVENTS,
            ),
        ).apply()
    }

    fun sharesLocation(context: Context): Boolean =
        prefs(context).getBoolean(SHARE_LOCATION, false)

    fun setSharesLocation(context: Context, sharesLocation: Boolean) {
        prefs(context).edit().putBoolean(SHARE_LOCATION, sharesLocation).apply()
    }
}

/** Process-wide exactly-once gate because both the foreground service and ViewModel observe gestures. */
object SafetySosGestureRuntime {
    sealed interface Result {
        data object Ignored : Result
        data object ReservedDuplicate : Result
        data class Progress(val count: Int, val required: Int) : Result
        data object Triggered : Result
    }

    private var lastGestureSequence = Long.MIN_VALUE
    private val accumulator = SafetySosGestureAccumulator()

    @Synchronized
    fun consume(
        context: Context,
        gestureSequence: Long,
        eventAtMs: Long = SystemClock.elapsedRealtime(),
    ): Result {
        val enabled = SafetySosGesturePrefs.enabled(context)
        if (gestureSequence == lastGestureSequence) {
            return if (enabled) Result.ReservedDuplicate else Result.Ignored
        }
        lastGestureSequence = gestureSequence
        if (!enabled) {
            accumulator.reset()
            return Result.Ignored
        }
        val required = SafetySosGesturePrefs.requiredEvents(context)
        return when (val result = accumulator.record(eventAtMs, required)) {
            is SafetySosGestureAccumulator.Result.Progress ->
                Result.Progress(result.count, required)
            SafetySosGestureAccumulator.Result.Triggered -> Result.Triggered
        }
    }
}

object SafetySosDispatcher {
    sealed interface Outcome {
        data object Opened : Outcome
        data object AlreadyActive : Outcome
        data class Unavailable(val reason: String) : Outcome
    }

    suspend fun trigger(context: Context): Outcome {
        val appContext = context.applicationContext
        val shareLocation = shouldShareLocation(
            preferenceEnabled = SafetySosGesturePrefs.sharesLocation(appContext),
            backgroundLocationAvailable = backgroundLocationAvailable(appContext),
        )
        val outcome = when (
            val managed = ManagedCloudService.get(appContext).triggerBandSos(
                durationHours = SafetyPagingPrefs.shareDurationHours(appContext),
                shareLocation = shareLocation,
            )
        ) {
            ManagedSafetyBandSosOutcome.Opened -> Outcome.Opened
            ManagedSafetyBandSosOutcome.AlreadyActive -> Outcome.AlreadyActive
            is ManagedSafetyBandSosOutcome.Unavailable ->
                Outcome.Unavailable(managed.reason)
        }
        SafetyStatusNotifications.postOutcome(appContext, outcome)
        return outcome
    }

    internal fun shouldShareLocation(
        preferenceEnabled: Boolean,
        backgroundLocationAvailable: Boolean,
    ): Boolean = preferenceEnabled && backgroundLocationAvailable

    private fun backgroundLocationAvailable(context: Context): Boolean {
        val foreground =
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED
        val background =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_BACKGROUND_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED
        return foreground && background
    }
}

internal object SafetyStatusNotifications {
    internal fun outcomeResources(
        outcome: SafetySosDispatcher.Outcome,
    ): Pair<Int, Int> = when (outcome) {
        SafetySosDispatcher.Outcome.Opened ->
            R.string.safety_page_status_submitted to
                R.string.safety_page_detail_submitted
        SafetySosDispatcher.Outcome.AlreadyActive ->
            R.string.safety_page_status_open to
                R.string.safety_page_detail_waiting
        is SafetySosDispatcher.Outcome.Unavailable ->
            R.string.safety_page_status_failed to
                R.string.safety_delivery_unavailable
    }

    fun deliveryAvailable(context: Context): Boolean {
        val app = context.applicationContext
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(app, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (!NotificationManagerCompat.from(app).areNotificationsEnabled()) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = manager.getNotificationChannel(CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }

    fun postOutcome(context: Context, outcome: SafetySosDispatcher.Outcome): Boolean {
        val (title, body) = outcomeResources(outcome)
        return post(context, title, body)
    }

    fun postIncident(context: Context, status: SafetyIncidentStatus): Boolean {
        val resources = when (status) {
            SafetyIncidentStatus.ACKNOWLEDGED ->
                R.string.safety_page_status_acknowledged to
                    R.string.safety_page_detail_acknowledged
            SafetyIncidentStatus.FAILED ->
                R.string.safety_page_all_contacts_failed_title to
                    R.string.safety_page_detail_failed
            else -> return true
        }
        return post(context, resources.first, resources.second)
    }

    private fun post(context: Context, titleResource: Int, bodyResource: Int): Boolean {
        val app = context.applicationContext
        if (!deliveryAvailable(app)) {
            NotificationLifecycleLedger.suppressed(
                app,
                NotificationLifecycleId.SAFETY_SOS_RESULT,
                NotificationLifecycleCategory.STATUS,
            )
            return false
        }
        val manager = runCatching {
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).also {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    it.getNotificationChannel(CHANNEL_ID) == null
                ) {
                    it.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            app.getString(R.string.safety_page_section),
                            NotificationManager.IMPORTANCE_HIGH,
                        ).apply {
                            description = app.getString(R.string.safety_page_disclaimer)
                        },
                    )
                }
            }
        }.getOrElse {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.SAFETY_SOS_RESULT,
                NotificationLifecycleCategory.STATUS,
            )
            return false
        }
        val title = app.getString(titleResource)
        val body = app.getString(bodyResource)
        val open = NotificationPlatformIdentity.activityPendingIntent(
            app,
            NotificationPlatformIdentity.ActivityIntent.SAFETY_SOS_RESULT,
            NotificationRouteBridge.launchIntent(app, NoopNotificationRoute.SAFETY),
        )
        return NotificationLifecycleLedger.posted(
            app,
            NotificationLifecycleId.SAFETY_SOS_RESULT,
            NotificationLifecycleCategory.STATUS,
        ) {
            manager.notify(
                NotificationPlatformIdentity.NotificationId.SAFETY_SOS_RESULT,
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .protectPrivateContent(context, CHANNEL_ID)
                    .build(),
            )
        }
    }

    private const val CHANNEL_ID = "noop_safety_page_status"
}
