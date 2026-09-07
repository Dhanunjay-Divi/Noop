package com.noop.ui

import java.io.File
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
