package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StrengthSessionSignalsTest {
    @Test fun heartRateIsShownOnlyForAFreshMeasuredPacket() {
        assertEquals(
            128,
            strengthFreshHeartRate(
                bpm = 128,
                receivedAtMillis = 90_000L,
                nowMillis = 100_000L,
            ),
        )
        assertNull(
            strengthFreshHeartRate(
                bpm = 128,
                receivedAtMillis = 80_000L,
                nowMillis = 100_000L,
            ),
        )
        assertNull(
            strengthFreshHeartRate(
                bpm = 128,
                receivedAtMillis = null,
                nowMillis = 100_000L,
            ),
        )
    }
}
