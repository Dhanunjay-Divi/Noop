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
import com.noop.AppDiagnosticsRecorder
import com.noop.R
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.ContextualActionCenter
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NotificationRouteBridge

internal data class StressBreathingNotificationState(
    val lastDeliveryMillis: Long? = null,
    val fingerprint: String? = null,
)

internal enum class StressBreathingNotificationReason {
    DELIVER,
    STALE,
    DUPLICATE,
    COOLDOWN,
    QUIET_HOURS,
}

internal data class StressBreathingNotificationDecision(
    val shouldDeliver: Boolean,
    val reason: StressBreathingNotificationReason,
    val nextState: StressBreathingNotificationState,
)

/** Restart-safe delivery gate for the optional phone lane of a qualified stress check-in. */
internal object StressBreathingNotificationPolicy {
    const val MAXIMUM_AGE_MILLIS: Long = 5L * 60L * 1_000L
    const val FUTURE_TOLERANCE_MILLIS: Long = 5L * 60L * 1_000L
    const val COOLDOWN_MILLIS: Long = 4L * 60L * 60L * 1_000L

    fun evaluate(
        observedAtMillis: Long,
        fingerprint: String,
        state: StressBreathingNotificationState,
        nowMillis: Long,
        localMinuteOfDay: Int,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): StressBreathingNotificationDecision {
        val age = nowMillis - observedAtMillis
        if (age !in -FUTURE_TOLERANCE_MILLIS..MAXIMUM_AGE_MILLIS) {
            return reject(StressBreathingNotificationReason.STALE, state)
        }
        if (state.fingerprint == fingerprint) {
            return reject(StressBreathingNotificationReason.DUPLICATE, state)
        }
        state.lastDeliveryMillis?.let { last ->
            if (nowMillis - last < COOLDOWN_MILLIS) {
                return reject(StressBreathingNotificationReason.COOLDOWN, state)
            }
        }
        if (
            quietHoursEnabled &&
            windowContains(localMinuteOfDay, quietStartMinutes, quietEndMinutes)
        ) {
            return reject(StressBreathingNotificationReason.QUIET_HOURS, state)
        }
        return StressBreathingNotificationDecision(
            shouldDeliver = true,
            reason = StressBreathingNotificationReason.DELIVER,
            nextState = StressBreathingNotificationState(
                lastDeliveryMillis = nowMillis,
                fingerprint = fingerprint,
            ),
        )
    }

    internal fun windowContains(minute: Int, start: Int, end: Int): Boolean {
        val day = 24 * 60
        val value = ((minute % day) + day) % day
        val low = ((start % day) + day) % day
        val high = ((end % day) + day) % day
        if (low == high) return false
        return if (low < high) value in low until high else value >= low || value < high
    }

    private fun reject(
        reason: StressBreathingNotificationReason,
        state: StressBreathingNotificationState,
    ) = StressBreathingNotificationDecision(false, reason, state)
}

/**
 * Posts detail-free notification copy only after the sensor detector has accepted a resting HRV onset.
 * It never requests permission from a background path and stores cooldown state only after notify().
 */
object StressBreathingNotifier {
    private const val CHANNEL_ID = "noop_stress_breathing"
    private const val PREFS_FILE = "noop_stress_breathing_delivery"
    private const val KEY_LAST_AT = "last.at"
    private const val KEY_FINGERPRINT = "last.fingerprint"

    @SuppressLint("MissingPermission")
    fun onQualifiedOnset(
        context: Context,
        observedAtMillis: Long,
        fingerprint: String,
        nowMillis: Long = System.currentTimeMillis(),
    ) {
        if (!BiofeedbackPrefs.phoneNudge(context)) return
        runCatching {
            ensureChannel(context)
            if (!canNotify(context)) {
                suppress(context)
                return
            }
            val manager = NotificationManagerCompat.from(context)

            val local = java.time.Instant.ofEpochMilli(nowMillis)
                .atZone(java.time.ZoneId.systemDefault())
            val state = loadState(context)
            val decision = StressBreathingNotificationPolicy.evaluate(
                observedAtMillis = observedAtMillis,
                fingerprint = fingerprint,
                state = state,
                nowMillis = nowMillis,
                localMinuteOfDay = local.hour * 60 + local.minute,
                quietHoursEnabled = BiofeedbackPrefs.quietHoursEnabled(context),
                quietStartMinutes = BiofeedbackPrefs.quietStartMinutes(context),
                quietEndMinutes = BiofeedbackPrefs.quietEndMinutes(context),
            )
            if (!decision.shouldDeliver) {
                if (decision.reason == StressBreathingNotificationReason.DUPLICATE) {
                    val receipt = ContextualPromptDeliveryLedger.pendingReceipt(
                        context,
                        ContextualPromptDeliveryOwner.STRESS_BREATHING,
                    )
                    if (
                        receipt?.pending == true &&
                        receipt.identity == fingerprint &&
                        state.lastDeliveryMillis == receipt.atMillis
                    ) {
                        ContextualPromptDeliveryLedger.confirmPendingIfOwned(
                            context = context,
                            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
                            expectedAtMillis = receipt.atMillis,
                            expectedIdentity = receipt.identity,
                        )
                    }
                    ContextualActionCenter.presentStress(
                        context = context,
                        fastRmssd = null,
                        baselineRmssd = null,
                        fingerprint = fingerprint,
                        observedAtMillis = observedAtMillis,
                    )
                }
                if (decision.reason == StressBreathingNotificationReason.QUIET_HOURS) {
                    suppress(context)
                }
                return
            }

            val title = context.getString(R.string.appwide_stress_checkin_notification_title)
            val body = context.getString(R.string.appwide_stress_checkin_notification_body)
            val openBreathe = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.STRESS_BREATHING,
                NotificationRouteBridge.launchIntent(context, NoopNotificationRoute.BREATHE),
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openBreathe)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .build()
            val postResult = ContextualPromptDeliveryLedger.postIfAllowed(
                context,
                nowMillis,
                ContextualPromptDeliveryOwner.STRESS_BREATHING,
                identity = fingerprint,
            ) {
                NotificationLifecycleLedger.posted(
                    context,
                    NotificationLifecycleId.STRESS_BREATHING,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    manager.notify(
                        NotificationPlatformIdentity.NotificationId.STRESS_BREATHING,
                        notification,
                    )
                }
            }
            if (postResult.status != ContextualPromptPostStatus.ACCEPTED) {
                if (postResult.status == ContextualPromptPostStatus.GLOBAL_COOLDOWN) {
                    suppress(context)
                }
                return
            }
            val acceptedReceipt = postResult.receipt ?: return
            ContextualActionCenter.presentStress(
                context = context,
                fastRmssd = null,
                baselineRmssd = null,
                fingerprint = fingerprint,
                observedAtMillis = observedAtMillis,
            )
            val privateStateStored = saveState(
                context,
                StressBreathingNotificationState(
                    lastDeliveryMillis = acceptedReceipt.atMillis,
                    fingerprint = fingerprint,
                ),
            )
            if (!privateStateStored) {
                AppDiagnosticsRecorder.record(
                    "contextual_prompt.private_state",
                    fields = mapOf(
                        "owner" to ContextualPromptDeliveryOwner.STRESS_BREATHING.storageKey,
                        "outcome" to "commit_failed",
                    ),
                )
            } else if (
                acceptedReceipt.pending &&
                !ContextualPromptDeliveryLedger.confirmPendingIfOwned(
                    context = context,
                    owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
                    expectedAtMillis = acceptedReceipt.atMillis,
                    expectedIdentity = acceptedReceipt.identity,
                )
            ) {
                AppDiagnosticsRecorder.record(
                    "contextual_prompt.shared_state",
                    fields = mapOf(
                        "owner" to ContextualPromptDeliveryOwner.STRESS_BREATHING.storageKey,
                        "outcome" to "commit_failed",
                    ),
                )
            }
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.STRESS_BREATHING,
                NotificationLifecycleCategory.RECOMMENDATION,
            )
        }
    }

    /** Explicit-enable check used by Automations so a disabled feature channel cannot look active. */
    fun prepareAndCanNotify(context: Context): Boolean {
        ensureChannel(context.applicationContext)
        return canNotify(context.applicationContext)
    }

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

    private fun suppress(context: Context) {
        NotificationLifecycleLedger.suppressed(
            context,
            NotificationLifecycleId.STRESS_BREATHING,
            NotificationLifecycleCategory.RECOMMENDATION,
        )
    }

    private fun loadState(context: Context): StressBreathingNotificationState {
        val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        return StressBreathingNotificationState(
            lastDeliveryMillis = prefs.getLong(KEY_LAST_AT, 0L)
                .takeIf { prefs.contains(KEY_LAST_AT) },
            fingerprint = prefs.getString(KEY_FINGERPRINT, null),
        )
    }

    private fun saveState(
        context: Context,
        state: StressBreathingNotificationState,
    ): Boolean {
        val editor = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE).edit()
        state.lastDeliveryMillis?.let { editor.putLong(KEY_LAST_AT, it) }
        state.fingerprint?.let { editor.putString(KEY_FINGERPRINT, it) }
        return editor.commit()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(CHANNEL_ID)
            ?: NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.appwide_stress_checkin_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        channel.name = context.getString(R.string.appwide_stress_checkin_channel_name)
        channel.description = context.getString(R.string.appwide_stress_checkin_channel_description)
        manager.createNotificationChannel(channel)
    }
}
