package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class LiveStateHeartRateSequenceTest {

    @Test
    fun everyAcceptedPacketAdvancesSequenceEvenWhenBpmIsUnchanged() {
        val first = LiveState().withHeartRate(80)
        val second = first.withHeartRate(80)

        assertEquals(80, second.heartRate)
        assertEquals(1L, first.heartRateSampleSequence)
        assertEquals(2L, second.heartRateSampleSequence)
    }

    @Test
    fun readingOrCopyingCachedStateDoesNotInventANewPacket() {
        val accepted = LiveState().withHeartRate(80)
        val presentationOnlyCopy = accepted.copy(connected = true)

        assertEquals(accepted.heartRateSampleSequence, presentationOnlyCopy.heartRateSampleSequence)
    }

    @Test
    fun identicalPhysicalEventsStillAdvanceGestureSequence() {
        val first = LiveState().withPhysicalEvent("DOUBLE_TAP(14)")
        val second = first.withPhysicalEvent("DOUBLE_TAP(14)")

        assertEquals("DOUBLE_TAP(14)", second.lastEvent)
        assertEquals(1L, first.gestureSequence)
        assertEquals(2L, second.gestureSequence)
    }
}
