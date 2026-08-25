package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.NotifPrefs
import com.noop.ui.appLaunchIntent

/**
 * #577 — posts the smart-alarm wake as a local notification, mirroring the iOS `AppModel.postSmartAlarm`.
 * The strap buzzes your wrist at the smart-alarm time; a pocketed phone surfaces it as a notification too
 * so a missed wrist buzz still reaches you. Called from `AppViewModel` when the strap reports
 * `STRAP_DRIVEN_ALARM_EXECUTED` (WhoopBleClient.onSmartAlarmFired).
 *
 * Gated on the SAME wrist-alerts master ([NotifPrefs.MASTER]) the inactivity/illness posters use, so
 * turning wrist alerts off silences it. Twin of [InactivityNotifier].
 */
object SmartAlarmNotifier {
    private const val CHANNEL_ID = "noop_smart_alarm"

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onFired(context: Context) {
        if (!NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) return
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.BAND_SMART_ALARM,
                    NotificationLifecycleCategory.ALARM,
                )
                return
            }
            ensureChannel(context)
            val openApp = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.BAND_SMART_ALARM,
                appLaunchIntent(context),
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle("Good morning")
                .setContentText("Your smart alarm just went off.")
                .setContentIntent(openApp)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.BAND_SMART_ALARM,
                NotificationLifecycleCategory.ALARM,
            ) {
                NotificationManagerCompat.from(context).notify(
                    NotificationPlatformIdentity.NotificationId.BAND_SMART_ALARM,
                    n,
                )
            }
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.BAND_SMART_ALARM,
                NotificationLifecycleCategory.ALARM,
            )
        }
    }

    fun dismiss(context: Context) {
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.BAND_SMART_ALARM,
            NotificationLifecycleCategory.ALARM,
        ) {
            NotificationManagerCompat.from(context.applicationContext).cancel(
                NotificationPlatformIdentity.NotificationId.BAND_SMART_ALARM,
            )
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Smart alarm",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Your wake-up smart alarm went off on Noop Band."
                },
            )
        }
    }
}
