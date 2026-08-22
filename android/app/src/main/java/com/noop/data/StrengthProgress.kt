package com.noop.data

/** One completed session's factual record for an exercise. */
data class StrengthExerciseHistoryPoint(
    val sessionId: String,
    val startedAt: Long,
    val completedSetCount: Int,
    val totalReps: Int,
    val maxReps: Int?,
    val maxLoadKg: Double?,
    val bestSetVolumeKg: Double?,
)

/** Completed manual work inside an explicit time window. */
data class StrengthWeeklyProgress(
    val sessionCount: Int,
    val completedSetCount: Int,
    val totalReps: Int,
    val loadedVolumeKg: Double,
)

/**
 * Set exposure by catalog muscle. Primary muscles receive one set of credit and secondary muscles
 * receive half a set. This is a training-log distribution, not a physiological load estimate.
 */
data class StrengthMuscleFocus(
    val muscle: String,
    val directSetCount: Int,
    val supportingSetCount: Int,
    val weightedSetExposure: Double,
)

/** Pure progress views over the normalized strength log. Mirrors Swift value-for-value. */
object StrengthProgressCalculator {
    fun exerciseHistory(
        exerciseId: String,
        sessions: List<StrengthSessionSnapshot>,
    ): List<StrengthExerciseHistoryPoint> =
        sessions.mapNotNull { snapshot ->
            if (snapshot.session.endedAt == null) return@mapNotNull null
            val sets = snapshot.sets.filter {
                it.exerciseId == exerciseId && it.completedAt != null
            }
            if (sets.isEmpty()) return@mapNotNull null
            StrengthExerciseHistoryPoint(
                sessionId = snapshot.session.id,
                startedAt = snapshot.session.startedAt,
                completedSetCount = sets.size,
                totalReps = sets.mapNotNull { it.reps }.sum(),
                maxReps = sets.mapNotNull { it.reps }.maxOrNull(),
                maxLoadKg = sets.mapNotNull { it.loadKg }.maxOrNull(),
                bestSetVolumeKg = sets.mapNotNull { it.volumeKg }.maxOrNull(),
            )
        }.sortedWith(
            compareByDescending<StrengthExerciseHistoryPoint> { it.startedAt }
                .thenBy { it.sessionId },
        )

    fun weeklyProgress(
        sessions: List<StrengthSessionSnapshot>,
        from: Long,
        to: Long,
    ): StrengthWeeklyProgress {
        if (to < from) return StrengthWeeklyProgress(0, 0, 0, 0.0)
        val included = sessions.filter {
            it.session.endedAt != null && it.session.startedAt in from..to
        }
        val sets = included.flatMap { it.sets }.filter { it.completedAt != null }
        return StrengthWeeklyProgress(
            sessionCount = included.size,
            completedSetCount = sets.size,
            totalReps = sets.mapNotNull { it.reps }.sum(),
            loadedVolumeKg = sets.mapNotNull { it.volumeKg }.sum(),
        )
    }

    fun muscleFocus(
        exercises: List<StrengthExerciseRow>,
        sessions: List<StrengthSessionSnapshot>,
        from: Long,
        to: Long,
    ): List<StrengthMuscleFocus> {
        if (to < from) return emptyList()
        val exerciseById = exercises.associateBy { it.id }
        val direct = mutableMapOf<String, Int>()
        val supporting = mutableMapOf<String, Int>()
        sessions.asSequence()
            .filter { it.session.endedAt != null && it.session.startedAt in from..to }
            .flatMap { it.sets.asSequence() }
            .filter { it.completedAt != null }
            .forEach { set ->
                val exercise = exerciseById[set.exerciseId] ?: return@forEach
                direct[exercise.primaryMuscle] = direct.getOrDefault(exercise.primaryMuscle, 0) + 1
                StrengthTrainingContract.secondaryMuscles(exercise.secondaryMusclesJSON)
                    .orEmpty()
                    .distinct()
                    .filter { it != exercise.primaryMuscle }
                    .forEach { muscle ->
                        supporting[muscle] = supporting.getOrDefault(muscle, 0) + 1
                    }
            }
        return (direct.keys + supporting.keys).map { muscle ->
            val directSets = direct.getOrDefault(muscle, 0)
            val supportingSets = supporting.getOrDefault(muscle, 0)
            StrengthMuscleFocus(
                muscle = muscle,
                directSetCount = directSets,
                supportingSetCount = supportingSets,
                weightedSetExposure = directSets + supportingSets * 0.5,
            )
        }.sortedWith(
            compareByDescending<StrengthMuscleFocus> { it.weightedSetExposure }
                .thenBy { it.muscle },
        )
    }
}
