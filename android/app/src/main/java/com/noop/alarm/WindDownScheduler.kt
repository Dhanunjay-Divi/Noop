package com.noop.alarm

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.text.format.DateFormat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.noop.R
import com.noop.notif.NotificationLifecycleCategory
import com.noop.notif.NotificationLifecycleId
import com.noop.notif.NotificationLifecycleLedger
import com.noop.notif.NotificationPlatformIdentity
import com.noop.notif.protectPrivateContent
import com.noop.ui.ContextualActionCenter
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Date
import java.util.TimeZone
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The wind-down nudge (#207) — a gentle, NON-safety-critical evening local notification.
 *
 * Deliberately INEXACT: a missed wind-down nudge costs nothing, so we use a one-shot inexact alarm
 * (no exact-alarm permission needed) rather than the privileged primitive the wake alarm uses.
 * The receiver computes the next local wall-clock occurrence after every fire. A repeating
 * INTERVAL_DAY alarm is incorrect here because it drifts by an hour when daylight-saving time
 * changes. Each one-shot alarm is derived from the next prospective wake date and that weekday's
 * planner override.
 *
 * The fired notification is low-key (default importance, no full-screen, no DND bypass) — it's a
 * suggestion, not an alarm.
 */
internal object WindDownScheduler {

    private const val REQUEST_CODE = 7311
    const val ACTION_NUDGE = "com.noop.alarm.action.WIND_DOWN_NUDGE"
    const val CHANNEL_ID = "noop_wind_down"
    // Brief inexact-alarm drift is acceptable; after this, or at bedtime, the reminder is stale.
    internal const val MAX_FIRE_LATENESS_MILLIS = 15 * 60 * 1_000L

    internal data class NotificationPlan(
        val windDownMinuteOfDay: Int,
        val bedtimeMinuteOfDay: Int,
    )

    internal data class DatedPlan(
        val windDownAtMillis: Long,
        val bedtimeAtMillis: Long,
        val wakeAtMillis: Long,
        val wakeWeekday: Int,
    )

    enum class DeliveryAvailability {
        AVAILABLE,
        NOTIFICATIONS_OFF,
        CHANNEL_OFF,
    }

    enum class ScheduleFailure {
        NOTIFICATIONS_OFF,
        CHANNEL_OFF,
        NO_FUTURE_PLAN,
        ALARM_MANAGER_REJECTED,
        PERSISTENCE_REJECTED,
    }

    sealed interface ScheduleResult {
        data class Scheduled(val plan: DatedPlan, val attempts: Int) : ScheduleResult
        data class Failed(val reason: ScheduleFailure, val attempts: Int = 0) : ScheduleResult
    }

    enum class ReconcileResult {
        DISABLED,
        SCHEDULED,
        RETRY_NOTIFICATIONS_OFF,
        RETRY_CHANNEL_OFF,
        RETRY_DELIVERY_CHECK_FAILURE,
        RETRY_SCHEDULE_FAILURE,
    }

    enum class FireResult {
        POSTED,
        SUPPRESSED_UNAVAILABLE,
        SUPPRESSED_NO_CURRENT_PLAN,
        FAILED,
    }

    internal data class RetryPolicy(val maximumAttempts: Int) {
        val boundedAttempts: Int = maximumAttempts.coerceIn(1, 3)

        companion object {
            val PRODUCTION = RetryPolicy(maximumAttempts = 2)
        }
    }

    fun deliveryAvailability(context: Context): DeliveryAvailability {
        if (!ensureChannel(context)) return DeliveryAvailability.CHANNEL_OFF
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return DeliveryAvailability.NOTIFICATIONS_OFF
        if (!runCatching {
                NotificationManagerCompat.from(context).areNotificationsEnabled()
            }.getOrDefault(false)
        ) {
            return DeliveryAvailability.NOTIFICATIONS_OFF
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = runCatching {
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            }.getOrNull() ?: return DeliveryAvailability.CHANNEL_OFF
            val channel = runCatching {
                manager.getNotificationChannel(CHANNEL_ID)
            }.getOrNull() ?: return DeliveryAvailability.CHANNEL_OFF
            if (channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return DeliveryAvailability.CHANNEL_OFF
            }
        }
        return DeliveryAvailability.AVAILABLE
    }

    fun notificationsAvailable(context: Context): Boolean =
        deliveryAvailability(context) == DeliveryAvailability.AVAILABLE

    fun notificationSettingsIntent(context: Context): Intent {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val hasChannel = runCatching {
                val manager =
                    context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.getNotificationChannel(CHANNEL_ID) != null
            }.getOrDefault(false)
            if (hasChannel) {
                return Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, CHANNEL_ID)
            }
        }
        return Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
    }

    /**
     * Schedules from a prospective wake date, not the reminder date. This is what makes a Friday
     * evening reminder honor Saturday's planner override. AlarmManager has no acceptance callback;
     * "scheduled" means its set call returned without throwing. The registration attempt is bounded
     * and returns a structured result so callers persist enabled only after acceptance.
     */
    fun schedule(
        context: Context,
        store: WindDownStore,
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault(),
        retryPolicy: RetryPolicy = RetryPolicy.PRODUCTION,
    ): ScheduleResult {
        val availability = deliveryAvailability(context)
        if (availability != DeliveryAvailability.AVAILABLE) {
            cancel(context)
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            )
            return ScheduleResult.Failed(
                reason = when (availability) {
                    DeliveryAvailability.NOTIFICATIONS_OFF ->
                        ScheduleFailure.NOTIFICATIONS_OFF
                    DeliveryAvailability.CHANNEL_OFF ->
                        ScheduleFailure.CHANNEL_OFF
                    DeliveryAvailability.AVAILABLE ->
                        error("unreachable")
                },
            )
        }
        val plan = nextDatedPlan(
            defaultWakeMinutes = store.wakeMinutes,
            wakeOverrides = store.perDayWakeOverrides,
            targetSleepMinutes = store.targetSleepMinutes,
            leadMinutes = store.leadMinutes,
            nowMs = nowMs,
            timeZone = timeZone,
        ) ?: return ScheduleResult.Failed(ScheduleFailure.NO_FUTURE_PLAN)

        val alarmManager = runCatching {
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        }.getOrNull() ?: return ScheduleResult.Failed(
            ScheduleFailure.ALARM_MANAGER_REJECTED,
        )
        val pendingIntent = runCatching {
            nudgePendingIntent(context)
        }.getOrNull() ?: return ScheduleResult.Failed(
            ScheduleFailure.ALARM_MANAGER_REJECTED,
        )
        return registerWithRetry(plan, retryPolicy) {
            NotificationLifecycleLedger.scheduled(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            ) {
                alarmManager.cancel(pendingIntent)
                // Inexact, one-shot, not wakeup. The receiver computes the next dated plan after fire.
                alarmManager.set(
                    AlarmManager.RTC,
                    plan.windDownAtMillis,
                    pendingIntent,
                )
            }
        }
    }

    internal fun registerWithRetry(
        plan: DatedPlan,
        retryPolicy: RetryPolicy,
        register: () -> Boolean,
    ): ScheduleResult {
        repeat(retryPolicy.boundedAttempts) { index ->
            if (runCatching(register).getOrDefault(false)) {
                return ScheduleResult.Scheduled(plan, attempts = index + 1)
            }
        }
        return ScheduleResult.Failed(
            ScheduleFailure.ALARM_MANAGER_REJECTED,
            attempts = retryPolicy.boundedAttempts,
        )
    }

    internal fun commitEnableAfterAcceptance(
        store: WindDownStore,
        schedule: () -> ScheduleResult,
        cancel: () -> Unit,
    ): ScheduleResult {
        val result = runCatching(schedule).getOrElse {
            ScheduleResult.Failed(ScheduleFailure.ALARM_MANAGER_REJECTED)
        }
        if (result is ScheduleResult.Scheduled) {
            if (!store.setEnabledDurably(true)) {
                runCatching { store.setEnabledDurably(false) }
                runCatching(cancel)
                return ScheduleResult.Failed(
                    ScheduleFailure.PERSISTENCE_REJECTED,
                    attempts = result.attempts,
                )
            }
        } else {
            runCatching { store.setEnabledDurably(false) }
            runCatching(cancel)
        }
        return result
    }

    internal fun reconcilePersisted(
        store: WindDownStore,
        availability: DeliveryAvailability,
        schedule: () -> ScheduleResult,
        cancel: () -> Unit,
    ): ReconcileResult {
        if (!store.enabled) {
            runCatching(cancel)
            return ReconcileResult.DISABLED
        }
        if (availability != DeliveryAvailability.AVAILABLE) {
            runCatching(cancel)
            return when (availability) {
                DeliveryAvailability.NOTIFICATIONS_OFF ->
                    ReconcileResult.RETRY_NOTIFICATIONS_OFF
                DeliveryAvailability.CHANNEL_OFF ->
                    ReconcileResult.RETRY_CHANNEL_OFF
                DeliveryAvailability.AVAILABLE ->
                    error("unreachable")
            }
        }
        val result = runCatching(schedule).getOrElse {
            ScheduleResult.Failed(ScheduleFailure.ALARM_MANAGER_REJECTED)
        }
        return when (result) {
            is ScheduleResult.Scheduled -> ReconcileResult.SCHEDULED
            is ScheduleResult.Failed -> {
                runCatching(cancel)
                ReconcileResult.RETRY_SCHEDULE_FAILURE
            }
        }
    }

    fun reconcilePersisted(
        context: Context,
        store: WindDownStore = WindDownStore.from(context),
    ): ReconcileResult {
        store.migrateWakeMinutesIfNeeded(
            SmartAlarmStore.from(context).targetMinutes,
        )
        if (!store.enabled) {
            cancel(context)
            return ReconcileResult.DISABLED
        }
        val availability = deliveryAvailability(context)
        return reconcilePersisted(
            store = store,
            availability = availability,
            schedule = { schedule(context, store) },
            cancel = { cancel(context) },
        )
    }

    internal fun reconcileDeliveryOnForeground(
        store: WindDownStore,
        availability: () -> DeliveryAvailability,
        schedule: () -> ScheduleResult,
        cancel: () -> Unit,
        publishEnabled: (Boolean) -> Unit = {},
    ): ReconcileResult {
        if (!store.enabled) {
            runCatching(cancel)
            runCatching { publishEnabled(false) }
            return ReconcileResult.DISABLED
        }
        val resolvedAvailability = runCatching(availability).getOrElse {
            runCatching(cancel)
            runCatching { publishEnabled(true) }
            return ReconcileResult.RETRY_DELIVERY_CHECK_FAILURE
        }
        val result = reconcilePersisted(
            store = store,
            availability = resolvedAvailability,
            schedule = schedule,
            cancel = cancel,
        )
        runCatching { publishEnabled(store.enabled) }
        return result
    }

    fun cancel(context: Context) {
        val alarmManager = runCatching {
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        }.getOrNull() ?: return
        val pendingIntent = runCatching {
            nudgePendingIntent(context)
        }.getOrNull() ?: return
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.WIND_DOWN,
            NotificationLifecycleCategory.REMINDER,
        ) {
            alarmManager.cancel(pendingIntent)
        }
    }

    /** Raise the low-key nudge notification. Called from [WindDownReceiver]. */
    @SuppressLint("MissingPermission")
    fun fireNotification(
        context: Context,
        store: WindDownStore = WindDownStore.from(context),
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault(),
    ): FireResult {
        if (deliveryAvailability(context) != DeliveryAvailability.AVAILABLE) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            )
            return FireResult.SUPPRESSED_UNAVAILABLE
        }
        val plan = currentDatedPlan(
            defaultWakeMinutes = store.wakeMinutes,
            wakeOverrides = store.perDayWakeOverrides,
            targetSleepMinutes = store.targetSleepMinutes,
            leadMinutes = store.leadMinutes,
            nowMs = nowMs,
            timeZone = timeZone,
        ) ?: run {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            )
            return FireResult.SUPPRESSED_NO_CURRENT_PLAN
        }
        return runCatching {
            val body = context.getString(
                R.string.wind_down_notification_body,
                localizedTime(context, plan.windDownAtMillis, timeZone),
                localizedTime(context, plan.bedtimeAtMillis, timeZone),
            )
            val open = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.WIND_DOWN,
                NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.SLEEP),
            )
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.wind_down_notification_title))
                .setContentText(body)
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .protectPrivateContent(context, CHANNEL_ID)
                .setAutoCancel(true)
                .build()
            val posted = NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            ) {
                (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(NotificationPlatformIdentity.NotificationId.WIND_DOWN, n)
            }
            if (posted) {
                ContextualActionCenter.presentWindDown(
                    context = context,
                    fingerprint = java.time.LocalDate.now().toString(),
                    title = context.getString(R.string.wind_down_notification_title),
                    detail = body,
                )
            }
            if (posted) FireResult.POSTED else FireResult.FAILED
        }.getOrElse {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.WIND_DOWN,
                NotificationLifecycleCategory.REMINDER,
            )
            FireResult.FAILED
        }
    }

    private fun nudgePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, WindDownReceiver::class.java).setAction(ACTION_NUDGE)
        return PendingIntent.getBroadcast(
            context, REQUEST_CODE, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun ensureChannel(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        context.getString(R.string.wind_down_channel_name),
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply {
                        description = context.getString(R.string.wind_down_channel_description)
                        setShowBadge(false)
                    },
                )
            }
            mgr.getNotificationChannel(CHANNEL_ID) != null
        }.getOrDefault(false)
    }

    internal fun datedPlan(
        wakeDate: LocalDate,
        wakeMinutes: Int,
        targetSleepMinutes: Int,
        leadMinutes: Int,
        zoneId: ZoneId,
    ): DatedPlan {
        val safeWake = wakeMinutes.coerceIn(0, WindDownStore.MINUTES_PER_DAY - 1)
        // LocalDateTime.atZone moves a DST-gap time forward by the full gap while preserving minutes,
        // and selects the earlier offset for an overlap. Foundation's component resolver uses the same
        // policy, which keeps the two clients on identical instants.
        val wake = LocalDateTime.of(
            wakeDate,
            java.time.LocalTime.of(safeWake / 60, safeWake % 60),
        ).atZone(zoneId)
        val bedtime = wake.minusMinutes(targetSleepMinutes.coerceAtLeast(0).toLong())
        val windDown = bedtime.minusMinutes(leadMinutes.coerceAtLeast(0).toLong())
        return DatedPlan(
            windDownAtMillis = windDown.toInstant().toEpochMilli(),
            bedtimeAtMillis = bedtime.toInstant().toEpochMilli(),
            wakeAtMillis = wake.toInstant().toEpochMilli(),
            wakeWeekday = calendarWeekday(wakeDate),
        )
    }

    internal fun nextDatedPlan(
        defaultWakeMinutes: Int,
        wakeOverrides: Map<Int, Int>,
        targetSleepMinutes: Int,
        leadMinutes: Int,
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault(),
    ): DatedPlan? {
        val zoneId = timeZone.toZoneId()
        val startWakeDate = Instant.ofEpochMilli(nowMs).atZone(zoneId).toLocalDate()
        repeat(10) { offset ->
            val wakeDate = startWakeDate.plusDays(offset.toLong())
            val weekday = calendarWeekday(wakeDate)
            val plan = datedPlan(
                wakeDate = wakeDate,
                wakeMinutes = wakeOverrides[weekday] ?: defaultWakeMinutes,
                targetSleepMinutes = targetSleepMinutes,
                leadMinutes = leadMinutes,
                zoneId = zoneId,
            )
            if (plan.windDownAtMillis > nowMs) return plan
        }
        return null
    }

    internal fun currentDatedPlan(
        defaultWakeMinutes: Int,
        wakeOverrides: Map<Int, Int>,
        targetSleepMinutes: Int,
        leadMinutes: Int,
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault(),
        earlyToleranceMillis: Long = 2 * 60 * 1_000L,
        maximumLatenessMillis: Long = MAX_FIRE_LATENESS_MILLIS,
    ): DatedPlan? {
        val zoneId = timeZone.toZoneId()
        val localDate = Instant.ofEpochMilli(nowMs).atZone(zoneId).toLocalDate()
        return (-1L..2L)
            .map { offset ->
                val wakeDate = localDate.plusDays(offset)
                val weekday = calendarWeekday(wakeDate)
                datedPlan(
                    wakeDate = wakeDate,
                    wakeMinutes = wakeOverrides[weekday] ?: defaultWakeMinutes,
                    targetSleepMinutes = targetSleepMinutes,
                    leadMinutes = leadMinutes,
                    zoneId = zoneId,
                )
            }
            .filter { plan ->
                plan.windDownAtMillis <= nowMs + earlyToleranceMillis &&
                    nowMs - plan.windDownAtMillis <= maximumLatenessMillis &&
                    nowMs < plan.bedtimeAtMillis &&
                    plan.wakeAtMillis > nowMs
            }
            .minByOrNull { kotlin.math.abs(nowMs - it.windDownAtMillis) }
    }

    internal fun notificationPlan(
        wakeMinutes: Int,
        targetSleepMinutes: Int,
        leadMinutes: Int,
    ): NotificationPlan {
        val bedtime = normalizedMinuteOfDay(wakeMinutes - targetSleepMinutes)
        return NotificationPlan(
            windDownMinuteOfDay = normalizedMinuteOfDay(bedtime - leadMinutes),
            bedtimeMinuteOfDay = bedtime,
        )
    }

    private fun localizedTime(
        context: Context,
        epochMillis: Long,
        timeZone: TimeZone = TimeZone.getDefault(),
    ): String =
        DateFormat.getTimeFormat(context).apply {
            this.timeZone = timeZone
        }.format(Date(epochMillis))

    private fun normalizedMinuteOfDay(minutes: Int): Int {
        val day = 24 * 60
        return ((minutes % day) + day) % day
    }

    private fun calendarWeekday(date: LocalDate): Int =
        (date.dayOfWeek.value % 7) + 1
}

internal class WindDownForegroundReconciler(
    private val store: WindDownStore,
    private val availability: () -> WindDownScheduler.DeliveryAvailability,
    private val schedule: () -> WindDownScheduler.ScheduleResult,
    private val cancel: () -> Unit,
    private val publishEnabled: (Boolean) -> Unit = {},
) {
    fun onAppResumed(): WindDownScheduler.ReconcileResult =
        WindDownScheduler.reconcileDeliveryOnForeground(
            store = store,
            availability = availability,
            schedule = schedule,
            cancel = cancel,
            publishEnabled = publishEnabled,
        )
}

/** Receives a one-shot wind-down nudge, raises the reminder, and schedules the next local occurrence.
 *  [SmartAlarmBootReceiver] also re-arms it after reboot and wall-clock/timezone changes. */
class WindDownReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != WindDownScheduler.ACTION_NUDGE) return
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val appContext = context.applicationContext
                val wind = WindDownStore.from(appContext)
                if (!wind.enabled) return@launch
                wind.migrateWakeMinutesIfNeeded(
                    SmartAlarmStore.from(appContext).targetMinutes,
                )
                if (WindDownScheduler.deliveryAvailability(appContext) !=
                    WindDownScheduler.DeliveryAvailability.AVAILABLE
                ) {
                    WindDownScheduler.reconcilePersisted(appContext, wind)
                    return@launch
                }

                val alreadyAsleep = withTimeoutOrNull(1_500L) {
                    try {
                        WindDownStore.hasFreshActiveSleepEvidence(appContext)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Throwable) {
                        false
                    }
                } ?: false
                if (alreadyAsleep) {
                    NotificationLifecycleLedger.suppressed(
                        appContext,
                        NotificationLifecycleId.WIND_DOWN,
                        NotificationLifecycleCategory.REMINDER,
                    )
                } else {
                    WindDownScheduler.fireNotification(
                        context = appContext,
                        store = wind,
                    )
                }

                if (wind.enabled) {
                    WindDownScheduler.reconcilePersisted(appContext, wind)
                }
            } finally {
                pendingResult.finish()
            }
        }
    }
}
