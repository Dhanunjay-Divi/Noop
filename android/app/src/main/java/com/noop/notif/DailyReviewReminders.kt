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
import com.noop.AppDiagnosticsRecorder
import com.noop.R
import com.noop.data.WhoopRepository
import com.noop.ui.ContextualActionCenter
import com.noop.ui.JOURNAL_DEVICE_ID
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotifPrefs
import com.noop.ui.NotificationRouteBridge
import java.time.Duration
import java.time.LocalDate
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
    const val DEFAULT_QUIET_START_MINUTES = 22 * 60
    const val DEFAULT_QUIET_END_MINUTES = 7 * 60

    fun clampMinuteOfDay(value: Int): Int = value.coerceIn(0, 24 * 60 - 1)

    fun nextRun(
        now: ZonedDateTime,
        minuteOfDay: Int,
        quietHoursEnabled: Boolean = false,
        quietStartMinutes: Int = DEFAULT_QUIET_START_MINUTES,
        quietEndMinutes: Int = DEFAULT_QUIET_END_MINUTES,
    ): ZonedDateTime {
        val nominal = nextNominalRun(now, minuteOfDay)
        return nextEligible(
            nominal,
            quietHoursEnabled,
            quietStartMinutes,
            quietEndMinutes,
        )
    }

    fun nextNominalRun(
        now: ZonedDateTime,
        minuteOfDay: Int,
    ): ZonedDateTime {
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

    fun isInQuietHours(
        dateTime: ZonedDateTime,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): Boolean {
        if (!quietHoursEnabled) return false
        val minute = dateTime.hour * 60 + dateTime.minute
        val start = clampMinuteOfDay(quietStartMinutes)
        val end = clampMinuteOfDay(quietEndMinutes)
        return if (start <= end) minute in start until end else minute >= start || minute < end
    }

    fun nextEligible(
        dateTime: ZonedDateTime,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): ZonedDateTime {
        if (
            !isInQuietHours(
                dateTime,
                quietHoursEnabled,
                quietStartMinutes,
                quietEndMinutes,
            )
        ) {
            return dateTime
        }
        val start = clampMinuteOfDay(quietStartMinutes)
        val end = clampMinuteOfDay(quietEndMinutes)
        val minute = dateTime.hour * 60 + dateTime.minute
        val endDay = if (start > end && minute >= start) {
            dateTime.toLocalDate().plusDays(1)
        } else {
            dateTime.toLocalDate()
        }
        return endDay.atTime(end / 60, end % 60).atZone(dateTime.zone)
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

    fun logicalDayMatchesDelivery(
        logicalDay: LocalDate,
        deliveryAt: ZonedDateTime,
    ): Boolean {
        val deliveryDay = deliveryAt.toLocalDate()
        return logicalDay == deliveryDay || logicalDay == deliveryDay.minusDays(1)
    }

    fun requiresCarryoverMarker(
        logicalDay: LocalDate,
        deliveryAt: ZonedDateTime,
    ): Boolean = deliveryAt.toLocalDate() == logicalDay.plusDays(1)

    fun carryoverRun(
        logicalDay: LocalDate,
        now: ZonedDateTime,
        minuteOfDay: Int,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): ZonedDateTime? {
        if (
            logicalDay != now.toLocalDate() &&
            logicalDay != now.toLocalDate().minusDays(1)
        ) {
            return null
        }
        val minute = clampMinuteOfDay(minuteOfDay)
        val nominal = logicalDay
            .atTime(minute / 60, minute % 60)
            .atZone(now.zone)
        val eligible = nextEligible(
            nominal,
            quietHoursEnabled,
            quietStartMinutes,
            quietEndMinutes,
        )
        val delivery = if (eligible.isAfter(now)) eligible else now.plusSeconds(1)
        return delivery.takeIf { logicalDayMatchesDelivery(logicalDay, it) }
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
    private const val LEGACY_ENABLED = "enabled"
    private const val MORNING_ENABLED = "morning_enabled"
    private const val JOURNAL_ENABLED = "journal_enabled"
    private const val SPLIT_MIGRATED = "split_migrated_v1"
    private const val MORNING_MINUTES = "morning_minutes"
    private const val EVENING_MINUTES = "evening_minutes"
    private const val MORNING_WORK = "noop_daily_review_morning"
    private const val EVENING_WORK = "noop_daily_review_evening"
    private const val CARRYOVER_DAY_PREFIX = "carryover_day."

    private val preferenceLock = Any()

    fun isEnabled(context: Context): Boolean =
        isMorningEnabled(context) || isJournalEnabled(context)

    fun isMorningEnabled(context: Context): Boolean {
        migrateLegacyPreferenceIfNeeded(context)
        return prefs(context).getBoolean(MORNING_ENABLED, false)
    }

    fun isJournalEnabled(context: Context): Boolean {
        migrateLegacyPreferenceIfNeeded(context)
        return prefs(context).getBoolean(JOURNAL_ENABLED, false)
    }

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
        return setPreferences(
            context = context,
            morningEnabled = enabled,
            journalEnabled = enabled,
        )
    }

    fun setMorningEnabled(context: Context, enabled: Boolean): Boolean =
        setPreferences(
            context = context,
            morningEnabled = enabled,
            journalEnabled = null,
        )

    fun setJournalEnabled(context: Context, enabled: Boolean): Boolean =
        setPreferences(
            context = context,
            morningEnabled = null,
            journalEnabled = enabled,
        )

    private fun setPreferences(
        context: Context,
        morningEnabled: Boolean?,
        journalEnabled: Boolean?,
    ): Boolean {
        val appContext = context.applicationContext
        migrateLegacyPreferenceIfNeeded(appContext)
        val requestedMorning = morningEnabled ?: isMorningEnabled(appContext)
        val requestedJournal = journalEnabled ?: isJournalEnabled(appContext)
        val enablingNewPreference =
            (morningEnabled == true && !isMorningEnabled(appContext)) ||
                (journalEnabled == true && !isJournalEnabled(appContext))
        if (enablingNewPreference) {
            DailyReviewReminderNotifier.ensureChannel(appContext)
        }
        if (enablingNewPreference && !DailyReviewReminderNotifier.canNotify(appContext)) {
            return false
        }
        val committed = prefs(appContext).edit()
            .putBoolean(MORNING_ENABLED, requestedMorning)
            .putBoolean(JOURNAL_ENABLED, requestedJournal)
            .putBoolean(LEGACY_ENABLED, requestedMorning || requestedJournal)
            .putBoolean(SPLIT_MIGRATED, true)
            .commit()
        if (!committed) return false
        reconcile(appContext)
        return true
    }

    fun setMorningMinutes(context: Context, minutes: Int) {
        prefs(context).edit()
            .putInt(MORNING_MINUTES, DailyReviewReminderPolicy.clampMinuteOfDay(minutes))
            .apply()
        if (isMorningEnabled(context)) {
            rescheduleKind(
                context = context.applicationContext,
                kind = DailyReviewKind.MORNING,
                now = ZonedDateTime.now(),
                policy = ExistingWorkPolicy.REPLACE,
                preserveQuietHoursCarryover = true,
            )
        }
    }

    fun setEveningMinutes(context: Context, minutes: Int) {
        prefs(context).edit()
            .putInt(EVENING_MINUTES, DailyReviewReminderPolicy.clampMinuteOfDay(minutes))
            .apply()
        if (isJournalEnabled(context)) {
            rescheduleKind(
                context = context.applicationContext,
                kind = DailyReviewKind.EVENING,
                now = ZonedDateTime.now(),
                policy = ExistingWorkPolicy.REPLACE,
                preserveQuietHoursCarryover = true,
            )
        }
    }

    fun reconcile(context: Context) {
        reconcile(context, ExistingWorkPolicy.REPLACE)
    }

    /**
     * Process-start repair keeps an already-enqueued quiet-hours carryover. Explicit preference/time
     * changes and system clock broadcasts still use [reconcile] to replace obsolete wall-clock work.
     */
    fun restore(context: Context) {
        reconcile(context, ExistingWorkPolicy.KEEP)
    }

    private fun reconcile(context: Context, policy: ExistingWorkPolicy) {
        val appContext = context.applicationContext
        val now = ZonedDateTime.now()
        for (kind in DailyReviewKind.entries) {
            if (isKindEnabled(appContext, kind)) {
                rescheduleKind(
                    context = appContext,
                    kind = kind,
                    now = now,
                    policy = policy,
                    preserveQuietHoursCarryover = true,
                )
            } else {
                cancel(appContext, kind)
            }
        }
    }

    private fun rescheduleKind(
        context: Context,
        kind: DailyReviewKind,
        now: ZonedDateTime,
        policy: ExistingWorkPolicy,
        preserveQuietHoursCarryover: Boolean,
    ) {
        if (!isKindEnabled(context, kind)) return
        val carryoverDay = if (preserveQuietHoursCarryover) {
            carryoverLogicalDay(context, kind)
        } else {
            null
        }
        if (carryoverDay != null) {
            val next = DailyReviewReminderPolicy.carryoverRun(
                logicalDay = carryoverDay,
                now = now,
                minuteOfDay = reminderMinutes(context, kind),
                quietHoursEnabled = NotifPrefs.getBool(context, NotifPrefs.QUIET, false),
                quietStartMinutes = NotifPrefs.getInt(
                    context,
                    NotifPrefs.QUIET_START,
                    DailyReviewReminderPolicy.DEFAULT_QUIET_START_MINUTES,
                ),
                quietEndMinutes = NotifPrefs.getInt(
                    context,
                    NotifPrefs.QUIET_END,
                    DailyReviewReminderPolicy.DEFAULT_QUIET_END_MINUTES,
                ),
            )
            if (next != null) {
                scheduleAt(
                    context = context,
                    kind = kind,
                    next = next,
                    policy = policy,
                    logicalDay = carryoverDay,
                    quietHoursCarryover = true,
                )
                return
            }
            clearCarryover(context, kind)
        }
        scheduleNext(context, kind, now, policy)
    }

    internal fun scheduleNext(
        context: Context,
        kind: DailyReviewKind,
        now: ZonedDateTime,
        policy: ExistingWorkPolicy,
    ) {
        if (!isKindEnabled(context, kind)) return
        clearCarryover(context, kind)
        val minute = reminderMinutes(context, kind)
        val nominal = DailyReviewReminderPolicy.nextNominalRun(
            now = now,
            minuteOfDay = minute,
        )
        val next = DailyReviewReminderPolicy.nextEligible(
            dateTime = nominal,
            quietHoursEnabled = NotifPrefs.getBool(context, NotifPrefs.QUIET, false),
            quietStartMinutes = NotifPrefs.getInt(
                context,
                NotifPrefs.QUIET_START,
                DailyReviewReminderPolicy.DEFAULT_QUIET_START_MINUTES,
            ),
            quietEndMinutes = NotifPrefs.getInt(
                context,
                NotifPrefs.QUIET_END,
                DailyReviewReminderPolicy.DEFAULT_QUIET_END_MINUTES,
            ),
        )
        scheduleAt(
            context = context,
            kind = kind,
            next = next,
            policy = policy,
            logicalDay = nominal.toLocalDate(),
            quietHoursCarryover = DailyReviewReminderPolicy.requiresCarryoverMarker(
                nominal.toLocalDate(),
                next,
            ),
        )
    }

    internal fun scheduleAt(
        context: Context,
        kind: DailyReviewKind,
        next: ZonedDateTime,
        policy: ExistingWorkPolicy,
        logicalDay: LocalDate = next.toLocalDate(),
        quietHoursCarryover: Boolean = false,
    ) {
        if (!isKindEnabled(context, kind)) return
        val now = ZonedDateTime.now(next.zone)
        val delayMillis = ChronoUnit.MILLIS.between(now, next).coerceAtLeast(1_000L)
        val request = OneTimeWorkRequestBuilder<DailyReviewReminderWorker>()
            .setInputData(
                workDataOf(
                    DailyReviewReminderWorker.KIND_KEY to kind.name,
                    DailyReviewReminderWorker.SCHEDULED_AT_KEY to next.toInstant().toEpochMilli(),
                    DailyReviewReminderWorker.DAY_KEY to logicalDay.toString(),
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
        if (quietHoursCarryover) {
            recordCarryover(context, kind, logicalDay)
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
            cancel(context, kind, workManager)
        }
    }

    private fun cancel(
        context: Context,
        kind: DailyReviewKind,
        workManager: WorkManager = WorkManager.getInstance(context),
    ) {
        clearCarryover(context, kind)
        NotificationLifecycleLedger.cancelled(
            context,
            lifecycleId(kind),
            NotificationLifecycleCategory.REMINDER,
        ) {
            workManager.cancelUniqueWork(workName(kind))
            NotificationManagerCompat.from(context).cancel(notificationId(kind))
        }
    }

    internal fun isKindEnabled(context: Context, kind: DailyReviewKind): Boolean = when (kind) {
        DailyReviewKind.MORNING -> isMorningEnabled(context)
        DailyReviewKind.EVENING -> isJournalEnabled(context)
    }

    private fun reminderMinutes(context: Context, kind: DailyReviewKind): Int = when (kind) {
        DailyReviewKind.MORNING -> morningMinutes(context)
        DailyReviewKind.EVENING -> eveningMinutes(context)
    }

    private fun carryoverKey(kind: DailyReviewKind): String =
        "$CARRYOVER_DAY_PREFIX${kind.name}"

    private fun carryoverLogicalDay(
        context: Context,
        kind: DailyReviewKind,
    ): LocalDate? = prefs(context).getString(carryoverKey(kind), null)?.let {
        runCatching { LocalDate.parse(it) }.getOrNull()
    }

    private fun recordCarryover(
        context: Context,
        kind: DailyReviewKind,
        logicalDay: LocalDate,
    ) {
        if (
            !prefs(context).edit()
                .putString(carryoverKey(kind), logicalDay.toString())
                .commit()
        ) {
            AppDiagnosticsRecorder.record(
                "daily_review.carryover_state",
                fields = mapOf("outcome" to "persist_failed"),
            )
        }
    }

    private fun clearCarryover(context: Context, kind: DailyReviewKind) {
        val preferences = prefs(context)
        val key = carryoverKey(kind)
        if (!preferences.contains(key)) return
        if (!preferences.edit().remove(key).commit()) {
            AppDiagnosticsRecorder.record(
                "daily_review.carryover_state",
                fields = mapOf("outcome" to "clear_failed"),
            )
        }
    }

    private fun migrateLegacyPreferenceIfNeeded(context: Context) {
        val appContext = context.applicationContext
        synchronized(preferenceLock) {
            val preferences = prefs(appContext)
            if (preferences.getBoolean(SPLIT_MIGRATED, false)) return
            val legacyEnabled = preferences.getBoolean(LEGACY_ENABLED, false)
            preferences.edit()
                .putBoolean(MORNING_ENABLED, legacyEnabled)
                .putBoolean(JOURNAL_ENABLED, legacyEnabled)
                .putBoolean(SPLIT_MIGRATED, true)
                .commit()
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
        val kind = inputData.getString(KIND_KEY)
            ?.let { runCatching { DailyReviewKind.valueOf(it) }.getOrNull() }
            ?: return Result.failure()
        if (!DailyReviewReminders.isKindEnabled(applicationContext, kind)) {
            return Result.success()
        }
        val scheduledAtMillis = inputData.getLong(SCHEDULED_AT_KEY, Long.MIN_VALUE)
        val scheduledDay = inputData.getString(DAY_KEY) ?: return Result.failure()
        val logicalDay = runCatching { LocalDate.parse(scheduledDay) }
            .getOrElse { return Result.failure() }
        if (scheduledAtMillis == Long.MIN_VALUE) return Result.failure()

        val now = ZonedDateTime.now()
        val scheduledAt = java.time.Instant.ofEpochMilli(scheduledAtMillis).atZone(now.zone)
        val fresh = DailyReviewReminderPolicy.logicalDayMatchesDelivery(
            logicalDay,
            scheduledAt,
        ) &&
            DailyReviewReminderPolicy.shouldDeliver(scheduledAt, now)
        if (!fresh) {
            DailyReviewReminders.suppress(applicationContext, kind)
            DailyReviewReminders.scheduleNext(
                applicationContext,
                kind,
                now,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
            )
            return Result.success()
        }
        val quietHoursEnabled =
            NotifPrefs.getBool(applicationContext, NotifPrefs.QUIET, false)
        val quietStartMinutes = NotifPrefs.getInt(
            applicationContext,
            NotifPrefs.QUIET_START,
            DailyReviewReminderPolicy.DEFAULT_QUIET_START_MINUTES,
        )
        val quietEndMinutes = NotifPrefs.getInt(
            applicationContext,
            NotifPrefs.QUIET_END,
            DailyReviewReminderPolicy.DEFAULT_QUIET_END_MINUTES,
        )
        if (
            DailyReviewReminderPolicy.isInQuietHours(
                now,
                quietHoursEnabled,
                quietStartMinutes,
                quietEndMinutes,
            )
        ) {
            val deferred = DailyReviewReminderPolicy.nextEligible(
                now,
                quietHoursEnabled,
                quietStartMinutes,
                quietEndMinutes,
            )
            DailyReviewReminders.scheduleAt(
                applicationContext,
                kind,
                deferred,
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                logicalDay,
                quietHoursCarryover = true,
            )
            DailyReviewReminders.suppress(applicationContext, kind)
            return Result.success()
        }
        val journalCompleted = if (kind == DailyReviewKind.EVENING) {
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

        if (DailyReviewReminderPolicy.shouldPost(kind, true, journalCompleted)) {
            if (!DailyReviewReminders.isKindEnabled(applicationContext, kind)) {
                return Result.success()
            }
            DailyReviewReminderNotifier.post(applicationContext, kind, logicalDay)
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
        val supported = when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_DATE_CHANGED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> true
            else -> false
        }
        if (!supported) return
        if (intent?.action == Intent.ACTION_DATE_CHANGED) {
            DailyReviewReminders.restore(context)
        } else {
            DailyReviewReminders.reconcile(context)
        }
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
    fun post(
        context: Context,
        kind: DailyReviewKind,
        logicalDay: LocalDate,
    ): Boolean = runCatching {
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
            NotificationRouteBridge.launchIntent(
                context,
                route,
                journalDay = logicalDay.takeIf { kind == DailyReviewKind.EVENING },
            ),
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
            .protectPrivateContent(context, CHANNEL_ID)
            .build()
        val posted = NotificationLifecycleLedger.posted(
            context,
            DailyReviewReminders.lifecycleId(kind),
            NotificationLifecycleCategory.REMINDER,
        ) {
            NotificationManagerCompat.from(context).notify(
                DailyReviewReminders.notificationId(kind),
                notification,
            )
        }
        if (posted && kind == DailyReviewKind.EVENING) {
            val fingerprint = "${kind.name.lowercase()}:$logicalDay"
            ContextualActionCenter.presentJournal(
                context = context,
                fingerprint = fingerprint,
                title = title,
                detail = body,
                journalDay = logicalDay.toString(),
            )
        }
        posted
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
