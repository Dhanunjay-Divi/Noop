package com.noop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AppDiagnosticsRecorderTest {
    @Test fun boundedTailKeepsNewestCompleteJsonLines() {
        val source = buildString {
            repeat(200) { index ->
                append("{\"schema\":1,\"event\":\"row_$index\"}\n")
            }
        }.toByteArray()

        val bounded = AppDiagnosticsRecorder.boundedJSONLTail(source, 512)
        val text = String(bounded)

        assertTrue(bounded.size <= 512)
        assertTrue(text.startsWith("{\"schema\":1,\"event\":\"log.trimmed\""))
        assertTrue(text.contains("\"event\":\"row_199\""))
        assertTrue(!text.contains("\"event\":\"row_0\""))
    }

    @Test fun navigationRouteDropsDynamicArguments() {
        assertEquals(
            "vital_detail",
            AppDiagnosticsRecorder.sanitizedRoute("vital_detail/heart_rate?source=private"),
        )
        assertEquals("unknown", AppDiagnosticsRecorder.sanitizedRoute(null))
    }

    @Test fun sensitiveFieldNamesAreDroppedAtRecorderBoundary() {
        val sanitized = AppDiagnosticsRecorder.sanitizedFields(
            mapOf(
                "route" to "/v1/managed/chunks/{chunk_id}",
                "authorization" to "Bearer private-value",
                "phone_number" to "+15555550123",
                "installation_id" to "noop-private-installation",
                "incident_id" to "11111111-1111-4111-8111-111111111111",
                "request_url" to "https://private.example/signed",
                "server_request_id" to "b".repeat(32),
                "user_note" to "private user text",
            ),
        )

        assertEquals("/v1/managed/chunks/{chunk_id}", sanitized["route"])
        assertEquals("7", sanitized["redacted_fields"])
        assertTrue(!sanitized.values.any { it.contains("private-value") })
        assertTrue(!sanitized.values.any { it.contains("15555550123") })
        assertTrue(!sanitized.values.any { it.contains("noop-private-installation") })
        assertTrue(!sanitized.containsKey("incident_id"))
        assertTrue(!sanitized.values.any { it.contains("private.example") })
        assertTrue(!sanitized.values.any { it.contains("b".repeat(32)) })
        assertTrue(!sanitized.values.any { it.contains("private user text") })
    }

    @Test fun freshnessBucketsDoNotRetainHealthTimestamps() {
        assertEquals("missing", AppDiagnosticsRecorder.freshnessBucket(null))
        assertEquals("future_clock", AppDiagnosticsRecorder.freshnessBucket(-120))
        assertEquals("under_2m", AppDiagnosticsRecorder.freshnessBucket(30))
        assertEquals("2m_to_15m", AppDiagnosticsRecorder.freshnessBucket(300))
        assertEquals("15m_to_2h", AppDiagnosticsRecorder.freshnessBucket(1_800))
        assertEquals("over_2h", AppDiagnosticsRecorder.freshnessBucket(8_000))
    }
}
