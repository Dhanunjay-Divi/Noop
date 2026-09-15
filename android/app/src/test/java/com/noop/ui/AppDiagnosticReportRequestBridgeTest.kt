package com.noop.ui

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertNull
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
}
