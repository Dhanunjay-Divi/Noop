package com.noop.notif

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.provider.Settings
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
    /**
     * The standard channel is also the managed-registration gate used by the existing cloud service.
     * Its versioned ID prevents old channel configuration from being silently rewritten.
     */
    const val CHANNEL_ID = "noop_managed_safety_standard_v2"
    internal const val URGENT_CHANNEL_ID = "noop_managed_safety_urgent_v2"
    internal const val LEGACY_CHANNEL_ID = "noop_managed_safety"
    private val standardVibration = longArrayOf(0L, 350L, 180L, 350L)
    private val urgentVibration = longArrayOf(0L, 700L, 250L, 700L, 250L, 1_000L)

    internal enum class ChannelReadiness(val diagnosticValue: String) {
        READY("ready"),
        STANDARD_FALLBACK("standard_fallback"),
        BLOCKED("blocked"),
    }

    fun prepare(context: Context) {
        ensureChannels(context.applicationContext)
    }

    fun urgentSoundEnabled(context: Context): Boolean =
        NotificationPresentationPreferences.managedSafetyUrgentSound(context)

    fun setUrgentSoundEnabled(context: Context, enabled: Boolean) {
        NotificationPresentationPreferences.setManagedSafetyUrgentSound(context, enabled)
        ensureChannels(context.applicationContext)
    }

    fun notificationSettingsIntent(context: Context): Intent {
        val channelId = activeChannelId(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(channelId) != null) {
                return Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
            }
        }
        return Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
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
        val readiness = channelReadiness(context)
        val channelId = when (readiness) {
            ChannelReadiness.READY -> activeChannelId(context)
            ChannelReadiness.STANDARD_FALLBACK -> CHANNEL_ID
            ChannelReadiness.BLOCKED -> null
        }
        if (channelId == null) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.MANAGED_SAFETY,
                NotificationLifecycleCategory.STATUS,
            )
            return "channel_blocked"
        }
        if (readiness == ChannelReadiness.STANDARD_FALLBACK) {
            com.noop.AppDiagnosticsRecorder.record(
                "managed_safety.channel_readiness",
                fields = mapOf("state" to readiness.diagnosticValue),
            )
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
        val urgent = urgentSoundEnabled(context)
        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.managed_safety_notification_title))
            .setContentText(context.getString(R.string.managed_safety_notification_body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setLights(ContextCompat.getColor(context, R.color.accent), 1_000, 500)
            .protectPrivateContent(context, channelId)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder
                .setSound(
                    if (urgent) {
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                    } else {
                        null
                    },
                )
                .setVibrate(if (urgent) urgentVibration else standardVibration)
        }
        val notification = builder.build()
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

    private fun activeChannelId(context: Context): String =
        if (urgentSoundEnabled(context)) URGENT_CHANNEL_ID else CHANNEL_ID

    internal fun channelReadiness(context: Context): ChannelReadiness {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return ChannelReadiness.READY
        }
        val preferred = activeChannelId(context)
        if (channelCanPresent(context, preferred)) {
            return ChannelReadiness.READY
        }
        return if (
            preferred == URGENT_CHANNEL_ID &&
            channelCanPresent(context, CHANNEL_ID)
        ) {
            ChannelReadiness.STANDARD_FALLBACK
        } else {
            ChannelReadiness.BLOCKED
        }
    }

    internal fun registrationChannelImportance(context: Context): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = when (channelReadiness(context)) {
            ChannelReadiness.READY -> activeChannelId(context)
            ChannelReadiness.STANDARD_FALLBACK -> CHANNEL_ID
            ChannelReadiness.BLOCKED -> return NotificationManager.IMPORTANCE_NONE
        }
        return manager.getNotificationChannel(channelId)?.importance
    }

    private fun channelCanPresent(context: Context, channelId: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return manager.getNotificationChannel(channelId)
            ?.importance
            ?.let { it != NotificationManager.IMPORTANCE_NONE }
            ?: false
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val versionedChannelExists =
            manager.getNotificationChannel(CHANNEL_ID) != null ||
                manager.getNotificationChannel(URGENT_CHANNEL_ID) != null
        val legacyWasDisabled =
            manager.getNotificationChannel(LEGACY_CHANNEL_ID)?.importance ==
                NotificationManager.IMPORTANCE_NONE
        // Never route around a channel the user explicitly disabled in an earlier release.
        if (!versionedChannelExists && legacyWasDisabled) return

        ensureChannel(
            context = context,
            manager = manager,
            id = CHANNEL_ID,
            name = context.getString(R.string.managed_safety_channel_name),
            description = context.getString(R.string.managed_safety_channel_description),
            soundEnabled = false,
            vibration = standardVibration,
        )
        if (urgentSoundEnabled(context)) {
            ensureChannel(
                context = context,
                manager = manager,
                id = URGENT_CHANNEL_ID,
                name = context.getString(R.string.managed_safety_urgent_channel_name),
                description = context.getString(R.string.managed_safety_urgent_channel_description),
                soundEnabled = true,
                vibration = urgentVibration,
            )
        }
    }

    private fun ensureChannel(
        context: Context,
        manager: NotificationManager,
        id: String,
        name: String,
        description: String,
        soundEnabled: Boolean,
        vibration: LongArray,
    ) {
        val existing = manager.getNotificationChannel(id)
        if (existing != null) {
            existing.name = name
            existing.description = description
            manager.createNotificationChannel(existing)
            return
        }
        val channel = NotificationChannel(
            id,
            name,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            this.description = description
            setShowBadge(true)
            enableLights(true)
            lightColor = ContextCompat.getColor(context, R.color.accent)
            enableVibration(true)
            vibrationPattern = vibration
            setBypassDnd(false)
            if (soundEnabled) {
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
            } else {
                setSound(null, null)
            }
        }
        manager.createNotificationChannel(channel)
    }
}
