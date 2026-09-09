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

class HealthScreenPerformanceTest {
    @Test
    fun connectionProjectionSuppressesSensorOnlyUpdates() = runTest {
        val observed = flowOf(
            LiveState(connected = false),
            LiveState(connected = true, heartRate = 70, heartRateSampleSequence = 1),
            LiveState(connected = true, heartRate = 71, heartRateSampleSequence = 2),
            LiveState(connected = true, rr = listOf(810), heartRateSampleSequence = 3),
            LiveState(connected = false),
        ).healthConnectionChanges().toList()

        assertEquals(listOf(false, true, false), observed)
    }

    @Test
    fun healthRootCollectsOnlyTheConnectionProjection() {
        val source = source("com/noop/ui/HealthScreen.kt")
        val rootStart = source.indexOf("fun HealthScreen(")
        val rootEnd = source.indexOf("// MARK: - Body composition", startIndex = rootStart)
        assertTrue(rootStart >= 0 && rootEnd > rootStart)

        val root = source.substring(rootStart, rootEnd)
        assertTrue(root.contains("vm.live.healthConnectionChanges()"))
        assertTrue(root.contains("collectAsStateWithLifecycle(initialValue = false)"))
        assertTrue(root.contains("if (days.isEmpty() && !connected)"))
        assertFalse(root.contains("vm.live.collectAsStateWithLifecycle()"))
        assertFalse(root.contains("vm.live.value"))

        // The full stream remains isolated to leaves that actually render connection/sensor details.
        assertTrue(source.substring(rootEnd).contains("val live by vm.live.collectAsStateWithLifecycle()"))
    }

    @Test
    fun healthHistoryQueriesUseTheObservedActiveDevice() {
        val source = source("com/noop/ui/HealthScreen.kt")
        val rootStart = source.indexOf("fun HealthScreen(")
        val rootEnd = source.indexOf("// MARK: - Body composition", startIndex = rootStart)
        val root = source.substring(rootStart, rootEnd)
        val detailStart = source.indexOf("fun VitalDetailScreen(")
        val detailEnd = source.indexOf(
            "private suspend fun buildSeriesVitalDetail(",
            startIndex = detailStart,
        )
        val detail = source.substring(detailStart, detailEnd)
        val seriesBuilder = source.substring(detailEnd)

        assertTrue(root.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(root.contains("activeDeviceId = activeDeviceId"))
        assertTrue(detail.contains("vm.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(detail.contains("LaunchedEffect(key, refreshTick, profileVersion, ageMetricDataVersion, activeDeviceId)"))
        assertTrue(seriesBuilder.contains("strapDeviceId = activeDeviceId"))
        assertFalse(seriesBuilder.contains("vm.activeStrapId"))
    }

    @Test
    fun liveHeartRateHeroUsesAStaticAtmosphere() {
        val source = source("com/noop/ui/HealthScreen.kt")
        assertTrue(source.contains(".timeOfDayBackground(animated = false)"))
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
