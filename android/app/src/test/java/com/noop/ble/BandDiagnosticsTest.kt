package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertEquals
import org.junit.Test

class BandDiagnosticsTest {
    @Test fun lifecycleRecorderUsesOnlyFixedPrivacySafeCategories() {
        val captured = mutableListOf<Pair<String, Map<String, String>>>()
        val recorder: (String, Map<String, String>) -> Unit = { event, fields ->
            captured += event to fields
        }

        BandDiagnostics.recordScan(
            BandDiagnostics.ScanState.NO_RESULT,
            DeviceFamily.WHOOP4,
            "timeout",
            recorder,
        )
        BandDiagnostics.recordReadiness(
            BandDiagnostics.ReadinessStage.NOTIFICATIONS,
            BandDiagnostics.ReadinessState.READY,
            DeviceFamily.WHOOP5,
            "live_hr",
            recorder = recorder,
        )
        BandDiagnostics.recordRetry(
            BandDiagnostics.RetryState.PAUSED,
            DeviceFamily.WHOOP5,
            "bond_loop",
            recorder,
        )

        assertEquals(
            "band.scan" to mapOf(
                "state" to "no_result",
                "family" to "legacy",
                "reason" to "timeout",
            ),
            captured[0],
        )
        assertEquals(
            "band.readiness" to mapOf(
                "stage" to "notifications",
                "state" to "ready",
                "family" to "modern",
                "channel" to "live_hr",
            ),
            captured[1],
        )
        assertEquals(
            "band.retry" to mapOf(
                "state" to "paused",
                "family" to "modern",
                "reason" to "bond_loop",
            ),
            captured[2],
        )
    }

    @Test fun lifecycleRecorderMapsUnknownReasonAndChannelToOther() {
        val captured = mutableListOf<Pair<String, Map<String, String>>>()
        val recorder: (String, Map<String, String>) -> Unit = { event, fields ->
            captured += event to fields
        }

        BandDiagnostics.recordScan(
            BandDiagnostics.ScanState.UNAVAILABLE,
            DeviceFamily.WHOOP4,
            "private dynamic failure",
            recorder,
        )
        BandDiagnostics.recordReadiness(
            BandDiagnostics.ReadinessStage.NOTIFICATIONS,
            BandDiagnostics.ReadinessState.FAILED,
            DeviceFamily.WHOOP5,
            "fd4b-private",
            "localized platform detail",
            recorder,
        )
        BandDiagnostics.recordRetry(
            BandDiagnostics.RetryState.CANCELLED,
            DeviceFamily.WHOOP5,
            "arbitrary retry detail",
            recorder,
        )

        assertEquals("other", captured[0].second["reason"])
        assertEquals("other", captured[1].second["channel"])
        assertEquals("other", captured[1].second["reason"])
        assertEquals("other", captured[2].second["reason"])
    }

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

    @Test fun candidateDiagnosticsDedupePerFamilyAndResetPerSession() {
        val deduper = BandDiagnostics.CandidateSessionDeduper()
        assertEquals(true, deduper.shouldRecord(DeviceFamily.WHOOP4))
        assertEquals(false, deduper.shouldRecord(DeviceFamily.WHOOP4))
        assertEquals(true, deduper.shouldRecord(DeviceFamily.WHOOP5))
        assertEquals(false, deduper.shouldRecord(DeviceFamily.WHOOP5))

        deduper.reset()
        assertEquals(true, deduper.shouldRecord(DeviceFamily.WHOOP4))
        assertEquals(true, deduper.shouldRecord(DeviceFamily.WHOOP5))
    }

    @Test fun serviceReadinessReasonsStayStableAndCategorical() {
        assertEquals(
            "discovery_error",
            BandDiagnostics.serviceFailureReason(
                supportedCustomServiceCount = 1,
                discoveryFailed = true,
            ),
        )
        assertEquals(
            "unsupported_service",
            BandDiagnostics.serviceFailureReason(supportedCustomServiceCount = 0),
        )
        assertEquals(
            "ambiguous_service",
            BandDiagnostics.serviceFailureReason(supportedCustomServiceCount = 2),
        )
        assertEquals(
            "command_missing",
            BandDiagnostics.serviceFailureReason(
                supportedCustomServiceCount = 1,
                hasRequiredCommandCharacteristic = false,
            ),
        )
        assertEquals(
            null,
            BandDiagnostics.serviceFailureReason(
                supportedCustomServiceCount = 1,
                hasRequiredCommandCharacteristic = true,
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
