package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyEffortScorerTest {
    private fun gravity(ts: Long, x: Double) =
        GravitySample(deviceId = "t", ts = ts, x = x, y = 0.0, z = 1.0)

    @Test
    fun missingMovementPreservesCardiovascularResult() {
        assertNull(DailyEffortScorer.score(cardioEffort = null, steps = null))
        assertEquals(0.0, DailyEffortScorer.score(cardioEffort = 0.0, steps = null)!!, 0.0)
        assertEquals(42.5, DailyEffortScorer.score(cardioEffort = 42.5, steps = null)!!, 0.0)
    }

    @Test
    fun ordinaryWalkingProducesConservativeEffort() {
        assertEquals(18.75, DailyEffortScorer.movementEffort(1_715)!!, 0.0)
        assertEquals(36.68, DailyEffortScorer.movementEffort(10_000)!!, 0.0)
    }

    @Test
    fun moreStepsIncreaseMovementEffort() {
        val light = DailyEffortScorer.movementEffort(1_715)!!
        val active = DailyEffortScorer.movementEffort(10_000)!!
        assertTrue(active > light)
    }

    @Test
    fun cardioAndMovementUseMaximumNotSum() {
        val movement = DailyEffortScorer.movementEffort(10_000)!!
        assertEquals(50.0, DailyEffortScorer.score(50.0, 10_000)!!, 0.0)
        assertEquals(movement, DailyEffortScorer.score(5.0, 10_000)!!, 0.0)
    }

    @Test
    fun gravityFallbackMatchesEquivalentWalkingMinutes() {
        val samples = (0..10).map { index ->
            gravity(index * 60L, if (index % 2 == 0) 0.0 else 0.2)
        }
        assertEquals(10.0, DailyEffortScorer.activeMotionMinutes(samples)!!, 0.0)
        assertEquals(
            DailyEffortScorer.movementEffort(1_000)!!,
            DailyEffortScorer.movementEffort(steps = null, gravity = samples)!!,
            0.0,
        )
    }

    @Test
    fun gravityDoesNotBridgeTelemetryHole() {
        val samples = listOf(gravity(0, 0.0), gravity(121, 0.3))
        assertNull(DailyEffortScorer.activeMotionMinutes(samples))
        assertNull(DailyEffortScorer.movementEffort(steps = null, gravity = samples))
    }

    @Test
    fun measuredStepsTakePrecedenceOverGravityFallback() {
        val samples = (0..10).map { index ->
            gravity(index * 60L, if (index % 2 == 0) 0.0 else 0.3)
        }
        assertEquals(
            DailyEffortScorer.movementEffort(100)!!,
            DailyEffortScorer.movementEffort(steps = 100, gravity = samples)!!,
            0.0,
        )
    }
}
