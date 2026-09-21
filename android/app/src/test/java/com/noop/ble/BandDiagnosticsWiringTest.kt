package com.noop.ble

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class BandDiagnosticsWiringTest {
    @Test fun scanReadinessAndRetryEventsRemainWiredToTheBleClient() {
        val source = locateSource().readText()

        assertTrue(source.contains("BandDiagnostics.recordScan("))
        assertTrue(source.contains("BandDiagnostics.recordReadiness("))
        assertTrue(source.contains("BandDiagnostics.recordRetry("))
        assertTrue(source.contains("BandDiagnostics.ScanState.NO_RESULT"))
        assertTrue(source.contains("BandDiagnostics.ReadinessStage.SERVICES"))
        assertTrue(source.contains("BandDiagnostics.ReadinessStage.BOND"))
        assertTrue(source.contains("BandDiagnostics.ReadinessStage.NOTIFICATIONS"))
        assertTrue(source.contains("BandDiagnostics.RetryState.SCHEDULED"))
        assertTrue(source.contains("BandDiagnostics.RetryState.FIRED"))
        assertTrue(source.contains("BandDiagnostics.RetryState.CANCELLED"))
        assertTrue(source.contains("BandDiagnostics.RetryState.PAUSED"))
        assertTrue(source.contains("presentScanDiagnosticDeduper.shouldRecord(observedFamily)"))
        assertTrue(!source.contains("updated.lastOrNull()?.model"))
        assertTrue(source.contains("BandDiagnostics.serviceFailureReason(supportedCustomServiceCount)"))
        assertTrue(!source.contains("\"fallback_timeout\""))
        assertTrue(!source.contains("\"start_failed\""))
        assertTrue(!source.contains("\"scanner\""))

        val customServiceFailure = source
            .substringAfter("val serviceFailure = BandDiagnostics.serviceFailureReason")
            .substringBefore("// The reassembler frames per family")
        assertTrue(customServiceFailure.contains("ReadinessState.FAILED"))
        assertTrue(customServiceFailure.contains("reason = serviceFailure"))
    }

    private fun locateSource(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop/ble/WhoopBleClient.kt"),
            File(root, "app/src/main/java/com/noop/ble/WhoopBleClient.kt"),
            File(root, "android/app/src/main/java/com/noop/ble/WhoopBleClient.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate WhoopBleClient.kt from $root")
    }
}
