package com.noop.safety

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
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.notif.NotificationLifecycleCategory
import com.noop.notif.NotificationLifecycleId
import com.noop.notif.NotificationLifecycleLedger
import com.noop.notif.NotificationLifecycleState
import com.noop.notif.NotificationPlatformIdentity
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.util.concurrent.TimeUnit

object SafetyContactSetupReminderScheduler {
    private const val WORK_NAME = "noop_safety_contacts_setup"

    fun reconcile(context: Context) {
        val app = context.applicationContext
        val required = needsReminder(
            reminderRequired = SafetyPagingPrefs.reminderRequired(app),
            acceptedCount = SafetyPagingPrefs.acceptedCount(app),
        )
        if (!required) {
            WorkManager.getInstance(app).cancelUniqueWork(WORK_NAME)
            SafetyContactSetupReminderNotifier.cancel(app)
            return
        }
        val request = PeriodicWorkRequestBuilder<SafetyContactSetupReminderWorker>(
            3,
            TimeUnit.DAYS,
        ).build()
        NotificationLifecycleLedger.observe(
            app,
            NotificationLifecycleId.SAFETY_CONTACT_SETUP,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.SCHEDULED,
        ) {
            WorkManager.getInstance(app).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }
    }

    internal fun needsReminder(reminderRequired: Boolean, acceptedCount: Int): Boolean =
        reminderRequired && acceptedCount < SafetyPagingController.MINIMUM_ACCEPTED
}

class SafetyContactSetupReminderWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (
            !SafetyPagingPrefs.reminderRequired(applicationContext) ||
            SafetyPagingPrefs.acceptedCount(applicationContext) >=
            SafetyPagingController.MINIMUM_ACCEPTED
        ) {
            SafetyContactSetupReminderNotifier.cancel(applicationContext)
            return Result.success()
        }
        SafetyContactSetupReminderNotifier.post(applicationContext)
        return Result.success()
    }
}

private object SafetyContactSetupReminderNotifier {
    private const val CHANNEL_ID = "noop_safety_setup"
    private const val NOTIFICATION_ID =
        NotificationPlatformIdentity.NotificationId.SAFETY_CONTACT_SETUP

    @SuppressLint("MissingPermission")
    fun post(context: Context): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.SAFETY_CONTACT_SETUP,
                NotificationLifecycleCategory.REMINDER,
            )
            return false
        }
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.SAFETY_CONTACT_SETUP,
                NotificationLifecycleCategory.REMINDER,
            )
            return false
        }
        ensureChannel(context)
        val openSafety = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.SAFETY_CONTACT_SETUP,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.SAFETY),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.safety_contacts_reminder_title))
            .setContentText(context.getString(R.string.safety_contacts_reminder_body))
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    context.getString(R.string.safety_contacts_reminder_body),
                ),
            )
            .setContentIntent(openSafety)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.SAFETY_CONTACT_SETUP,
            NotificationLifecycleCategory.REMINDER,
        ) {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            NotificationLifecycleId.SAFETY_CONTACT_SETUP,
            NotificationLifecycleCategory.REMINDER,
        )
        false
    }

    fun cancel(context: Context) {
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.SAFETY_CONTACT_SETUP,
            NotificationLifecycleCategory.REMINDER,
        ) {
            NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.safety_contacts_reminder_channel),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.description =
            context.getString(R.string.safety_contacts_reminder_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}
