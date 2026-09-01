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

/**
 * Transparent body-map estimate from completed working sets only. Load uses seven-day weighted set
 * exposure; recovery is the inverse of residual exposure fading over 72 hours.
 */
data class StrengthMuscleStatus(
    val muscle: String,
    val sevenDayExposure: Double,
    val loadScore: Double,
    val recoveryScore: Double,
    val lastTrainedAt: Long?,
) {
    val residualLoadScore: Double
        get() = 1.0 - recoveryScore
}

/** Pure progress views over the normalized strength log. Mirrors Swift value-for-value. */
object StrengthProgressCalculator {
    val BODY_MAP_MUSCLES = listOf(
        "chest", "back", "shoulders", "biceps", "triceps", "forearms", "core",
        "quadriceps", "hamstrings", "glutes", "calves",
    )
    const val LOAD_WINDOW_SECONDS = 7L * 24L * 60L * 60L
    const val RECOVERY_WINDOW_SECONDS = 72L * 60L * 60L
    const val FULL_LOAD_EXPOSURE = 12.0
    const val FULL_RESIDUAL_EXPOSURE = 6.0

    fun exerciseHistory(
        exerciseId: String,
        sessions: List<StrengthSessionSnapshot>,
    ): List<StrengthExerciseHistoryPoint> =
        sessions.mapNotNull { snapshot ->
            if (snapshot.session.endedAt == null) return@mapNotNull null
            val sets = snapshot.sets.filter {
                it.exerciseId == exerciseId &&
                    it.completedAt != null &&
                    it.setType != "warmup"
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
        val sets = included.flatMap { it.sets }
            .filter { it.completedAt != null && it.setType != "warmup" }
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
            .filter { it.completedAt != null && it.setType != "warmup" }
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

    fun muscleStatus(
        exercises: List<StrengthExerciseRow>,
        sessions: List<StrengthSessionSnapshot>,
        now: Long,
    ): List<StrengthMuscleStatus> {
        val exerciseById = exercises.associateBy { it.id }
        val exposure = mutableMapOf<String, Double>()
        val residual = mutableMapOf<String, Double>()
        val lastTrained = mutableMapOf<String, Long>()

        fun add(amount: Double, muscle: String, completedAt: Long) {
            if (muscle !in BODY_MAP_MUSCLES) return
            val age = now - completedAt
            if (age < 0L) return
            if (age <= LOAD_WINDOW_SECONDS) {
                exposure[muscle] = exposure.getOrDefault(muscle, 0.0) + amount
            }
            if (age <= RECOVERY_WINDOW_SECONDS) {
                val remaining = 1.0 - age.toDouble() / RECOVERY_WINDOW_SECONDS.toDouble()
                residual[muscle] = residual.getOrDefault(muscle, 0.0) +
                    amount * remaining.coerceAtLeast(0.0)
            }
            lastTrained[muscle] = maxOf(lastTrained.getOrDefault(muscle, 0L), completedAt)
        }

        sessions.asSequence()
            .flatMap { it.sets.asSequence() }
            .filter { it.setType != "warmup" && it.completedAt != null }
            .forEach { set ->
                val exercise = exerciseById[set.exerciseId] ?: return@forEach
                val completedAt = set.completedAt ?: return@forEach
                add(1.0, exercise.primaryMuscle, completedAt)
                StrengthTrainingContract.secondaryMuscles(exercise.secondaryMusclesJSON)
                    .orEmpty()
                    .distinct()
                    .filter { it != exercise.primaryMuscle }
                    .forEach { muscle -> add(0.5, muscle, completedAt) }
            }

        return BODY_MAP_MUSCLES.map { muscle ->
            val sevenDayExposure = exposure.getOrDefault(muscle, 0.0)
            val loadScore = (sevenDayExposure / FULL_LOAD_EXPOSURE).coerceIn(0.0, 1.0)
            val residualScore = (
                residual.getOrDefault(muscle, 0.0) / FULL_RESIDUAL_EXPOSURE
                ).coerceIn(0.0, 1.0)
            StrengthMuscleStatus(
                muscle = muscle,
                sevenDayExposure = sevenDayExposure,
                loadScore = loadScore,
                recoveryScore = 1.0 - residualScore,
                lastTrainedAt = lastTrained[muscle],
            )
        }
    }
}
