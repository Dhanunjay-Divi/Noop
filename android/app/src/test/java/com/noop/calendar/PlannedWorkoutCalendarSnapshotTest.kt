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
        val genericCatch = queryBoundary.indexOf("catch (_: Exception)")
        assertTrue(cancellationCatch >= 0)
        assertTrue(genericCatch > cancellationCatch)
        assertTrue(!queryBoundary.contains("catch (_: Throwable)"))
        assertTrue(queryBoundary.contains("outcome = \"cancelled\""))
        assertTrue(queryBoundary.contains("throw cancelled"))
    }

    @Test
    fun cacheAndPublishPathsFailClosedWhenCalendarPermissionChanges() {
        val source = plannedWorkoutCalendarStoreSource()
        val permissionCheck = source.indexOf("val granted = ContextCompat.checkSelfPermission")
        val initialState = source.indexOf("val initialState = synchronized", permissionCheck)
        val cachedReturn = source.indexOf(
            "if (initialState.first) return@withLock initialState.second",
            initialState,
        )
        assertTrue(permissionCheck >= 0)
        assertTrue(initialState > permissionCheck)
        assertTrue(cachedReturn > initialState)
        assertTrue(source.substring(initialState, cachedReturn).contains("granted &&"))

        val accessChanged = source.indexOf("rejectionOutcome = \"access_changed\"")
        val publishBranch = source.indexOf("} else {", accessChanged)
        assertTrue(accessChanged >= 0 && publishBranch > accessChanged)
        val rejectedBranch = source.substring(accessChanged, publishBranch)
        assertTrue(rejectedBranch.contains("_snapshot.value = null"))
        assertTrue(rejectedBranch.contains("lastRefreshAtMillis = nowMillis"))
    }

    @Test
    fun providerChangesForceRefreshBeforeAdaptiveGuidanceReevaluation() {
        val today = source("com/noop/ui/TodayScreen.kt")
        val viewModel = source("com/noop/ui/AppViewModel.kt")
        val observer = today.substring(
            today.indexOf("val providerObserver = object"),
            today.indexOf("fun ensureProviderObserver()"),
        )
        assertTrue(observer.contains("viewModel.onPlannedWorkoutCalendarChanged()"))

        val methodStart = viewModel.indexOf("fun onPlannedWorkoutCalendarChanged()")
        val methodEnd = viewModel.indexOf("private suspend fun evaluateAdaptiveDayGuidance", methodStart)
        assertTrue(methodStart >= 0 && methodEnd > methodStart)
        val method = viewModel.substring(methodStart, methodEnd)
        val refresh = method.indexOf("PlannedWorkoutCalendarStore.refresh(")
        val evaluate = method.indexOf("evaluateAdaptiveDayGuidance()")
        assertTrue(refresh >= 0 && evaluate > refresh)
        assertTrue(method.contains("force = true"))
    }

    @Test
    fun declinedInvitationsAreRejectedBeforeWorkoutTitleClassification() {
        val source = plannedWorkoutCalendarStoreSource()
        assertTrue(source.contains("CalendarContract.Instances.SELF_ATTENDEE_STATUS"))
        assertTrue(source.contains("CalendarContract.Attendees.ATTENDEE_STATUS_DECLINED"))
        val declinedGuard = source.indexOf("!declined &&")
        val titleClassifier = source.indexOf("PlannedWorkoutTitleClassifier.isWorkoutTitle(title)")
        assertTrue(declinedGuard >= 0 && titleClassifier > declinedGuard)
    }

    private fun plannedWorkoutCalendarStoreSource(): String {
        return source("com/noop/calendar/PlannedWorkoutCalendarStore.kt")
    }

    private fun source(relativePath: String): String {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val file = listOf(
            File(root, "src/main/java/$relativePath"),
            File(root, "app/src/main/java/$relativePath"),
            File(root, "android/app/src/main/java/$relativePath"),
        ).firstOrNull(File::isFile)
        return checkNotNull(file) {
            "Could not locate $relativePath from $root"
        }.readText()
    }
}
