package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionNotificationDetailTest {
    @Test
    fun connectedDetailIncludesEveryAvailableMetric() {
        assertEquals(
            "Streaming in the background  ·  Recovery 78%  ·  Effort 42  ·  Strap 65%",
            connectionNotificationDetail(
                connected = true,
                recoveryPct = 77.6,
                effort = 41.5,
                batteryPct = 64.7,
            ),
        )
    }

    @Test
    fun unavailableMetricsAreOmittedWithoutEmptySeparators() {
        assertEquals(
            "Keeping the link open",
            connectionNotificationDetail(
                connected = false,
                recoveryPct = null,
                effort = null,
                batteryPct = null,
            ),
        )
    }
}
