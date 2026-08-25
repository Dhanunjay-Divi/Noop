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
 * #577 — posts the inactivity (sedentary) wrist nudge as a real system notification, mirroring the iOS
 * `AppModel.postInactivity`. A pocketed phone can't show the strap buzz on screen the way the Mac does,
 * so a wrist buzz the user might miss is ALSO surfaced as a local notification. Called from
 * `WhoopBleClient.maybeBuzzInactivity` right after the buzz fires.
 *
 * Gated on the SAME wrist-alerts master ([NotifPrefs.MASTER]) the SedentaryDetector reads, so turning
 * wrist alerts off silences this too — belt-and-suspenders, since the engine's `mayBuzz` already checks
 * the master before reporting `shouldBuzz`.
 */
object InactivityNotifier {
    private const val CHANNEL_ID = "noop_inactivity"

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onNudged(context: Context, minutes: Int) {
        // Mirror the iOS master gate: the engine already honours it before buzzing, re-check anyway.
        if (!NotifPrefs.getBool(context, NotifPrefs.MASTER, false)) return
        val body = if (minutes > 0) {
            "You've been seated for about $minutes min. Time to move."
        } else {
            "Time to move. You've been seated a while."
        }
        // Defensive: never let a notify() throw (revoked POST_NOTIFICATIONS, OEM quirk) crash the offload.
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.INACTIVITY,
                    NotificationLifecycleCategory.REMINDER,
                )
                return
            }
            ensureChannel(context)
            val openApp = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.INACTIVITY,
                appLaunchIntent(context),
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle("Move reminder")
                .setContentText(body)
                .setContentIntent(openApp)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.INACTIVITY,
                NotificationLifecycleCategory.REMINDER,
            ) {
                NotificationManagerCompat.from(context).notify(
                    NotificationPlatformIdentity.NotificationId.INACTIVITY,
                    n,
                )
            }
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.INACTIVITY,
                NotificationLifecycleCategory.REMINDER,
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
                    CHANNEL_ID, "Inactivity reminder",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "A nudge to move after a long sedentary stretch."
                },
            )
        }
    }
}
