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
import com.noop.ui.NoopPrefs
import com.noop.ui.NotificationRouteBridge

internal data class WorkoutCautionDeliveryState(val lastDeliveryMillis: Long? = null)

internal object WorkoutCautionDeliveryPolicy {
    const val COOLDOWN_MILLIS = 10L * 60L * 1_000L

    fun shouldDeliver(state: WorkoutCautionDeliveryState, nowMillis: Long): Boolean =
        state.lastDeliveryMillis?.let { nowMillis - it >= COOLDOWN_MILLIS } ?: true
}

/**
 * Phone companion for the strongest sustained workout cue. This is exertion guidance, not arrhythmia,
 * emergency, or medical-event detection, so it asks the user to pause and assess symptoms.
 */
object WorkoutCautionNotifier {
    private const val CHANNEL_ID = "noop_workout_caution"
    private const val PREFS_FILE = "noop_workout_caution_delivery"
    private const val KEY_LAST_AT = "last.at"

    @SuppressLint("MissingPermission")
    @Synchronized
    fun onPauseAndAssess(
        context: Context,
        nowMillis: Long = System.currentTimeMillis(),
    ) {
        if (!NoopPrefs.zoneCoaching(context)) return
        runCatching {
            ensureChannel(context)
            if (!canNotify(context)) {
                suppress(context)
                return
            }
            val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            val state = WorkoutCautionDeliveryState(
                prefs.getLong(KEY_LAST_AT, 0L).takeIf { prefs.contains(KEY_LAST_AT) },
            )
            if (!WorkoutCautionDeliveryPolicy.shouldDeliver(state, nowMillis)) return

            val title = context.getString(R.string.appwide_workout_guidance_notification_title)
            val body = context.getString(R.string.appwide_workout_guidance_notification_body)
            val openWorkouts = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.WORKOUT_CAUTION,
                NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.WORKOUTS),
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openWorkouts)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .protectPrivateContent(context, CHANNEL_ID)
                .build()
            val manager = NotificationManagerCompat.from(context)
            if (!NotificationLifecycleLedger.posted(
                    context,
                    NotificationLifecycleId.WORKOUT_CAUTION,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    manager.notify(
                        NotificationPlatformIdentity.NotificationId.WORKOUT_CAUTION,
                        notification,
                    )
                }
            ) return
            prefs.edit().putLong(KEY_LAST_AT, nowMillis).apply()
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.WORKOUT_CAUTION,
                NotificationLifecycleCategory.RECOMMENDATION,
            )
        }
    }

    fun prepareAndCanNotify(context: Context): Boolean {
        ensureChannel(context.applicationContext)
        return canNotify(context.applicationContext)
    }

    private fun canNotify(context: Context): Boolean {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }

    private fun suppress(context: Context) {
        NotificationLifecycleLedger.suppressed(
            context,
            NotificationLifecycleId.WORKOUT_CAUTION,
            NotificationLifecycleCategory.RECOMMENDATION,
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.appwide_workout_guidance_channel_name),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = context.getString(
                    R.string.appwide_workout_guidance_channel_description,
                )
                lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
            },
        )
    }
}
