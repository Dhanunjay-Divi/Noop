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
}
