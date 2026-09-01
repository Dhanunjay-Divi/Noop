package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StrengthWorkoutPlanningTest {
    private val now = 1_800_000_000L

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
