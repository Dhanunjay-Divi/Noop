package com.noop.notif

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.noop.R
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge

/**
 * Generic, private presentation for a managed Friends poke.
 *
 * The notification deliberately omits the sender, profile identifiers, and health context. The
 * returned value is the bounded server acknowledgement category, not an OS delivery claim.
 */
internal object ManagedSocialPokeNotifier {
    private const val CHANNEL_ID = "noop_managed_friends"

    @SuppressLint("MissingPermission")
    fun post(context: Context): String = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.MANAGED_FRIENDS_POKE,
                NotificationLifecycleCategory.STATUS,
            )
            return "not_authorized"
        }
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.MANAGED_FRIENDS_POKE,
                NotificationLifecycleCategory.STATUS,
            )
            return "not_authorized"
        }
        ensureChannel(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val system = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (system.getNotificationChannel(CHANNEL_ID)?.importance ==
                NotificationManager.IMPORTANCE_NONE
            ) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.MANAGED_FRIENDS_POKE,
                    NotificationLifecycleCategory.STATUS,
                )
                return "not_authorized"
            }
        }
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.MANAGED_FRIENDS_POKE,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.FRIENDS),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.managed_friends_poke_title))
            .setContentText(context.getString(R.string.managed_friends_poke_body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_SOCIAL)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        if (
            NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.MANAGED_FRIENDS_POKE,
                NotificationLifecycleCategory.STATUS,
            ) {
                manager.notify(
                    NotificationPlatformIdentity.NotificationId.MANAGED_FRIENDS_POKE,
                    notification,
                )
            }
        ) {
            "scheduled"
        } else {
            "failed"
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            NotificationLifecycleId.MANAGED_FRIENDS_POKE,
            NotificationLifecycleCategory.STATUS,
        )
        "failed"
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.managed_friends_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.name = context.getString(R.string.managed_friends_channel_name)
        channel.description = context.getString(R.string.managed_friends_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}
