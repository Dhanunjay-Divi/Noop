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
import com.noop.AppDiagnosticsRecorder
import com.noop.NoopApplication
import com.noop.R
import com.noop.alarm.WindDownStore
import com.noop.analytics.AdaptiveDayGuidance
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.ReadinessEngine
import com.noop.ble.WhoopBleClient
import com.noop.calendar.PlannedWorkoutCalendarStore
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import com.noop.managed.ManagedRuntimeGate
import com.noop.ui.ContextualActionCenter
import com.noop.ui.NoopNotificationRoute
import com.noop.ui.NoopPrefs
import com.noop.ui.NotifPrefs
import com.noop.ui.NotificationRouteBridge
import com.noop.ui.logicalDay
import kotlinx.coroutines.CancellationException
import java.time.Duration
import java.time.Instant
import java.time.ZonedDateTime
import java.util.concurrent.TimeUnit
import kotlin.math.abs

internal enum class AdaptiveDayDeliveryKind {
    SLEEP_RECOVERY,
    ROUTINE_RECOVERY,
    PLANNED_WORKOUT,
    TRAVEL,
}

internal data class AdaptiveDayDeliveryCandidate(
    val kind: AdaptiveDayDeliveryKind,
    val observedAtMillis: Long,
    val maximumAgeMillis: Long,
    val fingerprint: String,
    val evaluationToken: Long? = null,
    val calendarRevision: Long? = null,
)

internal data class AdaptiveDayDelivery(
    val atMillis: Long,
    val fingerprint: String,
)

internal data class AdaptiveDayDeliveryState(
    val lastGlobalDeliveryMillis: Long? = null,
    val deliveries: Map<AdaptiveDayDeliveryKind, AdaptiveDayDelivery> = emptyMap(),
)

internal enum class AdaptiveDayDeliveryReason {
    DELIVER,
    STALE,
    DUPLICATE,
    TOPIC_COOLDOWN,
    GLOBAL_COOLDOWN,
    QUIET_HOURS,
}

internal data class AdaptiveDayDeliveryDecision(
    val shouldDeliver: Boolean,
    val reason: AdaptiveDayDeliveryReason,
    val nextState: AdaptiveDayDeliveryState,
)

/** Restart-safe arbitration for routine wellness prompts. */
internal object AdaptiveDayDeliveryPolicy {
    private const val FUTURE_TOLERANCE_MILLIS = 5L * 60L * 1_000L
    private const val GLOBAL_COOLDOWN_MILLIS = 30L * 60L * 1_000L

    fun evaluate(
        candidate: AdaptiveDayDeliveryCandidate,
        state: AdaptiveDayDeliveryState,
        nowMillis: Long,
        localMinuteOfDay: Int,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): AdaptiveDayDeliveryDecision {
        val age = nowMillis - candidate.observedAtMillis
        if (age !in -FUTURE_TOLERANCE_MILLIS..candidate.maximumAgeMillis) {
            return reject(AdaptiveDayDeliveryReason.STALE, state)
        }
        state.deliveries[candidate.kind]?.let { prior ->
            if (prior.fingerprint == candidate.fingerprint) {
                return reject(AdaptiveDayDeliveryReason.DUPLICATE, state)
            }
            if (nowMillis - prior.atMillis < topicCooldownMillis(candidate.kind)) {
                return reject(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, state)
            }
        }
        for (blocker in adaptivePriorityBlockers(candidate.kind)) {
            state.deliveries[blocker]?.let { prior ->
                if (nowMillis - prior.atMillis < Duration.ofHours(20).toMillis()) {
                    return reject(AdaptiveDayDeliveryReason.TOPIC_COOLDOWN, state)
                }
            }
        }
        state.lastGlobalDeliveryMillis?.let { prior ->
            if (nowMillis - prior < GLOBAL_COOLDOWN_MILLIS) {
                return reject(AdaptiveDayDeliveryReason.GLOBAL_COOLDOWN, state)
            }
        }
        if (
            quietHoursEnabled &&
            ContextualVitalDeliveryPolicy.windowContains(
                localMinuteOfDay,
                quietStartMinutes,
                quietEndMinutes,
            )
        ) {
            return reject(AdaptiveDayDeliveryReason.QUIET_HOURS, state)
        }
        return AdaptiveDayDeliveryDecision(
            shouldDeliver = true,
            reason = AdaptiveDayDeliveryReason.DELIVER,
            nextState = state.copy(
                lastGlobalDeliveryMillis = nowMillis,
                deliveries = state.deliveries + (
                    candidate.kind to AdaptiveDayDelivery(nowMillis, candidate.fingerprint)
                ),
            ),
        )
    }

    fun nextEligibleAtMillis(
        candidate: AdaptiveDayDeliveryCandidate,
        state: AdaptiveDayDeliveryState,
        notBefore: ZonedDateTime,
        quietHoursEnabled: Boolean,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
    ): Long? {
        if (candidate.maximumAgeMillis <= 0L) return null
        val expiresAtMillis = candidate.observedAtMillis + candidate.maximumAgeMillis
        if (expiresAtMillis < candidate.observedAtMillis) return null
        var probe = notBefore

        repeat(8) {
            val probeMillis = probe.toInstant().toEpochMilli()
            if (probeMillis >= expiresAtMillis) return null
            val decision = evaluate(
                candidate = candidate,
                state = state,
                nowMillis = probeMillis,
                localMinuteOfDay = probe.hour * 60 + probe.minute,
                quietHoursEnabled = quietHoursEnabled,
                quietStartMinutes = quietStartMinutes,
                quietEndMinutes = quietEndMinutes,
            )
            if (decision.shouldDeliver) return probeMillis

            val nextMillis = when (decision.reason) {
                AdaptiveDayDeliveryReason.GLOBAL_COOLDOWN ->
                    state.lastGlobalDeliveryMillis?.plus(GLOBAL_COOLDOWN_MILLIS)
                AdaptiveDayDeliveryReason.TOPIC_COOLDOWN ->
                    topicCooldownEndMillis(candidate.kind, state)
                AdaptiveDayDeliveryReason.QUIET_HOURS ->
                    nextQuietHoursEnd(probe, quietEndMinutes).toInstant().toEpochMilli()
                AdaptiveDayDeliveryReason.STALE,
                AdaptiveDayDeliveryReason.DUPLICATE,
                -> return null
                AdaptiveDayDeliveryReason.DELIVER -> return probeMillis
            } ?: return null

            val advancedMillis = maxOf(nextMillis, probeMillis + 1_000L)
            probe = ZonedDateTime.ofInstant(
                Instant.ofEpochMilli(advancedMillis),
                notBefore.zone,
            )
        }
        return null
    }

    private fun topicCooldownMillis(kind: AdaptiveDayDeliveryKind): Long = when (kind) {
        AdaptiveDayDeliveryKind.SLEEP_RECOVERY,
        AdaptiveDayDeliveryKind.ROUTINE_RECOVERY,
        AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
        -> Duration.ofHours(20).toMillis()
        AdaptiveDayDeliveryKind.TRAVEL -> Duration.ofHours(24).toMillis()
    }

    private fun adaptivePriorityBlockers(
        kind: AdaptiveDayDeliveryKind,
    ): List<AdaptiveDayDeliveryKind> = when (kind) {
        AdaptiveDayDeliveryKind.SLEEP_RECOVERY ->
            listOf(
                AdaptiveDayDeliveryKind.TRAVEL,
                AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
                AdaptiveDayDeliveryKind.ROUTINE_RECOVERY,
            )
        AdaptiveDayDeliveryKind.ROUTINE_RECOVERY ->
            listOf(AdaptiveDayDeliveryKind.TRAVEL, AdaptiveDayDeliveryKind.PLANNED_WORKOUT)
        AdaptiveDayDeliveryKind.PLANNED_WORKOUT ->
            listOf(AdaptiveDayDeliveryKind.TRAVEL)
        AdaptiveDayDeliveryKind.TRAVEL -> emptyList()
    }

    private fun topicCooldownEndMillis(
        kind: AdaptiveDayDeliveryKind,
        state: AdaptiveDayDeliveryState,
    ): Long? {
        val dates = buildList {
            state.deliveries[kind]?.let {
                add(it.atMillis + topicCooldownMillis(kind))
            }
            adaptivePriorityBlockers(kind).forEach { blocker ->
                state.deliveries[blocker]?.let {
                    add(it.atMillis + Duration.ofHours(20).toMillis())
                }
            }
        }
        return dates.maxOrNull()
    }

    private fun nextQuietHoursEnd(
        now: ZonedDateTime,
        endMinutes: Int,
    ): ZonedDateTime {
        val dayMinutes = 24 * 60
        val normalized = ((endMinutes % dayMinutes) + dayMinutes) % dayMinutes
        var end = now.toLocalDate()
            .atTime(normalized / 60, normalized % 60)
            .atZone(now.zone)
        if (!end.isAfter(now)) end = end.plusDays(1)
        return end
    }

    private fun reject(
        reason: AdaptiveDayDeliveryReason,
        state: AdaptiveDayDeliveryState,
    ) = AdaptiveDayDeliveryDecision(false, reason, state)
}

internal data class AdaptiveDayTimeZoneState(
    val currentOffsetSec: Int? = null,
    val pending: AdaptiveDayGuidance.TimeZoneChange? = null,
)

/** Pure transition rule behind the persisted timezone observation. */
internal object AdaptiveDayTimeZonePolicy {
    fun observe(
        state: AdaptiveDayTimeZoneState,
        offsetSec: Int,
        nowSec: Long,
    ): AdaptiveDayTimeZoneState {
        val prior = state.currentOffsetSec
        if (prior == null || prior == offsetSec) {
            return state.copy(currentOffsetSec = offsetSec)
        }
        val shift = AdaptiveDayGuidance.normalizedTravelDeltaSeconds(
            previousOffsetSec = prior,
            currentOffsetSec = offsetSec,
        )
        val pending = if (abs(shift) >= AdaptiveDayGuidance.TRAVEL_THRESHOLD_SECONDS) {
            AdaptiveDayGuidance.TimeZoneChange(
                previousOffsetSec = prior,
                currentOffsetSec = offsetSec,
                observedAtSec = nowSec,
            )
        } else {
            state.pending
        }
        return AdaptiveDayTimeZoneState(currentOffsetSec = offsetSec, pending = pending)
    }
}

/** SharedPreferences boundary for timezone state; qualified changes survive process death for retry. */
object AdaptiveDayTimeZoneStore {
    private const val PREFS_FILE = "noop_adaptive_day_timezone"
    private const val KEY_CURRENT_OFFSET = "current.offset.sec"
    private const val KEY_CHANGE_FROM = "change.from.sec"
    private const val KEY_CHANGE_TO = "change.to.sec"
    private const val KEY_CHANGE_AT = "change.at.sec"
    private val lock = Any()

    fun observe(
        context: Context,
        offsetSec: Int,
        nowSec: Long,
    ): AdaptiveDayGuidance.TimeZoneChange? = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val next = AdaptiveDayTimeZonePolicy.observe(load(prefs), offsetSec, nowSec)
        val editor = prefs.edit().putInt(KEY_CURRENT_OFFSET, offsetSec)
        next.pending?.let {
            editor
                .putInt(KEY_CHANGE_FROM, it.previousOffsetSec)
                .putInt(KEY_CHANGE_TO, it.currentOffsetSec)
                .putLong(KEY_CHANGE_AT, it.observedAtSec)
        }
        editor.apply()
        next.pending
    }

    fun pending(context: Context): AdaptiveDayGuidance.TimeZoneChange? = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        load(prefs).pending
    }

    fun discardPending(context: Context) = synchronized(lock) {
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_CHANGE_FROM)
            .remove(KEY_CHANGE_TO)
            .remove(KEY_CHANGE_AT)
            .apply()
    }

    private fun load(prefs: android.content.SharedPreferences): AdaptiveDayTimeZoneState {
        val current = prefs.getInt(KEY_CURRENT_OFFSET, 0)
            .takeIf { prefs.contains(KEY_CURRENT_OFFSET) }
        val pending = if (
            prefs.contains(KEY_CHANGE_FROM) &&
            prefs.contains(KEY_CHANGE_TO) &&
            prefs.contains(KEY_CHANGE_AT)
        ) {
            AdaptiveDayGuidance.TimeZoneChange(
                previousOffsetSec = prefs.getInt(KEY_CHANGE_FROM, 0),
                currentOffsetSec = prefs.getInt(KEY_CHANGE_TO, 0),
                observedAtSec = prefs.getLong(KEY_CHANGE_AT, 0),
            )
        } else {
            null
        }
        return AdaptiveDayTimeZoneState(current, pending)
    }
}

internal object AdaptivePlannedWorkoutSchedulePolicy {
    const val LEAD_SECONDS = 2L * 60L * 60L

    fun boundaryDelayMillis(startSec: Long, nowMillis: Long): Long? {
        val boundaryMillis = (startSec - LEAD_SECONDS) * 1_000L
        return (boundaryMillis - nowMillis).takeIf { it > 0L }
    }

    fun retryDelayMillis(
        startSec: Long,
        retryAtMillis: Long,
        nowMillis: Long,
    ): Long? {
        val startMillis = startSec * 1_000L
        if (retryAtMillis >= startMillis) return null
        return (retryAtMillis - nowMillis).takeIf { it > 0L }
    }
}

internal object AdaptiveDayEvaluationGate {
    private val lock = Any()
    private var generation = 0L

    fun begin(): Long = synchronized(lock) {
        generation += 1L
        generation
    }

    fun invalidate() {
        synchronized(lock) {
            generation += 1L
        }
    }

    fun isCurrent(token: Long): Boolean = synchronized(lock) {
        generation == token
    }

    fun commitIfCurrent(token: Long, block: () -> Boolean): Boolean = synchronized(lock) {
        if (generation != token) false else block()
    }
}

/** Durable two-hour boundary reevaluation. WorkManager survives process death and app dismissal. */
internal object AdaptivePlannedWorkoutScheduler {
    private const val WORK_NAME = "noop_adaptive_planned_workout_boundary"
    internal const val EXPECTED_START_SEC_KEY = "expected_start_sec"

    fun schedule(
        context: Context,
        startSec: Long,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        val delayMillis = AdaptivePlannedWorkoutSchedulePolicy.boundaryDelayMillis(
            startSec = startSec,
            nowMillis = nowMillis,
        ) ?: run {
            cancel(context)
            return false
        }
        val request = OneTimeWorkRequestBuilder<AdaptivePlannedWorkoutWorker>()
            .setInputData(workDataOf(EXPECTED_START_SEC_KEY to startSec))
            .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            request,
        )
        AppDiagnosticsRecorder.record(
            "adaptive_day.planned_workout_boundary",
            fields = mapOf("outcome" to "enqueue_requested"),
        )
        return true
    }

    fun scheduleRetry(
        context: Context,
        startSec: Long,
        retryAtMillis: Long,
        nowMillis: Long = System.currentTimeMillis(),
    ): Boolean {
        val delayMillis = AdaptivePlannedWorkoutSchedulePolicy.retryDelayMillis(
            startSec = startSec,
            retryAtMillis = retryAtMillis,
            nowMillis = nowMillis,
        ) ?: return false
        val request = OneTimeWorkRequestBuilder<AdaptivePlannedWorkoutWorker>()
            .setInputData(workDataOf(EXPECTED_START_SEC_KEY to startSec))
            .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            WORK_NAME,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            request,
        )
        AppDiagnosticsRecorder.record(
            "adaptive_day.planned_workout_boundary",
            fields = mapOf("outcome" to "retry_enqueue_requested"),
        )
        return true
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
    }
}

class AdaptivePlannedWorkoutWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (!ManagedRuntimeGate.isAuthorized(applicationContext)) {
            return Result.success()
        }
        val diagnostic = AppDiagnosticsRecorder.beginOperation(
            "adaptive_day.planned_workout_boundary",
        )
        if (
            !NoopPrefs.adaptiveDayGuidance(applicationContext) ||
            !NoopPrefs.plannedWorkoutCalendar(applicationContext)
        ) {
            AppDiagnosticsRecorder.endOperation(diagnostic, outcome = "disabled")
            return Result.success()
        }
        if (
            inputData.getLong(
                AdaptivePlannedWorkoutScheduler.EXPECTED_START_SEC_KEY,
                Long.MIN_VALUE,
            ) == Long.MIN_VALUE
        ) {
            AppDiagnosticsRecorder.endOperation(diagnostic, outcome = "invalid_input")
            return Result.failure()
        }
        return try {
            val app = applicationContext as? NoopApplication
            val activeDeviceId = runCatching {
                app?.deviceRegistry?.activeDeviceId()
            }.getOrNull()
                ?: app?.activeDeviceId?.takeIf(String::isNotBlank)
                ?: WhoopBleClient.DEFAULT_DEVICE_ID
            AdaptiveDayEvaluator.evaluateAndNotify(
                context = applicationContext,
                repository = WhoopRepository.from(applicationContext),
                deviceId = activeDeviceId,
            )
            AppDiagnosticsRecorder.endOperation(diagnostic)
            Result.success()
        } catch (cancelled: CancellationException) {
            AppDiagnosticsRecorder.endOperation(diagnostic, outcome = "cancelled")
            throw cancelled
        } catch (_: Exception) {
            AppDiagnosticsRecorder.endOperation(diagnostic, outcome = "retry")
            Result.retry()
        }
    }
}

/**
 * Process-safe evaluation boundary shared by foreground UI, band post-offload analysis, and background
 * Health Connect ingestion. Every path ranks the same evidence and converges on the notifier's durable
 * duplicate/cooldown state.
 */
object AdaptiveDayEvaluator {
    suspend fun evaluateAndNotify(
        context: Context,
        repository: WhoopRepository,
        deviceId: String,
        days: List<DailyMetric>? = null,
        now: ZonedDateTime = ZonedDateTime.now(),
        sleepTargetMinutes: Int = WindDownStore.from(context).sleepNeedMinutes,
        sleepTargetIsExplicit: Boolean = WindDownStore.from(context).hasExplicitSleepNeed,
    ): AdaptiveDayGuidance.Recommendation? {
        val evaluationToken = AdaptiveDayEvaluationGate.begin()
        val appContext = context.applicationContext
        val nowSec = now.toEpochSecond()
        val offsetSec = now.offset.totalSeconds
        val timeZoneChange = AdaptiveDayTimeZoneStore.observe(
            appContext,
            offsetSec = offsetSec,
            nowSec = nowSec,
        )
        if (!NoopPrefs.adaptiveDayGuidance(appContext)) {
            AdaptiveDayTimeZoneStore.discardPending(appContext)
            AdaptivePlannedWorkoutScheduler.cancel(appContext)
            AdaptiveDayNotifier.reconcilePlannedWorkoutArtifacts(
                appContext,
                currentFingerprint = null,
            )
            return null
        }

        val resolvedDays = days ?: try {
            repository.daysMerged(
                deviceId = deviceId,
                fromDay = now.minusDays(
                    AdaptiveDayGuidance.ROUTINE_LOOKBACK_DAYS.toLong() + 2L,
                ).toLocalDate().toString(),
                toDay = now.plusDays(1).toLocalDate().toString(),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            emptyList()
        }
        val sleepWindows = try {
            repository.sleepSessionsMerged(
                deviceId = deviceId,
                from = now.minusDays(
                    AdaptiveDayGuidance.ROUTINE_LOOKBACK_DAYS.toLong() + 1L,
                ).toEpochSecond(),
                to = nowSec,
                limit = 1_000,
            ).map {
                AdaptiveDayGuidance.SleepWindow(
                    startSec = it.effectiveStartTs,
                    endSec = it.endTs,
                )
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            emptyList()
        }
        val today = maxOf(logicalDay(now).toString(), now.toLocalDate().toString())
        if (!AdaptiveDayEvaluationGate.isCurrent(evaluationToken)) return null
        val recommendation = AdaptiveDayGuidance.recommendation(
            AdaptiveDayGuidance.Input(
                today = today,
                nowSec = nowSec,
                currentTimeZoneOffsetSec = offsetSec,
                sleepTargetMinutes = sleepTargetMinutes,
                sleepDays = resolvedDays.map {
                    AdaptiveDayGuidance.SleepDay(
                        day = it.day,
                        totalSleepMinutes = it.totalSleepMin,
                    )
                },
                sleepWindows = sleepWindows,
                timeZoneChange = timeZoneChange,
            ),
        )
        if (recommendation?.kind == AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT) {
            AdaptiveDayEvaluationGate.commitIfCurrent(evaluationToken) {
                AdaptivePlannedWorkoutScheduler.cancel(appContext)
                AdaptiveDayNotifier.reconcilePlannedWorkoutArtifacts(
                    appContext,
                    currentFingerprint = null,
                )
                AdaptiveDayNotifier.onRecommendation(appContext, recommendation)
                true
            }
            return recommendation
        }

        val plannedWorkout = PlannedWorkoutCalendarStore.refresh(
            context = appContext,
            now = now,
        )
        if (!AdaptiveDayEvaluationGate.isCurrent(evaluationToken)) return recommendation
        val plan = DailyActionPlanner.plan(
            today = today,
            readiness = ReadinessEngine.evaluate(resolvedDays, today),
            checkIn = NoopPrefs.dailyActionCheckIn(appContext, today),
            recentEffort = resolvedDays.map {
                DailyActionPlanner.EffortDay(day = it.day, effort = it.strain)
            },
            recentSleep = resolvedDays.map {
                DailyActionPlanner.SleepDay(day = it.day, minutes = it.totalSleepMin)
            },
            sleepTargetMinutes = sleepTargetMinutes,
            sleepTargetIsExplicit = sleepTargetIsExplicit,
            plannedWorkout = plannedWorkout?.asPlannedWorkout(today),
            nowSec = nowSec,
        )
        AdaptiveDayEvaluationGate.commitIfCurrent(evaluationToken) {
            if (
                plannedWorkout != null &&
                !PlannedWorkoutCalendarStore.isCurrent(plannedWorkout)
            ) {
                return@commitIfCurrent false
            }
            plan.workoutAdjustment?.let { adjustment ->
                val fingerprint = AdaptiveDayNotifier.plannedWorkoutFingerprint(
                    day = today,
                    adjustment = adjustment,
                )
                val leadSeconds = adjustment.startSec - nowSec
                if (leadSeconds <= 0L) {
                    AdaptivePlannedWorkoutScheduler.cancel(appContext)
                    AdaptiveDayNotifier.expirePlannedWorkoutArtifacts(
                        appContext,
                        fingerprint = fingerprint,
                    )
                } else {
                    AdaptiveDayNotifier.reconcilePlannedWorkoutArtifacts(
                        appContext,
                        currentFingerprint = fingerprint,
                    )
                    if (leadSeconds > AdaptivePlannedWorkoutSchedulePolicy.LEAD_SECONDS) {
                        val scheduled = AdaptivePlannedWorkoutScheduler.schedule(
                            context = appContext,
                            startSec = adjustment.startSec,
                            nowMillis = now.toInstant().toEpochMilli(),
                        )
                        if (scheduled) return@commitIfCurrent true
                    }
                    if (leadSeconds <= AdaptivePlannedWorkoutSchedulePolicy.LEAD_SECONDS) {
                        val snapshot = plannedWorkout ?: return@commitIfCurrent false
                        AdaptiveDayNotifier.onPlannedWorkoutAdjustment(
                            appContext,
                            day = today,
                            adjustment = adjustment,
                            evaluationToken = evaluationToken,
                            calendarRevision = snapshot.revision,
                            now = now,
                        )
                        return@commitIfCurrent true
                    }
                }
            } ?: run {
                AdaptivePlannedWorkoutScheduler.cancel(appContext)
                AdaptiveDayNotifier.reconcileMissingPlannedWorkoutArtifacts(
                    context = appContext,
                    nowSec = nowSec,
                )
            }
            recommendation?.let {
                AdaptiveDayNotifier.onRecommendation(appContext, it)
            }
            true
        }
        return recommendation
    }
}

/**
 * Privacy-safe notification side effect for evidence already ranked by [AdaptiveDayGuidance].
 * It never infers work, a party, alcohol, illness, or a medical condition.
 */
object AdaptiveDayNotifier {
    private const val CHANNEL_ID = "noop_adaptive_day"
    private const val PREFS_FILE = "noop_adaptive_day_delivery"
    private const val KEY_GLOBAL_AT = "global.at"

    fun onRecommendation(
        context: Context,
        recommendation: AdaptiveDayGuidance.Recommendation,
    ) {
        val (title, body) = copy(context, recommendation.kind)
        postCandidate(
            context = context,
            candidate = candidate(recommendation),
            title = title,
            body = body,
            route = NoopNotificationRoute.SLEEP,
            evidence = recommendation.evidence,
            onRejected = { reason ->
                if (
                    recommendation.kind == AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT &&
                    reason == AdaptiveDayDeliveryReason.DUPLICATE
                ) {
                    AdaptiveDayTimeZoneStore.discardPending(context)
                }
            },
            onPosted = {
                if (recommendation.kind == AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT) {
                    AdaptiveDayTimeZoneStore.discardPending(context)
                }
            },
        )
    }

    fun onPlannedWorkoutAdjustment(
        context: Context,
        day: String,
        adjustment: DailyActionPlanner.WorkoutAdjustment,
        evaluationToken: Long,
        calendarRevision: Long,
        now: ZonedDateTime = ZonedDateTime.now(),
    ) {
        val observedAtMillis = now.toInstant().toEpochMilli()
        val candidate = AdaptiveDayDeliveryCandidate(
            kind = AdaptiveDayDeliveryKind.PLANNED_WORKOUT,
            observedAtMillis = observedAtMillis,
            maximumAgeMillis = plannedWorkoutMaximumAgeMillis(
                startSec = adjustment.startSec,
                observedAtMillis = observedAtMillis,
            ),
            fingerprint = plannedWorkoutFingerprint(day, adjustment),
            evaluationToken = evaluationToken,
            calendarRevision = calendarRevision,
        )
        postCandidate(
            context = context,
            candidate = candidate,
            title = context.getString(
                R.string.appwide_adaptive_day_guidance_planned_workout_title,
            ),
            body = context.getString(
                R.string.appwide_adaptive_day_guidance_planned_workout_body,
            ),
            route = NoopNotificationRoute.WORKOUTS,
            evidence = plannedWorkoutEvidenceResources(adjustment.reason).map(context::getString),
        )
    }

    internal fun plannedWorkoutFingerprint(
        day: String,
        adjustment: DailyActionPlanner.WorkoutAdjustment,
    ): String = listOf(
        "planned-workout",
        day,
        adjustment.startSec,
    ).joinToString("|")

    internal fun plannedWorkoutStartSec(fingerprint: String): Long? {
        return plannedWorkoutIdentity(fingerprint)?.second
    }

    internal fun plannedWorkoutFingerprintsMatch(
        first: String?,
        second: String?,
    ): Boolean {
        if (first == null || second == null) return first == null && second == null
        if (first == second) return true
        val firstIdentity = plannedWorkoutIdentity(first) ?: return false
        val secondIdentity = plannedWorkoutIdentity(second) ?: return false
        return firstIdentity == secondIdentity
    }

    private fun plannedWorkoutIdentity(fingerprint: String): Pair<String, Long>? {
        val fields = fingerprint.split('|')
        if (
            fields.size !in 3..4 ||
            fields[0] != "planned-workout" ||
            fields[1].isBlank()
        ) {
            return null
        }
        return fields[2].toLongOrNull()?.let { fields[1] to it }
    }

    internal fun plannedWorkoutMaximumAgeMillis(
        startSec: Long,
        observedAtMillis: Long,
    ): Long = (startSec * 1_000L - observedAtMillis).coerceAtLeast(0L)

    internal fun plannedWorkoutRemainingLifetimeMillis(
        observedAtMillis: Long,
        maximumAgeMillis: Long,
        postAtMillis: Long,
    ): Long? {
        if (maximumAgeMillis <= 0L) return null
        val expiresAtMillis = observedAtMillis + maximumAgeMillis
        if (expiresAtMillis < observedAtMillis) return null
        return (expiresAtMillis - postAtMillis).takeIf { it > 0L }
    }

    internal fun plannedWorkoutEvidenceResources(
        reason: DailyActionPlanner.WorkoutAdjustmentReason,
    ): List<Int> = when (reason) {
        DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT -> listOf(
            R.string.daily_plan_workout_adjustment_title,
            R.string.daily_plan_workout_adjustment_sleep_label,
        )
        DailyActionPlanner.WorkoutAdjustmentReason.RECOVERY_SHIFT -> listOf(
            R.string.daily_plan_workout_adjustment_title,
            R.string.daily_plan_evidence_readiness,
        )
        DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_AND_RECOVERY -> listOf(
            R.string.daily_plan_workout_adjustment_title,
            R.string.daily_plan_workout_adjustment_sleep_label,
            R.string.daily_plan_evidence_readiness,
        )
    }

    @SuppressLint("MissingPermission")
    @Synchronized
    private fun postCandidate(
        context: Context,
        candidate: AdaptiveDayDeliveryCandidate,
        title: String,
        body: String,
        route: NoopNotificationRoute,
        evidence: List<String>,
        onRejected: (AdaptiveDayDeliveryReason) -> Unit = {},
        onPosted: () -> Unit = {},
    ) {
        if (!NoopPrefs.adaptiveDayGuidance(context)) return
        if (
            candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT &&
            !plannedWorkoutDeliveryCurrent(context, candidate)
        ) {
            AdaptivePlannedWorkoutScheduler.cancel(context)
            suppress(context)
            return
        }
        runCatching {
            ensureChannel(context)
            if (!canNotify(context)) {
                suppress(context)
                return
            }
            val deliveryState = loadState(context)
            val quietHoursEnabled =
                NotifPrefs.getBool(context, NotifPrefs.QUIET, false)
            val quietStartMinutes =
                NotifPrefs.getInt(context, NotifPrefs.QUIET_START, 22 * 60)
            val quietEndMinutes =
                NotifPrefs.getInt(context, NotifPrefs.QUIET_END, 7 * 60)
            val deliveryNow = ZonedDateTime.now()
            val deliveryAtMillis = deliveryNow.toInstant().toEpochMilli()
            val decision = AdaptiveDayDeliveryPolicy.evaluate(
                candidate = candidate,
                state = deliveryState,
                nowMillis = deliveryAtMillis,
                localMinuteOfDay = deliveryNow.hour * 60 + deliveryNow.minute,
                quietHoursEnabled = quietHoursEnabled,
                quietStartMinutes = quietStartMinutes,
                quietEndMinutes = quietEndMinutes,
            )
            if (!decision.shouldDeliver) {
                onRejected(decision.reason)
                if (candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT) {
                    AdaptiveDayDeliveryPolicy.nextEligibleAtMillis(
                        candidate = candidate,
                        state = deliveryState,
                        notBefore = deliveryNow,
                        quietHoursEnabled = quietHoursEnabled,
                        quietStartMinutes = quietStartMinutes,
                        quietEndMinutes = quietEndMinutes,
                    )?.let { retryAtMillis ->
                        schedulePlannedWorkoutRetry(
                            context = context,
                            candidate = candidate,
                            retryAtMillis = retryAtMillis,
                            nowMillis = deliveryAtMillis,
                        )
                    }
                }
                if (decision.reason == AdaptiveDayDeliveryReason.QUIET_HOURS) suppress(context)
                return
            }

            val manager = NotificationManagerCompat.from(context)
            var calendarConsentLost = false
            var plannedWorkoutExpired = false
            val postResult = ContextualPromptDeliveryLedger.postIfAllowed(
                context,
                deliveryAtMillis,
                if (candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT) {
                    ContextualPromptDeliveryOwner.PLANNED_WORKOUT
                } else {
                    ContextualPromptDeliveryOwner.ADAPTIVE_DAY
                },
            ) {
                if (
                    candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT &&
                    !plannedWorkoutDeliveryCurrent(context, candidate)
                ) {
                    calendarConsentLost = true
                    return@postIfAllowed false
                }
                val plannedWorkoutTimeoutMillis =
                    if (candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT) {
                        plannedWorkoutRemainingLifetimeMillis(
                            observedAtMillis = candidate.observedAtMillis,
                            maximumAgeMillis = candidate.maximumAgeMillis,
                            postAtMillis = System.currentTimeMillis(),
                        ) ?: run {
                            plannedWorkoutExpired = true
                            return@postIfAllowed false
                        }
                    } else {
                        null
                    }
                val openDestination = NotificationPlatformIdentity.activityPendingIntent(
                    context,
                    NotificationPlatformIdentity.ActivityIntent.ADAPTIVE_DAY,
                    NotificationRouteBridge.launchIntent(context, route),
                )
                val notificationBuilder = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_heart)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                    .setContentIntent(openDestination)
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                if (plannedWorkoutTimeoutMillis != null) {
                    notificationBuilder.setTimeoutAfter(plannedWorkoutTimeoutMillis)
                }
                val notification = notificationBuilder.build()
                val posted = NotificationLifecycleLedger.posted(
                    context,
                    NotificationLifecycleId.ADAPTIVE_DAY,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    manager.notify(NotificationPlatformIdentity.NotificationId.ADAPTIVE_DAY, notification)
                }
                if (
                    posted &&
                    candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT &&
                    !plannedWorkoutDeliveryCurrent(context, candidate)
                ) {
                    calendarConsentLost = true
                    NotificationLifecycleLedger.cancelled(
                        context,
                        NotificationLifecycleId.ADAPTIVE_DAY,
                        NotificationLifecycleCategory.RECOMMENDATION,
                    ) {
                        manager.cancel(NotificationPlatformIdentity.NotificationId.ADAPTIVE_DAY)
                    }
                    return@postIfAllowed false
                }
                posted
            }
            if (plannedWorkoutExpired) {
                onRejected(AdaptiveDayDeliveryReason.STALE)
                suppress(context)
                return
            }
            if (calendarConsentLost) {
                AdaptivePlannedWorkoutScheduler.cancel(context)
                suppress(context)
                return
            }
            if (postResult != ContextualPromptPostResult.POSTED) {
                if (postResult == ContextualPromptPostResult.GLOBAL_COOLDOWN) {
                    if (candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT) {
                        ContextualPromptDeliveryLedger.nextAllowedAtMillis(
                            context,
                            deliveryAtMillis,
                        )?.let { retryAtMillis ->
                            schedulePlannedWorkoutRetry(
                                context = context,
                                candidate = candidate,
                                retryAtMillis = retryAtMillis,
                                nowMillis = deliveryAtMillis,
                            )
                        }
                    }
                    suppress(context)
                }
                return
            }
            if (
                candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT &&
                !plannedWorkoutDeliveryCurrent(context, candidate)
            ) {
                ContextualPromptDeliveryLedger.reconcileIfOwned(
                    context,
                    ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                    expectedAtMillis = deliveryAtMillis,
                )
                NotificationLifecycleLedger.cancelled(
                    context,
                    NotificationLifecycleId.ADAPTIVE_DAY,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    manager.cancel(NotificationPlatformIdentity.NotificationId.ADAPTIVE_DAY)
                }
                AdaptivePlannedWorkoutScheduler.cancel(context)
                suppress(context)
                return
            }
            ContextualActionCenter.presentRecovery(
                context = context,
                title = title,
                detail = body,
                fingerprint = candidate.fingerprint,
                evidence = evidence,
                observedAtMillis = candidate.observedAtMillis,
                maximumAgeMillis = candidate.maximumAgeMillis,
                route = route,
            )
            if (
                candidate.kind == AdaptiveDayDeliveryKind.PLANNED_WORKOUT &&
                !plannedWorkoutDeliveryCurrent(context, candidate)
            ) {
                ContextualActionCenter.reconcileRecoveryActions(
                    context = context,
                    route = NoopNotificationRoute.WORKOUTS,
                    keepingFingerprint = null,
                )
                ContextualPromptDeliveryLedger.reconcileIfOwned(
                    context,
                    ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                    expectedAtMillis = deliveryAtMillis,
                )
                NotificationLifecycleLedger.cancelled(
                    context,
                    NotificationLifecycleId.ADAPTIVE_DAY,
                    NotificationLifecycleCategory.RECOMMENDATION,
                ) {
                    manager.cancel(NotificationPlatformIdentity.NotificationId.ADAPTIVE_DAY)
                }
                AdaptivePlannedWorkoutScheduler.cancel(context)
                suppress(context)
                return
            }
            saveState(context, decision.nextState)
            onPosted()
        }.onFailure {
            NotificationLifecycleLedger.unknown(
                context,
                NotificationLifecycleId.ADAPTIVE_DAY,
                NotificationLifecycleCategory.RECOMMENDATION,
            )
        }
    }

    private fun schedulePlannedWorkoutRetry(
        context: Context,
        candidate: AdaptiveDayDeliveryCandidate,
        retryAtMillis: Long,
        nowMillis: Long,
    ) {
        val expiresAtMillis = candidate.observedAtMillis + candidate.maximumAgeMillis
        if (
            candidate.kind != AdaptiveDayDeliveryKind.PLANNED_WORKOUT ||
            candidate.maximumAgeMillis <= 0L ||
            expiresAtMillis < candidate.observedAtMillis
        ) {
            return
        }
        AdaptivePlannedWorkoutScheduler.scheduleRetry(
            context = context,
            startSec = expiresAtMillis / 1_000L,
            retryAtMillis = retryAtMillis,
            nowMillis = nowMillis,
        )
    }

    private fun plannedWorkoutDeliveryCurrent(
        context: Context,
        candidate: AdaptiveDayDeliveryCandidate,
    ): Boolean {
        if (candidate.kind != AdaptiveDayDeliveryKind.PLANNED_WORKOUT) return true
        val evaluationToken = candidate.evaluationToken ?: return false
        val calendarRevision = candidate.calendarRevision ?: return false
        return NoopPrefs.adaptiveDayGuidance(context) &&
            NoopPrefs.plannedWorkoutCalendar(context) &&
            AdaptiveDayEvaluationGate.isCurrent(evaluationToken) &&
            PlannedWorkoutCalendarStore.isCurrentRevision(calendarRevision) &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.READ_CALENDAR,
            ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Broadcast-receiver entry point. Travel can be evaluated without opening Room because the qualified
     * offset transition is itself the complete evidence; sleep/routine guidance waits for app data.
     */
    fun onTimeZoneChanged(
        context: Context,
        now: ZonedDateTime = ZonedDateTime.now(),
    ) {
        if (!ManagedRuntimeGate.isAuthorized(context.applicationContext)) return
        val nowSec = now.toEpochSecond()
        val change = AdaptiveDayTimeZoneStore.observe(context, now.offset.totalSeconds, nowSec)
        if (!NoopPrefs.adaptiveDayGuidance(context)) {
            AdaptiveDayTimeZoneStore.discardPending(context)
            return
        }
        AdaptiveDayGuidance.recommendation(
            AdaptiveDayGuidance.Input(
                today = now.toLocalDate().toString(),
                nowSec = nowSec,
                currentTimeZoneOffsetSec = now.offset.totalSeconds,
                sleepTargetMinutes = 8 * 60,
                sleepDays = emptyList(),
                sleepWindows = emptyList(),
                timeZoneChange = change,
            ),
        )?.let {
            AdaptiveDayEvaluationGate.invalidate()
            AdaptivePlannedWorkoutScheduler.cancel(context)
            reconcilePlannedWorkoutArtifacts(
                context = context,
                currentFingerprint = null,
            )
            onRecommendation(context, it)
        }
    }

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

    internal fun candidate(
        recommendation: AdaptiveDayGuidance.Recommendation,
    ): AdaptiveDayDeliveryCandidate {
        val kind = when (recommendation.kind) {
            AdaptiveDayGuidance.Kind.SLEEP_RECOVERY -> AdaptiveDayDeliveryKind.SLEEP_RECOVERY
            AdaptiveDayGuidance.Kind.ROUTINE_RECOVERY -> AdaptiveDayDeliveryKind.ROUTINE_RECOVERY
            AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT -> AdaptiveDayDeliveryKind.TRAVEL
        }
        return AdaptiveDayDeliveryCandidate(
            kind = kind,
            observedAtMillis = recommendation.observedAtSec * 1_000L,
            maximumAgeMillis = recommendation.maximumAgeSeconds * 1_000L,
            fingerprint = recommendation.fingerprint,
        )
    }

    private fun copy(
        context: Context,
        kind: AdaptiveDayGuidance.Kind,
    ): Pair<String, String> = when (kind) {
        AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT ->
            context.getString(R.string.appwide_adaptive_day_guidance_travel_title) to
                context.getString(R.string.appwide_adaptive_day_guidance_travel_body)
        AdaptiveDayGuidance.Kind.ROUTINE_RECOVERY ->
            context.getString(R.string.appwide_adaptive_day_guidance_routine_title) to
                context.getString(R.string.appwide_adaptive_day_guidance_routine_body)
        AdaptiveDayGuidance.Kind.SLEEP_RECOVERY ->
            context.getString(R.string.appwide_adaptive_day_guidance_sleep_title) to
                context.getString(R.string.appwide_adaptive_day_guidance_sleep_body)
    }

    private fun loadState(context: Context): AdaptiveDayDeliveryState {
        val prefs = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val deliveries = AdaptiveDayDeliveryKind.entries.mapNotNull { kind ->
            val atKey = "${kind.name}.at"
            val fingerprint = prefs.getString("${kind.name}.fingerprint", null)
            if (!prefs.contains(atKey) || fingerprint == null) null
            else kind to AdaptiveDayDelivery(prefs.getLong(atKey, 0), fingerprint)
        }.toMap()
        return AdaptiveDayDeliveryState(
            lastGlobalDeliveryMillis = prefs.getLong(KEY_GLOBAL_AT, 0)
                .takeIf { prefs.contains(KEY_GLOBAL_AT) },
            deliveries = deliveries,
        )
    }

    @Synchronized
    internal fun expirePlannedWorkoutArtifacts(
        context: Context,
        fingerprint: String,
    ) {
        val app = context.applicationContext
        val state = loadState(app)
        val prior = state.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT]
        if (
            prior != null &&
            !plannedWorkoutFingerprintsMatch(prior.fingerprint, fingerprint)
        ) {
            return
        }
        ContextualActionCenter.reconcileRecoveryActions(
            context = app,
            route = NoopNotificationRoute.WORKOUTS,
            keepingFingerprint = null,
        )
        if (
            prior != null &&
            plannedWorkoutFingerprintsMatch(prior.fingerprint, fingerprint) &&
            state.lastGlobalDeliveryMillis == prior.atMillis
        ) {
            cancelAdaptiveDayNotification(app)
        }
    }

    @Synchronized
    internal fun reconcileMissingPlannedWorkoutArtifacts(
        context: Context,
        nowSec: Long,
    ) {
        val app = context.applicationContext
        val prior = loadState(app).deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT]
        if (
            prior != null &&
            plannedWorkoutStartSec(prior.fingerprint)?.let { it <= nowSec } == true
        ) {
            expirePlannedWorkoutArtifacts(app, prior.fingerprint)
            return
        }
        reconcilePlannedWorkoutArtifacts(app, currentFingerprint = null)
    }

    @Synchronized
    internal fun reconcilePlannedWorkoutArtifacts(
        context: Context,
        currentFingerprint: String?,
        forceCancelSharedNotification: Boolean = false,
    ) {
        val app = context.applicationContext
        val state = loadState(app)
        val prior = state.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT]
        if (currentFingerprint != null) {
            ContextualActionCenter.migrateRecoveryAction(
                context = app,
                route = NoopNotificationRoute.WORKOUTS,
                toFingerprint = currentFingerprint,
            ) {
                plannedWorkoutFingerprintsMatch(it, currentFingerprint)
            }
        }
        if (prior == null) {
            ContextualActionCenter.reconcileRecoveryActions(
                context = app,
                route = NoopNotificationRoute.WORKOUTS,
                keepingFingerprint = currentFingerprint,
            )
            val orphanedOwner = if (
                currentFingerprint == null || forceCancelSharedNotification
            ) {
                ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(
                    context = app,
                    owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                    onNotificationSlotOwnerRemoved = {
                        cancelAdaptiveDayNotification(app)
                    },
                )
            } else {
                null
            }
            if (
                forceCancelSharedNotification &&
                orphanedOwner?.ownedNotificationSlot != true
            ) {
                cancelAdaptiveDayNotification(app)
            }
            return
        }
        val remainsCurrent =
            currentFingerprint != null &&
                plannedWorkoutFingerprintsMatch(prior.fingerprint, currentFingerprint)
        ContextualActionCenter.reconcileRecoveryActions(
            context = app,
            route = NoopNotificationRoute.WORKOUTS,
            keepingFingerprint = currentFingerprint,
        )
        if (remainsCurrent) {
            val migrated = reconciledPlannedWorkoutState(state, currentFingerprint)
            if (migrated != state) saveState(app, migrated)
            return
        }

        ContextualPromptDeliveryLedger.reconcileIfOwned(
            context = app,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = prior.atMillis,
        )
        saveState(app, reconciledPlannedWorkoutState(state, currentFingerprint))
        if (forceCancelSharedNotification || state.lastGlobalDeliveryMillis == prior.atMillis) {
            cancelAdaptiveDayNotification(app)
        }
    }

    private fun cancelAdaptiveDayNotification(context: Context) {
        val manager = NotificationManagerCompat.from(context)
        NotificationLifecycleLedger.cancelled(
            context,
            NotificationLifecycleId.ADAPTIVE_DAY,
            NotificationLifecycleCategory.RECOMMENDATION,
        ) {
            manager.cancel(NotificationPlatformIdentity.NotificationId.ADAPTIVE_DAY)
        }
    }

    internal fun reconciledPlannedWorkoutState(
        state: AdaptiveDayDeliveryState,
        currentFingerprint: String?,
    ): AdaptiveDayDeliveryState {
        val prior = state.deliveries[AdaptiveDayDeliveryKind.PLANNED_WORKOUT]
            ?: return state
        if (
            currentFingerprint != null &&
            plannedWorkoutFingerprintsMatch(prior.fingerprint, currentFingerprint)
        ) {
            if (prior.fingerprint == currentFingerprint) return state
            return state.copy(
                deliveries = state.deliveries +
                    (AdaptiveDayDeliveryKind.PLANNED_WORKOUT to
                        prior.copy(fingerprint = currentFingerprint)),
            )
        }
        val remaining = state.deliveries - AdaptiveDayDeliveryKind.PLANNED_WORKOUT
        return state.copy(
            lastGlobalDeliveryMillis = remaining.values.maxOfOrNull { it.atMillis },
            deliveries = remaining,
        )
    }

    private fun saveState(context: Context, state: AdaptiveDayDeliveryState) {
        val editor = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .edit()
            .clear()
        state.lastGlobalDeliveryMillis?.let { editor.putLong(KEY_GLOBAL_AT, it) }
        for ((kind, delivery) in state.deliveries) {
            editor.putLong("${kind.name}.at", delivery.atMillis)
            editor.putString("${kind.name}.fingerprint", delivery.fingerprint)
        }
        editor.apply()
    }

    private fun suppress(context: Context) {
        NotificationLifecycleLedger.suppressed(
            context,
            NotificationLifecycleId.ADAPTIVE_DAY,
            NotificationLifecycleCategory.RECOMMENDATION,
        )
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.appwide_adaptive_day_guidance_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(
                    R.string.appwide_adaptive_day_guidance_channel_description,
                )
            },
        )
    }
}
