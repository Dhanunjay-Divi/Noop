package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent

// MARK: - Target-strain notification (#593)
//
// A single opt-in, default-OFF informational nudge: once per day, when canonical 0-100 Effort reaches the
// LOW end of DailyActionPlanner's evidence-gated personal range, post an informational
// "Effort marker reached" notification.
//
// CLEAN-ROOM: this reimplements the BEHAVIOUR only. The copy is NOOP's own — NOT WHOOP's decompiled
// strings — and the target is NOOP's own personal-history planner output, not another app's value.
//
// It is NOT "the instant" you cross the target — daily Effort is a per-analytics-pass rollup, so it fires
// on the first pass at/after the crossing. Once-per-day dedupe via a persisted day flag, the same
// crossing-dedupe idiom as ScheduledReportPolicy / BatteryAlertPolicy. Default OFF like every automation.

/** Pure, JVM-testable policy + copy for the target-strain notification — no Android types, so the decision
 *  logic is pinned by StrainTargetPolicyTest independently of the notification plumbing. */
object StrainTargetPolicy {

    /** Fire at most once per day: only when enabled, BOTH the day strain and the target are known, the day
     *  strain has reached the target, and we haven't already posted for [today]. [dayStrain] and [target]
     *  must be on the SAME canonical 0-100 axis. A null target means the planner withheld the range
     *  (unanswered check-in, stale/thin evidence, or recovery shift) ⇒ never fires. */
    fun shouldNotify(
        enabled: Boolean,
        dayStrain: Double?,
        target: Double?,
        lastNotifiedDay: String?,
        today: String,
    ): Boolean = enabled &&
        dayStrain != null && target != null &&
        dayStrain >= target &&
        lastNotifiedDay != today

    /** Title + body for the nudge. [target] is the marker on canonical 0-100 Effort. The wording
     *  deliberately avoids "optimal", "earned", or permission-to-push claims. */
    fun copy(target: Int): Pair<String, String> {
        val title = "Effort marker reached"
        val body = "You've reached today's Effort marker of $target. It is a planning cue, not a limit—" +
            "check how you feel before adding more."
        return title to body
    }
}

object StrainTargetNotifier {
    // Reuse the daily-reports channel the scheduled reports post to (same family, same importance).
    private const val CHANNEL_ID = "noop_scheduled_reports"
    // #297: distinct id so this never silently replaces another notifier's (4208 morning, 4209 workout).
    private const val STRAIN_TARGET_NOTIF_ID = 4210

    /**
     * Post the marker nudge if enabled and not already posted [day]. [dayEffort]/[targetEffort] are both
     * canonical 0-100 Effort. No-op on every path that fails the policy, so the caller can invoke it on
     * every days-collector publication.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onStrainTarget(context: Context, day: String, dayEffort: Double?, targetEffort: Int?) {
        if (!StrainTargetPolicy.shouldNotify(
                enabled = NoopPrefs.strainTargetEnabled(context),
                dayStrain = dayEffort,
                target = targetEffort?.toDouble(),
                lastNotifiedDay = NoopPrefs.reportStrainTargetDay(context),
                today = day,
            )
        ) return
        // Non-null: shouldNotify above required target != null before returning true.
        val copy = StrainTargetPolicy.copy(targetEffort!!)
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            post(context, STRAIN_TARGET_NOTIF_ID, copy.first, copy.second)
            // Mark fired only after a successful post, so a notifications-disabled day still notifies once
            // they're re-enabled while the same day still shows the reached target.
            NoopPrefs.setReportStrainTargetDay(context, day)
        }
    }

    @SuppressLint("MissingPermission")
    private fun post(context: Context, id: Int, title: String, body: String) {
        val openApp = PendingIntent.getActivity(
            context, 3,
            appLaunchIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        NotificationManagerCompat.from(context).notify(id, n)
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
                    description = "A morning recap and post-workout summary, after your strap syncs."
                },
            )
        }
    }
}
