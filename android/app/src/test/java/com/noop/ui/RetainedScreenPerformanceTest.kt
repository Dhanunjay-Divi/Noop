package com.noop.ui

import com.noop.ble.LiveState
import java.io.File
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RetainedScreenPerformanceTest {
    @Test
    fun sharedSyncProjectionSuppressesOrdinarySensorTicks() = runTest {
        val observed = flowOf(
            LiveState(heartRate = 70, heartRateSampleSequence = 1),
            LiveState(heartRate = 71, heartRateSampleSequence = 2),
            LiveState(
                backfilling = true,
                syncChunksThisSession = 1,
                syncRowsThisSession = 40,
            ),
            LiveState(
                backfilling = true,
                heartRate = 72,
                heartRateSampleSequence = 3,
                syncChunksThisSession = 1,
                syncRowsThisSession = 40,
            ),
            LiveState(
                backfilling = true,
                syncChunksThisSession = 2,
                syncRowsThisSession = 80,
            ),
            LiveState(heartRate = 73, heartRateSampleSequence = 4),
        ).historySyncStatusChanges().toList()

        assertEquals(4, observed.size)
        assertFalse(observed[0].backfilling)
        assertEquals(1, observed[1].batches)
        assertEquals(2, observed[2].batches)
        assertFalse(observed[3].backfilling)
    }

    @Test
    fun dashboardProjectionSuppressesSensorAndSyncProgressTicks() = runTest {
        val observed = flowOf(
            LiveState(heartRate = 70, heartRateSampleSequence = 1),
            LiveState(heartRate = 71, heartRateSampleSequence = 2),
            LiveState(
                connected = true,
                batteryPct = 80.0,
                syncChunksThisSession = 1,
            ),
            LiveState(
                connected = true,
                batteryPct = 80.0,
                heartRate = 72,
                heartRateSampleSequence = 3,
                syncChunksThisSession = 2,
            ),
            LiveState(
                connected = true,
                batteryPct = 79.0,
                syncChunksThisSession = 3,
            ),
        ).dashboardLiveChanges().toList()

        assertEquals(3, observed.size)
        assertFalse(observed[0].connected)
        assertEquals(80.0, observed[1].batteryPct)
        assertEquals(79.0, observed[2].batteryPct)
    }

    @Test
    fun dashboardProjectionPublishesLiveSessionReadinessChanges() = runTest {
        val observed = flowOf(
            LiveState(connected = true, bonded = true, encryptedBond = false, worn = true),
            LiveState(connected = true, bonded = true, encryptedBond = true, worn = true),
            LiveState(connected = true, bonded = true, encryptedBond = true, worn = false),
        ).dashboardLiveChanges().toList()

        assertEquals(3, observed.size)
        assertFalse(observed[0].encryptedBond)
        assertTrue(observed[1].encryptedBond)
        assertFalse(observed[2].worn)
    }

    @Test
    fun sleepHistoryUsesBatchedMotionReadsAndBoundedDiagnostics() {
        val sleep = source("com/noop/ui/SleepScreen.kt")
        val repository = source("com/noop/data/WhoopRepository.kt")
        val dao = source("com/noop/data/WhoopDao.kt")

        val rootStart = sleep.indexOf("fun SleepScreen(")
        val rootEnd = sleep.indexOf("// MARK: - 0b.", startIndex = rootStart)
        val root = sleep.substring(rootStart, rootEnd)
        assertTrue(root.contains("vm.historyBackfillActive.collectAsStateWithLifecycle()"))
        assertTrue(root.contains("SleepSyncingHistoryStatus(vm)"))
        assertFalse(root.contains("vm.historySyncStatus.collectAsStateWithLifecycle()"))
        assertFalse(root.contains("vm.live.collectAsStateWithLifecycle()"))
        assertTrue(
            Regex("""vm\.repo\.sessionMotions\(\s*activeDeviceId""")
                .containsMatchIn(root) ||
                Regex("""vm\.repo\.sessionMotions\(\s*requestDeviceId""")
                    .containsMatchIn(root),
        )
        assertTrue(root.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(root.contains("\"sleep.history_snapshot_load\""))
        assertTrue(root.contains("\"sleep.history_metrics_load\""))
        assertTrue(root.contains("shouldPublishSleepHistorySnapshot("))
        assertTrue(root.contains("SleepHistorySnapshot("))
        assertTrue(root.contains("SleepMetricSnapshot("))
        assertTrue(root.contains("val isBackfilling by vm.historyBackfillActive"))
        assertTrue(root.contains("rememberHistoryQueryGate(isBackfilling)"))
        assertTrue(root.contains("if (deferHistoricalQueries) return@LaunchedEffect"))
        val stressStart = root.indexOf("val sleepStressWindow")
        val stressEnd = root.indexOf("// #940:", startIndex = stressStart)
        val stressBlock = root.substring(stressStart, stressEnd)
        assertTrue(
            stressBlock.contains(
                "LaunchedEffect(sleepStressWindow, days, activeDeviceId, deferHistoricalQueries)",
            ),
        )
        assertTrue(stressBlock.contains("if (deferHistoricalQueries) return@LaunchedEffect"))
        assertTrue(stressBlock.contains("val heartRateJob = async"))
        assertTrue(stressBlock.contains("val intervalsJob = async"))
        assertTrue(stressBlock.contains("currentCoroutineContext().ensureActive()"))
        assertTrue(stressBlock.contains("remember(activeDeviceId)"))
        assertTrue(root.contains("it.deviceId == activeDeviceId"))
        assertFalse(stressBlock.contains("runCatching"))

        val batchStart = repository.indexOf("suspend fun sessionMotions(")
        val batchEnd = repository.indexOf("/** Persist the decoded", startIndex = batchStart)
        val batch = repository.substring(batchStart, batchEnd)
        assertTrue(batch.contains("val uniqueStarts = starts.distinct()"))
        assertTrue(batch.contains("for (computedId in computedSourceIds(strapDeviceId))"))
        assertTrue(batch.contains("uniqueStarts.chunked(500)"))
        assertTrue(batch.contains("dao.sessionMotionRows"))
        assertTrue(batch.contains("out.putIfAbsent(row.startTs, motion)"))
        assertFalse(batch.contains("for (start in starts)"))
        assertTrue(dao.contains("suspend fun sessionMotionRows("))
    }

    @Test
    fun sleepHistoryPublicationRejectsCancellationAndDeviceSupersession() {
        assertTrue(
            shouldPublishSleepHistorySnapshot(
                requestDeviceId = "device-a",
                currentDeviceId = "device-a",
                isCancelled = false,
            ),
        )
        assertFalse(
            shouldPublishSleepHistorySnapshot(
                requestDeviceId = "device-a",
                currentDeviceId = "device-b",
                isCancelled = false,
            ),
        )
        assertFalse(
            shouldPublishSleepHistorySnapshot(
                requestDeviceId = "device-a",
                currentDeviceId = "device-a",
                isCancelled = true,
            ),
        )
    }

    @Test
    fun workoutRecoveryStartsLazilyButSurvivesLazyItemDisposal() {
        val workouts = source("com/noop/ui/WorkoutsScreen.kt")
        val viewModel = source("com/noop/ui/AppViewModel.kt")

        assertTrue(workouts.contains("item(key = \"recovery-trend\")"))
        assertTrue(workouts.contains("private fun RecoveryTrendLazySection("))
        assertTrue(workouts.contains("val recoveryLoadScope = rememberCoroutineScope()"))
        assertTrue(workouts.contains("LaunchedEffect(recoveryInputKey)"))
        assertTrue(workouts.contains("recoveryLoadScope.launch"))
        assertTrue(workouts.contains("recoveryTrendLoadAttempt += 1"))
        assertTrue(workouts.contains("recoveryTrendLoadAttempt == requestAttempt"))
        assertTrue(workouts.contains("onLoadRequested = { requestedKey ->"))
        assertTrue(workouts.contains("\"workouts.recovery_trend_load\""))
        assertTrue(workouts.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(workouts.contains("loadActiveZoneWeek(vm, activeDeviceId)"))
        assertTrue(workouts.contains("if (vm.activeStrapId == activeDeviceId)"))

        val lazyStart = workouts.indexOf("private fun RecoveryTrendLazySection(")
        val lazyEnd = workouts.indexOf("internal data class ActiveZoneWeekSnapshot(", lazyStart)
        val lazySection = workouts.substring(lazyStart, lazyEnd)
        assertTrue(lazySection.contains("onLoadRequested(inputKey)"))
        assertFalse(lazySection.contains("workoutHeartRateRecovery("))
        assertFalse(lazySection.contains("beginOperation("))

        val start = viewModel.indexOf("suspend fun workoutHeartRateRecovery(")
        val end = viewModel.indexOf("/** Steps over", startIndex = start)
        val block = viewModel.substring(start, end)
        assertTrue(block.contains("catch (cancelled: CancellationException)"))
        assertTrue(block.contains("throw cancelled"))
    }

    @Test
    fun stressRefreshesFromLowFrequencyRevisionsAndActiveUnion() {
        val stress = source("com/noop/ui/StressScreen.kt")
        assertTrue(stress.contains("vm.metricDataVersion.collectAsStateWithLifecycle()"))
        assertTrue(stress.contains("vm.lastHistorySyncAt.collectAsStateWithLifecycle()"))
        assertTrue(stress.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(stress.contains("loadDaytimeStress(vm, analysisDeviceId)"))
        assertTrue(stress.contains("hrSamplesUnion(deviceId"))
        assertTrue(stress.contains("rrIntervalsUnion(deviceId"))
        assertTrue(stress.contains("catch (cancelled: CancellationException)"))
        assertTrue(stress.contains("throw cancelled"))
    }

    @Test
    fun todayHeartRateWaitsForStableHistoryWritesAndPublishesAtomically() {
        val today = source("com/noop/ui/TodayScreen.kt")
        val start = today.indexOf("private fun HeartRateTrendCard(")
        val end = today.indexOf("val selectedLabel =", startIndex = start)
        val block = today.substring(start, end)

        assertTrue(block.contains("viewModel.lastHistorySyncAt.collectAsStateWithLifecycle()"))
        assertTrue(block.contains("viewModel.historyBackfillActive.collectAsStateWithLifecycle()"))
        assertTrue(block.contains("rememberHistoryQueryGate(rawBackfilling)"))
        assertTrue(block.contains("if (deferHistoricalQueries) return@LaunchedEffect"))
        assertTrue(block.contains("coroutineScope"))
        assertTrue(block.contains("Triple("))
        assertTrue(block.contains("viewModel.activeStrapId != requestDeviceId"))
        assertTrue(block.contains("\"today.hr_trend_load\""))
        assertFalse(block.contains("syncChunksThisSession"))
        assertFalse(block.contains("runCatching"))
    }

    @Test
    fun todayRootDoesNotObserveExactHistoryProgress() {
        val today = source("com/noop/ui/TodayScreen.kt")
        val rootStart = today.indexOf("fun TodayScreen(")
        val rootEnd = today.indexOf("// MARK: - Evidence-gated Daily Action", startIndex = rootStart)
        val root = today.substring(rootStart, rootEnd)

        assertTrue(root.contains("viewModel.dashboardLive.collectAsStateWithLifecycle()"))
        assertTrue(root.contains("viewModel.historyBackfillActive.collectAsStateWithLifecycle()"))
        assertTrue(root.contains("TodayHeaderSyncStatus(viewModel)"))
        assertTrue(root.contains("TodaySyncingHistoryStatus("))
        assertTrue(root.contains("TodaySourcesSectionLive("))
        assertFalse(root.contains("viewModel.live.collectAsStateWithLifecycle()"))
        assertFalse(root.contains("viewModel.historySyncStatus.collectAsStateWithLifecycle()"))
        assertFalse(root.contains("syncRowsThisSession"))
        assertFalse(root.contains("syncChunksThisSession"))
    }

    @Test
    fun decorativeStatusClocksPauseWhileAListIsMoving() {
        val components = source("com/noop/ui/Components.kt")
        val today = source("com/noop/ui/TodayScreen.kt")

        assertTrue(components.contains("pulsing && !renderStill && !interactionInProgress"))
        assertTrue(today.contains("syncing && !rememberPoseStill() && !interactionInProgress"))
        assertTrue(today.contains("LaunchedEffect(status, posed, interactionInProgress)"))
        assertTrue(today.contains("if (posed || interactionInProgress) return@LaunchedEffect"))
    }

    @Test
    fun intelligenceRootKeepsExactSyncProgressInItsEmptyStateLeaf() {
        val intelligence = source("com/noop/ui/IntelligenceScreen.kt")
        val rootStart = intelligence.indexOf("fun IntelligenceScreen(")
        val rootEnd = intelligence.indexOf(
            "private fun IntelligenceSyncingHistoryStatus(",
            startIndex = rootStart,
        )
        val root = intelligence.substring(rootStart, rootEnd)

        assertTrue(root.contains("IntelligenceSyncingHistoryStatus(vm)"))
        assertFalse(root.contains("vm.live.collectAsStateWithLifecycle()"))
        assertFalse(root.contains("vm.historySyncStatus.collectAsStateWithLifecycle()"))
        assertFalse(root.contains("syncRowsThisSession"))
        assertFalse(root.contains("syncChunksThisSession"))
    }

    @Test
    fun boundedResultBucketsNeverExposeExactLargeCounts() {
        assertEquals("empty", sleepHistoryResultBucket(0))
        assertEquals("up_to_30", sleepHistoryResultBucket(30))
        assertEquals("31_to_365", sleepHistoryResultBucket(31))
        assertEquals("over_365", sleepHistoryResultBucket(20_000))
        assertEquals("empty", workoutRecoveryResultBucket(0))
        assertEquals("up_to_10", workoutRecoveryResultBucket(10))
        assertEquals("11_to_30", workoutRecoveryResultBucket(11))
        assertEquals("over_30", workoutRecoveryResultBucket(2_000))
    }

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
