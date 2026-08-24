package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DailyEffortGuidanceTest {
    private val range = DailyActionPlanner.EffortRange(40, 60)

    @Test
    fun missingAndInvalidInputsFailClosed() {
        val results = listOf(
            DailyEffortGuidance.evaluate(null, range),
            DailyEffortGuidance.evaluate(Double.NaN, range),
            DailyEffortGuidance.evaluate(-1.0, range),
            DailyEffortGuidance.evaluate(101.0, range),
            DailyEffortGuidance.evaluate(45.0, null),
            DailyEffortGuidance.evaluate(45.0, DailyActionPlanner.EffortRange(70, 60)),
        )
        results.forEach {
            assertEquals(DailyEffortGuidance.State.UNAVAILABLE, it.state)
            assertNull(it.current)
            assertNull(it.range)
            assertNull(it.remainingToLower)
            assertEquals(0.0, it.progress, 0.0)
        }
    }

    @Test
    fun belowRangeReportsRemainingAndCanonicalProgress() {
        val result = DailyEffortGuidance.evaluate(25.0, range)
        assertEquals(DailyEffortGuidance.State.BELOW_RANGE, result.state)
        assertEquals(15.0, result.remainingToLower!!, 0.0)
        assertEquals(0.25, result.progress, 0.0)
    }

    @Test
    fun rangeBoundsAreInclusive() {
        assertEquals(DailyEffortGuidance.State.IN_RANGE, DailyEffortGuidance.evaluate(40.0, range).state)
        assertEquals(DailyEffortGuidance.State.IN_RANGE, DailyEffortGuidance.evaluate(60.0, range).state)
    }

    @Test
    fun aboveRangeIsDescriptiveNotUnavailable() {
        val result = DailyEffortGuidance.evaluate(72.5, range)
        assertEquals(DailyEffortGuidance.State.ABOVE_RANGE, result.state)
        assertEquals(72.5, result.current!!, 0.0)
        assertEquals(0.0, result.remainingToLower!!, 0.0)
        assertEquals(0.725, result.progress, 0.0)
    }
}
