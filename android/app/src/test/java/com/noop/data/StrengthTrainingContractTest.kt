package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StrengthTrainingContractTest {
    private val now = 1_777_000_000L

    private fun set(
        reps: Int? = null,
        loadKg: Double? = null,
        durationS: Int? = null,
        rpe: Double? = null,
        restSeconds: Int? = 120,
        completedAt: Long? = null,
    ) = StrengthSetRow(
        id = "set-1",
        sessionId = "session-1",
        exerciseId = "barbell_back_squat",
        exercisePosition = 0,
        setPosition = 0,
        reps = reps,
        loadKg = loadKg,
        durationS = durationS,
        rpe = rpe,
        restSeconds = restSeconds,
        completedAt = completedAt,
        createdAt = now,
        updatedAt = now,
    )

    @Test
    fun builtInCatalogHasStableOwnedIdentity() {
        val originalIds = listOf(
            "barbell_back_squat",
            "barbell_bench_press",
            "conventional_deadlift",
            "overhead_press",
            "bent_over_row",
            "pull_up",
            "lat_pulldown",
            "leg_press",
            "romanian_deadlift",
            "dumbbell_lunge",
            "biceps_curl",
            "triceps_pushdown",
            "plank",
        )
        val ids = StrengthTrainingContract.BUILT_IN_EXERCISES.map { it.id }
        assertEquals(originalIds, ids.take(originalIds.size))
        assertEquals(ids.size, ids.distinct().size)
        assertTrue(ids.size > originalIds.size)
        assertTrue(StrengthTrainingContract.BUILT_IN_EXERCISES.all { !it.isCustom })
        assertTrue(
            StrengthTrainingContract.BUILT_IN_EXERCISES.all {
                StrengthTrainingContract.validated(it) == it
            },
        )
    }

    @Test
    fun draftSetCanBeEmptyButCompletedSetNeedsWork() {
        assertEquals(set(), StrengthTrainingContract.validated(set()))
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(set(completedAt = now))
        }
        assertEquals(
            45,
            StrengthTrainingContract.validated(
                set(durationS = 45, completedAt = now),
            ).durationS,
        )
    }

    @Test
    fun rejectsUnsafeSetBounds() {
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(set(reps = 0))
        }
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(set(loadKg = -1.0))
        }
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(set(loadKg = Double.POSITIVE_INFINITY))
        }
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(set(rpe = 10.5))
        }
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(set(restSeconds = 3_601))
        }
    }

    @Test
    fun volumeCountsOnlyCompletedLoadedSets() {
        assertEquals(500.0, set(reps = 5, loadKg = 100.0, completedAt = now).volumeKg)
        assertNull(set(reps = 8, completedAt = now).volumeKg)
        assertNull(set(reps = 5, loadKg = 100.0).volumeKg)
        assertNull(set(durationS = 60, completedAt = now).volumeKg)
    }

    @Test
    fun routineRepRangeAndSessionDurationAreValidated() {
        val routineExercise = StrengthRoutineExerciseRow(
            id = "routine-exercise-1",
            routineId = "routine-1",
            exerciseId = "barbell_back_squat",
            position = 0,
            targetRepsMin = 12,
            targetRepsMax = 8,
            createdAt = now,
            updatedAt = now,
        )
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(routineExercise)
        }

        val tooLong = StrengthSessionRow(
            id = "session-1",
            startedAt = now,
            endedAt = now + StrengthTrainingContract.MAX_DURATION_SECONDS + 1L,
            createdAt = now,
            updatedAt = now,
        )
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(tooLong)
        }
    }

    @Test
    fun malformedOrIncompleteExercisePlanIsRejectedInsteadOfDefaulted() {
        fun row(planJSON: String) = StrengthRoutineExerciseRow(
            id = "routine-exercise-1",
            routineId = "routine-1",
            exerciseId = "barbell_back_squat",
            position = 0,
            planJSON = planJSON,
            createdAt = now,
            updatedAt = now,
        )

        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(row("not-json"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(row("{}"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(
                row(
                    """
                    {
                      "dropPercent": 20,
                      "loadStepKg": 2.5,
                      "mode": "reps",
                      "progression": "double_progression",
                      "repsPerSide": false,
                      "restPauseSeconds": 15,
                      "setStyle": "straight",
                      "supersetGroup": null,
                      "targetDurationS": null,
                      "targetLoadKg": null,
                      "warmupSets": "2"
                    }
                    """.trimIndent(),
                ),
            )
        }

        val plan = StrengthExercisePlan(warmupSets = 2, setStyle = "rest_pause")
        val encoded = requireNotNull(StrengthTrainingContract.encodeExercisePlan(plan))
        val validated = StrengthTrainingContract.validated(row(encoded))
        assertEquals(plan, StrengthTrainingContract.exercisePlan(validated.planJSON))
    }

    @Test
    fun scheduledWeekdaysRejectCoercedValuesAndSupersetZero() {
        val routine = StrengthRoutineRow(
            id = "routine-1",
            name = "Day A",
            scheduledWeekdaysJSON = """["1",4]""",
            createdAt = now,
            updatedAt = now,
        )
        assertThrows(IllegalArgumentException::class.java) {
            StrengthTrainingContract.validated(routine)
        }
        assertNull(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(supersetGroup = 0),
            ),
        )
    }
}
