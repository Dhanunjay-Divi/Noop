package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.DailyEffortGuidance
import com.noop.ui.NoopPrefs
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge
import java.time.LocalDate
import kotlin.math.roundToInt

// MARK: - Target-strain notification (#593)
//
// A single opt-in, default-OFF informational nudge: once per day, when canonical 0-100 Effort reaches the
// LOW end of DailyActionPlanner's evidence-gated personal range, post an informational
// "Effort marker reached" notification.
//
// CLEAN-ROOM: this reimplements the BEHAVIOUR only. The copy is NOOP's own — NOT WHOOP's decompiled
// strings — and the target is NOOP's own personal-history planner output, not another app's value.
//
// It is NOT "the instant" you cross the target - daily Effort is a per-analytics-pass rollup, so it fires
// on the first pass at/after the crossing. Once-per-day dedupe via a persisted day flag, the same
// crossing-dedupe idiom as ScheduledReportPolicy / BatteryAlertPolicy. Default OFF like every automation.

/** Pure, JVM-testable policy + copy for the target-strain notification — no Android types, so the decision
 *  logic is pinned by StrainTargetPolicyTest independently of the notification plumbing. */
object StrainTargetPolicy {

    /** Fire at most once per local calendar day, only for that day's measured Effort and only when it is
     * within or above the planner's complete range. An unavailable result means the planner withheld the
     * range or the current value is not trustworthy, so the policy fails closed. */
    fun shouldNotify(
        enabled: Boolean,
        guidance: DailyEffortGuidance.Result,
        dataDay: String,
        currentLocalDay: String,
        lastNotifiedDay: String?,
    ): Boolean = enabled &&
        dataDay == currentLocalDay &&
        lastNotifiedDay != currentLocalDay &&
        (guidance.state == DailyEffortGuidance.State.IN_RANGE ||
            guidance.state == DailyEffortGuidance.State.ABOVE_RANGE)
}

object StrainTargetNotifier {
    // Reuse the daily-reports channel the scheduled reports post to (same family, same importance).
    private const val CHANNEL_ID = "noop_scheduled_reports"

    /**
     * Post the range nudge if enabled and not already posted [day]. [dayEffort]/[targetRange] are both
     * canonical 0-100 Effort. No-op on every path that fails the policy, so the caller can invoke it on
     * every days-collector publication.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onStrainTarget(
        context: Context,
        day: String,
        dayEffort: Double?,
        targetRange: DailyActionPlanner.EffortRange?,
    ) {
        val currentLocalDay = LocalDate.now().toString()
        val guidance = DailyEffortGuidance.evaluate(dayEffort, targetRange)
        if (!StrainTargetPolicy.shouldNotify(
                enabled = NoopPrefs.strainTargetEnabled(context),
                guidance = guidance,
                dataDay = day,
                currentLocalDay = currentLocalDay,
                lastNotifiedDay = NoopPrefs.reportStrainTargetDay(context),
            )
        ) return
        val current = guidance.current ?: return
        val range = guidance.range ?: return
        val title = context.getString(R.string.daily_plan_notification_title)
        val body = context.getString(
            R.string.daily_plan_notification_body,
            current.roundToInt(),
            range.lower,
            range.upper,
        )
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.STRAIN_TARGET,
                    NotificationLifecycleCategory.STATUS,
                )
                return
            }
            ensureChannel(context)
            if (!post(
                    context,
                    NotificationPlatformIdentity.NotificationId.STRAIN_TARGET,
                    title,
                    body,
                )
            ) return
            // Mark fired only after a successful post, so a notifications-disabled day still notifies once
            // they're re-enabled while the same day still shows the reached target.
            NoopPrefs.setReportStrainTargetDay(context, currentLocalDay)
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.STRAIN_TARGET,
                NotificationLifecycleCategory.STATUS,
            )
        }
    }

    @SuppressLint("MissingPermission")
    private fun post(context: Context, id: Int, title: String, body: String): Boolean {
        val openApp = NotificationPlatformIdentity.activityPendingIntent(
            context,
            NotificationPlatformIdentity.ActivityIntent.STRAIN_TARGET,
            NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.TODAY),
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
        return NotificationLifecycleLedger.posted(
            context,
            NotificationLifecycleId.STRAIN_TARGET,
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
