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
    fun sleepSyncProjectionSuppressesOrdinarySensorTicks() = runTest {
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
        ).sleepHistorySyncProgressChanges().toList()

        assertEquals(4, observed.size)
        assertEquals(null, observed[0])
        assertEquals(1, observed[1]?.batches)
        assertEquals(2, observed[2]?.batches)
        assertEquals(null, observed[3])
    }

    @Test
    fun sleepHistoryUsesBatchedMotionReadsAndBoundedDiagnostics() {
        val sleep = source("com/noop/ui/SleepScreen.kt")
        val repository = source("com/noop/data/WhoopRepository.kt")
        val dao = source("com/noop/data/WhoopDao.kt")

        val rootStart = sleep.indexOf("fun SleepScreen(")
        val rootEnd = sleep.indexOf("// MARK: - 0b.", startIndex = rootStart)
        val root = sleep.substring(rootStart, rootEnd)
        assertTrue(root.contains("sleepHistorySyncProgressChanges()"))
        assertFalse(root.contains("vm.live.collectAsStateWithLifecycle()"))
        assertTrue(
            Regex("""vm\.repo\.sessionMotions\(\s*activeDeviceId""")
                .containsMatchIn(root),
        )
        assertTrue(root.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(root.contains("\"sleep.history_sessions_load\""))
        assertTrue(root.contains("\"sleep.history_motion_load\""))
        assertTrue(root.contains("\"sleep.history_metrics_load\""))

        val batchStart = repository.indexOf("suspend fun sessionMotions(")
        val batchEnd = repository.indexOf("/** Persist the decoded", startIndex = batchStart)
        val batch = repository.substring(batchStart, batchEnd)
        assertTrue(batch.contains("starts.distinct().chunked(500)"))
        assertTrue(batch.contains("dao.sessionMotionRows"))
        assertFalse(batch.contains("for (start in starts)"))
        assertTrue(dao.contains("suspend fun sessionMotionRows("))
    }

    @Test
    fun workoutRecoveryWaitsForItsLazyItemAndPropagatesCancellation() {
        val workouts = source("com/noop/ui/WorkoutsScreen.kt")
        val viewModel = source("com/noop/ui/AppViewModel.kt")

        assertTrue(workouts.contains("item(key = \"recovery-trend\")"))
        assertTrue(workouts.contains("private fun RecoveryTrendLazySection("))
        assertTrue(workouts.contains("LaunchedEffect(inputKey)"))
        assertFalse(workouts.contains("LaunchedEffect(recoveryInputKey"))
        assertTrue(workouts.contains("\"workouts.recovery_trend_load\""))
        assertTrue(workouts.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(workouts.contains("loadActiveZoneWeek(vm, activeDeviceId)"))
        assertTrue(workouts.contains("if (vm.activeStrapId == activeDeviceId)"))

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
