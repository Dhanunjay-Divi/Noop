package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

class StrengthProgressTest {
    private fun set(
        id: String,
        sessionId: String,
        exerciseId: String,
        position: Int,
        reps: Int?,
        load: Double?,
        setType: String = "working",
        completed: Boolean = true,
    ) = StrengthSetRow(
        id = id,
        sessionId = sessionId,
        exerciseId = exerciseId,
        exercisePosition = 0,
        setPosition = position,
        setType = setType,
        reps = reps,
        loadKg = load,
        completedAt = if (completed) 2_000 else null,
        createdAt = 1_000,
        updatedAt = 2_000,
    )

    private fun session(
        id: String,
        startedAt: Long,
        ended: Boolean = true,
        sets: List<StrengthSetRow>,
    ) = StrengthSessionSnapshot(
        StrengthSessionRow(
            id = id,
            startedAt = startedAt,
            endedAt = if (ended) startedAt + 3_600 else null,
            createdAt = startedAt,
            updatedAt = startedAt + 3_600,
        ),
        sets,
    )

    @Test
    fun historyUsesCompletedFinishedWorkOnly() {
        val old = session(
            "old",
            100,
            sets = listOf(
                set("a", "old", "barbell_back_squat", 0, 5, 100.0),
                set("warm", "old", "barbell_back_squat", 1, 20, 150.0, "warmup"),
                set("draft", "old", "barbell_back_squat", 2, 8, 120.0, completed = false),
            ),
        )
        val recent = session(
            "recent",
            200,
            sets = listOf(set("b", "recent", "barbell_back_squat", 0, 6, 105.0)),
        )
        val active = session(
            "active",
            300,
            ended = false,
            sets = listOf(set("c", "active", "barbell_back_squat", 0, 10, 200.0)),
        )

        val points = StrengthProgressCalculator.exerciseHistory(
            "barbell_back_squat",
            listOf(old, recent, active),
        )
        assertEquals(listOf("recent", "old"), points.map { it.sessionId })
        assertEquals(105.0, points[0].maxLoadKg)
        assertEquals(630.0, points[0].bestSetVolumeKg)
        assertEquals(1, points[1].completedSetCount)
    }

    @Test
    fun weeklyProgressAndMuscleExposureStayFactual() {
        val completed = session(
            "week",
            150,
            sets = listOf(
                set("squat", "week", "barbell_back_squat", 0, 5, 100.0),
                set("pull", "week", "pull_up", 1, 8, null),
                set("warmup", "week", "barbell_back_squat", 2, 10, 20.0, "warmup"),
            ),
        )
        val progress = StrengthProgressCalculator.weeklyProgress(listOf(completed), 100, 200)
        assertEquals(1, progress.sessionCount)
        assertEquals(2, progress.completedSetCount)
        assertEquals(13, progress.totalReps)
        assertEquals(500.0, progress.loadedVolumeKg, 0.001)

        val focus = StrengthProgressCalculator.muscleFocus(
            StrengthTrainingContract.BUILT_IN_EXERCISES,
            listOf(completed),
            100,
            200,
        )
        assertEquals(1, focus.first { it.muscle == "back" }.directSetCount)
        assertEquals(1.0, focus.first { it.muscle == "quadriceps" }.weightedSetExposure, 0.001)
        assertEquals(0.5, focus.first { it.muscle == "glutes" }.weightedSetExposure, 0.001)
        assertEquals(1, focus.first { it.muscle == "biceps" }.supportingSetCount)
        assertEquals(1, focus.first { it.muscle == "quadriceps" }.directSetCount)
    }
}
