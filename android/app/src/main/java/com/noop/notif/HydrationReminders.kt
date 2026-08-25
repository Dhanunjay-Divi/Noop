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
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.noop.automation.PendingTapAutomation
import com.noop.automation.TapAutomationKind
import com.noop.automation.TapAutomationStore
import com.noop.R
import com.noop.ble.LiveState
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotifPrefs
import com.noop.ui.NotificationRouteBridge
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.concurrent.TimeUnit

/** New, isolated preferences; adding reminders never rewrites an existing hydration total or profile. */
object HydrationReminderPrefs {
    private const val FILE = "noop_hydration_reminders"
    private const val ENABLED = "hydration.reminders.enabled"
    private const val INTERVAL = "hydration.reminders.intervalMinutes"
    private const val START = "hydration.reminders.startMinutes"
    private const val END = "hydration.reminders.endMinutes"
    private const val ADAPTIVE = "hydration.reminders.adaptiveEnabled"
    private const val ADAPTIVE_INTERVAL = "hydration.reminders.adaptiveIntervalMinutes"
    private const val ADAPTIVE_DAY = "hydration.reminders.adaptiveEpochDay"
    private const val STRAP_BUZZ = "hydration.reminders.strapBuzz"
    private const val TAP_CONFIRM = "hydration.reminders.tapConfirm"
    private const val TAP_AMOUNT_ML = "hydration.reminders.tapAmountMl"
    private const val TAP_WINDOW_MINUTES = "hydration.reminders.tapWindowMinutes"
    private const val BAND_FIRST = "hydration.reminders.bandFirst"
    private const val LAST_NOTIFICATION_SLOT = "hydration.reminders.lastNotificationSlot"
    private const val LAST_STRAP_SLOT = "hydration.reminders.lastStrapSlot"
    private const val LAST_CONFIRMED_SLOT = "hydration.reminders.lastConfirmedSlot"

    data class Config(
        val enabled: Boolean,
        val intervalMinutes: Int,
        val startMinutes: Int,
        val endMinutes: Int,
        val adaptiveEnabled: Boolean,
        val effectiveIntervalMinutes: Int,
        val strapBuzzEnabled: Boolean,
        val tapConfirmEnabled: Boolean,
        val tapAmountMl: Int,
        val tapWindowMinutes: Int,
        val bandFirst: Boolean,
    )

    private fun prefs(context: Context) = context.applicationContext
        .getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun config(
        context: Context,
        epochDay: Long = LocalDate.now().toEpochDay(),
    ): Config {
        val prefs = prefs(context)
        val baseInterval = HydrationReminderPolicy.clampIntervalMinutes(
            prefs.getInt(INTERVAL, HydrationReminderPolicy.DEFAULT_INTERVAL_MINUTES),
        )
        val adaptiveEnabled = prefs.getBoolean(ADAPTIVE, true)
        val effectiveInterval =
            if (adaptiveEnabled && prefs.getLong(ADAPTIVE_DAY, Long.MIN_VALUE) == epochDay) {
                HydrationReminderPolicy.clampIntervalMinutes(
                    prefs.getInt(ADAPTIVE_INTERVAL, baseInterval),
                )
            } else {
                baseInterval
            }
        return Config(
            enabled = prefs.getBoolean(ENABLED, false),
            intervalMinutes = baseInterval,
            startMinutes = HydrationReminderPolicy.clampMinuteOfDay(
                prefs.getInt(START, HydrationReminderPolicy.DEFAULT_START_MINUTES),
            ),
            endMinutes = HydrationReminderPolicy.clampMinuteOfDay(
                prefs.getInt(END, HydrationReminderPolicy.DEFAULT_END_MINUTES),
            ),
            adaptiveEnabled = adaptiveEnabled,
            effectiveIntervalMinutes = effectiveInterval,
            strapBuzzEnabled = prefs.getBoolean(STRAP_BUZZ, false),
            tapConfirmEnabled = prefs.getBoolean(TAP_CONFIRM, false),
            tapAmountMl = prefs.getInt(TAP_AMOUNT_ML, 250).coerceIn(50, 1_000),
            tapWindowMinutes = prefs.getInt(TAP_WINDOW_MINUTES, 10).coerceIn(5, 30),
            bandFirst = prefs.getBoolean(BAND_FIRST, false),
        )
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(ENABLED, enabled).apply()
        if (!enabled) {
            TapAutomationStore.clear(context, TapAutomationKind.HYDRATION_CONFIRM)
            HydrationReminderEscalationScheduler.cancelAll(context)
        }
    }

    fun setIntervalMinutes(context: Context, minutes: Int) = prefs(context).edit()
        .putInt(INTERVAL, HydrationReminderPolicy.clampIntervalMinutes(minutes))
        .remove(ADAPTIVE_INTERVAL)
        .remove(ADAPTIVE_DAY)
        .apply()

    fun setStartMinutes(context: Context, minutes: Int) = prefs(context).edit()
        .putInt(START, HydrationReminderPolicy.clampMinuteOfDay(minutes))
        .remove(ADAPTIVE_INTERVAL)
        .remove(ADAPTIVE_DAY)
        .apply()

    fun setEndMinutes(context: Context, minutes: Int) = prefs(context).edit()
        .putInt(END, HydrationReminderPolicy.clampMinuteOfDay(minutes))
        .remove(ADAPTIVE_INTERVAL)
        .remove(ADAPTIVE_DAY)
        .apply()

    fun setAdaptiveEnabled(context: Context, enabled: Boolean) {
        val edit = prefs(context).edit().putBoolean(ADAPTIVE, enabled)
        if (!enabled) {
            edit.remove(ADAPTIVE_INTERVAL).remove(ADAPTIVE_DAY)
        }
        edit.apply()
    }

    /**
     * Stores only today's derived interval. The caller supplies confirmed intake and a scored Effort;
     * absent values stay absent and the pure policy falls back to the user's base interval.
     *
     * @return true when the effective interval changed and an enabled scheduler should be reconciled.
     */
    fun updateAdaptiveContext(
        context: Context,
        effort: Double?,
        consumedMl: Double?,
        goalMl: Int?,
        now: ZonedDateTime = ZonedDateTime.now(),
    ): Boolean {
        val epochDay = now.toLocalDate().toEpochDay()
        val current = config(context, epochDay)
        if (!current.adaptiveEnabled) return false
        val plan = HydrationReminderPolicy.adaptivePlan(
            baseIntervalMinutes = current.intervalMinutes,
            startMinutes = current.startMinutes,
            endMinutes = current.endMinutes,
            context = HydrationAdaptiveContext(
                effort = effort,
                consumedMl = consumedMl,
                goalMl = goalMl,
                minuteOfDay = now.hour * 60 + now.minute,
            ),
        )
        val prefs = prefs(context)
        val changed =
            prefs.getLong(ADAPTIVE_DAY, Long.MIN_VALUE) != epochDay ||
            current.effectiveIntervalMinutes != plan.intervalMinutes
        prefs.edit()
            .putLong(ADAPTIVE_DAY, epochDay)
            .putInt(ADAPTIVE_INTERVAL, plan.intervalMinutes)
            .apply()
        return changed
    }

    fun setStrapBuzzEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit()
            .putBoolean(STRAP_BUZZ, enabled)
            .apply()
        if (!enabled) {
            setBandFirst(context, false)
            TapAutomationStore.clear(context, TapAutomationKind.HYDRATION_CONFIRM)
        }
    }

    fun setTapConfirmEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(TAP_CONFIRM, enabled).apply()
        if (!enabled) {
            setBandFirst(context, false)
            TapAutomationStore.clear(context, TapAutomationKind.HYDRATION_CONFIRM)
        }
    }

    fun setTapAmountMl(context: Context, amountMl: Int) =
        prefs(context).edit().putInt(TAP_AMOUNT_ML, amountMl.coerceIn(50, 1_000)).apply()

    fun setTapWindowMinutes(context: Context, minutes: Int) =
        prefs(context).edit().putInt(TAP_WINDOW_MINUTES, minutes.coerceIn(5, 30)).apply()

    fun setBandFirst(context: Context, enabled: Boolean) {
        val current = config(context)
        val resolved = enabled && current.enabled && current.strapBuzzEnabled && current.tapConfirmEnabled
        prefs(context).edit().putBoolean(BAND_FIRST, resolved).apply()
        if (!resolved) HydrationReminderEscalationScheduler.cancelAll(context)
    }

    internal fun lastNotificationSlot(context: Context): String? =
        prefs(context).getString(LAST_NOTIFICATION_SLOT, null)

    internal fun markNotificationSlot(context: Context, slot: String) =
        prefs(context).edit().putString(LAST_NOTIFICATION_SLOT, slot).apply()

    internal fun lastStrapSlot(context: Context): String? =
        prefs(context).getString(LAST_STRAP_SLOT, null)

    internal fun markStrapSlot(context: Context, slot: String) =
        prefs(context).edit().putString(LAST_STRAP_SLOT, slot).apply()

    internal fun lastConfirmedSlot(context: Context): String? =
        prefs(context).getString(LAST_CONFIRMED_SLOT, null)

    internal fun markConfirmedSlot(context: Context, slot: String) =
        prefs(context).edit().putString(LAST_CONFIRMED_SLOT, slot).apply()
}

/**
 * Persistent best-effort scheduler. WorkManager survives process death/reboot but Android may defer it
 * under Doze or OEM battery policy, so neither code nor UI promises exact delivery.
 */
object HydrationReminderScheduler {
    private const val WORK_NAME = "noop_hydration_reminder"

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val manager = WorkManager.getInstance(appContext)
        val config = HydrationReminderPrefs.config(appContext)
        if (!config.enabled) {
            manager.cancelUniqueWork(WORK_NAME)
            HydrationReminderEscalationScheduler.cancelAll(appContext)
            TapAutomationStore.clear(appContext, TapAutomationKind.HYDRATION_CONFIRM)
            return
        }
        scheduleNext(appContext, ZonedDateTime.now(), ExistingWorkPolicy.REPLACE)
    }

    internal fun scheduleNext(
        context: Context,
        now: ZonedDateTime,
        existingWorkPolicy: ExistingWorkPolicy,
    ) {
        val config = HydrationReminderPrefs.config(context, now.toLocalDate().toEpochDay())
        if (!config.enabled) {
            NotificationLifecycleLedger.observe(
                context,
                NotificationLifecycleId.HYDRATION,
                NotificationLifecycleCategory.REMINDER,
                NotificationLifecycleState.CANCELLED,
            ) {
                WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            }
            return
        }
        val next = HydrationReminderPolicy.nextSlot(
            epochDay = now.toLocalDate().toEpochDay(),
            minuteOfDay = now.hour * 60 + now.minute,
            startMinutes = config.startMinutes,
            endMinutes = config.endMinutes,
            intervalMinutes = config.effectiveIntervalMinutes,
        )
        val zone = now.zone
        val nextInstant = LocalDate.ofEpochDay(next.epochDay)
            .atTime(next.minuteOfDay / 60, next.minuteOfDay % 60)
            .atZone(zone)
            .toInstant()
        val delayMs = (nextInstant.toEpochMilli() - now.toInstant().toEpochMilli()).coerceAtLeast(1_000L)
        val request = OneTimeWorkRequestBuilder<HydrationReminderWorker>()
            .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
            .build()
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.HYDRATION,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.SCHEDULED,
        ) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                WORK_NAME,
                existingWorkPolicy,
                request,
            )
        }
    }
}

class HydrationReminderWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val now = ZonedDateTime.now()
        val config = HydrationReminderPrefs.config(
            applicationContext,
            now.toLocalDate().toEpochDay(),
        )
        if (!config.enabled) return Result.success()

        val due = HydrationReminderPolicy.latestDueSlot(
            epochDay = now.toLocalDate().toEpochDay(),
            minuteOfDay = now.hour * 60 + now.minute,
            startMinutes = config.startMinutes,
            endMinutes = config.endMinutes,
            intervalMinutes = config.effectiveIntervalMinutes,
        )
        if (HydrationReminderPolicy.shouldNotify(
                enabled = config.enabled,
                currentSlotKey = due?.key,
                lastNotifiedSlotKey = HydrationReminderPrefs.lastNotificationSlot(applicationContext),
            )
        ) {
            val slot = checkNotNull(due).key
            // Band-first escalation is occurrence-driven. The live delivery path schedules it only
            // after issuing the band cue, so a delayed worker cannot shorten the user's tap window.
            if (!config.bandFirst && HydrationReminderNotifier.post(applicationContext)) {
                HydrationReminderPrefs.markNotificationSlot(applicationContext, slot)
            }
        }

        // Chain one persisted one-shot instead of polling every 15 minutes. A late worker skips stale
        // slots via the policy grace window, then still restores the next reminder.
        // Append behind this running worker instead of REPLACE-ing (and cancelling) ourselves.
        HydrationReminderScheduler.scheduleNext(
            applicationContext,
            now,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
        )
        return Result.success()
    }
}

/** Optional second lane: wait for the explicit band-tap window, then notify only if it was missed. */
object HydrationReminderEscalationScheduler {
    private const val WORK_PREFIX = "noop_hydration_escalation_"
    private const val WORK_TAG = "noop_hydration_escalation"
    internal const val SLOT_KEY = "slot"

    fun schedule(context: Context, slot: String, delayMinutes: Int) {
        val request = OneTimeWorkRequestBuilder<HydrationReminderEscalationWorker>()
            .setInputData(workDataOf(SLOT_KEY to slot))
            .setInitialDelay(delayMinutes.coerceIn(5, 30).toLong(), TimeUnit.MINUTES)
            .addTag(WORK_TAG)
            .build()
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.HYDRATION,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.SCHEDULED,
        ) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                WORK_PREFIX + slot,
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }

    fun cancel(context: Context, slot: String) {
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.HYDRATION,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.CANCELLED,
        ) {
            WorkManager.getInstance(context.applicationContext)
                .cancelUniqueWork(WORK_PREFIX + slot)
        }
    }

    fun cancelAll(context: Context) {
        NotificationLifecycleLedger.observe(
            context,
            NotificationLifecycleId.HYDRATION,
            NotificationLifecycleCategory.REMINDER,
            NotificationLifecycleState.CANCELLED,
        ) {
            WorkManager.getInstance(context.applicationContext).cancelAllWorkByTag(WORK_TAG)
        }
    }
}

class HydrationReminderEscalationWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val slot = inputData.getString(HydrationReminderEscalationScheduler.SLOT_KEY)
            ?: return Result.failure()
        val config = HydrationReminderPrefs.config(applicationContext)
        if (!HydrationReminderPolicy.shouldEscalateAfterTapWindow(
                enabled = config.enabled,
                bandFirst = config.bandFirst,
                currentSlotKey = slot,
                lastConfirmedSlotKey = HydrationReminderPrefs.lastConfirmedSlot(applicationContext),
                lastNotifiedSlotKey = HydrationReminderPrefs.lastNotificationSlot(applicationContext),
            )
        ) return Result.success()
        if (HydrationReminderNotifier.post(applicationContext)) {
            HydrationReminderPrefs.markNotificationSlot(applicationContext, slot)
        }
        return Result.success()
    }
}

object HydrationReminderNotifier {
    private const val CHANNEL_ID = "noop_hydration_reminders"

    @SuppressLint("MissingPermission")
    internal fun post(context: Context): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.HYDRATION,
                NotificationLifecycleCategory.REMINDER,
            )
            return false
        }
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.HYDRATION,
                NotificationLifecycleCategory.REMINDER,
            )
            return false
        }
        ensureChannel(context)
        val title = context.getString(R.string.l10n_hydration_reminders_hydration_check_in_f93a58b5)
        val body = context.getString(R.string.l10n_hydration_reminders_take_a_moment_to_drink_some_6a03f36a)
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.HYDRATION,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.HYDRATION),
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.HYDRATION,
            NotificationLifecycleCategory.REMINDER,
        ) {
            manager.notify(
                NotificationPlatformIdentity.NotificationId.HYDRATION,
                notification,
            )
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            NotificationLifecycleId.HYDRATION,
            NotificationLifecycleCategory.REMINDER,
        )
        false
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID)
            ?: NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.l10n_hydration_reminders_hydration_reminders_a4e4defb),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        // Re-apply user-visible metadata so it follows a later app-language change. Re-registering an
        // existing channel preserves the user's importance and delivery choices.
        channel.name = context.getString(R.string.l10n_hydration_reminders_hydration_reminders_a4e4defb)
        channel.description = context.getString(
            R.string.l10n_hydration_reminders_optional_private_reminders_to_pause_and_1f99dac8,
        )
        manager.createNotificationChannel(channel)
    }
}

/** WHOOP lane: invoked only for a newly observed HR packet by the connection service. */
object HydrationReminderDelivery {
    fun maybeBuzzOnFreshWhoopSample(
        context: Context,
        state: LiveState,
        buzz: (Int) -> Unit,
        now: ZonedDateTime = ZonedDateTime.now(ZoneId.systemDefault()),
    ): Boolean {
        val config = HydrationReminderPrefs.config(context, now.toLocalDate().toEpochDay())
        val due = HydrationReminderPolicy.latestDueSlot(
            epochDay = now.toLocalDate().toEpochDay(),
            minuteOfDay = now.hour * 60 + now.minute,
            startMinutes = config.startMinutes,
            endMinutes = config.endMinutes,
            intervalMinutes = config.effectiveIntervalMinutes,
        )
        if (!HydrationReminderPolicy.shouldBuzzStrap(
                enabled = config.enabled,
                strapBuzzEnabled = config.strapBuzzEnabled,
                wristAlertsMasterOn = NotifPrefs.getBool(context, NotifPrefs.MASTER, false),
                connected = state.connected,
                bonded = state.bonded,
                encryptedBond = state.encryptedBond,
                worn = state.worn,
                freshLiveSample = state.heartRate != null && state.heartRateSampleSequence > 0L,
                inQuietHours = NotifPrefs.inQuietHours(context),
                currentSlotKey = due?.key,
                lastBuzzedSlotKey = HydrationReminderPrefs.lastStrapSlot(context),
            )
        ) return false

        // Claim before sending so two back-to-back live packets cannot double-fire the slot.
        HydrationReminderPrefs.markStrapSlot(context, checkNotNull(due).key)
        val cueIssued = runCatching { buzz(1); true }.getOrDefault(false)
        if (cueIssued && config.tapConfirmEnabled) {
            val nowMs = now.toInstant().toEpochMilli()
            val slot = checkNotNull(due).key
            TapAutomationStore.arm(
                context,
                PendingTapAutomation.create(
                    kind = TapAutomationKind.HYDRATION_CONFIRM,
                    value = config.tapAmountMl,
                    contextKey = slot,
                    nowMs = nowMs,
                    windowMinutes = config.tapWindowMinutes,
                ),
                nowMs,
            )
            if (config.bandFirst && config.enabled) {
                HydrationReminderEscalationScheduler.schedule(
                    context,
                    slot,
                    config.tapWindowMinutes,
                )
            }
        }
        return cueIssued
    }
}
