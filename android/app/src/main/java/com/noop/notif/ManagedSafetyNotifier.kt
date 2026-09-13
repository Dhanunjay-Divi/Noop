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
import com.noop.managed.ManagedSafetyMessagingService
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.util.UUID

/**
 * Generic private presentation for managed Safety.
 *
 * The sender, incident details, location, and response state are fetched only after authenticated
 * app entry. The opaque incident reference stays in the launch intent and never enters diagnostics.
 */
internal object ManagedSafetyNotifier {
    const val CHANNEL_ID = "noop_managed_safety"

    fun prepare(context: Context) {
        ensureChannel(context.applicationContext)
    }

    @SuppressLint("MissingPermission")
    fun post(context: Context, incidentId: UUID): String = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.MANAGED_SAFETY,
                NotificationLifecycleCategory.STATUS,
            )
            return "not_authorized"
        }
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.MANAGED_SAFETY,
                NotificationLifecycleCategory.STATUS,
            )
            return "not_authorized"
        }
        prepare(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val system = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (system.getNotificationChannel(CHANNEL_ID)?.importance ==
                NotificationManager.IMPORTANCE_NONE
            ) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.MANAGED_SAFETY,
                    NotificationLifecycleCategory.STATUS,
                )
                return "not_authorized"
            }
        }
        val launchIntent = NotificationRouteBridge
            .launchIntent(context, NoopNotificationRoute.SAFETY)
            .putExtra(
                ManagedSafetyMessagingService.EXTRA_INCIDENT_ID,
                incidentId.toString().lowercase(),
            )
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.MANAGED_SAFETY,
            launchIntent,
            instanceKey = incidentId.toString().lowercase(),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.managed_safety_notification_title))
            .setContentText(context.getString(R.string.managed_safety_notification_body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .protectPrivateContent(context, CHANNEL_ID)
            .build()
        if (
            NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.MANAGED_SAFETY,
                NotificationLifecycleCategory.STATUS,
            ) {
                manager.notify(
                    "noop-safety-${incidentId.toString().lowercase()}",
                    NotificationPlatformIdentity.NotificationId.MANAGED_SAFETY,
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
            NotificationLifecycleId.MANAGED_SAFETY,
            NotificationLifecycleCategory.STATUS,
        )
        "failed"
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.managed_safety_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.name = context.getString(R.string.managed_safety_channel_name)
        channel.description = context.getString(R.string.managed_safety_channel_description)
        channel.setShowBadge(true)
        manager.createNotificationChannel(channel)
    }
}
