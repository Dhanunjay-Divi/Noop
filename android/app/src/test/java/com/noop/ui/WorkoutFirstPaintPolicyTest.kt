package com.noop.ui

import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.io.File
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkoutFirstPaintPolicyTest {
    private val zone = ZoneId.of("America/New_York")
    private val today = LocalDate.parse("2026-09-11")
    private val now = LocalDateTime.parse("2026-09-11T15:30:00")
        .atZone(zone)
        .toEpochSecond()

    @Test
    fun firstPaintUsesFourHundredCalendarDaysInsteadOfEpoch() {
        val request = WorkoutFirstPaintPolicy.initialRequest(
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )

        assertEquals(
            today.minusDays(399).atStartOfDay(zone).toEpochSecond(),
            request.window.fromEpochSeconds,
        )
        assertEquals(now, request.window.toEpochSeconds)
        assertTrue(request.window.fromEpochSeconds > 0L)
        assertEquals(null, request.range)
        assertEquals("bounded", request.diagnosticScope)
        assertEquals(300, WorkoutFirstPaintPolicy.HR_PROJECTION_QUERY_CAP)
        assertEquals(300, WorkoutFirstPaintPolicy.FIRST_PAINT_TOTAL_HR_PROJECTION_CAP)
        assertEquals(50, WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP)
        assertEquals(25, WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_ATTEMPT_CAP)
        assertEquals(250, WorkoutFirstPaintPolicy.DEDUP_PROJECTION_TOTAL_CAP)
        assertEquals(
            WorkoutFirstPaintPolicy.FIRST_PAINT_TOTAL_HR_PROJECTION_CAP,
            WorkoutFirstPaintPolicy.DEDUP_PROJECTION_TOTAL_CAP +
                WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP,
        )
        assertEquals(100_000, WorkoutFirstPaintPolicy.HISTORY_OVERLAP_ROW_LIMIT)
        assertTrue(
            WorkoutFirstPaintPolicy.overlapQueryIsComplete(
                WorkoutFirstPaintPolicy.HISTORY_OVERLAP_ROW_LIMIT,
            ),
        )
        assertFalse(
            WorkoutFirstPaintPolicy.overlapQueryIsComplete(
                WorkoutFirstPaintPolicy.HISTORY_OVERLAP_ROW_LIMIT + 1,
            ),
        )
    }

    @Test
    fun onlyExplicitAllQueriesEpochAndCustomUsesExactInclusiveDates() {
        val customStart = LocalDate.parse("2026-08-03")
        val customEnd = LocalDate.parse("2026-08-05")
        val custom = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.Custom,
            customStartDate = customEnd,
            customEndDate = customStart,
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )
        val week = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.Week,
            customStartDate = customStart,
            customEndDate = customEnd,
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )
        val all = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.All,
            customStartDate = customStart,
            customEndDate = customEnd,
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )

        assertEquals(customStart, custom.customStartDate)
        assertEquals(customEnd, custom.customEndDate)
        assertEquals(customStart.atStartOfDay(zone).toEpochSecond(), custom.window.fromEpochSeconds)
        assertEquals(
            customEnd.plusDays(1).atStartOfDay(zone).toEpochSecond() - 1L,
            custom.window.toEpochSeconds,
        )
        assertTrue(custom.window.fromEpochSeconds > 0L)
        assertTrue(week.window.fromEpochSeconds > 0L)
        assertEquals("bounded", custom.diagnosticScope)
        assertEquals(0L, all.window.fromEpochSeconds)
        assertEquals(now, all.window.toEpochSeconds)
        assertEquals("full", all.diagnosticScope)
    }

    @Test
    fun failedExpansionKeepsRowsBoundsAndAppliedRange() {
        val row = workout(startTs = now - 600L, source = "manual")
        val initial = WorkoutFirstPaintPolicy.initialRequest(now, today, zone)
        val previous = WorkoutFirstPaintPolicy.applyResult(
            previous = null,
            request = initial,
            loadedRows = listOf(row),
        )!!
        val allRequest = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.All,
            customStartDate = today.minusDays(29),
            customEndDate = today,
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )
        val customRequest = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.Custom,
            customStartDate = today.minusDays(7),
            customEndDate = today.minusDays(3),
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )

        assertEquals(previous, WorkoutFirstPaintPolicy.applyResult(previous, allRequest, null))
        assertEquals(previous, WorkoutFirstPaintPolicy.applyResult(previous, customRequest, null))
        assertNotEquals(WorkoutRange.All, previous.range)
        assertNotEquals(WorkoutRange.Custom, previous.range)
        assertEquals(initial.window, previous.window)
        assertEquals(initial.customStartDate, previous.customStartDate)
        assertEquals(initial.customEndDate, previous.customEndDate)
        assertNotEquals(customRequest.customStartDate, previous.customStartDate)
        assertNotEquals(customRequest.customEndDate, previous.customEndDate)
        assertEquals(listOf(row), previous.rows)

        val expandedRow = workout(startTs = 1_000L, source = "health-connect")
        val expanded = WorkoutFirstPaintPolicy.applyResult(
            previous = previous,
            request = allRequest,
            loadedRows = listOf(expandedRow),
        )!!
        assertEquals(WorkoutRange.All, expanded.range)
        assertEquals(allRequest.window, expanded.window)
        assertEquals(listOf(expandedRow), expanded.rows)

        val customApplied = WorkoutFirstPaintPolicy.applyResult(
            previous = previous,
            request = customRequest,
            loadedRows = listOf(expandedRow),
        )!!
        assertEquals(WorkoutRange.Custom, customApplied.range)
        assertEquals(customRequest.customStartDate, customApplied.customStartDate)
        assertEquals(customRequest.customEndDate, customApplied.customEndDate)
        assertEquals(customRequest.window, customApplied.window)
    }

    @Test
    fun reloadRefreshesTheUpperBoundWithoutChangingRequestedRange() {
        val initial = WorkoutFirstPaintPolicy.initialRequest(now, today, zone)
        val refreshedInitial = WorkoutFirstPaintPolicy.refreshRequest(
            request = initial,
            nowEpochSeconds = now + 600L,
            today = today,
            zoneId = zone,
        )
        val all = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.All,
            customStartDate = today.minusDays(29),
            customEndDate = today,
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )
        val refreshedAll = WorkoutFirstPaintPolicy.refreshRequest(
            request = all,
            nowEpochSeconds = now + 600L,
            today = today,
            zoneId = zone,
        )

        assertEquals(now + 600L, refreshedInitial.window.toEpochSeconds)
        assertEquals(null, refreshedInitial.range)
        assertEquals(now + 600L, refreshedAll.window.toEpochSeconds)
        assertEquals(WorkoutRange.All, refreshedAll.range)
        assertEquals(0L, refreshedAll.window.fromEpochSeconds)
    }

    @Test
    fun boundedEmptyHistoryStillExposesExplicitAllAccess() {
        val initial = WorkoutFirstPaintPolicy.initialRequest(now, today, zone)
        val emptySnapshot = WorkoutFirstPaintPolicy.applyResult(
            previous = null,
            request = initial,
            loadedRows = emptyList(),
        )

        assertTrue(WorkoutFirstPaintPolicy.shouldShowRangeControl(emptySnapshot))
        assertEquals(WorkoutRange.Year, emptySnapshot!!.range)
        assertTrue(emptySnapshot.rows.isEmpty())
        assertTrue(emptySnapshot.window.fromEpochSeconds > 0L)

        val explicitAll = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.All,
            customStartDate = today.minusDays(29),
            customEndDate = today,
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )
        assertEquals(0L, explicitAll.window.fromEpochSeconds)
    }

    @Test
    fun totalProjectionWorkIsHardCappedAndOlderAmbiguousGroupsStayConservative() = runBlocking {
        val rows = (0 until 400).flatMap { index ->
            val start = 10_000L + index * 10_000L
            listOf(
                workout(
                    startTs = start,
                    endTs = start + 3_600L,
                    source = "manual",
                    energyKcal = 300.0,
                ),
                workout(
                    startTs = start + 30L,
                    endTs = start + 3_570L,
                    source = "health-connect",
                    energyKcal = 300.0,
                ),
            )
        }
        val callbackSizes = mutableListOf<Int>()
        val projectedKeys = mutableListOf<Pair<Long, String>>()
        fun projected(row: WorkoutRow): WorkoutRow =
            if (row.source == "health-connect") row.copy(avgHr = 142, maxHr = 176) else row

        val resolved = WorkoutFirstPaintPolicy.resolveDedupWithBoundedProjection(rows) { batch ->
            callbackSizes += batch.size
            batch.forEach { projectedKeys += it.startTs to it.source }
            batch.map(::projected)
        }

        assertEquals(listOf(WorkoutFirstPaintPolicy.DEDUP_PROJECTION_TOTAL_CAP), callbackSizes)
        assertEquals(WorkoutFirstPaintPolicy.DEDUP_PROJECTION_TOTAL_CAP, projectedKeys.size)
        assertEquals(
            WorkoutFirstPaintPolicy.FIRST_PAINT_TOTAL_HR_PROJECTION_CAP,
            callbackSizes.sum() + WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP,
        )
        assertEquals(675, resolved.size)
        assertEquals(400, resolved.count { it.source == "health-connect" })
        assertEquals(275, resolved.count { it.source == "manual" })
        assertEquals(125, resolved.count { it.source == "health-connect" && it.avgHr == 142 })
        assertTrue(resolved.take(550).all { it.avgHr == null })
        assertTrue(resolved.takeLast(125).all { it.source == "health-connect" && it.avgHr == 142 })

        val secondProjectedKeys = mutableListOf<Pair<Long, String>>()
        val second = WorkoutFirstPaintPolicy.resolveDedupWithBoundedProjection(
            rows = rows,
            totalProjectionCap = Int.MAX_VALUE,
        ) { batch ->
            batch.forEach { secondProjectedKeys += it.startTs to it.source }
            batch.map(::projected)
        }
        assertEquals(projectedKeys, secondProjectedKeys)
        assertEquals(WorkoutFirstPaintPolicy.DEDUP_PROJECTION_TOTAL_CAP, secondProjectedKeys.size)
        assertEquals(resolved, second)
    }

    @Test
    fun dedupProjectionSkipsUnrelatedHistoryAndNeverPartiallyResolvesAGroup() = runBlocking {
        val unrelated = (0 until 500).map { index ->
            val start = 10_000L + index * 1_000L
            workout(
                startTs = start,
                endTs = start + 300L,
                source = "health-connect",
            )
        }
        val duplicateStart = 1_000_000L
        val duplicates = listOf(
            workout(
                startTs = duplicateStart,
                endTs = duplicateStart + 3_600L,
                source = "manual",
            ),
            workout(
                startTs = duplicateStart + 30L,
                endTs = duplicateStart + 3_570L,
                source = "health-connect",
            ),
        )
        val projected = mutableListOf<WorkoutRow>()

        WorkoutFirstPaintPolicy.resolveDedupWithBoundedProjection(unrelated + duplicates) { batch ->
            projected += batch
            batch
        }

        assertEquals(duplicates, projected)

        val conservativelyKept = WorkoutFirstPaintPolicy.resolveDedupWithBoundedProjection(
            rows = duplicates,
            totalProjectionCap = 1,
        ) {
            throw AssertionError("A component larger than the remaining total cap must not be projected")
        }
        assertEquals(duplicates, conservativelyKept)
    }

    @Test
    fun exactWindowIncludesArbitrarilyLongOverlapAndRejectsBoundaryLeaks() {
        val request = WorkoutFirstPaintPolicy.request(
            range = WorkoutRange.Custom,
            customStartDate = LocalDate.parse("2026-08-03"),
            customEndDate = LocalDate.parse("2026-08-05"),
            nowEpochSeconds = now,
            today = today,
            zoneId = zone,
        )
        val lower = request.window.fromEpochSeconds
        val upper = request.window.toEpochSeconds
        val overlapsFromBefore = workout(
            startTs = lower - 10L * 86_400L,
            endTs = lower + 60L,
            source = "manual",
        )
        val endsAtLowerBoundary = workout(
            startTs = lower - 60L,
            endTs = lower,
            source = "manual",
        )
        val startsAtUpperInclusive = workout(
            startTs = upper,
            endTs = upper + 60L,
            source = "manual",
        )
        val startsAfterWindow = workout(
            startTs = upper + 1L,
            endTs = upper + 61L,
            source = "manual",
        )

        val selectedSources = workoutHistoryRowsForSources(
            overlappingRows = listOf(overlapsFromBefore),
            importedSourceIds = listOf("test"),
            computedSourceIds = listOf("test-noop"),
        )
        assertEquals(listOf(overlapsFromBefore), selectedSources)
        assertTrue(request.window.intersectsExact(overlapsFromBefore))
        assertFalse(request.window.intersectsExact(endsAtLowerBoundary))
        assertTrue(request.window.intersectsExact(startsAtUpperInclusive))
        assertFalse(request.window.intersectsExact(startsAfterWindow))
        assertEquals(
            listOf(overlapsFromBefore, startsAtUpperInclusive),
            request.window.filterExact(
                listOf(
                    overlapsFromBefore,
                    endsAtLowerBoundary,
                    startsAtUpperInclusive,
                    startsAfterWindow,
                ),
            ),
        )
    }

    @Test
    fun overlapDaoNormalizesMalformedIntervalsBeforeTestingTheLowerBoundary() {
        val dao = source("com/noop/data/WhoopDao.kt")
        val method = dao.indexOf("suspend fun workoutsOverlappingAllSources")
        val query = dao.substring(dao.lastIndexOf("@Query(", method), method)

        assertTrue(query.contains("CASE WHEN endTs > startTs THEN endTs"))
        assertTrue(query.contains("WHEN startTs < 9223372036854775807 THEN startTs + 1"))
        assertTrue(query.contains("ELSE startTs END) > :from"))
        assertTrue(query.contains("AND startTs <= :to"))
        assertFalse(query.contains("endTs >= :from"))

        val window = WorkoutHistoryWindow(fromEpochSeconds = 100L, toEpochSeconds = 200L)
        val malformedInside = workout(
            startTs = 150L,
            endTs = 75L,
            source = "manual",
        )
        val malformedAtLower = workout(
            startTs = 100L,
            endTs = 75L,
            source = "manual",
        )
        val malformedBeforeLower = workout(
            startTs = 99L,
            endTs = 75L,
            source = "manual",
        )
        val validEndsAtLower = workout(
            startTs = 50L,
            endTs = 100L,
            source = "manual",
        )

        assertTrue(window.intersectsExact(malformedInside))
        assertTrue(window.intersectsExact(malformedAtLower))
        assertFalse(window.intersectsExact(malformedBeforeLower))
        assertFalse(window.intersectsExact(validEndsAtLower))
    }

    @Test
    fun overlapSourceAssemblyPreservesActiveUnionPrecedenceAndDropsUnrequestedDevices() {
        val active = workout(
            deviceId = "active",
            startTs = 1_000L,
            source = "manual",
            avgHr = 140,
        )
        val canonicalDuplicate = active.copy(
            deviceId = WhoopRepository.WHOOP_SOURCE,
            avgHr = 120,
        )
        val computed = workout(
            deviceId = "active-noop",
            startTs = 2_000L,
            source = "active-noop",
        )
        val unrelated = workout(
            deviceId = "old-strap",
            startTs = 3_000L,
            source = "manual",
        )

        val selected = workoutHistoryRowsForSources(
            overlappingRows = listOf(canonicalDuplicate, computed, unrelated, active),
            importedSourceIds = listOf("active", WhoopRepository.WHOOP_SOURCE),
            computedSourceIds = listOf("active-noop", "${WhoopRepository.WHOOP_SOURCE}-noop"),
        )

        assertEquals(listOf(active, computed), selected)
    }

    @Test
    fun visibleProjectionBudgetIsLifetimeBoundAcrossHugePagination() {
        val lifting = (0L until 60L).map { index ->
            workout(startTs = index, source = "lifting")
        }
        val importedMissingHr = (100L until 600L).map { index ->
            workout(startTs = index, source = "health-connect")
        }
        val importedComplete = workout(
            startTs = 1_000L,
            source = "health-connect",
            avgHr = 130,
        )
        val source = lifting + importedMissingHr + importedComplete
        val budget = WorkoutVisibleProjectionBudget()
        var completed = emptySet<WorkoutRow>()
        val callbackSizes = mutableListOf<Int>()

        for (visibleCount in 50..source.size step 50) {
            while (true) {
                val eligible = WorkoutFirstPaintPolicy.hrProjectionCandidates(
                    rows = source.take(visibleCount),
                    completedRows = completed,
                    limit = WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP,
                )
                val reserved = budget.reserve(eligible)
                if (reserved.isEmpty()) break
                callbackSizes += reserved.size
                assertTrue(reserved.all { it.source == "health-connect" && it.avgHr == null })
                completed = WorkoutFirstPaintPolicy.completedProjectionRows(
                    previous = completed,
                    candidates = reserved,
                    succeeded = true,
                )
            }
        }

        assertEquals(listOf(25, 15, 10), callbackSizes)
        assertEquals(3, callbackSizes.size)
        assertEquals(WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP, callbackSizes.sum())
        assertEquals(WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP, budget.consumedRows)
        assertEquals(0, budget.remainingRows)
        assertEquals(WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP, completed.size)
        assertTrue(
            budget.reserve(
                WorkoutFirstPaintPolicy.hrProjectionCandidates(
                    rows = source,
                    completedRows = completed,
                    limit = WorkoutFirstPaintPolicy.VISIBLE_SESSION_PROJECTION_CAP,
                ),
            ).isEmpty(),
        )
        assertEquals(
            WorkoutFirstPaintPolicy.FIRST_PAINT_TOTAL_HR_PROJECTION_CAP,
            WorkoutFirstPaintPolicy.DEDUP_PROJECTION_TOTAL_CAP + callbackSizes.sum(),
        )
    }

    @Test
    fun failedProjectionRemainsUnappliedAndRetryWorkStaysWithinLifetimeBudget() {
        val candidate = workout(startTs = 1_000L, source = "manual", avgHr = 140)
        val candidates = (0L until 100L).map { index ->
            candidate.copy(startTs = candidate.startTs + index, endTs = candidate.endTs + index)
        }
        val context = WorkoutProjectionContext(
            activeStrapId = "strap-a",
            hrMax = 190,
            sex = "female",
            profileRevision = 7L,
        )
        val failedCompleted = WorkoutFirstPaintPolicy.completedProjectionRows(
            previous = emptySet(),
            candidates = candidates,
            succeeded = false,
        )
        val firstAttempt = WorkoutProjectionAttemptKey(candidates, context, retryGeneration = 0L)
        val retryAttempt = WorkoutProjectionAttemptKey(candidates, context, retryGeneration = 1L)
        val budget = WorkoutVisibleProjectionBudget()
        val firstReservation = budget.reserve(candidates)
        val retryReservation = budget.reserve(candidates)
        val exhaustedReservation = budget.reserve(candidates)

        assertTrue(failedCompleted.isEmpty())
        assertEquals(25, firstReservation.size)
        assertEquals(firstReservation, retryReservation)
        assertTrue(exhaustedReservation.isEmpty())
        assertEquals(50, budget.consumedRows)
        assertEquals(0, budget.remainingRows)
        assertNotEquals(firstAttempt, retryAttempt)
        assertEquals(firstAttempt.candidates, retryAttempt.candidates)
        assertEquals(firstAttempt.context, retryAttempt.context)
    }

    @Test
    fun hoistedProjectionStateKeepsRowsHonestAcrossFailureRetryAndSuccess() {
        val original = workout(startTs = 1_000L, source = "health-connect")
        val projected = original.copy(avgHr = 142, maxHr = 176)
        val firstContext = WorkoutProjectionContext(
            activeStrapId = "strap-a",
            hrMax = 190,
            sex = "female",
            profileRevision = 7L,
        )
        val nextContext = firstContext.copy(activeStrapId = "strap-b")
        var state = WorkoutVisibleProjectionState().forContext(firstContext)

        state = state.beginAttempt().markFailed()
        assertTrue(state.failed)
        assertTrue(state.projections.isEmpty())
        assertTrue(state.completedRows.isEmpty())

        state = state.retry()
        assertFalse(state.failed)
        assertEquals(1L, state.retryGeneration)
        assertTrue(state.projections.isEmpty())

        state = state.applySuccess(
            candidates = listOf(original),
            projected = listOf(projected),
        )
        assertFalse(state.failed)
        assertEquals(projected, state.projections[original])
        assertEquals(setOf(original), state.completedRows)
        assertEquals(1L, state.retryGeneration)

        val switched = state.forContext(nextContext)
        assertEquals(nextContext, switched.context)
        assertTrue(switched.projections.isEmpty())
        assertTrue(switched.completedRows.isEmpty())
        assertFalse(switched.failed)
        assertEquals(1L, switched.retryGeneration)
    }

    @Test
    fun visibleProjectionBudgetIdentityChangesOnlyWithWindowOrRows() {
        val row = workout(startTs = 1_000L, source = "manual")
        val window = WorkoutHistoryWindow(500L, 2_000L)
        val key = WorkoutSessionProjectionBudgetKey(window = window, rows = listOf(row))

        assertEquals(
            key,
            WorkoutSessionProjectionBudgetKey(window = window, rows = listOf(row)),
        )
        assertNotEquals(
            key,
            WorkoutSessionProjectionBudgetKey(
                window = window.copy(toEpochSeconds = 2_001L),
                rows = listOf(row),
            ),
        )
        assertNotEquals(
            key,
            WorkoutSessionProjectionBudgetKey(
                window = window,
                rows = listOf(row.copy(notes = "changed")),
            ),
        )

        val workouts = source("com/noop/ui/WorkoutsScreen.kt")
        val rootStart = workouts.indexOf("fun WorkoutsScreen(")
        val rootEnd = workouts.indexOf("LazyScreenScaffold(", rootStart)
        val rootState = workouts.substring(rootStart, rootEnd)
        assertTrue(
            rootState.contains(
                "val sessionProjectionBudget = remember(sessionProjectionBudgetKey)",
            ),
        )
        assertTrue(
            rootState.contains(
                "var sessionProjectionState by remember(sessionProjectionBudgetKey)",
            ),
        )
        assertTrue(
            rootState.contains(
                "var sessionShownCount by remember(sessionProjectionBudgetKey)",
            ),
        )
        assertFalse(
            rootState.contains(
                "remember(sessionProjectionBudgetKey, workoutProjectionContext)",
            ),
        )
        assertTrue(rootState.contains("LaunchedEffect(sessionProjectionAttemptKey)"))
        assertTrue(rootState.contains("sessionProjectionBudget.reserve(attempt.candidates)"))
        assertTrue(
            rootState.contains("sessionProjectionState = sessionProjectionState") &&
                rootState.contains(".forContext(workoutProjectionContext)") &&
                rootState.contains(".applySuccess("),
        )

        val callStart = workouts.indexOf("SessionsSection(", rootEnd)
        val callEnd = workouts.indexOf("selectionMode = selectionMode", callStart)
        val call = workouts.substring(callStart, callEnd)
        assertTrue(call.contains("projectionFailed = activeSessionProjectionState.failed"))
        assertTrue(
            call.contains(
                "projectionRetryAvailable = sessionProjectionBudget.remainingRows > 0",
            ),
        )
        assertTrue(call.contains("if (sessionProjectionBudget.remainingRows > 0)"))
        assertTrue(
            call.contains(
                "sessionProjectionState = activeSessionProjectionState.retry()",
            ),
        )
        assertTrue(call.contains("onShowMore = { sessionShownCount += SESSIONS_PAGE_SIZE }"))

        val sectionStart = workouts.indexOf("private fun SessionsSection(")
        val sectionEnd = workouts.indexOf("/** #64: the \"Select\" pill", sectionStart)
        val section = workouts.substring(sectionStart, sectionEnd)
        assertTrue(section.contains("visibleRows: List<WorkoutRow>"))
        assertTrue(section.contains("onRetryProjection: () -> Unit"))
        assertTrue(section.contains("onShowMore: () -> Unit"))
        assertFalse(section.contains("WorkoutVisibleProjectionBudget"))
        assertFalse(section.contains("fillWorkoutHrFromStrap"))
        assertFalse(section.contains("workouts.visible_session_projection"))
        assertFalse(section.contains("sessionProjectionState"))
        assertFalse(section.contains("LaunchedEffect("))
    }

    @Test
    fun visibleProjectionDiagnosticsExposeOnlyBoundedStatusContextAndCount() {
        assertEquals(
            mapOf("scope" to "visible_page", "result_bucket" to "none"),
            workoutVisibleProjectionDiagnosticFields(0),
        )
        assertEquals(
            mapOf("scope" to "visible_page", "result_bucket" to "under_50"),
            workoutVisibleProjectionDiagnosticFields(25),
        )
        assertEquals(
            setOf("scope", "result_bucket"),
            workoutVisibleProjectionDiagnosticFields(Int.MAX_VALUE).keys,
        )
        assertEquals(
            "200_plus",
            workoutVisibleProjectionDiagnosticFields(Int.MAX_VALUE)["result_bucket"],
        )

        val workouts = source("com/noop/ui/WorkoutsScreen.kt")
        val operation = workouts.indexOf("\"workouts.visible_session_projection\"")
        val block = workouts.substring(
            workouts.lastIndexOf("LaunchedEffect(", operation),
            workouts.indexOf("val projectedVisibleSessionRows =", operation),
        )
        assertTrue(block.contains("outcome = \"completed\""))
        assertTrue(block.contains("outcome = \"failed\""))
        assertTrue(block.contains("outcome = \"superseded\""))
        assertTrue(block.contains("workoutVisibleProjectionDiagnosticFields"))
        assertTrue(block.contains("AppDiagnosticsRecorder.endOperation"))
        assertFalse(block.contains("exception.message"))
        assertFalse(block.contains("throwable.message"))
    }

    @Test
    fun detailProjectionKeyIncludesCompleteRowAndProfileContext() {
        val row = workout(
            startTs = 1_000L,
            source = "manual",
            avgHr = 140,
            notes = "easy",
        )
        val context = WorkoutProjectionContext(
            activeStrapId = "strap-a",
            hrMax = 190,
            sex = "female",
            profileRevision = 7L,
        )
        val key = WorkoutDetailProjectionKey(row, context)

        assertNotEquals(key, WorkoutDetailProjectionKey(row.copy(notes = "hard"), context))
        assertNotEquals(key, WorkoutDetailProjectionKey(row.copy(routePolyline = "encoded"), context))
        assertNotEquals(
            key,
            WorkoutDetailProjectionKey(row, context.copy(activeStrapId = "strap-b")),
        )
        assertNotEquals(key, WorkoutDetailProjectionKey(row, context.copy(hrMax = 191)))
        assertNotEquals(key, WorkoutDetailProjectionKey(row, context.copy(sex = "male")))
        assertNotEquals(key, WorkoutDetailProjectionKey(row, context.copy(profileRevision = 8L)))

        val firstAttempt = WorkoutDetailProjectionAttemptKey(key, retryGeneration = 0L)
        val retryAttempt = WorkoutDetailProjectionAttemptKey(key, retryGeneration = 1L)
        assertNotEquals(firstAttempt, retryAttempt)
        assertEquals(firstAttempt.detail, retryAttempt.detail)

        val failed = WorkoutFirstPaintPolicy.detailProjectionResult(row, emptyList())
        assertTrue(failed.failed)
        assertEquals(row, failed.row)
        assertTrue(
            WorkoutFirstPaintPolicy.detailProjectionResult(row, listOf(row, row)).failed,
        )

        val projected = row.copy(avgHr = 144, maxHr = 177)
        val succeeded = WorkoutFirstPaintPolicy.detailProjectionResult(row, listOf(projected))
        assertFalse(succeeded.failed)
        assertEquals(projected, succeeded.row)
    }

    private fun workout(
        deviceId: String = "test",
        startTs: Long,
        endTs: Long = startTs + 300L,
        source: String,
        avgHr: Int? = null,
        maxHr: Int? = null,
        energyKcal: Double? = null,
        notes: String? = null,
    ): WorkoutRow = WorkoutRow(
        deviceId = deviceId,
        startTs = startTs,
        endTs = endTs,
        sport = "Running",
        source = source,
        durationS = (endTs - startTs).toDouble(),
        energyKcal = energyKcal,
        avgHr = avgHr,
        maxHr = maxHr,
        notes = notes,
    )

    private fun source(relative: String): String {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/$relative"),
            File(userDir, "app/src/main/java/$relative"),
            File(userDir, "android/app/src/main/java/$relative"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relative from $userDir")
    }
}
