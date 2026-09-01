package com.noop.data

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

enum class StrengthProgressionReason {
    FIRST_SESSION,
    REPEAT_LOAD,
    REP_RANGE_ADVANCED,
    LINEAR_ADVANCED,
    TIME_ADVANCED,
    BODYWEIGHT_REP_PROGRESS,
}

data class StrengthPlannedSet(
    val setType: String,
    val reps: Int?,
    val loadKg: Double?,
    val durationS: Int?,
    val restSecondsAfter: Int?,
)

data class StrengthWorkoutPrescription(
    val sets: List<StrengthPlannedSet>,
    val reason: StrengthProgressionReason,
    val previousSessionAt: Long?,
)

data class StrengthEstimatedMaximum(
    val exerciseId: String,
    val kilograms: Double,
    val sourceLoadKg: Double,
    val sourceReps: Int,
    val sessionId: String,
    val recordedAt: Long,
)

object StrengthWorkoutPlanner {
    fun prescription(
        exercise: StrengthExerciseRow,
        prescription: StrengthRoutineExerciseRow,
        history: List<StrengthSessionSnapshot>,
    ): StrengthWorkoutPrescription {
        val plan = StrengthTrainingContract.exercisePlan(prescription.planJSON)
        val previous = history
            .filter { it.session.endedAt != null }
            .sortedWith(compareByDescending<StrengthSessionSnapshot> { it.session.startedAt }.thenBy { it.session.id })
            .firstOrNull { snapshot ->
                snapshot.sets.any {
                    it.exerciseId == exercise.id &&
                        it.completedAt != null &&
                        it.setType in PROGRESSION_SET_TYPES
                }
            }
        val previousSets = previous?.sets.orEmpty()
            .filter {
                it.exerciseId == exercise.id &&
                    it.completedAt != null &&
                    it.setType in PROGRESSION_SET_TYPES
            }
            .sortedBy { it.setPosition }
        val lower = max(1, prescription.targetRepsMin ?: 8)
        val upper = max(lower, prescription.targetRepsMax ?: lower)
        val priorLoad = previousSets.mapNotNull { it.loadKg }.maxOrNull()
        var workLoad = priorLoad ?: plan.targetLoadKg
        val compared = previousSets.take(prescription.targetSets)
        var workRepTargets = List(prescription.targetSets) { index ->
            compared.getOrNull(index)?.reps?.coerceIn(lower, upper) ?: lower
        }
        var duration = compared.mapNotNull { it.durationS }.maxOrNull() ?: plan.targetDurationS
        var reason = if (previous == null) {
            StrengthProgressionReason.FIRST_SESSION
        } else {
            StrengthProgressionReason.REPEAT_LOAD
        }
        when (plan.progression) {
            "double_progression" -> if (
                compared.size >= prescription.targetSets && compared.all { (it.reps ?: 0) >= upper }
            ) {
                if (workLoad != null) {
                    progressedLoad(workLoad, plan.loadStepKg)?.let {
                        workLoad = it
                        workRepTargets = List(prescription.targetSets) { lower }
                        reason = StrengthProgressionReason.REP_RANGE_ADVANCED
                    }
                } else {
                    val step = if (plan.repsPerSide) 2 else 1
                    val completedFloor = compared.mapNotNull { it.reps }.minOrNull() ?: upper
                    val advanced = min(
                        StrengthTrainingContract.MAX_REPS,
                        max(upper, completedFloor) + step,
                    )
                    workRepTargets = List(prescription.targetSets) { advanced }
                    if (advanced > completedFloor) {
                        reason = StrengthProgressionReason.BODYWEIGHT_REP_PROGRESS
                    }
                }
            } else if (compared.isNotEmpty()) {
                val step = if (plan.repsPerSide) 2 else 1
                workRepTargets = List(prescription.targetSets) { index ->
                    compared.getOrNull(index)?.reps
                        ?.let { min(upper, max(lower, it) + step) }
                        ?: lower
                }
            }
            "linear" -> {
                val current = workLoad
                if (
                    compared.size >= prescription.targetSets &&
                    compared.all { (it.reps ?: 0) >= lower } &&
                    current != null
                ) {
                    progressedLoad(current, plan.loadStepKg)?.let {
                        workLoad = it
                        reason = StrengthProgressionReason.LINEAR_ADVANCED
                    }
                }
            }
            "time" -> {
                val target = max(
                    plan.targetDurationS ?: 30,
                    compared.mapNotNull { it.durationS }.maxOrNull() ?: 0,
                )
                if (
                    compared.size >= prescription.targetSets &&
                    compared.all { (it.durationS ?: 0) >= target }
                ) {
                    val advanced = min(StrengthTrainingContract.MAX_DURATION_SECONDS, target + 5)
                    duration = advanced
                    if (advanced > target) reason = StrengthProgressionReason.TIME_ADVANCED
                } else {
                    duration = target
                }
            }
        }
        if (exercise.equipment == "bodyweight" && plan.targetLoadKg == null && priorLoad == null) {
            workLoad = null
        }
        val timed = plan.mode == "timed" || exercise.movementPattern == "cardio"
        val warmups = warmupRows(
            if (timed) 0 else plan.warmupSets,
            workLoad,
            workRepTargets.firstOrNull() ?: lower,
        )
        val work = (0 until prescription.targetSets).map { index ->
            StrengthPlannedSet(
                setType = if (exercise.equipment == "bodyweight" && workLoad == null) {
                    "bodyweight"
                } else {
                    "working"
                },
                reps = if (timed) null else workRepTargets[index],
                loadKg = workLoad,
                durationS = if (timed) duration ?: 30 else null,
                restSecondsAfter = null,
            )
        }.toMutableList()
        val clusterLoad = workLoad
        if (!timed && plan.setStyle == "drop" && clusterLoad != null) {
            val dropLoad = roundedLoad(clusterLoad * (1.0 - plan.dropPercent / 100.0))
            if (work.isNotEmpty() && dropLoad > 0.0 && dropLoad < clusterLoad) {
                work[work.lastIndex] = work.last().copy(restSecondsAfter = 0)
                work += StrengthPlannedSet(
                    setType = "drop",
                    reps = workRepTargets.lastOrNull() ?: lower,
                    loadKg = dropLoad,
                    durationS = null,
                    restSecondsAfter = null,
                )
            }
        } else if (!timed && plan.setStyle == "rest_pause" && work.isNotEmpty()) {
            work[work.lastIndex] = work.last().copy(restSecondsAfter = plan.restPauseSeconds)
            work += StrengthPlannedSet(
                setType = "rest_pause",
                reps = null,
                loadKg = clusterLoad,
                durationS = null,
                restSecondsAfter = null,
            )
        }
        return StrengthWorkoutPrescription(warmups + work, reason, previous?.session?.startedAt)
    }

    /**
     * Resolve the timer after a planned set. Warm-ups keep their prescription rest, while working
     * sets inside a superset wait only after the last movement in the round.
     */
    fun resolvedRestSeconds(
        target: StrengthPlannedSet,
        prescriptionRestSeconds: Int,
        continuesSuperset: Boolean,
    ): Int {
        if (target.setType == "warmup") return prescriptionRestSeconds
        return target.restSecondsAfter ?: if (continuesSuperset) 0 else prescriptionRestSeconds
    }

    fun estimatedOneRepMaximum(loadKg: Double, reps: Int): Double? {
        if (!loadKg.isFinite() || loadKg <= 0.0 || reps !in 1..10) return null
        return if (reps == 1) loadKg else loadKg * (1.0 + reps / 30.0)
    }

    fun bestEstimatedMaximum(
        exerciseId: String,
        sessions: List<StrengthSessionSnapshot>,
    ): StrengthEstimatedMaximum? =
        sessions.filter { it.session.endedAt != null }.flatMap { snapshot ->
            snapshot.sets.mapNotNull { set ->
                val load = set.loadKg
                val reps = set.reps
                if (
                    set.exerciseId != exerciseId || set.completedAt == null ||
                    set.setType !in setOf("working", "failure") || load == null || reps == null
                ) return@mapNotNull null
                val estimate = estimatedOneRepMaximum(load, reps) ?: return@mapNotNull null
                StrengthEstimatedMaximum(
                    exerciseId, estimate, load, reps, snapshot.session.id, snapshot.session.startedAt,
                )
            }
        }.maxWithOrNull(compareBy<StrengthEstimatedMaximum> { it.kilograms }.thenBy { it.recordedAt })

    private fun warmupRows(count: Int, workLoad: Double?, workReps: Int): List<StrengthPlannedSet> {
        if (count <= 0 || workLoad == null) return emptyList()
        val ladder = mapOf(
            1 to listOf(0.6 to 5),
            2 to listOf(0.5 to 5, 0.75 to 3),
            3 to listOf(0.4 to 5, 0.6 to 3, 0.8 to 2),
            4 to listOf(0.35 to 5, 0.5 to 4, 0.65 to 3, 0.8 to 2),
            5 to listOf(0.3 to 5, 0.45 to 4, 0.6 to 3, 0.72 to 2, 0.84 to 1),
        ).getValue(count.coerceAtMost(5))
        return ladder.mapNotNull { (loadFraction, suggestedReps) ->
            val load = roundedLoad(workLoad * loadFraction)
            if (load <= 0.0 || load >= workLoad) return@mapNotNull null
            StrengthPlannedSet(
                "warmup",
                max(1, min(workReps, suggestedReps)),
                load,
                null,
                null,
            )
        }
    }

    private fun roundedLoad(kilograms: Double): Double = floor(kilograms * 2.0 + 0.5) / 2.0

    private val PROGRESSION_SET_TYPES = setOf("working", "failure", "bodyweight")

    /**
     * ACSM recommends a 2–10% load increase after the target is exceeded. Respect the configured
     * increment while capping it at 10%; if 0.5 kg resolution would exceed that cap, hold the load.
     */
    private fun progressedLoad(current: Double, configuredStep: Double): Double? {
        if (!current.isFinite() || current <= 0.0 || !configuredStep.isFinite() || configuredStep <= 0.0) {
            return null
        }
        val maximumIncrease = current * 0.10
        val unrounded = current + min(configuredStep, maximumIncrease)
        var candidate = roundedLoad(unrounded)
        if (candidate - current > maximumIncrease + 0.000_001) {
            candidate = floor(unrounded * 2.0) / 2.0
        }
        return candidate.takeIf { it > current }
    }

}
