package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.AppDiagnosticsRecorder
import com.noop.R
import com.noop.analytics.ContextualVitalPolicy
import com.noop.ui.NotifPrefs
import com.noop.ui.appLaunchIntent
import java.time.Duration
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit

internal data class ContextualVitalDelivery(
    val atMillis: Long,
    val fingerprint: String,
)

internal data class ContextualVitalDeliveryState(
    val lastGlobalDeliveryMillis: Long? = null,
    val deliveries: Map<ContextualVitalPolicy.Kind, ContextualVitalDelivery> = emptyMap(),
)

internal enum class ContextualVitalDecisionReason {
    DELIVER,
    STALE,
    DUPLICATE,
    TOPIC_COOLDOWN,
    GLOBAL_COOLDOWN,
    QUIET_HOURS,
}

internal data class ContextualVitalDecision(
    val shouldDeliver: Boolean,
    val reason: ContextualVitalDecisionReason,
    val nextState: ContextualVitalDeliveryState,
)

/** Restart-safe delivery gate shared by all optional vital trend reviews. */
internal object ContextualVitalDeliveryPolicy {
    private const val GLOBAL_COOLDOWN_MILLIS = 30L * 60L * 1000L

    fun evaluate(
        candidate: ContextualVitalPolicy.Candidate,
        state: ContextualVitalDeliveryState,
        now: ZonedDateTime,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): ContextualVitalDecision {
        val observedDay = runCatching { java.time.LocalDate.parse(candidate.observedDay) }.getOrNull()
            ?: return reject(ContextualVitalDecisionReason.STALE, state)
        val ageDays = ChronoUnit.DAYS.between(observedDay, now.toLocalDate())
        if (ageDays !in 0L..candidate.maximumAgeDays) {
            return reject(ContextualVitalDecisionReason.STALE, state)
        }

        val nowMillis = now.toInstant().toEpochMilli()
        state.deliveries[candidate.kind]?.let { prior ->
            if (prior.fingerprint == candidate.fingerprint) {
                return reject(ContextualVitalDecisionReason.DUPLICATE, state)
            }
            if (nowMillis - prior.atMillis < topicCooldownMillis(candidate.kind)) {
                return reject(ContextualVitalDecisionReason.TOPIC_COOLDOWN, state)
            }
        }
        state.lastGlobalDeliveryMillis?.let { last ->
            if (nowMillis - last < GLOBAL_COOLDOWN_MILLIS) {
                return reject(ContextualVitalDecisionReason.GLOBAL_COOLDOWN, state)
            }
        }
        if (quietHoursEnabled) {
            val minute = now.hour * 60 + now.minute
            if (windowContains(minute, quietStartMinutes, quietEndMinutes)) {
                return reject(ContextualVitalDecisionReason.QUIET_HOURS, state)
            }
        }

        return ContextualVitalDecision(
            shouldDeliver = true,
            reason = ContextualVitalDecisionReason.DELIVER,
            nextState = state.copy(
                lastGlobalDeliveryMillis = nowMillis,
                deliveries = state.deliveries + (
                    candidate.kind to ContextualVitalDelivery(
                        atMillis = nowMillis,
                        fingerprint = candidate.fingerprint,
                    )
                ),
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

    private fun topicCooldownMillis(kind: ContextualVitalPolicy.Kind): Long = when (kind) {
        ContextualVitalPolicy.Kind.OXYGEN_TREND,
        ContextualVitalPolicy.Kind.BODY_TEMPERATURE_REVIEW
        -> Duration.ofDays(1).toMillis()
        ContextualVitalPolicy.Kind.VO2_TREND -> Duration.ofDays(21).toMillis()
    }

    private fun reject(
        reason: ContextualVitalDecisionReason,
        state: ContextualVitalDeliveryState,
    ) = ContextualVitalDecision(false, reason, state)
}

/**
 * Posts privacy-safe system notifications for candidates already accepted by [ContextualVitalPolicy].
 * No values, diagnosis, severity, or emergency language appears in lock-screen copy.
 */
object ContextualVitalNotifier {
    private const val CHANNEL_ID = "noop_contextual_vitals"
    private const val PREFS_FILE = "noop_contextual_vital_delivery"
    private const val KEY_GLOBAL_AT = "global.at"

    @SuppressLint("MissingPermission")
    fun onCandidate(
        context: Context,
        candidate: ContextualVitalPolicy.Candidate,
        now: ZonedDateTime = ZonedDateTime.now(),
    ) {
        runCatching {
            val manager = NotificationManagerCompat.from(context)
            if (!manager.areNotificationsEnabled()) {
                NotificationLifecycleLedger.suppressed(
                    context,
                    NotificationLifecycleId.CONTEXTUAL_VITAL,
                    NotificationLifecycleCategory.RECOMMENDATION,
                )
                return
            }

            val state = loadState(context)
            val decision = ContextualVitalDeliveryPolicy.evaluate(
                candidate = candidate,
                state = state,
                now = now,
                quietHoursEnabled = NotifPrefs.getBool(context, NotifPrefs.QUIET, false),
                quietStartMinutes = NotifPrefs.getInt(context, NotifPrefs.QUIET_START, 22 * 60),
                quietEndMinutes = NotifPrefs.getInt(context, NotifPrefs.QUIET_END, 7 * 60),
            )
            if (!decision.shouldDeliver) {
                if (decision.reason == ContextualVitalDecisionReason.DUPLICATE) {
                    val prior = state.deliveries[candidate.kind]
                    val receipt = ContextualPromptDeliveryLedger.pendingReceipt(
                        context,
                        ContextualPromptDeliveryOwner.VITAL_REVIEW,
                    )
                    if (
                        receipt?.pending == true &&
                        receipt.identity == candidate.fingerprint &&
                        prior?.atMillis == receipt.atMillis
                    ) {
                        ContextualPromptDeliveryLedger.confirmPendingIfOwned(
                            context = context,
                            owner = ContextualPromptDeliveryOwner.VITAL_REVIEW,
                            expectedAtMillis = receipt.atMillis,
                            expectedIdentity = receipt.identity,
                        )
                    }
                }
                if (decision.reason == ContextualVitalDecisionReason.QUIET_HOURS) {
                    NotificationLifecycleLedger.suppressed(
                        context,
                        NotificationLifecycleId.CONTEXTUAL_VITAL,
                        NotificationLifecycleCategory.RECOMMENDATION,
                    )
                }
                return
            }

            ensureChannel(context)
            val (title, body) = copy(candidate.kind)
            val openApp = NotificationPlatformIdentity.activityPendingIntent(
                context,
                NotificationPlatformIdentity.ActivityIntent.CONTEXTUAL_VITAL,
                appLaunchIntent(context),
            )
            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(openApp)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .build()
            val postResult = ContextualPromptDeliveryLedger.postIfAllowed(
                context,
                now.toInstant().toEpochMilli(),
                ContextualPromptDeliveryOwner.VITAL_REVIEW,
                identity = candidate.fingerprint,
            ) {
                NotificationLifecycleLedger.posted(
                    context,
                    NotificationLifecycleId.CONTEXTUAL_VITAL,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    manager.notify(
                        NotificationPlatformIdentity.NotificationId.CONTEXTUAL_VITAL,
                        notification,
                    )
                }
            }
            if (postResult.status != ContextualPromptPostStatus.ACCEPTED) {
                if (postResult.status == ContextualPromptPostStatus.GLOBAL_COOLDOWN) {
                    NotificationLifecycleLedger.suppressed(
                        context,
                        NotificationLifecycleId.CONTEXTUAL_VITAL,
                        NotificationLifecycleCategory.RECOMMENDATION,
                    )
                }
                return
            }
            val acceptedReceipt = postResult.receipt ?: return
            val deliveries = state.deliveries + (
                candidate.kind to ContextualVitalDelivery(
                    atMillis = acceptedReceipt.atMillis,
                    fingerprint = candidate.fingerprint,
                )
            )
            val privateStateStored = saveState(
                context,
                state.copy(
                    lastGlobalDeliveryMillis = deliveries.values.maxOfOrNull { it.atMillis },
                    deliveries = deliveries,
                ),
            )
            if (!privateStateStored) {
                AppDiagnosticsRecorder.record(
                    "contextual_prompt.private_state",
                    fields = mapOf(
                        "owner" to ContextualPromptDeliveryOwner.VITAL_REVIEW.storageKey,
                        "outcome" to "commit_failed",
                    ),
                )
            } else if (
                acceptedReceipt.pending &&
                !ContextualPromptDeliveryLedger.confirmPendingIfOwned(
                    context = context,
                    owner = ContextualPromptDeliveryOwner.VITAL_REVIEW,
                    expectedAtMillis = acceptedReceipt.atMillis,
                    expectedIdentity = acceptedReceipt.identity,
                )
            ) {
                AppDiagnosticsRecorder.record(
                    "contextual_prompt.shared_state",
                    fields = mapOf(
                        "owner" to ContextualPromptDeliveryOwner.VITAL_REVIEW.storageKey,
                        "outcome" to "commit_failed",
                    ),
                )
            }
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.CONTEXTUAL_VITAL,
                NotificationLifecycleCategory.RECOMMENDATION,
            )
        }
    }

    private fun copy(kind: ContextualVitalPolicy.Kind): Pair<String, String> = when (kind) {
        ContextualVitalPolicy.Kind.OXYGEN_TREND ->
            "Wellness readings to review" to
                "Two recent blood oxygen readings were outside the usual wearable range. " +
                "Open NOOP to review their source and context."
        ContextualVitalPolicy.Kind.BODY_TEMPERATURE_REVIEW ->
            "Body temperature reading to review" to
                "A fresh explicit body temperature reading was outside the broad review range. " +
                "Recheck with a thermometer and consider how you feel; NOOP cannot assess severity."
        ContextualVitalPolicy.Kind.VO2_TREND ->
            "Cardio fitness trend updated" to
                "A meaningful longer-term VO2 max change is ready to review. " +
                "Check the source and trend in NOOP."
    }

    private fun loadState(context: Context): ContextualVitalDeliveryState {
        val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val deliveries = ContextualVitalPolicy.Kind.entries.mapNotNull { kind ->
            val atKey = "${kind.name}.at"
            val fingerprint = prefs.getString("${kind.name}.fingerprint", null)
            if (!prefs.contains(atKey) || fingerprint == null) null
            else kind to ContextualVitalDelivery(prefs.getLong(atKey, 0), fingerprint)
        }.toMap()
        return ContextualVitalDeliveryState(
            lastGlobalDeliveryMillis = prefs.getLong(KEY_GLOBAL_AT, 0)
                .takeIf { prefs.contains(KEY_GLOBAL_AT) },
            deliveries = deliveries,
        )
    }

    private fun saveState(
        context: Context,
        state: ContextualVitalDeliveryState,
    ): Boolean {
        val editor = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE).edit()
        state.lastGlobalDeliveryMillis?.let { editor.putLong(KEY_GLOBAL_AT, it) }
        for ((kind, delivery) in state.deliveries) {
            editor.putLong("${kind.name}.at", delivery.atMillis)
            editor.putString("${kind.name}.fingerprint", delivery.fingerprint)
        }
        return editor.commit()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Private vital trend reviews",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Optional prompts to review fresh wellness readings inside NOOP."
            },
        )
    }
}
