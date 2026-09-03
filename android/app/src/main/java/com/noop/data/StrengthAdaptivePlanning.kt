package com.noop.data

data class StrengthScheduleDay(
    val dateKey: String,
    val isoWeekday: Int,
)

data class StrengthRoutineCompletion(
    val dateKey: String,
    val routineId: String,
)

enum class StrengthTrainingExperience {
    BEGINNER,
    INTERMEDIATE,
    EXPERIENCED,
}

enum class StrengthTrainingStyle {
    BALANCED,
    STRENGTH,
    MUSCLE,
    CONDITIONING,
}

enum class StrengthPhysiqueGoal {
    BALANCED,
    BUILD_SIZE,
    LEAN_CONDITIONED,
    V_TAPER,
    UPPER_BODY,
    LOWER_BODY_GLUTES,
    ATHLETIC,
}

data class StrengthProgramRequest(
    val weekdays: List<Int>,
    val experience: StrengthTrainingExperience = StrengthTrainingExperience.BEGINNER,
    val style: StrengthTrainingStyle = StrengthTrainingStyle.BALANCED,
    val physiqueGoal: StrengthPhysiqueGoal = StrengthPhysiqueGoal.BALANCED,
    val sessionMinutes: Int = 45,
    val focusMuscles: List<String> = emptyList(),
)

enum class StrengthDayRecommendationReason {
    SCHEDULED,
    MAKE_UP,
    COMPLETED,
    REST,
}

data class StrengthDayRecommendation(
    val routineId: String?,
    val reason: StrengthDayRecommendationReason,
    val originallyScheduledDateKey: String? = null,
)

data class StrengthProgramExercise(
    val exerciseId: String,
    val targetSets: Int,
    val targetRepsMin: Int? = null,
    val targetRepsMax: Int? = null,
    val restSeconds: Int,
    val targetDurationS: Int? = null,
    val warmupSets: Int = 0,
    val targetRPE: Double = 7.0,
) {
    val plan: StrengthExercisePlan
        get() = StrengthExercisePlan(
            mode = if (targetDurationS == null) "reps" else "timed",
            targetDurationS = targetDurationS,
            progression = if (targetDurationS == null) "double_progression" else "time",
            warmupSets = warmupSets,
        )
}

data class StrengthProgramRoutine(
    val name: String,
    val isoWeekday: Int,
    val exercises: List<StrengthProgramExercise>,
)

/** Local deterministic counterpart to Swift StrengthAdaptivePlanner. */
object StrengthAdaptivePlanner {
    const val MAXIMUM_MAKE_UP_AGE_DAYS = 3

    fun recommendation(
        today: StrengthScheduleDay,
        previousDaysNearestFirst: List<StrengthScheduleDay>,
        routines: List<StrengthRoutineSnapshot>,
        completions: List<StrengthRoutineCompletion>,
    ): StrengthDayRecommendation {
        val completedToday = completions.filter { it.dateKey == today.dateKey }
        val todayRoutines = scheduledRoutines(today.isoWeekday, routines)
        todayRoutines.firstOrNull { routine ->
            completedToday.none { it.routineId == routine.routine.id }
        }?.let { scheduled ->
            return StrengthDayRecommendation(
                routineId = scheduled.routine.id,
                reason = StrengthDayRecommendationReason.SCHEDULED,
                originallyScheduledDateKey = today.dateKey,
            )
        }
        if (todayRoutines.isNotEmpty() || completedToday.isNotEmpty()) {
            return StrengthDayRecommendation(null, StrengthDayRecommendationReason.COMPLETED)
        }

        val candidates = previousDaysNearestFirst.take(MAXIMUM_MAKE_UP_AGE_DAYS)
        candidates.forEachIndexed { index, day ->
            scheduledRoutines(day.isoWeekday, routines).forEach { routine ->
                val routineId = routine.routine.id
                val completedSince = completions.any {
                    it.routineId == routineId &&
                        it.dateKey >= day.dateKey &&
                        it.dateKey <= today.dateKey
                }
                val scheduledDays = StrengthTrainingContract.scheduledWeekdays(
                    routine.routine.scheduledWeekdaysJSON,
                )
                val newerOccurrence = candidates.take(index).any {
                    it.isoWeekday in scheduledDays
                }
                if (!completedSince && !newerOccurrence) {
                    return StrengthDayRecommendation(
                        routineId = routineId,
                        reason = StrengthDayRecommendationReason.MAKE_UP,
                        originallyScheduledDateKey = day.dateKey,
                    )
                }
            }
        }
        return StrengthDayRecommendation(null, StrengthDayRecommendationReason.REST)
    }

    fun suggestedWeekdays(dayCount: Int): List<Int> = when (dayCount) {
        2 -> listOf(1, 4)
        3 -> listOf(1, 3, 5)
        4 -> listOf(1, 2, 4, 5)
        5 -> listOf(1, 2, 3, 5, 6)
        6 -> listOf(1, 2, 3, 4, 5, 6)
        else -> emptyList()
    }

    fun program(weekdays: List<Int>): List<StrengthProgramRoutine> =
        program(StrengthProgramRequest(weekdays))

    fun program(request: StrengthProgramRequest): List<StrengthProgramRoutine> {
        val days = request.weekdays.distinct().sorted()
        if (days.size !in 2..6 || days.any { it !in 1..7 }) return emptyList()
        val specs = when (days.size) {
            2 -> listOf("Full Body A" to fullBodyA, "Full Body B" to fullBodyB)
            3 -> listOf("Push" to pushA, "Pull" to pullA, "Legs" to legsA)
            4 -> listOf(
                "Upper A" to upperA,
                "Lower A" to lowerA,
                "Upper B" to upperB,
                "Lower B" to lowerB,
            )
            5 -> listOf(
                "Push" to pushA,
                "Pull" to pullA,
                "Legs" to legsA,
                "Upper" to upperB,
                "Lower" to lowerB,
            )
            else -> listOf(
                "Push A" to pushA,
                "Pull A" to pullA,
                "Legs A" to legsA,
                "Push B" to pushB,
                "Pull B" to pullB,
                "Legs B" to legsB,
            )
        }
        return days.zip(specs).mapIndexed { routineIndex, (day, spec) ->
            val limit = when (normalizedSessionMinutes(request.sessionMinutes)) {
                30 -> 3
                45 -> 4
                60 -> 5
                else -> 6
            }
            val goalAdjusted = exercisesPrioritizing(
                request.physiqueGoal,
                spec.second,
            )
            val exercises = exercisesPrioritizing(
                request.focusMuscles,
                goalAdjusted,
                routineIndex,
            ).take(limit).mapIndexed { index, exercise ->
                customized(exercise, index, request)
            }
            StrengthProgramRoutine(spec.first, day, exercises)
        }
    }

    fun focusWorkout(
        exercises: List<StrengthExerciseRow>,
        experience: StrengthTrainingExperience,
        style: StrengthTrainingStyle,
        physiqueGoal: StrengthPhysiqueGoal = StrengthPhysiqueGoal.BALANCED,
        sessionMinutes: Int,
    ): List<StrengthProgramExercise> {
        val request = StrengthProgramRequest(
            weekdays = emptyList(),
            experience = experience,
            style = style,
            physiqueGoal = physiqueGoal,
            sessionMinutes = sessionMinutes,
        )
        val limit = when (normalizedSessionMinutes(sessionMinutes)) {
            30 -> 3
            45 -> 4
            60 -> 5
            else -> 6
        }
        val prioritized = exercisesPrioritizing(
            physiqueGoal,
            exercises.map(::starterExercise),
        )
        return prioritized.take(limit).mapIndexed { index, exercise ->
            customized(exercise, index, request)
        }
    }

    private fun scheduledRoutines(
        isoWeekday: Int,
        routines: List<StrengthRoutineSnapshot>,
    ): List<StrengthRoutineSnapshot> = routines
        .filter {
            isoWeekday in StrengthTrainingContract.scheduledWeekdays(
                it.routine.scheduledWeekdaysJSON,
            )
        }
        .sortedWith(compareBy({ it.routine.createdAt }, { it.routine.id }))

    private fun reps(
        id: String,
        sets: Int,
        minimum: Int,
        maximum: Int,
        rest: Int = 90,
        warmups: Int = 0,
    ) = StrengthProgramExercise(id, sets, minimum, maximum, rest, warmupSets = warmups)

    private fun timed(id: String, sets: Int, seconds: Int, rest: Int = 60) =
        StrengthProgramExercise(
            exerciseId = id,
            targetSets = sets,
            restSeconds = rest,
            targetDurationS = seconds,
        )

    private fun normalizedSessionMinutes(minutes: Int): Int =
        listOf(30, 45, 60, 75).minByOrNull { kotlin.math.abs(it - minutes) } ?: 45

    private fun customized(
        exercise: StrengthProgramExercise,
        position: Int,
        request: StrengthProgramRequest,
    ): StrengthProgramExercise {
        val sessionMinutes = normalizedSessionMinutes(request.sessionMinutes)
        val workingSets = when (request.experience) {
            StrengthTrainingExperience.BEGINNER -> minOf(exercise.targetSets, 2)
            StrengthTrainingExperience.INTERMEDIATE -> minOf(exercise.targetSets, 3)
            StrengthTrainingExperience.EXPERIENCED -> minOf(
                4,
                exercise.targetSets + if (position < 2 && sessionMinutes >= 60) 1 else 0,
            )
        }
        var minimum = exercise.targetRepsMin
        var maximum = exercise.targetRepsMax
        var duration = exercise.targetDurationS
        var rest = exercise.restSeconds
        when (request.style) {
            StrengthTrainingStyle.BALANCED -> Unit
            StrengthTrainingStyle.STRENGTH -> {
                if (duration == null) {
                    minimum = if (position < 2) 4 else 6
                    maximum = if (position < 2) 6 else 10
                }
                rest = maxOf(rest, if (position < 2) 180 else 105)
            }
            StrengthTrainingStyle.MUSCLE -> {
                if (duration == null) {
                    minimum = if (position < 2) 8 else 10
                    maximum = if (position < 2) 12 else 15
                }
                rest = minOf(maxOf(rest, 60), if (position < 2) 120 else 90)
            }
            StrengthTrainingStyle.CONDITIONING -> {
                if (duration == null) {
                    minimum = 12
                    maximum = 15
                } else {
                    duration = maxOf(duration, 40)
                }
                rest = minOf(rest, 60)
            }
        }
        val targetRPE = when (request.experience) {
            StrengthTrainingExperience.BEGINNER -> 6.5
            StrengthTrainingExperience.INTERMEDIATE -> 7.0
            StrengthTrainingExperience.EXPERIENCED -> 7.5
        }
        return exercise.copy(
            targetSets = maxOf(1, workingSets),
            targetRepsMin = minimum,
            targetRepsMax = maximum,
            restSeconds = maxOf(30, rest),
            targetDurationS = duration,
            warmupSets = if (request.experience == StrengthTrainingExperience.BEGINNER) {
                minOf(exercise.warmupSets, 1)
            } else {
                exercise.warmupSets
            },
            targetRPE = targetRPE,
        )
    }

    private fun starterExercise(exercise: StrengthExerciseRow): StrengthProgramExercise {
        if (exercise.movementPattern == "cardio") {
            return timed(exercise.id, 3, 45, 60)
        }
        val compound = exercise.movementPattern in setOf(
            "squat", "hinge", "lunge", "horizontal_push", "vertical_push",
            "horizontal_pull", "vertical_pull", "carry",
        )
        return reps(
            exercise.id,
            3,
            if (compound) 6 else 10,
            if (compound) 10 else 15,
            if (compound) 120 else 75,
            if (compound && exercise.equipment != "bodyweight") 1 else 0,
        )
    }

    private fun exercisesPrioritizing(
        goal: StrengthPhysiqueGoal,
        exercises: List<StrengthProgramExercise>,
    ): List<StrengthProgramExercise> {
        val priorities = when (goal) {
            StrengthPhysiqueGoal.BALANCED -> return exercises
            StrengthPhysiqueGoal.BUILD_SIZE -> PriorityProfile(
                setOf("chest", "back", "shoulders", "glutes", "quadriceps", "hamstrings"),
                listOf(
                    "squat", "hinge", "horizontal_push", "vertical_push",
                    "horizontal_pull", "vertical_pull",
                ),
            )
            StrengthPhysiqueGoal.LEAN_CONDITIONED -> PriorityProfile(
                emptySet(),
                listOf("cardio", "carry", "lunge", "squat", "horizontal_pull"),
            )
            StrengthPhysiqueGoal.V_TAPER -> PriorityProfile(
                setOf("back", "shoulders"),
                listOf("vertical_pull", "horizontal_pull", "vertical_push"),
            )
            StrengthPhysiqueGoal.UPPER_BODY -> PriorityProfile(
                setOf("chest", "back", "shoulders", "biceps", "triceps"),
                listOf(
                    "horizontal_push", "vertical_push", "horizontal_pull", "vertical_pull",
                ),
            )
            StrengthPhysiqueGoal.LOWER_BODY_GLUTES -> PriorityProfile(
                setOf("glutes", "quadriceps", "hamstrings", "calves"),
                listOf("squat", "hinge", "lunge"),
            )
            StrengthPhysiqueGoal.ATHLETIC -> PriorityProfile(
                setOf("glutes", "quadriceps", "hamstrings", "back", "core"),
                listOf(
                    "carry", "lunge", "squat", "hinge", "horizontal_pull", "vertical_pull",
                ),
            )
        }
        val catalog = StrengthTrainingContract.BUILT_IN_EXERCISES.associateBy { it.id }
        return exercises.withIndex().sortedWith(
            compareByDescending<IndexedValue<StrengthProgramExercise>> { item ->
                priorityScore(catalog[item.value.exerciseId], priorities)
            }.thenBy { it.index },
        ).map { it.value }
    }

    private data class PriorityProfile(
        val muscles: Set<String>,
        val movements: List<String>,
    )

    private fun priorityScore(
        exercise: StrengthExerciseRow?,
        priorities: PriorityProfile,
    ): Int {
        if (exercise == null) return 0
        val muscleScore = if (exercise.primaryMuscle in priorities.muscles) 100 else 0
        val movementIndex = priorities.movements.indexOf(exercise.movementPattern)
        val movementScore = if (movementIndex >= 0) {
            priorities.movements.size - movementIndex
        } else {
            0
        }
        return muscleScore + movementScore
    }

    private fun exercisesPrioritizing(
        requestedMuscles: List<String>,
        exercises: List<StrengthProgramExercise>,
        routineIndex: Int,
    ): List<StrengthProgramExercise> {
        val muscles = requestedMuscles
            .filter { it in StrengthTrainingContract.MUSCLES }
            .filter { it != "full_body" && it != "other" }
            .distinct()
            .sorted()
        if (muscles.isEmpty()) return exercises
        val catalog = StrengthTrainingContract.BUILT_IN_EXERCISES
        val existingIds = exercises.map { it.exerciseId }.toSet()
        val focusedIds = catalog.filter {
            it.id in existingIds && it.primaryMuscle in muscles
        }.map { it.id }.toSet()
        if (focusedIds.isNotEmpty()) {
            return exercises.withIndex().sortedWith(
                compareByDescending<IndexedValue<StrengthProgramExercise>> {
                    it.value.exerciseId in focusedIds
                }.thenBy { it.index },
            ).map { it.value }
        }
        val candidates = catalog.filter {
            it.primaryMuscle in muscles &&
                it.movementPattern != "cardio" &&
                it.id !in existingIds
        }
        if (candidates.isEmpty()) return exercises
        val selected = candidates[routineIndex % candidates.size]
        return if (exercises.isEmpty()) {
            listOf(starterExercise(selected))
        } else {
            exercises.toMutableList().apply {
                this[minOf(2, lastIndex)] = starterExercise(selected)
            }
        }
    }

    private val pushA = listOf(
        reps("barbell_bench_press", 3, 6, 8, 150, 2),
        reps("overhead_press", 3, 6, 8, 120, 1),
        reps("incline_barbell_bench_press", 3, 8, 10, 120),
        reps("lateral_raise", 3, 12, 15, 60),
        reps("triceps_pushdown", 3, 10, 12, 75),
    )
    private val pushB = listOf(
        reps("overhead_press", 3, 6, 8, 150, 2),
        reps("dumbbell_bench_press", 3, 8, 10, 120, 1),
        reps("machine_chest_press", 3, 10, 12, 90),
        reps("lateral_raise", 3, 12, 15, 60),
        reps("overhead_triceps_extension", 3, 10, 12, 75),
    )
    private val pullA = listOf(
        reps("conventional_deadlift", 3, 4, 6, 180, 2),
        reps("pull_up", 3, 6, 10, 120),
        reps("bent_over_row", 3, 6, 8, 120, 1),
        reps("face_pull", 3, 12, 15, 60),
        reps("biceps_curl", 3, 10, 12, 75),
    )
    private val pullB = listOf(
        reps("romanian_deadlift", 3, 6, 8, 150, 2),
        reps("lat_pulldown", 3, 8, 10, 120),
        reps("seated_cable_row", 3, 8, 10, 105),
        reps("rear_delt_fly", 3, 12, 15, 60),
        reps("hammer_curl", 3, 10, 12, 75),
    )
    private val legsA = listOf(
        reps("barbell_back_squat", 3, 6, 8, 180, 2),
        reps("romanian_deadlift", 3, 8, 10, 150, 1),
        reps("walking_lunge", 3, 8, 10, 90),
        reps("lying_leg_curl", 3, 10, 12, 75),
        reps("standing_calf_raise", 3, 12, 15, 60),
    )
    private val legsB = listOf(
        reps("conventional_deadlift", 3, 4, 6, 180, 2),
        reps("barbell_front_squat", 3, 6, 8, 150, 1),
        reps("bulgarian_split_squat", 3, 8, 10, 90),
        reps("leg_extension", 3, 10, 12, 75),
        reps("seated_calf_raise", 3, 12, 15, 60),
    )
    private val upperA = listOf(
        reps("barbell_bench_press", 3, 6, 8, 150, 2),
        reps("bent_over_row", 3, 6, 8, 120, 1),
        reps("overhead_press", 3, 8, 10, 105),
        reps("lat_pulldown", 3, 8, 10, 105),
        reps("triceps_pushdown", 2, 10, 12, 60),
        reps("biceps_curl", 2, 10, 12, 60),
    )
    private val upperB = listOf(
        reps("pull_up", 3, 6, 10, 120, 1),
        reps("incline_barbell_bench_press", 3, 8, 10, 120, 1),
        reps("seated_cable_row", 3, 8, 10, 105),
        reps("dumbbell_shoulder_press", 3, 8, 10, 105),
        reps("face_pull", 2, 12, 15, 60),
        reps("hammer_curl", 2, 10, 12, 60),
    )
    private val lowerA = listOf(
        reps("barbell_back_squat", 3, 6, 8, 180, 2),
        reps("romanian_deadlift", 3, 8, 10, 150, 1),
        reps("walking_lunge", 3, 8, 10, 90),
        reps("lying_leg_curl", 3, 10, 12, 75),
        reps("standing_calf_raise", 3, 12, 15, 60),
        timed("plank", 3, 30),
    )
    private val lowerB = listOf(
        reps("conventional_deadlift", 3, 4, 6, 180, 2),
        reps("barbell_front_squat", 3, 6, 8, 150, 1),
        reps("bulgarian_split_squat", 3, 8, 10, 90),
        reps("leg_extension", 3, 10, 12, 75),
        reps("seated_calf_raise", 3, 12, 15, 60),
        timed("side_plank", 3, 25),
    )
    private val fullBodyA = listOf(
        reps("barbell_back_squat", 3, 6, 8, 180, 2),
        reps("barbell_bench_press", 3, 6, 8, 150, 2),
        reps("seated_cable_row", 3, 8, 10, 105),
        reps("romanian_deadlift", 3, 8, 10, 150, 1),
        timed("plank", 3, 30),
    )
    private val fullBodyB = listOf(
        reps("conventional_deadlift", 3, 4, 6, 180, 2),
        reps("overhead_press", 3, 6, 8, 120, 1),
        reps("lat_pulldown", 3, 8, 10, 105),
        reps("bulgarian_split_squat", 3, 8, 10, 90),
        timed("farmers_carry", 3, 30),
    )
}
