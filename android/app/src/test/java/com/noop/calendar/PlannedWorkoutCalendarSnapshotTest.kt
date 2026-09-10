package com.noop.calendar

import org.junit.Assert.assertEquals
import org.junit.Test

class PlannedWorkoutCalendarSnapshotTest {
    @Test
    fun civilWorkoutCanBeBridgedIntoLogicalPlanningDayWithoutChangingTime() {
        val snapshot = PlannedWorkoutCalendarSnapshot(
            day = "2026-09-10",
            startSec = 1_789_060_200L,
            endSec = 1_789_063_800L,
            observedAtSec = 1_789_010_000L,
            revision = 3L,
        )

        val workout = snapshot.asPlannedWorkout("2026-09-09")

        assertEquals("2026-09-09", workout.day)
        assertEquals(snapshot.startSec, workout.startSec)
        assertEquals(snapshot.endSec, workout.endSec)
    }
}
