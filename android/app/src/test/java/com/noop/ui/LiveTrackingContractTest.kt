package com.noop.ui

import org.junit.Assert.assertTrue
import org.junit.Test

class LiveTrackingContractTest {
    @Test
    fun copyDisclosesBatteryForegroundAndIndependentBackgroundFeatures() {
        assertTrue(LIVE_TRACKING_BATTERY_COPY.contains("uses more strap and phone battery"))
        assertTrue(LIVE_TRACKING_BATTERY_COPY.contains("only while this Live screen and NOOP are in the foreground"))
        assertTrue(LIVE_TRACKING_SEPARATION_COPY.contains("Connection and history sync continue"))
        assertTrue(LIVE_TRACKING_SEPARATION_COPY.contains("Continuous HRV capture is a separate option"))
    }
}
