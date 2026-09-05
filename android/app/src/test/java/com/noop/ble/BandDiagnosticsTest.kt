package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class BandDiagnosticsTest {
    @Test fun transportReasonsStayStableAndCategorical() {
        assertEquals(
            "pairing_reset",
            BandDiagnostics.transportReason(
                intentional = false,
                timedOut = false,
                pairingReset = true,
                hasTransportError = true,
                wasConnected = false,
            ),
        )
        assertEquals(
            "timeout",
            BandDiagnostics.transportReason(
                intentional = false,
                timedOut = true,
                pairingReset = false,
                hasTransportError = true,
                wasConnected = true,
            ),
        )
        assertEquals(
            "intentional",
            BandDiagnostics.transportReason(
                intentional = true,
                timedOut = false,
                pairingReset = false,
                hasTransportError = false,
                wasConnected = true,
            ),
        )
        assertEquals(
            "transport_error",
            BandDiagnostics.transportReason(
                intentional = false,
                timedOut = false,
                pairingReset = false,
                hasTransportError = true,
                wasConnected = true,
            ),
        )
        assertEquals(
            "remote",
            BandDiagnostics.transportReason(
                intentional = false,
                timedOut = false,
                pairingReset = false,
                hasTransportError = false,
                wasConnected = true,
            ),
        )
        assertEquals(
            "unavailable",
            BandDiagnostics.transportReason(
                intentional = false,
                timedOut = false,
                pairingReset = false,
                hasTransportError = false,
                wasConnected = false,
            ),
        )
    }

    @Test fun reconnectAndHistoryOutcomesUseFixedVocabulary() {
        assertEquals(
            "retry",
            BandDiagnostics.reconnectPlan(
                intentional = false,
                paused = false,
                pairingReset = false,
            ),
        )
        assertEquals(
            "user_action",
            BandDiagnostics.reconnectPlan(
                intentional = false,
                paused = true,
                pairingReset = false,
            ),
        )
        assertEquals("completed", BandDiagnostics.historyOutcome("HISTORY_COMPLETE"))
        assertEquals("idle_timeout", BandDiagnostics.historyOutcome("timeout"))
        assertEquals("progress_stalled", BandDiagnostics.historyOutcome("durableProgressTimeout"))
        assertEquals("interrupted", BandDiagnostics.historyOutcome("disconnect"))
        assertEquals("other", BandDiagnostics.historyOutcome("dynamic error text"))
    }
}
