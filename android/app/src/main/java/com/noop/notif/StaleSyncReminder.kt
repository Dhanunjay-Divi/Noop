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
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NoopPrefs
import com.noop.ui.NotificationRouteBridge
import java.util.UUID
import java.util.concurrent.TimeUnit

internal object StaleSyncReminderPolicy {
    const val DELAY_HOURS = 2L
    const val DELAY_SECONDS = DELAY_HOURS * 60L * 60L

    fun dueAction(
        appBackgrounded: Boolean,
        hasPairedBand: Boolean,
        notificationsAuthorized: Boolean,
        expectedGeneration: String,
        currentGeneration: String?,
        baselineFreshnessAt: Long,
        currentFreshnessAt: Long,
        nowEpochSeconds: Long,
    ): StaleSyncReminderDueAction {
        if (!appBackgrounded ||
            !hasPairedBand ||
            !notificationsAuthorized ||
            expectedGeneration.isBlank() ||
            expectedGeneration != currentGeneration
        ) {
            return StaleSyncReminderDueAction.Suppress
        }
        if (currentFreshnessAt <= baselineFreshnessAt) {
            return StaleSyncReminderDueAction.Post
        }

        val secondsSinceProgress = (nowEpochSeconds - currentFreshnessAt).coerceAtLeast(0L)
        val remaining = DELAY_SECONDS - secondsSinceProgress
        return if (remaining <= 0L) {
            StaleSyncReminderDueAction.Post
        } else {
            StaleSyncReminderDueAction.Rearm(
                baselineFreshnessAt = currentFreshnessAt,
                delaySeconds = remaining,
            )
        }
    }
}

internal sealed class StaleSyncReminderDueAction {
    object Suppress : StaleSyncReminderDueAction()
    object Post : StaleSyncReminderDueAction()
    data class Rearm(
        val baselineFreshnessAt: Long,
        val delaySeconds: Long,
    ) : StaleSyncReminderDueAction()
}

private object StaleSyncReminderState {
    private const val PREFS = "noop_stale_sync_reminder"
    private const val BACKGROUNDED = "backgrounded"
    private const val GENERATION = "generation"
    private const val BASELINE_FRESHNESS = "baseline_freshness"
    private const val NOTIFICATION_POSTED = "notification_posted"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isBackgrounded(context: Context): Boolean =
        prefs(context).getBoolean(BACKGROUNDED, false)

    fun generation(context: Context): String? =
        prefs(context).getString(GENERATION, null)

    fun isArmed(context: Context): Boolean = generation(context) != null

    fun consumePosted(context: Context): Boolean {
        val preferences = prefs(context)
        val posted = preferences.getBoolean(NOTIFICATION_POSTED, false)
        if (posted) preferences.edit().remove(NOTIFICATION_POSTED).commit()
        return posted
    }

    fun markPosted(context: Context) {
        prefs(context).edit().putBoolean(NOTIFICATION_POSTED, true).commit()
    }

    fun markBackgrounded(context: Context, backgrounded: Boolean) {
        prefs(context).edit().putBoolean(BACKGROUNDED, backgrounded).commit()
    }

    fun arm(context: Context, generation: String, baselineFreshnessAt: Long) {
        prefs(context).edit()
            .putString(GENERATION, generation)
            .putLong(BASELINE_FRESHNESS, baselineFreshnessAt.coerceAtLeast(0L))
            .commit()
    }

    fun disarm(context: Context, expectedGeneration: String? = null): Boolean {
        val preferences = prefs(context)
        val current = preferences.getString(GENERATION, null)
        if (expectedGeneration != null && current != expectedGeneration) return false
        if (current == null) return false
        preferences.edit()
            .remove(GENERATION)
            .remove(BASELINE_FRESHNESS)
            .commit()
        return true
    }
}

/**
 * Two-hour, best-effort reminder for a paired band whose background history has stopped advancing.
 *
 * WorkManager survives normal task dismissal and process death. Android may defer execution under Doze,
 * and a user-issued Force stop disables all app work until the next launch.
 */
object StaleSyncReminderScheduler {
    private const val WORK_NAME = "noop_stale_band_sync"
    private const val INPUT_GENERATION = "generation"
    private const val INPUT_BASELINE_FRESHNESS = "baseline_freshness"

    fun onAppBackgrounded(context: Context) {
        val app = context.applicationContext
        StaleSyncReminderState.markBackgrounded(app, true)
        scheduleIfEligible(app)
    }

    fun onAppForegrounded(context: Context) {
        val app = context.applicationContext
        StaleSyncReminderState.markBackgrounded(app, false)
        val hadPendingReminder = StaleSyncReminderState.disarm(app)
        val hadPostedReminder = StaleSyncReminderState.consumePosted(app)
        if (hadPendingReminder || hadPostedReminder) cancelPlatformState(app)
    }

    /**
     * Persist every durable advance. Keep the existing WorkManager countdown alive: if this process dies
     * before the burst settles, that worker will rearm itself from this timestamp instead of losing the
     * two-hour reminder. Only a previously delivered stale banner needs immediate removal.
     */
    fun onSyncProgress(
        context: Context,
        progressedAtEpochSeconds: Long = System.currentTimeMillis() / 1_000L,
    ) {
        val app = context.applicationContext
        NoopPrefs.setLastSyncWriteAt(app, progressedAtEpochSeconds)
        if (!StaleSyncReminderState.isBackgrounded(app)) return
        if (StaleSyncReminderState.consumePosted(app)) {
            cancelDeliveredNotification(app)
        }
        if (!StaleSyncReminderState.isArmed(app)) {
            scheduleIfEligible(app)
        }
    }

    /** A completed/settled burst starts a fresh two-hour window from its latest durable state. */
    fun onSyncSettled(context: Context) {
        val app = context.applicationContext
        if (StaleSyncReminderState.isBackgrounded(app)) scheduleIfEligible(app)
    }

    internal fun dueAction(
        context: Context,
        expectedGeneration: String,
        baselineFreshnessAt: Long,
        nowEpochSeconds: Long = System.currentTimeMillis() / 1_000L,
    ): StaleSyncReminderDueAction {
        val app = context.applicationContext
        return StaleSyncReminderPolicy.dueAction(
            appBackgrounded = StaleSyncReminderState.isBackgrounded(app),
            hasPairedBand = NoopPrefs.lastDevice(app) != null,
            notificationsAuthorized = canNotify(app),
            expectedGeneration = expectedGeneration,
            currentGeneration = StaleSyncReminderState.generation(app),
            baselineFreshnessAt = baselineFreshnessAt,
            currentFreshnessAt = NoopPrefs.syncFreshnessAt(app),
            nowEpochSeconds = nowEpochSeconds,
        )
    }

    internal fun stillCurrent(
        context: Context,
        expectedGeneration: String,
        baselineFreshnessAt: Long,
    ): Boolean =
        dueAction(context, expectedGeneration, baselineFreshnessAt) ===
            StaleSyncReminderDueAction.Post

    internal fun rearmAfterProgress(
        context: Context,
        expectedGeneration: String,
        action: StaleSyncReminderDueAction.Rearm,
    ): Boolean = scheduleIfEligible(
        context = context.applicationContext,
        baselineFreshnessAt = action.baselineFreshnessAt,
        initialDelaySeconds = action.delaySeconds,
        existingWorkPolicy = ExistingWorkPolicy.APPEND_OR_REPLACE,
        expectedGeneration = expectedGeneration,
    )

    internal fun complete(context: Context, expectedGeneration: String) {
        StaleSyncReminderState.disarm(context.applicationContext, expectedGeneration)
    }

    internal fun dismissPosted(context: Context) {
        val app = context.applicationContext
        if (StaleSyncReminderState.consumePosted(app)) {
            cancelDeliveredNotification(app)
        }
    }

    internal fun inputGeneration(data: Data): String =
        data.getString(INPUT_GENERATION).orEmpty()

    internal fun inputBaselineFreshness(data: Data): Long =
        data.getLong(INPUT_BASELINE_FRESHNESS, 0L)

    private fun scheduleIfEligible(
        context: Context,
        baselineFreshnessAt: Long = NoopPrefs.syncFreshnessAt(context),
        initialDelaySeconds: Long = StaleSyncReminderPolicy.DELAY_SECONDS,
        existingWorkPolicy: ExistingWorkPolicy = ExistingWorkPolicy.REPLACE,
        expectedGeneration: String? = null,
    ): Boolean {
        StaleSyncReminderNotifier.ensureChannel(context)
        if (expectedGeneration != null &&
            StaleSyncReminderState.generation(context) != expectedGeneration
        ) {
            return false
        }
        if (NoopPrefs.lastDevice(context) == null || !canNotify(context)) {
            if (StaleSyncReminderState.disarm(context, expectedGeneration)) {
                WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            }
            return false
        }

        val generation = UUID.randomUUID().toString()
        val input = Data.Builder()
            .putString(INPUT_GENERATION, generation)
            .putLong(INPUT_BASELINE_FRESHNESS, baselineFreshnessAt)
            .build()
        val request = OneTimeWorkRequestBuilder<StaleSyncReminderWorker>()
            .setInputData(input)
            .setInitialDelay(initialDelaySeconds.coerceAtLeast(1L), TimeUnit.SECONDS)
            .build()

        StaleSyncReminderState.arm(context, generation, baselineFreshnessAt)
        val scheduled = runCatching {
            NotificationLifecycleLedger.scheduled(
                context,
                NotificationLifecycleId.STALE_SYNC,
                NotificationLifecycleCategory.STATUS,
            ) {
                WorkManager.getInstance(context).enqueueUniqueWork(
                    WORK_NAME,
                    existingWorkPolicy,
                    request,
                )
            }
        }.getOrDefault(false)
        if (!scheduled) StaleSyncReminderState.disarm(context, generation)
        return scheduled
    }

    private fun cancelPlatformState(context: Context) {
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.STALE_SYNC,
            NotificationLifecycleCategory.STATUS,
        ) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            NotificationManagerCompat.from(context)
                .cancel(StaleSyncReminderNotifier.NOTIFICATION_ID)
        }
    }

    private fun cancelDeliveredNotification(context: Context) {
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.STALE_SYNC,
            NotificationLifecycleCategory.STATUS,
        ) {
            NotificationManagerCompat.from(context)
                .cancel(StaleSyncReminderNotifier.NOTIFICATION_ID)
        }
    }

    internal fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return false
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(StaleSyncReminderNotifier.CHANNEL_ID)
                    ?.importance == NotificationManager.IMPORTANCE_NONE
            ) return false
        }
        return true
    }
}

class StaleSyncReminderWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val generation = StaleSyncReminderScheduler.inputGeneration(inputData)
        val baselineFreshness = StaleSyncReminderScheduler.inputBaselineFreshness(inputData)
        when (val action = StaleSyncReminderScheduler.dueAction(
            applicationContext,
            generation,
            baselineFreshness,
        )) {
            StaleSyncReminderDueAction.Suppress -> {
                NotificationLifecycleLedger.suppressed(
                    applicationContext,
                    NotificationLifecycleId.STALE_SYNC,
                    NotificationLifecycleCategory.STATUS,
                )
                StaleSyncReminderScheduler.complete(applicationContext, generation)
                return Result.success()
            }
            is StaleSyncReminderDueAction.Rearm -> {
                StaleSyncReminderScheduler.rearmAfterProgress(
                    applicationContext,
                    generation,
                    action,
                )
                StaleSyncReminderScheduler.complete(applicationContext, generation)
                return Result.success()
            }
            StaleSyncReminderDueAction.Post -> Unit
        }

        val posted = StaleSyncReminderNotifier.post(applicationContext) {
            StaleSyncReminderScheduler.stillCurrent(
                applicationContext,
                generation,
                baselineFreshness,
            )
        }
        if (posted) StaleSyncReminderState.markPosted(applicationContext)
        when (val latest = StaleSyncReminderScheduler.dueAction(
            applicationContext,
            generation,
            baselineFreshness,
        )) {
            StaleSyncReminderDueAction.Suppress -> {
                if (posted) StaleSyncReminderScheduler.dismissPosted(applicationContext)
            }
            is StaleSyncReminderDueAction.Rearm -> {
                if (posted) StaleSyncReminderScheduler.dismissPosted(applicationContext)
                StaleSyncReminderScheduler.rearmAfterProgress(
                    applicationContext,
                    generation,
                    latest,
                )
            }
            StaleSyncReminderDueAction.Post -> Unit
        }
        StaleSyncReminderScheduler.complete(applicationContext, generation)
        return Result.success()
    }
}

internal object StaleSyncReminderNotifier {
    const val CHANNEL_ID = "noop_band_sync"
    const val NOTIFICATION_ID = NotificationPlatformIdentity.NotificationId.STALE_SYNC

    @SuppressLint("MissingPermission")
    fun post(context: Context, stillRelevant: () -> Boolean): Boolean = runCatching {
        ensureChannel(context)
        if (!StaleSyncReminderScheduler.canNotify(context) || !stillRelevant()) {
            NotificationLifecycleLedger.suppressed(
                context,
                NotificationLifecycleId.STALE_SYNC,
                NotificationLifecycleCategory.STATUS,
            )
            return false
        }
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.STALE_SYNC,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.TODAY),
        )
        val body = context.getString(R.string.stale_sync_notification_body)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(context.getString(R.string.stale_sync_notification_title))
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        if (!stillRelevant()) return false
        NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.STALE_SYNC,
            NotificationLifecycleCategory.STATUS,
        ) {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
    }.getOrElse {
        NotificationLifecycleLedger.unknown(
            context,
            NotificationLifecycleId.STALE_SYNC,
            NotificationLifecycleCategory.STATUS,
        )
        false
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID) ?: NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.stale_sync_notification_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        channel.name = context.getString(R.string.stale_sync_notification_channel_name)
        channel.description =
            context.getString(R.string.stale_sync_notification_channel_description)
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }
}
