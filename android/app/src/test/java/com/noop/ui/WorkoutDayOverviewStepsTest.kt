package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WorkoutDayOverviewStepsTest {
    @Test
    fun importedPedometerCountOutranksBandMotionEstimate() {
        assertEquals(
            ResolvedDayOverviewSteps(9_500, DayOverviewStepSource.IMPORTED_PEDOMETER),
            resolvedDayOverviewSteps(imported = 9_500, classifiedBand = 4_000),
        )
        assertEquals(
            ResolvedDayOverviewSteps(4_000, DayOverviewStepSource.CLASSIFIED_BAND),
            resolvedDayOverviewSteps(imported = null, classifiedBand = 4_000),
        )
        assertNull(resolvedDayOverviewSteps(imported = null, classifiedBand = null))
    }
}
