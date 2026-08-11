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
import com.noop.R
import com.noop.ble.LiveState
import com.noop.ui.NotifPrefs
import com.noop.ui.appLaunchIntent
import android.app.PendingIntent
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
    private const val STRAP_BUZZ = "hydration.reminders.strapBuzz"
    private const val LAST_NOTIFICATION_SLOT = "hydration.reminders.lastNotificationSlot"
    private const val LAST_STRAP_SLOT = "hydration.reminders.lastStrapSlot"

    data class Config(
        val enabled: Boolean,
        val intervalMinutes: Int,
        val startMinutes: Int,
        val endMinutes: Int,
        val strapBuzzEnabled: Boolean,
    )

    private fun prefs(context: Context) = context.applicationContext
        .getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun config(context: Context): Config = Config(
        enabled = prefs(context).getBoolean(ENABLED, false),
        intervalMinutes = HydrationReminderPolicy.clampIntervalMinutes(
            prefs(context).getInt(INTERVAL, HydrationReminderPolicy.DEFAULT_INTERVAL_MINUTES),
        ),
        startMinutes = HydrationReminderPolicy.clampMinuteOfDay(
            prefs(context).getInt(START, HydrationReminderPolicy.DEFAULT_START_MINUTES),
        ),
        endMinutes = HydrationReminderPolicy.clampMinuteOfDay(
            prefs(context).getInt(END, HydrationReminderPolicy.DEFAULT_END_MINUTES),
        ),
        strapBuzzEnabled = prefs(context).getBoolean(STRAP_BUZZ, false),
    )

    fun setEnabled(context: Context, enabled: Boolean) =
        prefs(context).edit().putBoolean(ENABLED, enabled).apply()

    fun setIntervalMinutes(context: Context, minutes: Int) = prefs(context).edit()
        .putInt(INTERVAL, HydrationReminderPolicy.clampIntervalMinutes(minutes)).apply()

    fun setStartMinutes(context: Context, minutes: Int) = prefs(context).edit()
        .putInt(START, HydrationReminderPolicy.clampMinuteOfDay(minutes)).apply()

    fun setEndMinutes(context: Context, minutes: Int) = prefs(context).edit()
        .putInt(END, HydrationReminderPolicy.clampMinuteOfDay(minutes)).apply()

    fun setStrapBuzzEnabled(context: Context, enabled: Boolean) =
        prefs(context).edit().putBoolean(STRAP_BUZZ, enabled).apply()

    internal fun lastNotificationSlot(context: Context): String? =
        prefs(context).getString(LAST_NOTIFICATION_SLOT, null)

    internal fun markNotificationSlot(context: Context, slot: String) =
        prefs(context).edit().putString(LAST_NOTIFICATION_SLOT, slot).apply()

    internal fun lastStrapSlot(context: Context): String? =
        prefs(context).getString(LAST_STRAP_SLOT, null)

    internal fun markStrapSlot(context: Context, slot: String) =
        prefs(context).edit().putString(LAST_STRAP_SLOT, slot).apply()
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
            return
        }
        scheduleNext(appContext, ZonedDateTime.now(), ExistingWorkPolicy.REPLACE)
    }

    internal fun scheduleNext(
        context: Context,
        now: ZonedDateTime,
        existingWorkPolicy: ExistingWorkPolicy,
    ) {
        val config = HydrationReminderPrefs.config(context)
        if (!config.enabled) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            return
        }
        val next = HydrationReminderPolicy.nextSlot(
            epochDay = now.toLocalDate().toEpochDay(),
            minuteOfDay = now.hour * 60 + now.minute,
            startMinutes = config.startMinutes,
            endMinutes = config.endMinutes,
            intervalMinutes = config.intervalMinutes,
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
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            WORK_NAME,
            existingWorkPolicy,
            request,
        )
    }
}

class HydrationReminderWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val config = HydrationReminderPrefs.config(applicationContext)
        if (!config.enabled) return Result.success()

        val now = ZonedDateTime.now()
        val due = HydrationReminderPolicy.latestDueSlot(
            epochDay = now.toLocalDate().toEpochDay(),
            minuteOfDay = now.hour * 60 + now.minute,
            startMinutes = config.startMinutes,
            endMinutes = config.endMinutes,
            intervalMinutes = config.intervalMinutes,
        )
        if (HydrationReminderPolicy.shouldNotify(
                enabled = config.enabled,
                currentSlotKey = due?.key,
                lastNotifiedSlotKey = HydrationReminderPrefs.lastNotificationSlot(applicationContext),
            ) && HydrationReminderNotifier.post(applicationContext)
        ) {
            HydrationReminderPrefs.markNotificationSlot(applicationContext, checkNotNull(due).key)
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

object HydrationReminderNotifier {
    private const val CHANNEL_ID = "noop_hydration_reminders"
    private const val NOTIFICATION_ID = 4214

    @SuppressLint("MissingPermission")
    internal fun post(context: Context): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return false
        ensureChannel(context)
        val title = context.getString(R.string.l10n_hydration_reminders_hydration_check_in_f93a58b5)
        val body = context.getString(R.string.l10n_hydration_reminders_take_a_moment_to_drink_some_6a03f36a)
        val openApp = PendingIntent.getActivity(
            context,
            14,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
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
        manager.notify(NOTIFICATION_ID, notification)
        true
    }.getOrDefault(false)

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
        val config = HydrationReminderPrefs.config(context)
        val due = HydrationReminderPolicy.latestDueSlot(
            epochDay = now.toLocalDate().toEpochDay(),
            minuteOfDay = now.hour * 60 + now.minute,
            startMinutes = config.startMinutes,
            endMinutes = config.endMinutes,
            intervalMinutes = config.intervalMinutes,
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
        return runCatching { buzz(1); true }.getOrDefault(false)
    }
}
