package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StrengthWorkoutPlanningTest {
    private val now = 1_800_000_000L

    @Test
    fun everyBuiltInExerciseHasSpecificPositiveMotionGuidance() {
        assertEquals(56, StrengthTrainingContract.BUILT_IN_EXERCISES.size)
        val variants = mutableSetOf<StrengthExerciseAnimationVariant>()
        StrengthTrainingContract.BUILT_IN_EXERCISES.forEach { exercise ->
            val guide = StrengthExerciseGuidance.guide(exercise)
            assertTrue(exercise.id, guide.isExerciseSpecific)
            assertTrue(exercise.id, guide.profile != StrengthExerciseMotionProfile.GENERIC)
            assertTrue(exercise.id, guide.cycleDurationSeconds > 0f)
            assertEquals(exercise.id, guide.animationVariant?.exerciseId)
            guide.animationVariant?.let(variants::add)
        }
        assertEquals(StrengthTrainingContract.BUILT_IN_EXERCISES.size, variants.size)
        assertEquals(StrengthExerciseAnimationVariant.entries.size, variants.size)

        val custom = StrengthExerciseRow(
            id = "custom-squat",
            name = "Custom squat",
            primaryMuscle = "quadriceps",
            secondaryMusclesJSON = "[]",
            equipment = "other",
            movementPattern = "squat",
            isCustom = true,
            createdAt = now,
            updatedAt = now,
        )
        val fallback = StrengthExerciseGuidance.guide(custom)
        assertEquals(StrengthExerciseMotionProfile.SQUAT, fallback.profile)
        assertNull(fallback.animationVariant)
        assertTrue(!fallback.isExerciseSpecific)
    }

    @Test
    fun adaptiveProgramsCoverTwoThroughSixGymDaysWithKnownExercises() {
        val known = StrengthTrainingContract.BUILT_IN_EXERCISES.map { it.id }.toSet()
        (2..6).forEach { count ->
            val weekdays = StrengthAdaptivePlanner.suggestedWeekdays(count)
            val program = StrengthAdaptivePlanner.program(weekdays)
            assertEquals(count, weekdays.size)
            assertEquals(count, program.size)
            assertEquals(weekdays, program.map { it.isoWeekday })
            assertTrue(program.all { it.exercises.isNotEmpty() })
            assertTrue(
                program.flatMap { it.exercises }.all {
                    it.exerciseId in known && it.targetSets > 0 && it.restSeconds > 0
                },
            )
        }
        assertTrue(StrengthAdaptivePlanner.program(listOf(1)).isEmpty())
        assertTrue(StrengthAdaptivePlanner.program(listOf(1, 1)).isEmpty())
    }

    @Test
    fun profileDrivenProgramScalesSessionWithoutInventingProgress() {
        val beginner = StrengthAdaptivePlanner.program(
            StrengthProgramRequest(
                weekdays = listOf(1, 3, 5),
                experience = StrengthTrainingExperience.BEGINNER,
                style = StrengthTrainingStyle.BALANCED,
                sessionMinutes = 30,
                focusMuscles = listOf("chest"),
            ),
        )
        assertEquals(3, beginner.size)
        assertTrue(beginner.all { it.exercises.size == 3 })
        assertTrue(beginner.flatMap { it.exercises }.all {
            it.targetSets <= 2 && it.targetRPE == 6.5
        })
        assertTrue(beginner.all { routine ->
            routine.exercises.any { item ->
                StrengthTrainingContract.BUILT_IN_EXERCISES
                    .firstOrNull { it.id == item.exerciseId }
                    ?.primaryMuscle == "chest"
            }
        })

        val experienced = StrengthAdaptivePlanner.program(
            StrengthProgramRequest(
                weekdays = listOf(1, 4),
                experience = StrengthTrainingExperience.EXPERIENCED,
                style = StrengthTrainingStyle.STRENGTH,
                sessionMinutes = 75,
            ),
        )
        assertTrue(experienced.flatMap { it.exercises }.take(2).all {
            it.targetRepsMin == 4 &&
                it.targetRepsMax == 6 &&
                it.restSeconds >= 180 &&
                it.targetRPE == 7.5
        })

        val custom = StrengthExerciseRow(
            id = "custom-row",
            name = "Custom row",
            primaryMuscle = "back",
            secondaryMusclesJSON = "[]",
            equipment = "band",
            movementPattern = "horizontal_pull",
            isCustom = true,
            createdAt = now,
            updatedAt = now,
        )
        val focus = StrengthAdaptivePlanner.focusWorkout(
            exercises = listOf(custom),
            experience = StrengthTrainingExperience.BEGINNER,
            style = StrengthTrainingStyle.MUSCLE,
            sessionMinutes = 30,
        )
        assertEquals(listOf(custom.id), focus.map { it.exerciseId })
        assertEquals(2, focus.first().targetSets)
        assertEquals(8, focus.first().targetRepsMin)
        assertEquals(12, focus.first().targetRepsMax)
    }

    @Test
    fun muscleStatusUsesCompletedSetExposureAndFadesOverSeventyTwoHours() {
        val bench = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val session = StrengthSessionSnapshot(
            StrengthSessionRow(
                id = "body-map",
                startedAt = now - 3_600,
                endedAt = now - 1_800,
                createdAt = now - 3_600,
                updatedAt = now - 1_800,
            ),
            listOf(
                StrengthSetRow(
                    id = "working",
                    sessionId = "body-map",
                    exerciseId = bench.id,
                    exercisePosition = 0,
                    setPosition = 0,
                    reps = 8,
                    completedAt = now - 3_600,
                    createdAt = now - 3_600,
                    updatedAt = now - 3_600,
                ),
                StrengthSetRow(
                    id = "warmup",
                    sessionId = "body-map",
                    exerciseId = bench.id,
                    exercisePosition = 0,
                    setPosition = 1,
                    setType = "warmup",
                    reps = 5,
                    completedAt = now - 3_600,
                    createdAt = now - 3_600,
                    updatedAt = now - 3_600,
                ),
            ),
        )
        val current = StrengthProgressCalculator.muscleStatus(
            listOf(bench),
            listOf(session),
            now,
        )
        assertEquals(1.0, current.first { it.muscle == "chest" }.sevenDayExposure, 0.0)
        assertEquals(0.5, current.first { it.muscle == "triceps" }.sevenDayExposure, 0.0)
        assertTrue(current.first { it.muscle == "chest" }.recoveryScore < 1.0)

        val recovered = StrengthProgressCalculator.muscleStatus(
            listOf(bench),
            listOf(session),
            now + StrengthProgressCalculator.RECOVERY_WINDOW_SECONDS + 1,
        )
        assertEquals(1.0, recovered.first { it.muscle == "chest" }.recoveryScore, 0.0)
        assertTrue(recovered.first { it.muscle == "chest" }.loadScore > 0.0)
    }

    @Test
    fun adaptiveScheduleUsesRestDayForRecentMissedRoutineWithoutStacking() {
        val push = scheduledRoutine("push", 1, 10)
        val pull = scheduledRoutine("pull", 3, 20)
        val routines = listOf(pull, push)
        val monday = StrengthScheduleDay("2026-08-31", 1)
        val tuesday = StrengthScheduleDay("2026-09-01", 2)
        val wednesday = StrengthScheduleDay("2026-09-02", 3)

        assertEquals(
            StrengthDayRecommendation(
                routineId = "push",
                reason = StrengthDayRecommendationReason.MAKE_UP,
                originallyScheduledDateKey = monday.dateKey,
            ),
            StrengthAdaptivePlanner.recommendation(
                today = tuesday,
                previousDaysNearestFirst = listOf(monday),
                routines = routines,
                completions = emptyList(),
            ),
        )
        assertEquals(
            "pull",
            StrengthAdaptivePlanner.recommendation(
                today = wednesday,
                previousDaysNearestFirst = listOf(tuesday, monday),
                routines = routines,
                completions = emptyList(),
            ).routineId,
        )
        assertEquals(
            StrengthDayRecommendationReason.COMPLETED,
            StrengthAdaptivePlanner.recommendation(
                today = tuesday,
                previousDaysNearestFirst = listOf(monday),
                routines = routines,
                completions = listOf(StrengthRoutineCompletion(tuesday.dateKey, "push")),
            ).reason,
        )
    }

    @Test
    fun adaptiveScheduleDoesNotCarryStaleWork() {
        val result = StrengthAdaptivePlanner.recommendation(
            today = StrengthScheduleDay("2026-09-04", 5),
            previousDaysNearestFirst = listOf(
                StrengthScheduleDay("2026-09-03", 4),
                StrengthScheduleDay("2026-09-02", 3),
                StrengthScheduleDay("2026-09-01", 2),
                StrengthScheduleDay("2026-08-31", 1),
            ),
            routines = listOf(scheduledRoutine("push", 1, 10)),
            completions = emptyList(),
        )
        assertEquals(StrengthDayRecommendationReason.REST, result.reason)
        assertNull(result.routineId)
    }

    private fun scheduledRoutine(
        id: String,
        weekday: Int,
        createdAt: Long,
    ) = StrengthRoutineSnapshot(
        StrengthRoutineRow(
            id = id,
            name = id,
            scheduledWeekdaysJSON = StrengthTrainingContract.encodeScheduledWeekdays(
                listOf(weekday),
            ),
            createdAt = createdAt,
            updatedAt = createdAt,
        ),
        emptyList(),
    )

    private fun routine(
        exerciseId: String,
        sets: Int = 3,
        minimum: Int = 6,
        maximum: Int = 8,
        plan: StrengthExercisePlan,
    ) = StrengthRoutineExerciseRow(
        id = "rx-$exerciseId",
        routineId = "routine",
        exerciseId = exerciseId,
        position = 0,
        targetSets = sets,
        targetRepsMin = minimum,
        targetRepsMax = maximum,
        planJSON = StrengthTrainingContract.encodeExercisePlan(plan),
        createdAt = now - 10_000,
        updatedAt = now - 10_000,
    )

    private fun history(
        exerciseId: String,
        reps: List<Int?>,
        load: Double?,
        durations: List<Int?> = emptyList(),
        setTypes: List<String> = emptyList(),
    ): List<StrengthSessionSnapshot> {
        val sessionId = "previous"
        return listOf(
            StrengthSessionSnapshot(
                StrengthSessionRow(
                    id = sessionId,
                    startedAt = now - 86_400,
                    endedAt = now - 82_800,
                    createdAt = now - 86_400,
                    updatedAt = now - 82_800,
                ),
                reps.indices.map { index ->
                    StrengthSetRow(
                        id = "set-$index",
                        sessionId = sessionId,
                        exerciseId = exerciseId,
                        exercisePosition = 0,
                        setPosition = index,
                        setType = setTypes.getOrElse(index) { "working" },
                        reps = reps[index],
                        loadKg = load,
                        durationS = durations.getOrNull(index),
                        rpe = 8.0,
                        completedAt = now - 82_900 + index,
                        createdAt = now - 86_400,
                        updatedAt = now - 82_900 + index,
                    )
                },
            ),
        )
    }

    @Test
    fun doubleProgressionAddsLoadAndSeedsWarmups() {
        val exercise = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val result = StrengthWorkoutPlanner.prescription(
            exercise,
            routine(exercise.id, plan = StrengthExercisePlan(warmupSets = 2)),
            history(exercise.id, listOf(8, 8, 8), 80.0),
        )
        assertEquals(StrengthProgressionReason.REP_RANGE_ADVANCED, result.reason)
        assertEquals(
            listOf("warmup", "warmup", "working", "working", "working"),
            result.sets.map { it.setType },
        )
        assertEquals(listOf(41.5, 62.0, 82.5, 82.5, 82.5), result.sets.map { it.loadKg })
        assertEquals(listOf(5, 3), result.sets.take(2).map { it.reps })
        assertEquals(listOf(6, 6, 6), result.sets.takeLast(3).map { it.reps })
    }

    @Test
    fun missedTargetHoldsAndBodyweightProgressesByReps() {
        val bench = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val held = StrengthWorkoutPlanner.prescription(
            bench,
            routine(bench.id, plan = StrengthExercisePlan()),
            history(bench.id, listOf(8, 8, 7), 80.0),
        )
        assertEquals(StrengthProgressionReason.REPEAT_LOAD, held.reason)
        assertEquals(listOf(80.0, 80.0, 80.0), held.sets.map { it.loadKg })

        val pullUp = StrengthTrainingContract.BUILT_IN_EXERCISES.first { it.id == "pull_up" }
        val progressed = StrengthWorkoutPlanner.prescription(
            pullUp,
            routine(pullUp.id, plan = StrengthExercisePlan()),
            history(pullUp.id, listOf(8, 8, 8), null),
        )
        assertEquals(StrengthProgressionReason.BODYWEIGHT_REP_PROGRESS, progressed.reason)
        assertEquals(listOf(9, 9, 9), progressed.sets.map { it.reps })
        assertTrue(progressed.sets.all { it.setType == "bodyweight" })

        val progressedAgain = StrengthWorkoutPlanner.prescription(
            pullUp,
            routine(pullUp.id, plan = StrengthExercisePlan()),
            history(pullUp.id, listOf(9, 9, 9), null),
        )
        assertEquals(StrengthProgressionReason.BODYWEIGHT_REP_PROGRESS, progressedAgain.reason)
        assertEquals(listOf(10, 10, 10), progressedAgain.sets.map { it.reps })
    }

    @Test
    fun doubleProgressionAdvancesUnevenSetsIndependently() {
        val bench = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val result = StrengthWorkoutPlanner.prescription(
            bench,
            routine(bench.id, plan = StrengthExercisePlan()),
            history(bench.id, listOf(8, 7, 6), 80.0),
        )

        assertEquals(StrengthProgressionReason.REPEAT_LOAD, result.reason)
        assertEquals(listOf(80.0, 80.0, 80.0), result.sets.map { it.loadKg })
        assertEquals(listOf(8, 8, 7), result.sets.map { it.reps })
    }

    @Test
    fun configuredLoadStepIsCappedAtTenPercent() {
        val bench = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val capped = StrengthWorkoutPlanner.prescription(
            bench,
            routine(bench.id, plan = StrengthExercisePlan(loadStepKg = 100.0)),
            history(bench.id, listOf(8, 8, 8), 10.0),
        )
        assertEquals(StrengthProgressionReason.REP_RANGE_ADVANCED, capped.reason)
        assertEquals(listOf(11.0, 11.0, 11.0), capped.sets.map { it.loadKg })

        val held = StrengthWorkoutPlanner.prescription(
            bench,
            routine(bench.id, plan = StrengthExercisePlan(loadStepKg = 100.0)),
            history(bench.id, listOf(8, 8, 8), 2.5),
        )
        assertEquals(StrengthProgressionReason.REPEAT_LOAD, held.reason)
        assertEquals(listOf(2.5, 2.5, 2.5), held.sets.map { it.loadKg })
    }

    @Test
    fun tinyLoadsDoNotCreateZeroOrNonDroppingAccessorySets() {
        val bench = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val result = StrengthWorkoutPlanner.prescription(
            bench,
            routine(
                bench.id,
                plan = StrengthExercisePlan(
                    targetLoadKg = 0.25,
                    progression = "none",
                    warmupSets = 2,
                    setStyle = "drop",
                ),
            ),
            emptyList(),
        )

        assertEquals(listOf("working", "working", "working"), result.sets.map { it.setType })
        assertEquals(listOf(0.25, 0.25, 0.25), result.sets.map { it.loadKg })
        assertTrue(result.sets.mapNotNull { it.loadKg }.all { it > 0.0 })
    }

    @Test
    fun intensityStylesAppendExplicitClusters() {
        val bench = StrengthTrainingContract.BUILT_IN_EXERCISES.first {
            it.id == "barbell_bench_press"
        }
        val drop = StrengthWorkoutPlanner.prescription(
            bench,
            routine(
                bench.id,
                plan = StrengthExercisePlan(
                    targetLoadKg = 100.0,
                    progression = "none",
                    setStyle = "drop",
                    dropPercent = 20,
                ),
            ),
            emptyList(),
        )
        assertEquals(
            listOf("working", "working", "working", "drop"),
            drop.sets.map { it.setType },
        )
        assertEquals(listOf(100.0, 100.0, 100.0, 80.0), drop.sets.map { it.loadKg })
        assertEquals(0, drop.sets[2].restSecondsAfter)

        val restPause = StrengthWorkoutPlanner.prescription(
            bench,
            routine(
                bench.id,
                plan = StrengthExercisePlan(
                    targetLoadKg = 100.0,
                    progression = "none",
                    setStyle = "rest_pause",
                    restPauseSeconds = 20,
                ),
            ),
            emptyList(),
        )
        assertEquals(
            listOf("working", "working", "working", "rest_pause"),
            restPause.sets.map { it.setType },
        )
        assertEquals(20, restPause.sets[2].restSecondsAfter)
        assertNull(restPause.sets[3].reps)
    }

    @Test
    fun timedAndEstimatedMaximumAreBounded() {
        val plank = StrengthTrainingContract.BUILT_IN_EXERCISES.first { it.id == "plank" }
        val timed = StrengthWorkoutPlanner.prescription(
            plank,
            routine(
                plank.id,
                sets = 2,
                plan = StrengthExercisePlan(
                    mode = "timed",
                    targetDurationS = 30,
                    progression = "time",
                ),
            ),
            history(plank.id, listOf(null, null), null, listOf(30, 30)),
        )
        assertEquals(StrengthProgressionReason.TIME_ADVANCED, timed.reason)
        assertEquals(listOf(35, 35), timed.sets.map { it.durationS })

        val repeated = StrengthWorkoutPlanner.prescription(
            plank,
            routine(
                plank.id,
                sets = 2,
                plan = StrengthExercisePlan(
                    mode = "timed",
                    targetDurationS = 30,
                    progression = "time",
                ),
            ),
            history(plank.id, listOf(null, null), null, listOf(35, 35)),
        )
        assertEquals(StrengthProgressionReason.TIME_ADVANCED, repeated.reason)
        assertEquals(listOf(40, 40), repeated.sets.map { it.durationS })

        assertEquals(116.666_666, StrengthWorkoutPlanner.estimatedOneRepMaximum(100.0, 5)!!, 0.000_001)
        assertNull(StrengthWorkoutPlanner.estimatedOneRepMaximum(100.0, 11))

        val mixed = history(
            plank.id,
            listOf(5, 4, 3),
            100.0,
            setTypes = listOf("drop", "rest_pause", "working"),
        )
        val best = StrengthWorkoutPlanner.bestEstimatedMaximum(plank.id, mixed)!!
        assertEquals(3, best.sourceReps)
        assertEquals(110.0, best.kilograms, 0.000_001)
    }

    @Test
    fun planModeRejectsMismatchedProgression() {
        assertNull(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(mode = "timed", targetDurationS = 30),
            ),
        )
        assertNull(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(mode = "reps", progression = "time"),
            ),
        )
        assertTrue(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(
                    mode = "timed",
                    targetDurationS = 30,
                    progression = "time",
                ),
            ) != null,
        )
        assertNull(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(supersetGroup = 0),
            ),
        )
    }

    @Test
    fun supersetRestKeepsWarmupsAndExplicitClusterPauses() {
        val warmup = StrengthPlannedSet("warmup", 5, 40.0, null, null)
        val working = StrengthPlannedSet("working", 8, 80.0, null, null)
        val cluster = StrengthPlannedSet("working", 8, 80.0, null, 20)

        assertEquals(120, StrengthWorkoutPlanner.resolvedRestSeconds(warmup, 120, true))
        assertEquals(0, StrengthWorkoutPlanner.resolvedRestSeconds(working, 120, true))
        assertEquals(120, StrengthWorkoutPlanner.resolvedRestSeconds(working, 120, false))
        assertEquals(20, StrengthWorkoutPlanner.resolvedRestSeconds(cluster, 120, true))
    }

}
