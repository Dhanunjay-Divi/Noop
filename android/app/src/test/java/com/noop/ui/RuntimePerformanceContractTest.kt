package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Source-level guards for launch and lifecycle costs that pure JVM tests cannot instantiate. */
class RuntimePerformanceContractTest {
    @Test
    fun launchDoesNotOpenWorkManagerOrRoomOnTheMainThreadBeforeCompose() {
        val main = source("com/noop/ui/MainActivity.kt")
        val application = source("com/noop/NoopApplication.kt")
        val manifest = projectFile("src/main/AndroidManifest.xml")

        val setContent = main.indexOf("setContent {")
        assertTrue("setContent must exist", setContent >= 0)

        val preCompose = main.substring(0, setContent)
        assertFalse(preCompose.contains("DebugExportScheduler.reschedule"))
        assertFalse(preCompose.contains("BackupSync.reschedule"))
        assertFalse(preCompose.contains("RemoteSyncScheduler.reschedule"))
        assertFalse(preCompose.contains("HealthConnectSyncScheduler.reconcile"))
        assertFalse(preCompose.contains("HydrationReminderScheduler.reconcile"))
        assertTrue(main.contains("lifecycleScope.launch(Dispatchers.IO)"))

        assertFalse("Application startup must not block on a suspend Room query", application.contains("runBlocking"))
        assertTrue(application.contains("val activeDeviceIdFlow: StateFlow<String>"))
        assertTrue(application.contains("startupScope.launch"))
        assertTrue(application.contains("synchronized(activeDeviceLock)"))

        val onCreate = application.substring(
            application.indexOf("override fun onCreate()"),
            application.indexOf("fun startOperationalRuntime()"),
        )
        assertTrue(onCreate.contains("if (hasAcceptedCurrentTerms())"))
        assertFalse(onCreate.contains("resolveActiveDeviceId()"))
        assertFalse(onCreate.contains("deferProcessMaintenance()"))
        assertFalse(onCreate.contains("SafetyContactSetupReminderScheduler.reconcile(this)"))
        assertFalse(onCreate.contains("FriendsSyncScheduler.reconcile(this)"))

        val operational = application.substring(
            application.indexOf("fun startOperationalRuntime()"),
            application.indexOf("override fun onTrimMemory"),
        )
        assertTrue(operational.contains("resolveActiveDeviceId()"))
        assertTrue(operational.contains("deferProcessMaintenance()"))

        assertTrue(application.contains("androidx.work.Configuration.Provider"))
        assertTrue(application.contains("override val workManagerConfiguration"))
        assertTrue(manifest.contains("androidx.work.WorkManagerInitializer"))
        assertTrue(
            Regex(
                """android:name="androidx\.work\.WorkManagerInitializer"\s+tools:node="remove"""",
            ).containsMatchIn(manifest),
        )
    }

    @Test
    fun retainedDataScreensStopCollectingWhenTheirLifecycleStops() {
        val workouts = source("com/noop/ui/WorkoutsScreen.kt")
        val insights = source("com/noop/ui/InsightsHubScreen.kt")

        assertFalse(workouts.contains(".collectAsState()"))
        assertFalse(insights.contains(".collectAsState()"))
        assertTrue(workouts.contains("vm.workouts.collectAsStateWithLifecycle()"))
        assertTrue(insights.contains("vm.recentDays.collectAsStateWithLifecycle()"))
        assertTrue(insights.contains("hub.state.collectAsStateWithLifecycle()"))
    }

    @Test
    fun sharedScreenScaffoldsPauseLiquidClocksDuringDragAndFling() {
        val components = source("com/noop/ui/Components.kt")
        val primitives = source("com/noop/ui/LiquidPrimitives.kt")

        assertTrue(components.contains("val scrollState = rememberScrollState()"))
        assertTrue(
            components.contains(
                "LocalLiquidInteractionInProgress provides scrollState.isScrollInProgress",
            ),
        )
        assertTrue(
            components.contains(
                "LocalLiquidInteractionInProgress provides listState.isScrollInProgress",
            ),
        )

        val vesselStart = primitives.indexOf("fun LiquidVessel(")
        val vesselPauseGate = primitives.indexOf(
            "if (shouldAnimateLiquid(animated, renderStill, interactionInProgress))",
            vesselStart,
        )
        val vesselSim = primitives.indexOf(
            "val sim = remember { LiquidSim(target = value ?: 0.0) }",
            vesselStart,
        )
        assertTrue(vesselStart >= 0 && vesselSim in vesselStart until vesselPauseGate)

        val tubeStart = primitives.indexOf("fun LiquidTube(")
        val tubePauseGate = primitives.indexOf(
            "if (shouldAnimateLiquid(animated, renderStill, interactionInProgress))",
            tubeStart,
        )
        val tubeSim = primitives.indexOf(
            "val sim = remember { LiquidSim(target = 0.0) }",
            tubeStart,
        )
        assertTrue(tubeStart >= 0 && tubeSim in tubeStart until tubePauseGate)
    }

    @Test
    fun todayUsesOneCachedRestHistoryForTheNumberAndSparkline() {
        val today = source("com/noop/ui/TodayScreen.kt")
        val start = today.indexOf("val restCompositeSig =")
        val end = today.indexOf("// Calibrated SpO2", start)
        assertTrue(start >= 0 && end > start)

        val restBlock = today.substring(start, end)
        assertEquals(1, Regex("""resolvedSeries\("sleep_performance"""").findAll(restBlock).count())
        assertTrue(restBlock.contains("viewModel.todayRestCompositeLoadedSig"))
        assertTrue(restBlock.contains("remember(restCompositeByDay, selectedDayKey, selectedDayOffset)"))
        assertTrue(restBlock.contains("remember(restCompositeByDay, selectedDay, keyMetricsWindowDays)"))
    }

    private fun source(relative: String): String {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val file = listOf(
            File(userDir, "src/main/java/$relative"),
            File(userDir, "app/src/main/java/$relative"),
            File(userDir, "android/app/src/main/java/$relative"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $relative from $userDir")
        return file.readText()
    }

    private fun projectFile(relative: String): String {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val file = listOf(
            File(userDir, relative),
            File(userDir, "app/$relative"),
            File(userDir, "android/app/$relative"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $relative from $userDir")
        return file.readText()
    }
}
