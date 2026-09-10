package com.noop.calendar

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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

    @Test
    fun providerRefreshNeverConvertsCoroutineCancellationIntoFailure() {
        val source = plannedWorkoutCalendarStoreSource()
        val queryStart = source.indexOf("val result = try {")
        val publishStart = source.indexOf("var rejectionOutcome", startIndex = queryStart)
        assertTrue(queryStart >= 0 && publishStart > queryStart)

        val queryBoundary = source.substring(queryStart, publishStart)
        val cancellationCatch = queryBoundary.indexOf("catch (cancelled: CancellationException)")
        val genericCatch = queryBoundary.indexOf("catch (_: Throwable)")
        assertTrue(cancellationCatch >= 0)
        assertTrue(genericCatch > cancellationCatch)
        assertTrue(queryBoundary.contains("outcome = \"cancelled\""))
        assertTrue(queryBoundary.contains("throw cancelled"))
    }

    private fun plannedWorkoutCalendarStoreSource(): String {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val file = listOf(
            File(root, "src/main/java/com/noop/calendar/PlannedWorkoutCalendarStore.kt"),
            File(root, "app/src/main/java/com/noop/calendar/PlannedWorkoutCalendarStore.kt"),
            File(root, "android/app/src/main/java/com/noop/calendar/PlannedWorkoutCalendarStore.kt"),
        ).firstOrNull(File::isFile)
        return checkNotNull(file) {
            "Could not locate PlannedWorkoutCalendarStore.kt from $root"
        }.readText()
    }
}
