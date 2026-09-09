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
    fun realtimeHrEffectsReleaseTheLeaseOwnedByTheDisposedEffect() {
        val health = source("com/noop/ui/HealthScreen.kt")
        val live = source("com/noop/ui/LiveScreen.kt")
        val hrv = source("com/noop/ui/HrvSnapshotScreen.kt")

        assertRealtimeHrLeaseEffect(
            source = health,
            ownershipExpression = "liveTrackingOptedIn",
            receiver = "vm",
        )
        assertRealtimeHrLeaseEffect(
            source = live,
            ownershipExpression = "liveTrackingOptedIn",
            receiver = "viewModel",
        )
        assertRealtimeHrLeaseEffect(
            source = hrv,
            ownershipExpression = "phase == HrvPhase.Capturing",
            receiver = "viewModel",
        )

        val viewModel = source("com/noop/ui/AppViewModel.kt")
        assertTrue(viewModel.contains("\"realtime_hr.lease\""))
        assertTrue(viewModel.contains("\"action\" to action"))
        assertTrue(viewModel.contains("\"transition\" to transition.name.lowercase()"))
        assertTrue(viewModel.contains("\"lease_count_bucket\""))
        assertTrue(viewModel.contains("\"foreground\" to realtimeLeasePolicy.isForeground.toString()"))
        assertTrue(viewModel.contains("\"transport_armed\" to realtimeLeasePolicy.transportArmed.toString()"))
        assertFalse(viewModel.contains("\"lease_count\" to realtimeLeasePolicy.leaseCount.toString()"))
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
        val start = today.indexOf("val restCompositeKey =")
        val end = today.indexOf("// Calibrated SpO2", start)
        assertTrue(start >= 0 && end > start)

        val restBlock = today.substring(start, end)
        assertEquals(
            1,
            Regex("""resolvedSeries\(\s*"sleep_performance"""")
                .findAll(restBlock)
                .count(),
        )
        assertTrue(restBlock.contains("restDataVersion = restDataVersion"))
        assertTrue(
            restBlock.contains(
                "LaunchedEffect(days, activeStrapId, restDataVersion, deferHistoricalQueries)",
            ),
        )
        assertTrue(restBlock.contains("if (deferHistoricalQueries) return@LaunchedEffect"))
        assertTrue(restBlock.contains("viewModel.todayRestCompositeLoadedKey"))
        assertTrue(restBlock.contains("loadTodayRestWithRetry"))
        assertTrue(restBlock.contains("catch (cancelled: CancellationException)"))
        assertTrue(restBlock.contains("AppDiagnosticsRecorder.beginOperation"))
        assertTrue(restBlock.contains("AppDiagnosticsRecorder.endOperation"))
        assertTrue(restBlock.contains("\"result_bucket\""))
        assertFalse(restBlock.contains("getOrDefault(emptyMap())"))
        assertTrue(restBlock.contains("\"today.rest_composite_load\""))
        assertTrue(restBlock.contains("remember(restCompositeByDay, selectedDayKey, selectedDayOffset)"))
        assertTrue(restBlock.contains("remember(restCompositeByDay, selectedDay, keyMetricsWindowDays)"))

        assertTrue(today.contains("viewModel.selectedDeviceId.collectAsStateWithLifecycle()"))
        assertTrue(today.contains("viewModel.todayCardsLoadedDeviceId == activeStrapId"))
        assertTrue(today.contains("viewModel.todayFooterLoadedDeviceId == activeStrapId"))
        assertTrue(today.contains("rememberHistoryQueryGate(historyBackfilling)"))
        assertTrue(today.contains("loadTodayBestEffort"))
        assertTrue(today.contains("currentCoroutineContext().ensureActive()"))

        val components = source("com/noop/ui/Components.kt")
        assertTrue(components.contains("HISTORY_QUERY_QUIET_MS = 2_000L"))
        assertTrue(components.contains("rememberHistoryQueryGate"))
        assertTrue(components.contains("delay(HISTORY_QUERY_QUIET_MS)"))
    }

    @Test
    fun deletingDeviceDataInvalidatesTheCachedRestRevision() {
        val viewModel = source("com/noop/ui/AppViewModel.kt")
        val start = viewModel.indexOf("suspend fun deletePairedDeviceData")
        val end = viewModel.indexOf("/**", start + 1)
        assertTrue(start >= 0 && end > start)

        val deleteBlock = viewModel.substring(start, end)
        assertTrue(deleteBlock.contains("noteAllMetricsChanged()"))
        assertFalse(deleteBlock.contains("noteAgeMetricsChanged()"))

        val notifierStart = viewModel.indexOf("private fun noteAllMetricsChanged()")
        val notifierEnd = viewModel.indexOf("\n    }", notifierStart) + "\n    }".length
        assertTrue(notifierStart >= 0 && notifierEnd > notifierStart)
        assertTrue(
            viewModel.substring(notifierStart, notifierEnd)
                .contains("repository.noteMetricsChanged()"),
        )
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

    private fun assertRealtimeHrLeaseEffect(
        source: String,
        ownershipExpression: String,
        receiver: String,
    ) {
        assertTrue(
            source.contains(
                "val ownsRealtimeHrLease = $ownershipExpression",
            ),
        )
        assertTrue(
            source.contains(
                "if (ownsRealtimeHrLease) $receiver.requestRealtimeHr()",
            ),
        )
        assertTrue(
            source.contains(
                "if (ownsRealtimeHrLease) $receiver.releaseRealtimeHr()",
            ),
        )
        assertFalse(
            source.contains(
                "onDispose { if ($ownershipExpression)",
            ),
        )
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
