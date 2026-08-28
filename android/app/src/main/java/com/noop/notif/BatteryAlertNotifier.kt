package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.ble.WhoopModel
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent

/**
 * Pure battery-alert decision logic so it's JVM-testable (IllnessAlertPolicy idiom). The two
 * `*Alerted` flags are PERSISTED state (NoopPrefs), so the decision survives process death — no
 * in-memory previous-pct crossing, which would re-fire on every 15↔14 jitter and reset on restart.
 *
 * A 25% re-arm band (hysteresis) means a battery hovering near 15% fires the low alert exactly once
 * per discharge cycle; the full alert re-arms only after the cell drops back below 100%.
 */
internal object BatteryAlertPolicy {
    const val LOW_THRESHOLD = 15
    const val LOW_REARM_ABOVE = 25
    const val FULL_THRESHOLD = 100

    data class Decision(
        val fireLow: Boolean,
        val fireFull: Boolean,
        val clearFull: Boolean,
        val newLowAlerted: Boolean,
        val newFullAlerted: Boolean,
    )

    /**
     * @param pct          current strap battery percentage (rounded to Int)
     * @param charging     charging state (null = unknown)
     * @param lowAlerted   persisted: has the low alert already fired this discharge cycle?
     * @param fullAlerted  persisted: has the full alert already fired since the last drop below 100?
     *
     * `clearFull` (#514): the strap was showing a "fully charged" notification and has now dropped
     * below 100% — the standing note is stale, so cancel it. It's exactly the full re-arm
     * transition (fullAlerted && pct < FULL_THRESHOLD), surfaced so the notifier can pull the
     * delivered full-charge notification by its id.
     */
    fun evaluate(pct: Int, charging: Boolean?, lowAlerted: Boolean, fullAlerted: Boolean): Decision {
        var low = lowAlerted
        var full = fullAlerted
        // The stale 100%-full note must be cleared the moment we re-arm below the full line.
        val clearFull = fullAlerted && pct < FULL_THRESHOLD
        // Re-arm (hysteresis) so jitter near a threshold can't re-fire. #80: re-arm ONLY on genuine recovery
        // (pct >= LOW_REARM_ABOVE), NOT on charging. The strap reports its charge bit only every ~8 min, so
        // it flickers true→null; re-arming on `true` then firing on the `null` gap re-fired the low alert
        // repeatedly WHILE charging. `fireLow`'s `charging != true` still suppresses an explicit charging
        // reading, and a null-charging strap (generic/FTMS) still alerts.
        if (pct >= LOW_REARM_ABOVE) low = false
        if (pct < FULL_THRESHOLD) full = false
        // Fire at most once per genuine crossing.
        val fireLow = !low && pct <= LOW_THRESHOLD && charging != true
        val fireFull = !full && pct >= FULL_THRESHOLD
        if (fireLow) low = true
        if (fireFull) full = true
        return Decision(fireLow, fireFull, clearFull, low, full)
    }
}

/**
 * Posts battery-state alerts — low battery (≤15%) and charge-complete (100%) — as real system
 * notifications. Mirrors [IllnessAlertNotifier]'s pattern: called from WhoopConnectionService on
 * every live-state update, gated behind a user setting and the OS notification permission. The
 * once-per-crossing dedupe lives in [BatteryAlertPolicy] over two persisted NoopPrefs flags.
 *
 * With thanks to @ujix (#368) for the original notification copy and channel.
 */
object BatteryAlertNotifier {
    private const val CHANNEL_ID = "noop_battery_alert"

    /**
     * Predictive twin of [onBatteryUpdate]: run the runtime estimate against
     * [com.noop.analytics.BatteryEstimator.runtimeAlert] (fire ≤24 h, re-arm ≥36 h — a runtime
     * threshold gives the same warning lead time on a 4.0 and a 5.0/MG, which a fixed SoC line
     * can't) and post at most one notification per discharge cycle. The 15% SoC alert stays as the
     * safety net for straps with no usable estimate (null skips here). Same gating discipline as
     * #368: persisted flag advances even when delivery is deferred; no-ops when battery alerts are
     * off. iOS/macOS twin: BatteryNotifier.onRuntimeEstimate.
     */
    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onRuntimeEstimate(context: Context, remainingHours: Double?, charging: Boolean?) {
        if (remainingHours == null) return
        if (!NoopPrefs.batteryAlerts(context)) return
        if (!NoopPrefs.predictiveBatteryAlerts(context)) return
        runCatching {
            val decision = com.noop.analytics.BatteryEstimator.runtimeAlert(
                remainingHours = remainingHours,
                charging = charging,
                alerted = NoopPrefs.batteryRuntimeAlerted(context),
            )
            // ALWAYS persist the updated gate — re-arming must stick even when nothing fired.
            NoopPrefs.setBatteryRuntimeAlerted(context, decision.newAlerted)
            if (!decision.fire) return
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.BATTERY_RUNTIME,
                    NotificationLifecycleCategory.STATUS,
                )
                return
            }
            ensureChannel(context)
            val label = com.noop.analytics.BatteryEstimator.label(remainingHours)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle("Noop Band battery low")
                .setContentText("$label left on your ${WhoopModel.CUSTOMER_NAME} - recharge tonight.")
                .setContentIntent(
                    openAppIntent(
                        context,
                        NotificationPlatformIdentity.ActivityIntent.BATTERY_RUNTIME,
                    ),
                )
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()
            NotificationLifecycleLedger.posted(
                context,
                NotificationLifecycleId.BATTERY_RUNTIME,
                NotificationLifecycleCategory.STATUS,
            ) {
                NotificationManagerCompat.from(context).notify(
                    NotificationPlatformIdentity.NotificationId.BATTERY_RUNTIME,
                    n,
                )
            }
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.BATTERY_RUNTIME,
                NotificationLifecycleCategory.STATUS,
            )
        }
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    fun onBatteryUpdate(context: Context, currPct: Int?, charging: Boolean?) {
        if (currPct == null) return
        if (!NoopPrefs.batteryAlerts(context)) return
        // Defensive: never let a notify() throw (revoked POST_NOTIFICATIONS, OEM quirk) crash a collector.
        runCatching {
            val decision = BatteryAlertPolicy.evaluate(
                pct = currPct,
                charging = charging,
                lowAlerted = NoopPrefs.batteryLowAlerted(context),
                fullAlerted = NoopPrefs.batteryFullAlerted(context),
            )
            // Persist before any permission/posting return. Otherwise a successful low/full post leaves
            // the crossing latch unchanged and the next live battery update can alert again.
            NoopPrefs.setBatteryLowAlerted(context, decision.newLowAlerted)
            NoopPrefs.setBatteryFullAlerted(context, decision.newFullAlerted)
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
                if (decision.fireLow) {
                    NotificationLifecycleLedger.suppressed(
                        context,
                        NotificationLifecycleId.BATTERY_LOW,
                        NotificationLifecycleCategory.STATUS,
                    )
                }
                if (decision.fireFull) {
                    NotificationLifecycleLedger.suppressed(
                        context,
                        NotificationLifecycleId.BATTERY_FULL,
                        NotificationLifecycleCategory.STATUS,
                    )
                }
                return
            }
            ensureChannel(context)
            if (decision.fireLow) {
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle("Low battery")
                    .setContentText("Recharge your ${WhoopModel.CUSTOMER_NAME} before tonight.")
                    .setContentIntent(
                        openAppIntent(
                            context,
                            NotificationPlatformIdentity.ActivityIntent.BATTERY_LOW,
                        ),
                    )
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build()
                if (!NotificationLifecycleLedger.posted(
                        context,
                        NotificationLifecycleId.BATTERY_LOW,
                        NotificationLifecycleCategory.STATUS,
                    ) {
                        NotificationManagerCompat.from(context).notify(
                            NotificationPlatformIdentity.NotificationId.BATTERY_LOW,
                            n,
                        )
                    }
                ) return
            }
            if (decision.fireFull) {
                val n = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle("Noop Band fully charged")
                    .setContentText("Your ${WhoopModel.CUSTOMER_NAME} is at 100%.")
                    .setContentIntent(
                        openAppIntent(
                            context,
                            NotificationPlatformIdentity.ActivityIntent.BATTERY_FULL,
                        ),
                    )
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_STATUS)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .build()
                if (!NotificationLifecycleLedger.posted(
                        context,
                        NotificationLifecycleId.BATTERY_FULL,
                        NotificationLifecycleCategory.STATUS,
                    ) {
                        NotificationManagerCompat.from(context).notify(
                            NotificationPlatformIdentity.NotificationId.BATTERY_FULL,
                            n,
                        )
                    }
                ) return
            }
            // #514: the strap has dropped below 100% - pull the stale "fully charged" note so it
            // can't linger after the cell discharges. cancel() covers a posted notification; a
            // not-yet-shown one simply no-ops.
            if (decision.clearFull) {
                if (!NotificationLifecycleLedger.cancelled(
                        context,
                        NotificationLifecycleId.BATTERY_FULL,
                        NotificationLifecycleCategory.STATUS,
                    ) {
                        NotificationManagerCompat.from(context).cancel(
                            NotificationPlatformIdentity.NotificationId.BATTERY_FULL,
                        )
                    }
                ) return
            }
        }
    }

    private fun openAppIntent(
        context: Context,
        identity: NotificationPlatformIdentity.ActivityIntentIdentity,
    ) = NotificationPlatformIdentity.activityPendingIntent(
        context,
        identity,
        appLaunchIntent(context),
    )

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Battery alerts",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Alerts when Noop Band battery is low or fully charged."
                },
            )
        }
    }
}
