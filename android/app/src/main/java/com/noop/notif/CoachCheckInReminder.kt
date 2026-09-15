package com.noop.notif

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit

/** Opt-in local Coach reminder. It contains no metric and never invokes a model or network call. */
object CoachCheckInReminder {
    private const val PREFS = "noop_coach_check_in"
    private const val ENABLED = "enabled"
    private const val MINUTES = "minutes"
    private const val WORK_NAME = "noop_coach_local_check_in"
    private const val DEFAULT_MINUTES = 18 * 60

    fun isEnabled(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(ENABLED, false)

    fun minutes(context: Context): Int =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(MINUTES, DEFAULT_MINUTES).coerceIn(0, 23 * 60 + 59)

    fun setEnabled(context: Context, enabled: Boolean, minutes: Int = minutes(context)): Boolean {
        val appContext = context.applicationContext
        if (!enabled) {
            appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(ENABLED, false).apply()
            WorkManager.getInstance(appContext).cancelUniqueWork(WORK_NAME)
            NotificationLifecycleLedger.cancelled(
                appContext,
                NotificationLifecycleId.COACH_CHECK_IN,
                NotificationLifecycleCategory.REMINDER,
            ) {
                NotificationManagerCompat.from(appContext).cancel(NOTIFICATION_ID)
            }
            return true
        }
        CoachCheckInNotifier.ensureChannel(appContext)
        if (!canNotify(appContext)) return false

        val resolved = minutes.coerceIn(0, 23 * 60 + 59)
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(ENABLED, true)
            .putInt(MINUTES, resolved)
            .apply()
        scheduleNext(appContext)
        return true
    }

    fun reconcile(context: Context) {
        if (isEnabled(context)) scheduleNext(context.applicationContext)
    }

    internal fun scheduleNext(context: Context) {
        if (!isEnabled(context)) return
        val now = ZonedDateTime.now()
        val next = nextRun(now, minutes(context))
        val delayMillis = ChronoUnit.MILLIS.between(now, next).coerceAtLeast(1_000)
        val request = OneTimeWorkRequestBuilder<CoachCheckInWorker>()
            .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .build()
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.COACH_CHECK_IN,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.SCHEDULED,
        ) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }

    internal fun nextRun(now: ZonedDateTime, minutes: Int): ZonedDateTime {
        val value = minutes.coerceIn(0, 23 * 60 + 59)
        var next = now.toLocalDate().atTime(value / 60, value % 60).atZone(now.zone)
        if (!next.isAfter(now.plusSeconds(1))) {
            next = now.toLocalDate().plusDays(1).atTime(value / 60, value % 60).atZone(now.zone)
        }
        return next
    }

    fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CoachCheckInNotifier.CHANNEL_ID)
                    ?.importance == NotificationManager.IMPORTANCE_NONE
            ) return false
        }
        return true
    }

    internal const val NOTIFICATION_ID =
        NotificationPlatformIdentity.NotificationId.COACH_CHECK_IN
}

class CoachCheckInWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (!CoachCheckInReminder.isEnabled(applicationContext)) return Result.success()
        CoachCheckInNotifier.post(applicationContext)
        CoachCheckInReminder.scheduleNext(applicationContext)
        return Result.success()
    }
}

/** Recomputes the next local wall-clock reminder after reboot, manual clock changes, or travel. */
class CoachCheckInTimeChangeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        CoachCheckInReminder.reconcile(context)
    }
}

internal object CoachCheckInNotifier {
    const val CHANNEL_ID = "noop_coach_check_in"

    @SuppressLint("MissingPermission")
    fun post(context: Context): Boolean = runCatching {
        ensureChannel(context)
        if (!CoachCheckInReminder.canNotify(context)) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.COACH_CHECK_IN,
                NotificationLifecycleCategory.REMINDER,
            )
            return false
        }
        val openCoach = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.COACH_CHECK_IN,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.COACH),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.coach_check_in_notification_title))
            .setContentText(context.getString(R.string.coach_check_in_notification_body))
            .setStyle(
                NotificationCompat.BigTextStyle().bigText(
                    context.getString(R.string.coach_check_in_notification_body),
                ),
            )
            .setContentIntent(openCoach)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .protectPrivateContent(context, CHANNEL_ID)
            .build()
        NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.COACH_CHECK_IN,
            NotificationLifecycleCategory.REMINDER,
        ) {
            NotificationManagerCompat.from(context).notify(
                CoachCheckInReminder.NOTIFICATION_ID,
                notification,
            )
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            NotificationLifecycleId.COACH_CHECK_IN,
            NotificationLifecycleCategory.REMINDER,
        )
        false
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.coach_check_in_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.name = context.getString(R.string.coach_check_in_channel_name)
        channel.description = context.getString(R.string.coach_check_in_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}
