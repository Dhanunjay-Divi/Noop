package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppDiagnosticReportEntryPointTest {
    @Test
    fun reportEntryPointIsOwnedByCurrentActivityWithoutGlobalReplayState() {
        val activity = source("com/noop/ui/MainActivity.kt")
        val appRoot = source("com/noop/ui/AppRoot.kt")
        val testCentre = source("com/noop/ui/TestCentreScreen.kt")
        val report = source("com/noop/ui/AppDiagnosticReport.kt")

        assertTrue(
            activity.contains(
                "onRequestAppReport = ::requestAppDiagnosticReport",
            ),
        )
        assertTrue(
            activity.contains(
                "internal fun requestAppDiagnosticReport()",
            ),
        )
        assertTrue(
            appRoot.contains(
                "onRequestAppReport = onRequestAppReport",
            ),
        )
        assertTrue(testCentre.contains("onClick = onRequestAppReport"))
        assertFalse(report.contains("AppDiagnosticReportRequestBridge"))
        assertFalse(report.contains("Channel.CONFLATED"))
        assertFalse(report.contains("MutableSharedFlow"))
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
