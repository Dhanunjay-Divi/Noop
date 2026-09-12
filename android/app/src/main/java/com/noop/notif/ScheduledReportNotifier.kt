package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent
import kotlin.math.roundToInt

/**
 * One completed sync can materialize several routine prompts at once. The first eligible lane owns
 * this process-local budget; lower lanes keep their persisted frontiers untouched and may retry later.
 * Safety paging and active-workout cautions deliberately bypass this budget.
 */
class PostSyncRoutineNotificationBudget {
    enum class Lane(val storageKey: String) {
        AUTO_WORKOUT("auto_workout"),
        ADAPTIVE_DAY("adaptive_day"),
        POST_WORKOUT_SUMMARY("post_workout_summary"),
        MORNING_RECAP("morning_recap"),
    }

    private var claimed: Lane? = null
    private var reserved: Lane? = null

    @get:Synchronized
    val claimedLane: Lane?
        get() = claimed

    @get:Synchronized
    val isClaimed: Boolean
        get() = claimed != null

    @Synchronized
    fun reserve(lane: Lane): Boolean {
        if (claimed != null || reserved != null) return false
        reserved = lane
        return true
    }

    @Synchronized
    fun commit(lane: Lane): Boolean {
        if (claimed != null || reserved != lane) return false
        reserved = null
        claimed = lane
        return true
    }

    @Synchronized
    fun release(lane: Lane) {
        if (reserved == lane) reserved = null
    }

    @Synchronized
    fun claim(lane: Lane): Boolean = reserve(lane) && commit(lane)
}

// MARK: - Scheduled report notifications (#517)
//
// Two opt-in, default-OFF system notifications, no AI involved:
//   1. A MORNING RECAP once a fresh night has been processed.
//   2. A POST-WORKOUT REMINDER when a newly synced workout is first seen.
//
// Neither is alarm-precise: NOOP reads the strap over BLE and scores on a ~15-minute analytics pass, so a
// report lands when the next sync + pass completes — NOT the instant you wake or finish a session. The copy
// is honest about that timing ("after your strap synced"). Everything is on-device.
//
// The pure [ScheduledReportPolicy] + the copy builders are JVM-testable (the CallAlertPolicy idiom); the
// notifier wires them to a real channel + the persisted dedupe markers in NoopPrefs. Call sites:
//   - morning recap: the BLE post-offload scorer, only after its database transaction succeeds.
//   - post-workout: after loadWorkouts(), when the newest workout start-ts is newer than the last fired.
// Both gates survive process death, so the app-open and (future) background call sites can't double-post.

/** Pure, JVM-testable policy + copy for the scheduled reports — no Android types, so the logic is pinned
 *  by ScheduledReportPolicyTest independently of the notification plumbing. */
object ScheduledReportPolicy {

    /** Fire the morning recap at most once per REPORTED NIGHT: only when enabled, a recap value exists, and
     *  we haven't already posted for [reportDay]. [reportDay] is the day of the banked night the recap is
     *  FOR (the resolved today-row's `day`), NOT the phone's calendar day — keying on the calendar day made
     *  it re-fire at midnight for anyone up late, since the row still resolves to last night's until a new
     *  night is banked (#567). */
    fun shouldNotifyMorning(
        enabled: Boolean,
        materializedAfterSync: Boolean,
        chargeOrRestPresent: Boolean,
        lastNotifiedDay: String?,
        reportDay: String,
    ): Boolean = enabled && materializedAfterSync && chargeOrRestPresent && lastNotifiedDay != reportDay

    /** Fire the post-workout summary only for a workout STRICTLY newer than the last one summarised, so a
     *  re-sync of the same backlog never re-notifies. [lastWorkoutTs] is 0 before the first ever. */
    fun shouldNotifyWorkout(
        enabled: Boolean,
        newestWorkoutTs: Long?,
        lastWorkoutTs: Long,
    ): Boolean = enabled && newestWorkoutTs != null && newestWorkoutTs > lastWorkoutTs

    /** Privacy-safe title + body for the morning recap. The score arguments are used only as the honest
     *  availability gate: lock-screen copy never includes biometric values. Returns null when neither
     *  Recovery nor Sleep Score is present. */
    fun morningCopy(chargePct: Int?, restPct: Int?): Pair<String, String>? {
        if (chargePct == null && restPct == null) return null
        return "Your morning recap is ready" to
            "Open NOOP to review your Recovery and Sleep Score."
    }

    /** Privacy-safe title + body for the post-workout summary. Detailed inputs stay available to the
     *  in-app report, but none are rendered in notification text. */
    @Suppress("UNUSED_PARAMETER")
    fun workoutCopy(
        sportLabel: String,
        effortDisplay: String,
        effortMaxLabel: String,
        durationLabel: String,
        avgHr: Int?,
    ): Pair<String, String> = workoutReminderCopy()

    internal fun workoutReminderCopy(): Pair<String, String> =
        "Your workout summary is ready" to
            "Open NOOP to review your Effort, duration and heart-rate summary."

    /** "42 min" / "1 h 8 min" from a whole-minute duration; clamps a 0/negative span to "under a minute"
     *  so a mis-timed session never reads as "0 min". */
    fun durationLabel(minutes: Int): String = when {
        minutes <= 0 -> "under a minute"
        minutes < 60 -> "$minutes min"
        minutes % 60 == 0 -> "${minutes / 60} h"
        else -> "${minutes / 60} h ${minutes % 60} min"
    }
}

object ScheduledReportNotifier {
    private const val CHANNEL_ID = "noop_scheduled_reports"

    /**
     * Post the morning recap if enabled and not already posted today. [chargePct]/[restPct] are the
     * just-computed Recovery/Sleep Score for the night (either may be null). They gate availability but
     * are never placed in notification text. No-op on every path that fails the policy.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onMorning(
        context: Context,
        reportDay: String,
        chargePct: Int?,
        restPct: Int?,
        materializedAfterSync: Boolean,
        budget: PostSyncRoutineNotificationBudget? = null,
    ): Boolean {
        // reportDay is the banked night's day (the resolved today-row's `day`), NOT LocalDate.now() — the
        // calendar day rolls at midnight while the row still resolves to last night's until a new night is
        // banked, which re-fired the recap at the start of a new day for late-nighters (#567).
        if (!ScheduledReportPolicy.shouldNotifyMorning(
                enabled = NoopPrefs.morningReportEnabled(context),
                materializedAfterSync = materializedAfterSync,
                chargeOrRestPresent = chargePct != null || restPct != null,
                lastNotifiedDay = NoopPrefs.reportMorningDay(context),
                reportDay = reportDay,
            )
        ) return false
        val copy = ScheduledReportPolicy.morningCopy(chargePct, restPct) ?: return false
        val lane = PostSyncRoutineNotificationBudget.Lane.MORNING_RECAP
        var reserved = false
        return runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.MORNING_REPORT,
                    NotificationLifecycleCategory.STATUS,
                )
                return@runCatching false
            }
            ensureChannel(context)
            if (budget?.reserve(lane) == false) {
                return@runCatching false
            }
            reserved = budget != null
            if (!post(
                    context,
                    NotificationPlatformIdentity.NotificationId.MORNING_REPORT,
                    NotificationPlatformIdentity.ActivityIntent.MORNING_REPORT,
                    NotificationLifecycleId.MORNING_REPORT,
                    copy.first,
                    copy.second,
                )
            ) {
                budget?.release(lane)
                reserved = false
                return@runCatching false
            }
            if (budget != null && !budget.commit(lane)) {
                cancelMorning(context)
                budget.release(lane)
                reserved = false
                return@runCatching false
            }
            reserved = false
            // Mark fired only after a successful post, so a notifications-disabled night still notifies
            // once they're re-enabled while the same night's row is showing.
            NoopPrefs.setReportMorningDay(context, reportDay)
            true
        }.onFailure {
            if (reserved) budget?.release(lane)
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.MORNING_REPORT,
                NotificationLifecycleCategory.STATUS,
            )
        }.getOrElse { false }
    }

    /**
     * Post a privacy-safe workout reminder for [newestWorkoutTs] if it's strictly newer than the last
     * summarised. Legacy [title]/[body] parameters remain for source compatibility, but the final posting
     * boundary deliberately replaces them with generic copy. No-op when disabled or the workout isn't new.
     */
    @SuppressLint("MissingPermission")
    @Suppress("UNUSED_PARAMETER")
    fun onWorkout(
        context: Context,
        newestWorkoutTs: Long?,
        title: String,
        body: String,
        budget: PostSyncRoutineNotificationBudget? = null,
    ): Boolean {
        if (NoopPrefs.postWorkoutReportEnabled(context) &&
            !NoopPrefs.reportWorkoutFrontierInitialized(context)
        ) {
            // Upgrade/process-order safety: an enabled preference without the companion frontier came
            // from an older build. Snapshot existing history silently instead of announcing an old row.
            seedWorkoutFrontier(context, newestWorkoutTs)
            return false
        }
        if (!ScheduledReportPolicy.shouldNotifyWorkout(
                enabled = NoopPrefs.postWorkoutReportEnabled(context),
                newestWorkoutTs = newestWorkoutTs,
                lastWorkoutTs = NoopPrefs.reportLastWorkoutTs(context),
            )
        ) return false
        val lane = PostSyncRoutineNotificationBudget.Lane.POST_WORKOUT_SUMMARY
        var reserved = false
        return runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.WORKOUT_REPORT,
                    NotificationLifecycleCategory.STATUS,
                )
                return@runCatching false
            }
            ensureChannel(context)
            if (budget?.reserve(lane) == false) {
                return@runCatching false
            }
            reserved = budget != null
            // Enforce redaction at the final posting boundary too. One caller can produce a lean
            // no-Effort summary without going through workoutCopy(); it must not leak duration, HR,
            // sport, or another health detail onto the lock screen.
            val privateCopy = ScheduledReportPolicy.workoutReminderCopy()
            if (!post(
                    context,
                    NotificationPlatformIdentity.NotificationId.WORKOUT_REPORT,
                    NotificationPlatformIdentity.ActivityIntent.WORKOUT_REPORT,
                    NotificationLifecycleId.WORKOUT_REPORT,
                    privateCopy.first,
                    privateCopy.second,
                )
            ) {
                budget?.release(lane)
                reserved = false
                return@runCatching false
            }
            if (budget != null && !budget.commit(lane)) {
                cancelWorkout(context)
                budget.release(lane)
                reserved = false
                return@runCatching false
            }
            reserved = false
            newestWorkoutTs?.let { NoopPrefs.setReportLastWorkoutTs(context, it) }
            true
        }.onFailure {
            if (reserved) budget?.release(lane)
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.WORKOUT_REPORT,
                NotificationLifecycleCategory.STATUS,
            )
        }.getOrElse { false }
    }

    /**
     * Seed the post-workout frontier to the current newest workout WITHOUT notifying — called once when the
     * user first enables the toggle, so turning it on doesn't immediately fire a summary for an old session
     * already in history. Explicit re-enabling replaces a stale/future marker with the current snapshot.
     */
    fun seedWorkoutFrontier(context: Context, newestWorkoutTs: Long?) {
        NoopPrefs.setReportLastWorkoutTs(context, newestWorkoutTs ?: 0L)
        NoopPrefs.setReportWorkoutFrontierInitialized(context, true)
    }

    fun cancelMorning(context: Context) {
        cancel(
            context,
            NotificationPlatformIdentity.NotificationId.MORNING_REPORT,
            NotificationLifecycleId.MORNING_REPORT,
        )
    }

    fun cancelWorkout(context: Context) {
        cancel(
            context,
            NotificationPlatformIdentity.NotificationId.WORKOUT_REPORT,
            NotificationLifecycleId.WORKOUT_REPORT,
        )
    }

    private fun cancel(context: Context, id: Int, lifecycleId: String) {
        NotificationLifecycleLedger.cancelled(
            context,
            lifecycleId,
            NotificationLifecycleCategory.STATUS,
        ) {
            NotificationManagerCompat.from(context).cancel(id)
        }
    }

    @SuppressLint("MissingPermission")
    private fun post(
        context: Context,
        id: Int,
        activityIdentity: NotificationPlatformIdentity.ActivityIntentIdentity,
        lifecycleId: String,
        title: String,
        body: String,
    ): Boolean {
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            activityIdentity,
            appLaunchIntent(context),
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .protectPrivateContent(context, CHANNEL_ID)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        return NotificationLifecycleLedger.posted(
            context,
            lifecycleId,
            NotificationLifecycleCategory.STATUS,
        ) {
            NotificationManagerCompat.from(context).notify(id, n)
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Daily reports",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "A morning recap and post-workout summary after Noop Band syncs."
                },
            )
        }
    }
}

/** Round a 0–100 score to a whole number for display, or null if absent (never fabricate a 0). */
internal fun Double?.scorePctOrNull(): Int? = this?.roundToInt()
