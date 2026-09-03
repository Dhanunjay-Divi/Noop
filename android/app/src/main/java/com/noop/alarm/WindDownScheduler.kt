package com.noop.alarm

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.noop.R
import com.noop.notif.NotificationLifecycleCategory
import com.noop.notif.NotificationLifecycleId
import com.noop.notif.NotificationLifecycleLedger
import com.noop.notif.NotificationLifecycleState
import com.noop.notif.NotificationPlatformIdentity
import com.noop.ui.ContextualActionCenter
import com.noop.ui.appLaunchIntent
import java.util.Calendar
import java.util.TimeZone

/**
 * The wind-down nudge (#207) — a gentle, NON-safety-critical evening local notification.
 *
 * Deliberately INEXACT: a missed wind-down nudge costs nothing, so we use a one-shot inexact alarm
 * (no exact-alarm permission needed) rather than the privileged primitive the wake alarm uses.
 * The receiver computes the next local wall-clock occurrence after every fire. A repeating
 * INTERVAL_DAY alarm is incorrect here because it drifts by an hour when daylight-saving time
 * changes.
 * The nudge minute is derived from the user's earliest wake time via [WindDownStore.nudgeMinuteOfDay].
 *
 * The fired notification is low-key (default importance, no full-screen, no DND bypass) — it's a
 * suggestion, not an alarm.
 */
object WindDownScheduler {

    private const val REQUEST_CODE = 7311
    const val ACTION_NUDGE = "com.noop.alarm.action.WIND_DOWN_NUDGE"
    const val CHANNEL_ID = "noop_wind_down"

    /**
     * Schedule (or reschedule) the daily nudge at the minute derived from [wakeMinutes]. Cancels any
     * prior schedule first so a settings change doesn't stack two nudges. No-op'd by the caller when
     * the nudge is disabled (it calls [cancel] instead).
     */
    fun schedule(context: Context, store: WindDownStore, wakeMinutes: Int) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = nudgePendingIntent(context)
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.WIND_DOWN,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.SCHEDULED,
        ) {
            am.cancel(pi)
            val minuteOfDay = store.nudgeMinuteOfDay(wakeMinutes)
            val next = nextOccurrenceEpochMillis(minuteOfDay)
            // Inexact, one-shot, NOT wakeup — a wind-down reminder doesn't need to punch through Doze.
            // WindDownReceiver schedules the following local occurrence after this one fires.
            am.set(
                AlarmManager.RTC,
                next,
                pi,
            )
        }
    }

    fun cancel(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.WIND_DOWN,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.CANCELLED,
        ) {
            am.cancel(nudgePendingIntent(context))
        }
    }

    /** Raise the low-key nudge notification. Called from [WindDownReceiver]. */
    fun fireNotification(context: Context) {
        ensureChannel(context)
        runCatching {
            val open = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.WIND_DOWN,
                appLaunchIntent(context),
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.wind_down_notification_title))
                .setContentText(context.getString(R.string.wind_down_notification_body))
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .build()
            val posted = NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            ) {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(NotificationPlatformIdentity.NotificationId.WIND_DOWN, n)
            }
            if (posted) {
                ContextualActionCenter.presentWindDown(
                    context = context,
                    fingerprint = java.time.LocalDate.now().toString(),
                    title = context.getString(R.string.wind_down_notification_title),
                    detail = context.getString(R.string.wind_down_notification_body),
                )
            }
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            )
        }
    }

    private fun nudgePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, WindDownReceiver::class.java).setAction(ACTION_NUDGE)
        return PendingIntent.getBroadcast(
            context, REQUEST_CODE, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.wind_down_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = context.getString(R.string.wind_down_channel_description)
                    setShowBadge(false)
                },
            )
        }
    }

    /**
     * Next strictly-future local wall-clock occurrence. Clock and zone are injectable so DST and
     * travel behavior remain covered by plain JVM tests.
     */
    internal fun nextOccurrenceEpochMillis(
        minuteOfDay: Int,
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault(),
    ): Long =
        Calendar.getInstance(timeZone).apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
            set(Calendar.MINUTE, minuteOfDay % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= nowMs) add(Calendar.DAY_OF_YEAR, 1)
        }.timeInMillis
}

/** Receives a one-shot wind-down nudge, raises the reminder, and schedules the next local occurrence.
 *  [SmartAlarmBootReceiver] also re-arms it after reboot and wall-clock/timezone changes. */
class WindDownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != WindDownScheduler.ACTION_NUDGE) return
        WindDownScheduler.fireNotification(context)
        runCatching {
            val wind = WindDownStore.from(context)
            if (wind.enabled) {
                WindDownScheduler.schedule(
                    context,
                    wind,
                    SmartAlarmStore.from(context).targetMinutes,
                )
            }
        }
    }
}
