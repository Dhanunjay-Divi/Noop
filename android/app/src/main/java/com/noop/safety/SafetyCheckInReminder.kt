package com.noop.safety

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.notif.NotificationLifecycleCategory
import com.noop.notif.NotificationLifecycleId
import com.noop.notif.NotificationLifecycleLedger
import com.noop.notif.NotificationLifecycleState
import com.noop.notif.NotificationPlatformIdentity
import com.noop.notif.protectPrivateContent
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.util.concurrent.TimeUnit

/** Durable local timestamp for the one manually armed personal check-in. */
object SafetyCheckInReminderPrefs {
    private const val FILE = "noop_safety"
    private const val DUE_AT_UNIX = "safety.checkInDueAtUnix"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun dueAtUnix(context: Context): Long = prefs(context).getLong(DUE_AT_UNIX, 0L)

    internal fun setDueAtUnix(context: Context, dueAtUnix: Long) {
        prefs(context).edit().putLong(DUE_AT_UNIX, dueAtUnix.coerceAtLeast(0L)).apply()
    }
}

/**
 * Best-effort WorkManager reminder. It survives process death/reboot, but Android may defer it under
 * Doze or OEM battery policy. It never messages another person or escalates an overdue check-in.
 */
object SafetyCheckInReminderScheduler {
    private const val WORK_NAME = "noop_safety_personal_check_in"
    private const val INPUT_DUE_AT = "due_at_unix"

    enum class DeliveryAvailability {
        AVAILABLE,
        NOTIFICATIONS_OFF,
        CHANNEL_OFF,
    }

    fun schedule(context: Context, dueAtUnix: Long): Boolean {
        val nowUnix = System.currentTimeMillis() / 1_000L
        SafetyCheckInReminderNotifier.ensureChannel(context)
        if (dueAtUnix <= nowUnix || deliveryAvailability(context) != DeliveryAvailability.AVAILABLE) {
            return false
        }
        val delaySeconds = (dueAtUnix - nowUnix).coerceAtLeast(1L)
        return runCatching {
            val input = Data.Builder().putLong(INPUT_DUE_AT, dueAtUnix).build()
            val request = OneTimeWorkRequestBuilder<SafetyCheckInReminderWorker>()
                .setInputData(input)
                .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
                .build()
            NotificationLifecycleLedger.observe(
                context,
                NotificationLifecycleId.SAFETY_CHECK_IN,
                NotificationLifecycleCategory.REMINDER,
                NotificationLifecycleState.SCHEDULED,
            ) {
                WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                    WORK_NAME,
                    ExistingWorkPolicy.REPLACE,
                    request,
                )
            }
            SafetyCheckInReminderPrefs.setDueAtUnix(context, dueAtUnix)
            true
        }.getOrDefault(false)
    }

    fun cancel(context: Context) {
        SafetyCheckInReminderPrefs.setDueAtUnix(context, 0L)
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.SAFETY_CHECK_IN,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.CANCELLED,
        ) {
            WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
            NotificationManagerCompat.from(context)
                .cancel(SafetyCheckInReminderNotifier.NOTIFICATION_ID)
        }
    }

    fun canPostNotifications(context: Context): Boolean {
        return deliveryAvailability(context) == DeliveryAvailability.AVAILABLE
    }

    fun deliveryAvailability(context: Context): DeliveryAvailability {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return DeliveryAvailability.NOTIFICATIONS_OFF
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            return DeliveryAvailability.NOTIFICATIONS_OFF
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(SafetyCheckInReminderNotifier.CHANNEL_ID)
                    ?.importance == NotificationManager.IMPORTANCE_NONE
            ) {
                return DeliveryAvailability.CHANNEL_OFF
            }
        }
        return DeliveryAvailability.AVAILABLE
    }

    fun notificationSettingsIntent(context: Context): Intent {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(SafetyCheckInReminderNotifier.CHANNEL_ID) != null) {
                return Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, SafetyCheckInReminderNotifier.CHANNEL_ID)
            }
        }
        return Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    }

    internal fun inputDueAt(data: Data): Long = data.getLong(INPUT_DUE_AT, 0L)
}

class SafetyCheckInReminderWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val expectedDueAt = SafetyCheckInReminderScheduler.inputDueAt(inputData)
        if (expectedDueAt <= 0L ||
            SafetyCheckInReminderPrefs.dueAtUnix(applicationContext) != expectedDueAt
        ) return Result.success()

        // A large wall-clock change can make an elapsed-delay worker arrive early. Never claim the
        // timer ended before its persisted due timestamp.
        if (System.currentTimeMillis() / 1_000L < expectedDueAt) return Result.retry()
        SafetyCheckInReminderNotifier.post(applicationContext)
        return Result.success()
    }
}

object SafetyCheckInReminderNotifier {
    internal const val CHANNEL_ID = "noop_safety_check_in"
    const val NOTIFICATION_ID =
        NotificationPlatformIdentity.NotificationId.SAFETY_CHECK_IN

    @SuppressLint("MissingPermission")
    fun post(context: Context): Boolean = runCatching {
        if (!SafetyCheckInReminderScheduler.canPostNotifications(context)) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.SAFETY_CHECK_IN,
                NotificationLifecycleCategory.REMINDER,
            )
            return false
        }
        ensureChannel(context)
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.SAFETY_CHECK_IN,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.SAFETY),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.safety_notification_title))
            .setContentText(context.getString(R.string.safety_notification_body))
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    context.getString(R.string.safety_notification_body),
                ),
            )
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .protectPrivateContent(context, CHANNEL_ID)
            .build()
        NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.SAFETY_CHECK_IN,
            NotificationLifecycleCategory.REMINDER,
        ) {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            NotificationLifecycleId.SAFETY_CHECK_IN,
            NotificationLifecycleCategory.REMINDER,
        )
        false
    }

    internal fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.safety_notification_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.name = context.getString(R.string.safety_notification_channel_name)
        channel.description = context.getString(R.string.safety_notification_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}
