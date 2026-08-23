package com.noop.safety

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import com.noop.R
import com.noop.ui.appLaunchIntent

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
        val controller = SafetyPagingController(appContext)
        controller.refresh()
        val active = controller.activeIncident
        val outcome = when {
            active != null -> {
                SafetyLiveLocationSession.start(
                    appContext,
                    active.dispatchId,
                    expiresAtUnix = active.expiresAt?.let(::parseIsoInstantUnix),
                )
                Outcome.AlreadyActive
            }
            !controller.canPage -> Outcome.Unavailable(
                controller.errorMessage
                    ?: "Finish Safety setup and add two accepted contacts.",
            )
            controller.pageAcceptedContacts() -> Outcome.Opened
            else -> Outcome.Unavailable(
                controller.errorMessage ?: "The paging server did not accept the request.",
            )
        }
        postResultNotification(appContext, outcome)
        return outcome
    }

    private fun postResultNotification(context: Context, outcome: Outcome) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(CHANNEL_ID) == null
        ) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Safety page status",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Confirms whether an explicit band SOS gesture opened a page."
                },
            )
        }
        val title: String
        val body: String
        when (outcome) {
            Outcome.Opened -> {
                title = "SOS page sent"
                body = "Accepted contacts are being paged. Open Safety to monitor responses."
            }
            Outcome.AlreadyActive -> {
                title = "SOS page already active"
                body = "Open Safety to monitor contact responses."
            }
            is Outcome.Unavailable -> {
                title = "SOS page was not sent"
                body = "Open Safety to check setup, accepted contacts, and delivery."
            }
        }
        val open = PendingIntent.getActivity(
            context,
            0,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        runCatching {
            manager.notify(
                NOTIFICATION_ID,
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build(),
            )
        }
    }

    private const val CHANNEL_ID = "noop_safety_page_status"
    private const val NOTIFICATION_ID = 4_207
}
