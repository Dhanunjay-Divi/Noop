package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReviewSampleModeContractTest {
    @Test
    fun reviewSampleHasNoOperationalDependencies() {
        val source = source("com/noop/ui/ReviewSampleMode.kt")

        listOf(
            "noop.review.entry.explore",
            "noop.review.disclosure.enter",
            "noop.review.root",
            "noop.review.exit",
        ).forEach { assertTrue("Missing review contract marker $it", source.contains(it)) }

        listOf(
            "AppViewModel",
            "WhoopRepository",
            "WhoopDatabase",
            "WhoopBleClient",
            "ManagedCloudService",
            "SafetyPagingService",
            "NotificationManager",
            "WorkManager",
            "HealthConnectClient",
            "SharedPreferences",
            "LocalContext",
            "LaunchedEffect",
            "rememberSaveable",
        ).forEach { token ->
            assertFalse(
                "Review Sample must remain a pure in-memory Compose tree; found $token",
                source.contains(token),
            )
        }
    }

    @Test
    fun applicationStartupDefersOperationalRuntimeUntilCurrentTerms() {
        val application = source("com/noop/NoopApplication.kt")
        val onCreate = application.substring(
            application.indexOf("override fun onCreate()"),
            application.indexOf("fun startOperationalRuntime()"),
        )
        val operational = application.substring(
            application.indexOf("fun startOperationalRuntime()"),
            application.indexOf("override fun onTrimMemory"),
        )

        assertTrue(onCreate.contains("if (hasAcceptedCurrentTerms())"))
        assertTrue(onCreate.contains("startOperationalRuntime()"))
        assertFalse(onCreate.contains("resolveActiveDeviceId()"))
        assertFalse(onCreate.contains("deferProcessMaintenance()"))
        assertTrue(operational.contains("resolveActiveDeviceId()"))
        assertTrue(operational.contains("deferProcessMaintenance()"))
        assertTrue(application.contains("AtomicBoolean(false)"))
    }

    @Test
    fun reviewGatePrecedesTermsAndViewModelConstruction() {
        val main = source("com/noop/ui/MainActivity.kt")
        val root = main.substring(main.indexOf("fun NoopRoot("))

        val reviewGate = root.indexOf("if (reviewSampleOffered")
        val termsGate = root.indexOf("TermsGateScreen(")
        val model = root.indexOf("val appViewModel: AppViewModel = viewModel()")
        assertTrue(reviewGate >= 0)
        assertTrue(termsGate > reviewGate)
        assertTrue(model > termsGate)
        assertTrue(root.contains("application.startOperationalRuntime()"))
        assertTrue(root.contains("context.mainActivityOrNull()?.resumeAfterOperationalRuntimeStarted()"))
        assertFalse(root.contains("LaunchedEffect(operationalRuntimeReady)"))
        assertFalse(main.contains("deferLaunchMaintenance()"))
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
}
