package com.noop.alarm

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.noop.R
import com.noop.automation.AlarmTapAutomationPrefs
import com.noop.notif.NotificationLifecycleCategory
import com.noop.notif.NotificationLifecycleId
import com.noop.notif.NotificationLifecycleLedger
import com.noop.notif.NotificationPlatformIdentity
import com.noop.ui.appLaunchIntent

/**
 * Fires when the guaranteed wake alarm goes off (scheduled by [SmartAlarmScheduler] via AlarmManager).
 *
 * Raises a FULL-SCREEN, high-priority, alarm-category notification with the device alarm sound and a
 * vibration pattern — the standard way a sideloaded app delivers a dependable wake without owning a
 * foreground Activity. The full-screen intent re-opens NOOP; on a locked screen the system promotes
 * the notification to a heads-up / full-screen alarm. This path is reached whether the alarm fired at
 * the smart (light-sleep) time or the hard deadline, so the user is woken either way.
 *
 * Registered in the manifest (exported=false) so it survives the app being killed. After firing it
 * clears the persisted schedule (a one-shot alarm), then immediately re-arms the next day only when
 * the alarm is still enabled. A disabled-but-fired alarm cannot resurrect itself.
 */
class SmartAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val isSnooze = action == SmartAlarmScheduler.ACTION_FIRE_SNOOZE
        if (action != SmartAlarmScheduler.ACTION_FIRE && !isSnooze) return
        val smart = intent.getBooleanExtra(SmartAlarmScheduler.EXTRA_SMART, false)

        if (!isSnooze) {
            // Clear the schedule we just fired so a boot right after firing doesn't re-raise THIS one...
            val store = SmartAlarmStore.from(context)
            store.scheduledDeadlineMs = 0L
            store.scheduledWindowStartMs = 0L
            // ...then, if the alarm is still enabled, re-arm the GUARANTEED deadline for the NEXT day.
            runCatching { if (store.enabled) SmartAlarmScheduler.arm(context, store, afterFire = true) }
        }

        ensureChannel(context)
        // Defensive: a notify() throw (OEM quirk / revoked POST_NOTIFICATIONS) must not crash the
        // broadcast. The system alarm sound below is the fallback-of-the-fallback audible cue.
        NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.PHONE_SMART_ALARM,
            NotificationLifecycleCategory.ALARM,
        ) {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.notify(NOTIF_ID, buildNotification(context, smart, isSnooze))
        }
        AlarmTapAutomationPrefs.armForActiveAlarm(context)
    }

    private fun buildNotification(context: Context, smart: Boolean, snooze: Boolean): Notification {
        val fullScreen = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.PHONE_SMART_ALARM,
            appLaunchIntent(context),
        )
        val title = "Good morning"
        val body = if (snooze) {
            "Your snooze has ended. Time to get up."
        } else if (smart) {
            "You're in a lighter sleep phase. Time to wake up."
        } else {
            "Your wake window has ended. Time to get up."
        }
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(fullScreen)
            .setFullScreenIntent(fullScreen, true)   // promote to a full-screen alarm on a locked phone
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            val alarmSound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Smart alarm",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "The phone wake alarm NOOP fires inside your chosen wake window."
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 400, 600, 400, 600)
                setBypassDnd(true)   // a wake alarm should sound through Do Not Disturb
                if (alarmSound != null) {
                    setSound(
                        alarmSound,
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                }
            }
            mgr.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "noop_smart_alarm"
        const val NOTIF_ID =
            NotificationPlatformIdentity.NotificationId.PHONE_SMART_ALARM

        fun dismissActive(context: Context) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            NotificationLifecycleLedger.cancelled(
                context,
                NotificationLifecycleId.PHONE_SMART_ALARM,
                NotificationLifecycleCategory.ALARM,
            ) {
                manager.cancel(NOTIF_ID)
            }
        }
    }
}
