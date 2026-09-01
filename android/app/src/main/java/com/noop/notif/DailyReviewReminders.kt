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
import androidx.work.workDataOf
import com.noop.R
import com.noop.data.WhoopRepository
import com.noop.ui.JOURNAL_DEVICE_ID
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.time.Duration
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit

internal enum class DailyReviewKind {
    MORNING,
    EVENING,
}

/** Pure wall-clock policy shared by the scheduler and JVM tests. */
internal object DailyReviewReminderPolicy {
    const val DEFAULT_MORNING_MINUTES = 8 * 60
    const val DEFAULT_EVENING_MINUTES = 19 * 60
    const val DELIVERY_GRACE_MINUTES = 3 * 60L

    fun clampMinuteOfDay(value: Int): Int = value.coerceIn(0, 24 * 60 - 1)

    fun nextRun(now: ZonedDateTime, minuteOfDay: Int): ZonedDateTime {
        val minute = clampMinuteOfDay(minuteOfDay)
        var next = now.toLocalDate()
            .atTime(minute / 60, minute % 60)
            .atZone(now.zone)
        if (!next.isAfter(now)) {
            next = now.toLocalDate()
                .plusDays(1)
                .atTime(minute / 60, minute % 60)
                .atZone(now.zone)
        }
        return next
    }

    fun shouldDeliver(
        scheduledAt: ZonedDateTime,
        now: ZonedDateTime,
    ): Boolean {
        if (scheduledAt.toLocalDate() != now.toLocalDate()) return false
        if (now.isBefore(scheduledAt)) return false
        val lateness = Duration.between(scheduledAt.toInstant(), now.toInstant()).toMinutes()
        return lateness in 0..DELIVERY_GRACE_MINUTES
    }

    fun shouldPost(
        kind: DailyReviewKind,
        scheduleIsFresh: Boolean,
        journalCompleted: Boolean,
    ): Boolean = scheduleIsFresh && (kind != DailyReviewKind.EVENING || !journalCompleted)
}

/**
 * Explicit opt-in daily guidance. Two independent persisted one-shot chains survive process death and
 * avoid a delayed morning worker displacing the evening prompt. The evening worker reads the native
 * journal at fire time, so a completed day is suppressed even when NOOP has not been opened since.
 */
object DailyReviewReminders {
    private const val PREFS = "noop_daily_review"
    private const val ENABLED = "enabled"
    private const val MORNING_MINUTES = "morning_minutes"
    private const val EVENING_MINUTES = "evening_minutes"
    private const val MORNING_WORK = "noop_daily_review_morning"
    private const val EVENING_WORK = "noop_daily_review_evening"

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(ENABLED, false)

    fun morningMinutes(context: Context): Int =
        DailyReviewReminderPolicy.clampMinuteOfDay(
            prefs(context).getInt(
                MORNING_MINUTES,
                DailyReviewReminderPolicy.DEFAULT_MORNING_MINUTES,
            ),
        )

    fun eveningMinutes(context: Context): Int =
        DailyReviewReminderPolicy.clampMinuteOfDay(
            prefs(context).getInt(
                EVENING_MINUTES,
                DailyReviewReminderPolicy.DEFAULT_EVENING_MINUTES,
            ),
        )

    fun canNotify(context: Context): Boolean =
        DailyReviewReminderNotifier.canNotify(context.applicationContext)

    /**
     * Returns false when system permission or the feature channel is unavailable. A failed enable never
     * leaves an apparently-on preference behind.
     */
    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        val appContext = context.applicationContext
        if (!enabled) {
            prefs(appContext).edit().putBoolean(ENABLED, false).apply()
            cancel(appContext)
            return true
        }
        DailyReviewReminderNotifier.ensureChannel(appContext)
        if (!DailyReviewReminderNotifier.canNotify(appContext)) {
            prefs(appContext).edit().putBoolean(ENABLED, false).apply()
            cancel(appContext)
            return false
        }
        prefs(appContext).edit().putBoolean(ENABLED, true).apply()
        reconcile(appContext)
        return true
    }

    fun setMorningMinutes(context: Context, minutes: Int) {
        prefs(context).edit()
            .putInt(MORNING_MINUTES, DailyReviewReminderPolicy.clampMinuteOfDay(minutes))
            .apply()
        if (isEnabled(context)) scheduleNext(
            context.applicationContext,
            DailyReviewKind.MORNING,
            ZonedDateTime.now(),
            ExistingWorkPolicy.REPLACE,
        )
    }

    fun setEveningMinutes(context: Context, minutes: Int) {
        prefs(context).edit()
            .putInt(EVENING_MINUTES, DailyReviewReminderPolicy.clampMinuteOfDay(minutes))
            .apply()
        if (isEnabled(context)) scheduleNext(
            context.applicationContext,
            DailyReviewKind.EVENING,
            ZonedDateTime.now(),
            ExistingWorkPolicy.REPLACE,
        )
    }

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        if (!isEnabled(appContext)) return
        val now = ZonedDateTime.now()
        scheduleNext(appContext, DailyReviewKind.MORNING, now, ExistingWorkPolicy.REPLACE)
        scheduleNext(appContext, DailyReviewKind.EVENING, now, ExistingWorkPolicy.REPLACE)
    }

    internal fun scheduleNext(
        context: Context,
        kind: DailyReviewKind,
        now: ZonedDateTime,
        policy: ExistingWorkPolicy,
    ) {
        if (!isEnabled(context)) return
        val minute = when (kind) {
            DailyReviewKind.MORNING -> morningMinutes(context)
            DailyReviewKind.EVENING -> eveningMinutes(context)
        }
        val next = DailyReviewReminderPolicy.nextRun(now, minute)
        val delayMillis = ChronoUnit.MILLIS.between(now, next).coerceAtLeast(1_000L)
        val request = OneTimeWorkRequestBuilder<DailyReviewReminderWorker>()
            .setInputData(
                workDataOf(
                    DailyReviewReminderWorker.KIND_KEY to kind.name,
                    DailyReviewReminderWorker.SCHEDULED_AT_KEY to next.toInstant().toEpochMilli(),
                    DailyReviewReminderWorker.DAY_KEY to next.toLocalDate().toString(),
                ),
            )
            .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .build()
        NotificationLifecycleLedger.observe(
            context,
            lifecycleId(kind),
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.SCHEDULED,
        ) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                workName(kind),
                policy,
                request,
            )
        }
    }

    internal fun suppress(context: Context, kind: DailyReviewKind) {
        NotificationLifecycleLedger.suppressed(
            context,
            lifecycleId(kind),
            NotificationLifecycleCategory.REMINDER,
        )
    }

    private fun cancel(context: Context) {
        val workManager = WorkManager.getInstance(context)
        for (kind in DailyReviewKind.entries) {
            NotificationLifecycleLedger.cancelled(
                context,
                lifecycleId(kind),
                NotificationLifecycleCategory.REMINDER,
            ) {
                workManager.cancelUniqueWork(workName(kind))
                NotificationManagerCompat.from(context).cancel(notificationId(kind))
            }
        }
    }

    private fun prefs(context: Context) = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    internal fun workName(kind: DailyReviewKind): String = when (kind) {
        DailyReviewKind.MORNING -> MORNING_WORK
        DailyReviewKind.EVENING -> EVENING_WORK
    }

    internal fun lifecycleId(kind: DailyReviewKind): String = when (kind) {
        DailyReviewKind.MORNING -> NotificationLifecycleId.DAILY_REVIEW_MORNING
        DailyReviewKind.EVENING -> NotificationLifecycleId.DAILY_REVIEW_EVENING
    }

    internal fun notificationId(kind: DailyReviewKind): Int = when (kind) {
        DailyReviewKind.MORNING -> NotificationPlatformIdentity.NotificationId.DAILY_REVIEW_MORNING
        DailyReviewKind.EVENING -> NotificationPlatformIdentity.NotificationId.DAILY_REVIEW_EVENING
    }
}

class DailyReviewReminderWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        if (!DailyReviewReminders.isEnabled(applicationContext)) return Result.success()
        val kind = inputData.getString(KIND_KEY)
            ?.let { runCatching { DailyReviewKind.valueOf(it) }.getOrNull() }
            ?: return Result.failure()
        val scheduledAtMillis = inputData.getLong(SCHEDULED_AT_KEY, Long.MIN_VALUE)
        val scheduledDay = inputData.getString(DAY_KEY) ?: return Result.failure()
        if (scheduledAtMillis == Long.MIN_VALUE) return Result.failure()

        val now = ZonedDateTime.now()
        val scheduledAt = java.time.Instant.ofEpochMilli(scheduledAtMillis).atZone(now.zone)
        val fresh = scheduledDay == scheduledAt.toLocalDate().toString() &&
            DailyReviewReminderPolicy.shouldDeliver(scheduledAt, now)
        val journalCompleted = if (kind == DailyReviewKind.EVENING && fresh) {
            try {
                WhoopRepository.from(applicationContext)
                    .journal(JOURNAL_DEVICE_ID, scheduledDay, scheduledDay)
                    .isNotEmpty()
            } catch (_: Throwable) {
                return Result.retry()
            }
        } else {
            false
        }

        if (DailyReviewReminderPolicy.shouldPost(kind, fresh, journalCompleted)) {
            if (!DailyReviewReminders.isEnabled(applicationContext)) return Result.success()
            DailyReviewReminderNotifier.post(applicationContext, kind)
        } else {
            DailyReviewReminders.suppress(applicationContext, kind)
        }

        DailyReviewReminders.scheduleNext(
            applicationContext,
            kind,
            now,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
        )
        return Result.success()
    }

    companion object {
        internal const val KIND_KEY = "kind"
        internal const val SCHEDULED_AT_KEY = "scheduled_at"
        internal const val DAY_KEY = "day"
    }
}

/** Recomputes local wall-clock work after reboot, DST, travel, or manual clock changes. */
class DailyReviewTimeChangeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        DailyReviewReminders.reconcile(context)
    }
}

internal object DailyReviewReminderNotifier {
    private const val CHANNEL_ID = "noop_daily_review"

    fun canNotify(context: Context): Boolean {
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

    @SuppressLint("MissingPermission")
    fun post(context: Context, kind: DailyReviewKind): Boolean = runCatching {
        ensureChannel(context)
        if (!canNotify(context)) {
            DailyReviewReminders.suppress(context, kind)
            return false
        }
        val route = when (kind) {
            DailyReviewKind.MORNING -> NoopNotificationRoute.SLEEP
            DailyReviewKind.EVENING -> NoopNotificationRoute.JOURNAL
        }
        val identity = when (kind) {
            DailyReviewKind.MORNING ->
                NotificationPlatformIdentity.ActivityIntent.DAILY_REVIEW_MORNING
            DailyReviewKind.EVENING ->
                NotificationPlatformIdentity.ActivityIntent.DAILY_REVIEW_EVENING
        }
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            identity,
            NotificationRouteBridge.launchIntent(context, route),
        )
        val title = context.getString(
            if (kind == DailyReviewKind.MORNING) {
                R.string.daily_review_morning_title
            } else {
                R.string.daily_review_evening_title
            },
        )
        val body = context.getString(
            if (kind == DailyReviewKind.MORNING) {
                R.string.daily_review_morning_body
            } else {
                R.string.daily_review_evening_body
            },
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        NotificationLifecycleLedger.posted(
            context,
            DailyReviewReminders.lifecycleId(kind),
            NotificationLifecycleCategory.REMINDER,
        ) {
            NotificationManagerCompat.from(context).notify(
                DailyReviewReminders.notificationId(kind),
                notification,
            )
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            DailyReviewReminders.lifecycleId(kind),
            NotificationLifecycleCategory.REMINDER,
        )
        false
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.daily_review_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.name = context.getString(R.string.daily_review_channel_name)
        channel.description = context.getString(R.string.daily_review_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}
