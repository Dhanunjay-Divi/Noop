package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimeoutSyncErrorTest {
    private val interrupted = "Sync interrupted - the strap went quiet. It will retry on the next sync."

    @Test
    fun productiveTimeoutRaisesNoBanner() {
        assertNull(WhoopBleClient.timeoutSyncError(null, bankedThisOffload = true))
    }

    @Test
    fun stalledTimeoutStillWarns() {
        assertEquals(
            interrupted,
            WhoopBleClient.timeoutSyncError(null, bankedThisOffload = false),
        )
    }

    @Test
    fun bankedPredicateUsesProgressCounters() {
        assertFalse(WhoopBleClient.offloadBankedAnything(chunks = 0, rows = 0, deepPackets = 0))
        assertTrue(WhoopBleClient.offloadBankedAnything(chunks = 0, rows = 17_205, deepPackets = 0))
        assertTrue(WhoopBleClient.offloadBankedAnything(chunks = 3, rows = 0, deepPackets = 0))
        assertTrue(WhoopBleClient.offloadBankedAnything(chunks = 0, rows = 0, deepPackets = 5))
    }

    @Test
    fun futureClockWarningOutranksTimeoutClassification() {
        assertEquals(
            "clock is ahead",
            WhoopBleClient.timeoutSyncError("clock is ahead", bankedThisOffload = true),
        )
    }
}
