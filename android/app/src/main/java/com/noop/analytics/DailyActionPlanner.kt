package com.noop.analytics

import java.time.LocalDate
import kotlin.math.ceil
import kotlin.math.floor

/**
 * Conservative daily planning contract. A wearable read never grants permission to train.
 *
 * A numeric range requires an "as usual" same-day self-check, a solid multi-signal readiness read,
 * and enough prior scored Effort days to describe the user's own normal range. PRIMED never raises
 * the range; readiness is a confidence gate, not a load bonus. Swift twin: DailyActionPlanner.swift.
 */
object DailyActionPlanner {
    enum class CheckIn(val storedValue: String) {
        UNANSWERED("unanswered"),
        AS_USUAL("asUsual"),
        BELOW_USUAL("belowUsual"),
        PAIN_OR_UNWELL("painOrUnwell");

        companion object {
            fun fromStoredValue(raw: String?): CheckIn? = entries.firstOrNull { it.storedValue == raw }
        }
    }
    data class SleepDay(val day: String, val minutes: Double?)
    data class PlannedWorkout(val day: String, val startSec: Long, val endSec: Long)
    enum class WorkoutAdjustmentReason { SLEEP_DEFICIT, RECOVERY_SHIFT, SLEEP_AND_RECOVERY }
    enum class SleepReference { PERSONAL_USUAL, EXPLICIT_TARGET }
    data class WorkoutAdjustment(
        val startSec: Long,
        val durationMinutes: Int,
        val reason: WorkoutAdjustmentReason,
        val measuredSleepMinutes: Int?,
        val referenceSleepMinutes: Int?,
        val sleepDeficitMinutes: Int?,
        val sleepReference: SleepReference?,
        val confidence: ScoreConfidence,
    )
    enum class Availability { READY, CHECK_IN_NEEDED, CALIBRATING, RECOVERY_SHIFT, STOP }
    enum class Action {
        COMPLETE_CHECK_IN, KEEP_SLEEP_WINDOW, PROTECT_EXTRA_SLEEP, CHOOSE_EASY_DAY, STOP_AND_ASSESS,
    }
    enum class EvidenceSource { SELF_CHECK, READINESS_BASELINE, PERSONAL_EFFORT_HISTORY, SLEEP_PLAN }

    data class EffortDay(val day: String, val effort: Double?)
    data class EffortRange(val lower: Int, val upper: Int)
    data class Evidence(val source: EvidenceSource, val detail: String)
    data class Plan(
        val day: String,
        val availability: Availability,
        /** Personal planning range on NOOP's canonical 0-100 Effort scale. */
        val target: EffortRange?,
        val confidence: ScoreConfidence,
        val action: Action,
        val evidence: List<Evidence>,
        val limitations: List<String>,
        val workoutAdjustment: WorkoutAdjustment? = null,
    )

    const val HISTORY_WINDOW_DAYS = 28
    const val MINIMUM_EFFORT_DAYS = 7
    const val SOLID_EFFORT_DAYS = 14
    const val EXTRA_SLEEP_ACTION_THRESHOLD_MINUTES = 30
    const val SLEEP_HISTORY_WINDOW_DAYS = 21
    const val MINIMUM_USUAL_SLEEP_NIGHTS = 5
    const val SOLID_USUAL_SLEEP_NIGHTS = 7
    const val WORKOUT_SLEEP_DEFICIT_THRESHOLD_MINUTES = 45
    const val MINIMUM_PLANNED_WORKOUT_MINUTES = 10
    const val MAXIMUM_PLANNED_WORKOUT_MINUTES = 6 * 60
    const val MAXIMUM_PLANNED_WORKOUT_LEAD_SECONDS = 24 * 60 * 60L

    private const val planningLimitation =
        "This is a personal planning range, not a safety limit, diagnosis, or medical clearance."

    fun plan(
        today: String,
        readiness: ReadinessEngine.Readiness,
        checkIn: CheckIn,
        recentEffort: List<EffortDay>,
        sleepRecoveryMinutes: Int = 0,
        sleepConfidence: ScoreConfidence = ScoreConfidence.CALIBRATING,
        recentSleep: List<SleepDay> = emptyList(),
        sleepTargetMinutes: Int = 8 * 60,
        sleepTargetIsExplicit: Boolean = false,
        plannedWorkout: PlannedWorkout? = null,
        nowSec: Long = System.currentTimeMillis() / 1_000L,
    ): Plan {
        val selfEvidence = Evidence(EvidenceSource.SELF_CHECK, checkIn.storedValue)
        val plannedAdjustment = workoutAdjustment(
            today = today,
            nowSec = nowSec,
            readiness = readiness,
            recentSleep = recentSleep,
            sleepTargetMinutes = sleepTargetMinutes,
            sleepTargetIsExplicit = sleepTargetIsExplicit,
            plannedWorkout = plannedWorkout,
        )

        if (checkIn == CheckIn.PAIN_OR_UNWELL) {
            return Plan(
                today, Availability.STOP, null, ScoreConfidence.CALIBRATING, Action.STOP_AND_ASSESS,
                listOf(selfEvidence),
                listOf(planningLimitation, "A symptom or pain check-in always overrides wearable data."),
            )
        }
        if (checkIn == CheckIn.UNANSWERED) {
            return Plan(
                today, Availability.CHECK_IN_NEEDED, null, ScoreConfidence.CALIBRATING,
                Action.COMPLETE_CHECK_IN, emptyList(),
                listOf(planningLimitation, "A same-day self-check is required before showing a range."),
                plannedAdjustment,
            )
        }
        if (checkIn == CheckIn.BELOW_USUAL) {
            return Plan(
                today, Availability.RECOVERY_SHIFT, null, ScoreConfidence.CALIBRATING,
                Action.CHOOSE_EASY_DAY, listOf(selfEvidence),
                listOf(planningLimitation, "How you feel takes priority over an aligned wearable read."),
                plannedAdjustment,
            )
        }
        if (readiness.asOfDay != today) {
            return Plan(
                today, Availability.CALIBRATING, null, ScoreConfidence.CALIBRATING,
                Action.KEEP_SLEEP_WINDOW, listOf(selfEvidence),
                listOf(planningLimitation, "No current readiness read is available for this date."),
                plannedAdjustment,
            )
        }

        val recoverySignals = readiness.signals.filter {
            it.key == "hrv" || it.key == "rhr" || it.key == "respRate"
        }
        val readinessEvidence = Evidence(
            EvidenceSource.READINESS_BASELINE,
            "${recoverySignals.size} current signals, ${readiness.baselineDays} prior days",
        )
        if (readiness.level == ReadinessEngine.Level.STRAINED ||
            readiness.level == ReadinessEngine.Level.RUNDOWN
        ) {
            return Plan(
                today, Availability.RECOVERY_SHIFT, null, readiness.confidence, Action.CHOOSE_EASY_DAY,
                listOf(selfEvidence, readinessEvidence),
                listOf(
                    planningLimitation,
                    "A measured recovery shift withholds the range; it does not diagnose a cause.",
                ),
                plannedAdjustment,
            )
        }
        if (readiness.confidence != ScoreConfidence.SOLID ||
            (readiness.level != ReadinessEngine.Level.BALANCED &&
                readiness.level != ReadinessEngine.Level.PRIMED)
        ) {
            return Plan(
                today, Availability.CALIBRATING, null, readiness.confidence, Action.KEEP_SLEEP_WINDOW,
                listOf(selfEvidence, readinessEvidence),
                listOf(
                    planningLimitation,
                    "At least two current signals and a trusted personal baseline are required.",
                ),
                plannedAdjustment,
            )
        }

        val values = effortValues(recentEffort, today)
        val effortEvidence = Evidence(
            EvidenceSource.PERSONAL_EFFORT_HISTORY,
            "${values.size} scored days in the prior $HISTORY_WINDOW_DAYS days",
        )
        val target = planningRange(values)
        if (values.size < MINIMUM_EFFORT_DAYS || target == null) {
            return Plan(
                today, Availability.CALIBRATING, null, ScoreConfidence.CALIBRATING,
                Action.KEEP_SLEEP_WINDOW, listOf(selfEvidence, readinessEvidence, effortEvidence),
                listOf(
                    planningLimitation,
                    "At least $MINIMUM_EFFORT_DAYS prior scored Effort days are required.",
                ),
                plannedAdjustment,
            )
        }

        val boundedSleepRecovery = sleepRecoveryMinutes.coerceIn(0, 60)
        val supportedExtraSleep =
            boundedSleepRecovery >= EXTRA_SLEEP_ACTION_THRESHOLD_MINUTES &&
                sleepConfidence != ScoreConfidence.CALIBRATING
        val evidence = mutableListOf(selfEvidence, readinessEvidence, effortEvidence)
        if (supportedExtraSleep) {
            evidence += Evidence(
                EvidenceSource.SLEEP_PLAN,
                "$boundedSleepRecovery min recovery addition",
            )
        }
        return Plan(
            today,
            Availability.READY,
            target,
            if (values.size >= SOLID_EFFORT_DAYS) ScoreConfidence.SOLID else ScoreConfidence.BUILDING,
            if (supportedExtraSleep) Action.PROTECT_EXTRA_SLEEP else Action.KEEP_SLEEP_WINDOW,
            evidence,
            listOf(
                planningLimitation,
                "Aligned readiness never raises the range above the user's recent normal Effort.",
            ),
            plannedAdjustment,
        )
    }

    internal fun workoutAdjustment(
        today: String,
        nowSec: Long,
        readiness: ReadinessEngine.Readiness,
        recentSleep: List<SleepDay>,
        sleepTargetMinutes: Int,
        sleepTargetIsExplicit: Boolean,
        plannedWorkout: PlannedWorkout?,
    ): WorkoutAdjustment? {
        val workout = plannedWorkout ?: return null
        if (
            workout.day != today ||
            workout.startSec <= nowSec ||
            workout.startSec - nowSec > MAXIMUM_PLANNED_WORKOUT_LEAD_SECONDS ||
            workout.endSec <= workout.startSec
        ) return null
        val durationMinutes = ((workout.endSec - workout.startSec) / 60L).toInt()
        if (durationMinutes !in MINIMUM_PLANNED_WORKOUT_MINUTES..MAXIMUM_PLANNED_WORKOUT_MINUTES) {
            return null
        }

        val sleep = sleepContext(
            recentSleep,
            today,
            sleepTargetMinutes,
            sleepTargetIsExplicit,
        )
        val recoveryShift =
            readiness.asOfDay == today &&
                readiness.confidence != ScoreConfidence.CALIBRATING &&
                (
                    readiness.level == ReadinessEngine.Level.STRAINED ||
                        readiness.level == ReadinessEngine.Level.RUNDOWN
                    )
        if (sleep == null && !recoveryShift) return null
        val reason = when {
            sleep != null && recoveryShift -> WorkoutAdjustmentReason.SLEEP_AND_RECOVERY
            sleep != null -> WorkoutAdjustmentReason.SLEEP_DEFICIT
            else -> WorkoutAdjustmentReason.RECOVERY_SHIFT
        }
        val confidence = when {
            sleep == null -> if (readiness.confidence == ScoreConfidence.SOLID) {
                ScoreConfidence.SOLID
            } else {
                ScoreConfidence.BUILDING
            }
            !recoveryShift -> sleep.confidence
            sleep.confidence == ScoreConfidence.SOLID &&
                readiness.confidence == ScoreConfidence.SOLID -> ScoreConfidence.SOLID
            else -> ScoreConfidence.BUILDING
        }
        return WorkoutAdjustment(
            startSec = workout.startSec,
            durationMinutes = durationMinutes,
            reason = reason,
            measuredSleepMinutes = sleep?.measuredMinutes,
            referenceSleepMinutes = sleep?.referenceMinutes,
            sleepDeficitMinutes = sleep?.deficitMinutes,
            sleepReference = sleep?.reference,
            confidence = confidence,
        )
    }

    private data class SleepContext(
        val measuredMinutes: Int,
        val referenceMinutes: Int,
        val deficitMinutes: Int,
        val reference: SleepReference,
        val confidence: ScoreConfidence,
    )

    private fun sleepContext(
        days: List<SleepDay>,
        today: String,
        sleepTargetMinutes: Int,
        sleepTargetIsExplicit: Boolean,
    ): SleepContext? {
        val grouped = validSleepByDay(days, today)
        val current = grouped[today] ?: return null
        val prior = grouped
            .filterKeys { it < today }
            .toSortedMap()
            .values
            .toList()
            .takeLast(SLEEP_HISTORY_WINDOW_DAYS)
        val reference: Double
        val source: SleepReference
        val confidence: ScoreConfidence
        if (prior.size >= MINIMUM_USUAL_SLEEP_NIGHTS) {
            reference = quantile(prior.sorted(), 0.5)
            source = SleepReference.PERSONAL_USUAL
            confidence = if (prior.size >= SOLID_USUAL_SLEEP_NIGHTS) {
                ScoreConfidence.SOLID
            } else {
                ScoreConfidence.BUILDING
            }
        } else {
            if (!sleepTargetIsExplicit) return null
            reference = sleepTargetMinutes.coerceIn(5 * 60, 11 * 60).toDouble()
            source = SleepReference.EXPLICIT_TARGET
            confidence = ScoreConfidence.BUILDING
        }
        val deficit = kotlin.math.round(reference - current).toInt()
        if (deficit < WORKOUT_SLEEP_DEFICIT_THRESHOLD_MINUTES) return null
        return SleepContext(
            measuredMinutes = kotlin.math.round(current).toInt(),
            referenceMinutes = kotlin.math.round(reference).toInt(),
            deficitMinutes = deficit,
            reference = source,
            confidence = confidence,
        )
    }

    private fun validSleepByDay(days: List<SleepDay>, through: String): Map<String, Double> {
        val end = runCatching { LocalDate.parse(through).takeIf { it.toString() == through } }
            .getOrNull() ?: return emptyMap()
        val start = end.minusDays(SLEEP_HISTORY_WINDOW_DAYS.toLong()).toString()
        val grouped = mutableMapOf<String, MutableList<Double>>()
        for (row in days) {
            if (row.day < start || row.day > through) continue
            val parsed = runCatching {
                LocalDate.parse(row.day).takeIf { it.toString() == row.day }
            }.getOrNull() ?: continue
            if (parsed.isBefore(end.minusDays(SLEEP_HISTORY_WINDOW_DAYS.toLong())) || parsed.isAfter(end)) {
                continue
            }
            val minutes = row.minutes
            if (minutes == null || !minutes.isFinite() || minutes !in 120.0..900.0) continue
            grouped.getOrPut(row.day) { mutableListOf() }.add(minutes)
        }
        return grouped.mapValues { (_, values) -> values.average() }
    }

    /** One deterministic value per prior calendar day in [today-28, today-1]. */
    internal fun effortValues(days: List<EffortDay>, before: String): List<Double> {
        val end = runCatching { LocalDate.parse(before).takeIf { it.toString() == before } }.getOrNull()
            ?: return emptyList()
        val start = end.minusDays(HISTORY_WINDOW_DAYS.toLong()).toString()
        val grouped = mutableMapOf<String, MutableList<Double>>()
        for (row in days) {
            if (row.day < start || row.day >= before) continue
            val parsed = runCatching {
                LocalDate.parse(row.day).takeIf { it.toString() == row.day }
            }.getOrNull() ?: continue
            if (parsed.isBefore(end.minusDays(HISTORY_WINDOW_DAYS.toLong())) || !parsed.isBefore(end)) continue
            val effort = row.effort
            if (effort == null || !effort.isFinite() || effort !in 0.0..100.0) continue
            grouped.getOrPut(row.day) { mutableListOf() }.add(effort)
        }
        return grouped.keys.sorted().map { day -> grouped.getValue(day).average() }
    }

    internal fun planningRange(values: List<Double>): EffortRange? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        var lower = (floor(quantile(sorted, 0.25) / 5.0) * 5.0).toInt()
        var upper = (ceil(quantile(sorted, 0.75) / 5.0) * 5.0).toInt()
        if (upper - lower < 10) {
            val center = quantile(sorted, 0.5)
            lower = (floor((center - 5.0) / 5.0) * 5.0).toInt()
            upper = (ceil((center + 5.0) / 5.0) * 5.0).toInt()
        }
        lower = lower.coerceIn(0, 100)
        upper = upper.coerceIn(0, 100)
        if (upper - lower < 10) {
            if (lower == 0) {
                upper = minOf(100, lower + 10)
            } else if (upper == 100) {
                lower = maxOf(0, upper - 10)
            } else {
                upper = minOf(100, lower + 10)
            }
        }
        return EffortRange(lower, upper)
    }

    internal fun quantile(sorted: List<Double>, q: Double): Double {
        if (sorted.size <= 1) return sorted.firstOrNull() ?: 0.0
        val position = q.coerceIn(0.0, 1.0) * (sorted.size - 1)
        val lower = floor(position).toInt()
        val upper = minOf(lower + 1, sorted.lastIndex)
        val fraction = position - lower
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}
