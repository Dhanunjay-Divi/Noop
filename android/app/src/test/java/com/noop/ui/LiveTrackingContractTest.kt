package com.noop.ui

import com.noop.ble.LiveState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveTrackingContractTest {
    @Test
    fun copyDisclosesBatteryForegroundAndIndependentBackgroundFeatures() {
        assertTrue(LIVE_TRACKING_BATTERY_COPY.contains("uses more Noop Band and phone battery"))
        assertTrue(LIVE_TRACKING_BATTERY_COPY.contains("only while this Live screen and NOOP are in the foreground"))
        assertTrue(LIVE_TRACKING_SEPARATION_COPY.contains("Connection and history sync continue"))
        assertTrue(LIVE_TRACKING_SEPARATION_COPY.contains("Continuous HRV capture is a separate option"))
    }

    @Test
    fun genericStreamingSourceCanStartAndStopLiveTrackingWithoutAWhoopBond() {
        assertTrue(hasLiveHrConnection(LiveState(connected = true, streamingLiveHR = true)))
        assertTrue(hasLiveHrConnection(LiveState(connected = true, bonded = true)))
        assertFalse(hasLiveHrConnection(LiveState(connected = true)))
        assertFalse(hasLiveHrConnection(LiveState(connected = false, bonded = true, streamingLiveHR = true)))
    }
}
