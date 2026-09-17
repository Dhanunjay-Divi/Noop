package com.noop.ui

import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppDiagnosticReportRequestBridgeTest {
    @Test
    fun requestBeforeCollectorIsDeliveredOnceWithoutReplay() = runTest {
        AppDiagnosticReportRequestBridge.request()

        withTimeout(1_000L) {
            AppDiagnosticReportRequestBridge.requests.first()
        }

        assertNull(
            withTimeoutOrNull(1L) {
                AppDiagnosticReportRequestBridge.requests.first()
            },
        )
    }

    @Test
    fun mainActivityDeliversRequestsOnlyWhileResumed() {
        val source = source("com/noop/ui/MainActivity.kt")
        val collection = source.substring(
            source.indexOf("lifecycleScope.launch {"),
            source.indexOf("\n        requestDemoReportIfNeeded()"),
        )

        assertTrue(
            collection.contains(
                "lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED)",
            ),
        )
        assertTrue(collection.contains("AppDiagnosticReportRequestBridge.requests.collect"))
        assertTrue(collection.contains("appReport.requestManually()"))
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
