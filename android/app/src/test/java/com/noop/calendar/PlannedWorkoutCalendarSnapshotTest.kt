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
    fun recoverableProviderFailurePreservesKnownStateAndReturnsUnknownOutcome() {
        val source = plannedWorkoutCalendarStoreSource()
        val genericCatch = source.indexOf("catch (_: Exception)")
        val publishStart = source.indexOf("var rejectionOutcome", genericCatch)
        assertTrue(genericCatch >= 0 && publishStart > genericCatch)

        val failureBranch = source.substring(genericCatch, publishStart)
        assertTrue(
            failureBranch.contains("PlannedWorkoutCalendarRefreshOutcome.Failed"),
        )
        assertTrue(!failureBranch.contains("_snapshot.value = null"))
        assertTrue(!failureBranch.contains("lastRefreshAtMillis = nowMillis"))
    }

    @Test
    fun nullProviderCursorIsFailureRatherThanAConfirmedEmptyCalendar() {
        val source = plannedWorkoutCalendarStoreSource()
        val query = source.indexOf("val cursor = context.contentResolver.query(")
        val candidates = source.indexOf("val candidates =", query)
        assertTrue(query >= 0 && candidates > query)

        val cursorBoundary = source.substring(query, candidates)
        assertTrue(cursorBoundary.contains("?: throw CalendarProviderUnavailableException()"))
        assertTrue(!cursorBoundary.contains("QueryResult(null, \"zero\")"))
    }

    @Test
    fun refreshInvalidationWithdrawsThePublishedSnapshot() {
        val source = plannedWorkoutCalendarStoreSource()
        val clearStart = source.indexOf("fun clear()")
        val invalidateStart = source.indexOf("fun invalidate()", clearStart)
        val currentStart = source.indexOf("fun isCurrent(", invalidateStart)
        assertTrue(clearStart >= 0 && invalidateStart > clearStart && currentStart > invalidateStart)

        val clear = source.substring(clearStart, invalidateStart)
        val invalidate = source.substring(invalidateStart, currentStart)
        assertTrue(clear.contains("_snapshot.value = null"))
        assertTrue(invalidate.contains("_snapshot.value = null"))
        assertTrue(invalidate.contains("invalidationGeneration += 1L"))
        assertTrue(invalidate.contains("lastRefreshAtMillis = 0L"))
        assertTrue(invalidate.contains("lastRefreshDay = null"))
    }

    @Test
    fun cacheAndPublishPathsFailClosedWhenCalendarPermissionChanges() {
        val source = plannedWorkoutCalendarStoreSource()
        val permissionCheck = source.indexOf("val granted = ContextCompat.checkSelfPermission")
        val initialState = source.indexOf("val initialState = synchronized", permissionCheck)
        val cachedReturn = source.indexOf(
            "return@withLock PlannedWorkoutCalendarRefreshOutcome.Completed(initialState.second)",
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
        val observer = viewModel.substring(
            viewModel.indexOf("private val plannedWorkoutCalendarObserver"),
            viewModel.indexOf("private val noopApp"),
        )
        assertTrue(observer.contains("onPlannedWorkoutCalendarChanged()"))
        assertTrue(viewModel.contains("CalendarContract.Events.CONTENT_URI"))
        assertTrue(viewModel.contains("registerContentObserver("))
        assertTrue(viewModel.contains("unregisterContentObserver("))
        assertTrue(!today.contains("CalendarContract.Events.CONTENT_URI"))

        val methodStart = viewModel.indexOf("fun onPlannedWorkoutCalendarChanged()")
        val methodEnd = viewModel.indexOf(
            "private fun reconcilePlannedWorkoutCalendarObserver",
            methodStart,
        )
        assertTrue(methodStart >= 0 && methodEnd > methodStart)
        val method = viewModel.substring(methodStart, methodEnd)
        val cancel = method.indexOf("plannedWorkoutCalendarEvaluationJob?.cancel()")
        val invalidate = method.indexOf("AdaptiveDayEvaluationGate.invalidate()")
        val invalidateStore = method.indexOf("PlannedWorkoutCalendarStore.invalidate()")
        val cancelArtifacts = method.indexOf("AdaptivePlannedWorkoutScheduler.cancel(appContext)")
        val reconcileArtifacts = method.indexOf(
            "AdaptiveDayNotifier.reconcilePlannedWorkoutArtifacts(",
        )
        val refresh = method.indexOf("PlannedWorkoutCalendarStore.refresh(")
        val evaluate = method.indexOf("evaluateAdaptiveDayGuidance()")
        assertTrue(invalidate >= 0 && invalidateStore > invalidate)
        assertTrue(cancelArtifacts > invalidateStore)
        assertTrue(reconcileArtifacts > cancelArtifacts)
        assertTrue(cancel > reconcileArtifacts && refresh > cancel)
        assertTrue(refresh >= 0 && evaluate > refresh)
        assertTrue(method.contains("force = true"))

        val resumeStart = viewModel.indexOf("override fun onActivityResumed")
        val resumeEnd = viewModel.indexOf("override fun onActivityCreated", resumeStart)
        assertTrue(resumeStart >= 0 && resumeEnd > resumeStart)
        val resume = viewModel.substring(resumeStart, resumeEnd)
        assertTrue(resume.contains("refreshPlannedWorkoutCalendar()"))
        assertTrue(!resume.contains("onPlannedWorkoutCalendarChanged()"))

        val refreshStart = viewModel.indexOf("fun refreshPlannedWorkoutCalendar()")
        val refreshEnd = viewModel.indexOf(
            "fun onAdaptiveDayInputsChanged()",
            refreshStart,
        )
        assertTrue(refreshStart >= 0 && refreshEnd > refreshStart)
        val resumeRefresh = viewModel.substring(refreshStart, refreshEnd)
        assertTrue(resumeRefresh.contains("reconcilePlannedWorkoutCalendarObserver()"))
        val activeJobGuard =
            resumeRefresh.indexOf("plannedWorkoutCalendarEvaluationJob?.isActive == true")
        val generationInvalidation =
            resumeRefresh.indexOf("AdaptiveDayEvaluationGate.invalidate()")
        assertTrue(activeJobGuard >= 0)
        assertTrue(generationInvalidation > activeJobGuard)
        assertTrue(!resumeRefresh.contains("plannedWorkoutCalendarEvaluationJob?.cancel()"))
        assertTrue(resumeRefresh.contains("force = true"))
        assertTrue(resumeRefresh.contains("evaluateAdaptiveDayGuidance()"))
        assertTrue(!resumeRefresh.contains("PlannedWorkoutCalendarStore.invalidate()"))
        assertTrue(!resumeRefresh.contains("AdaptivePlannedWorkoutScheduler.cancel("))
        assertTrue(!resumeRefresh.contains("reconcilePlannedWorkoutArtifacts("))
    }

    @Test
    fun recentHealthDataInvalidatesAndCancelsOlderAdaptiveEvaluation() {
        val viewModel = source("com/noop/ui/AppViewModel.kt")
        val chainStart = viewModel.indexOf(
            "recentDays\n" +
                "                .onEach { AdaptiveDayEvaluationGate.invalidate() }",
        )
        val collectLatest = viewModel.indexOf(".collectLatest { days ->", chainStart)
        val evaluate = viewModel.indexOf("evaluateAdaptiveDayGuidance(days)", collectLatest)

        assertTrue(chainStart >= 0)
        assertTrue(collectLatest > chainStart)
        assertTrue(evaluate > collectLatest)
        assertTrue(!viewModel.contains("recentDays.collect { days ->"))
    }

    @Test
    fun enablingCalendarAccessImmediatelyReevaluatesAdaptiveGuidance() {
        val source = source("com/noop/ui/AutomationsScreen.kt")
        assertTrue(!source.contains("PlannedWorkoutCalendarStore.refresh(ctx, force = true)"))
        assertTrue(source.countOccurrences("viewModel.onPlannedWorkoutCalendarChanged()") >= 4)
        assertTrue(source.contains("viewModel.refreshPlannedWorkoutCalendar()"))
    }

    @Test
    fun disablingAdaptiveGuidanceImmediatelyRetractsPlannedWorkoutArtifacts() {
        val viewModel = source("com/noop/ui/AppViewModel.kt")
        val notifier = source("com/noop/notif/AdaptiveDayNotifier.kt")
        val start = viewModel.indexOf("fun setAdaptiveDayGuidanceEnabled(enabled: Boolean)")
        val end = viewModel.indexOf("fun onPlannedWorkoutCalendarChanged()", start)
        assertTrue(start >= 0 && end > start)
        val method = viewModel.substring(start, end)

        val consent = method.indexOf("AdaptiveDayNotifier.setGuidanceConsent")
        val failedCommit = method.indexOf("return false", consent)
        val disabled = method.indexOf("if (!enabled)")
        val returnIndex = method.indexOf("return true", disabled)
        assertTrue(consent >= 0)
        assertTrue(failedCommit > consent)
        assertTrue(disabled >= 0)
        assertTrue(returnIndex > disabled)

        val setterStart = notifier.indexOf("fun setGuidanceConsent(")
        val setterEnd = notifier.indexOf(
            "fun setPlannedWorkoutCalendarConsent(",
            setterStart,
        )
        assertTrue(setterStart >= 0 && setterEnd > setterStart)
        val setter = notifier.substring(setterStart, setterEnd)
        val committed = setter.indexOf("AdaptiveDayConsentGate.commitGuidance")
        val cleanup = setter.indexOf("completeGuidanceCleanup(app)", committed)
        assertTrue(committed >= 0)
        assertTrue(cleanup > committed)
        assertTrue(setter.substring(committed, cleanup).contains("return false"))
        assertTrue(
            setter.substring(cleanup)
                .contains("AdaptiveDayConsentGate.clearGuidanceCleanupPending(app)"),
        )
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

    private fun String.countOccurrences(needle: String): Int =
        windowed(needle.length, 1).count { it == needle }
}
