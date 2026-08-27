package com.noop.ble

import com.noop.oura.OuraCommands
import com.noop.oura.OuraDriverPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraCommandWriteQueueTest {
    @Test
    fun commandsRemainSerialUntilPacingCompletes() {
        val queue = OuraCommandWriteQueue()
        val first = OuraCommands.getBattery()
        val second = OuraCommands.getProductHardware()
        queue.enqueue(listOf(first, second))

        assertEquals(first, queue.beginNext())
        assertNull(queue.beginNext())
        assertEquals(first, queue.completeActive())
        assertEquals(second, queue.beginNext())
        assertEquals(second, queue.completeActive())
        assertTrue(queue.isDrained)
    }

    @Test
    fun teardownPreservesActiveAndReplacesPendingBackgroundWork() {
        val queue = OuraCommandWriteQueue()
        val active = OuraCommands.getBattery()
        val staleBackground = OuraCommands.getProductHardware()
        val disable = OuraCommands.liveHRDisable()
        val unsubscribe = OuraCommands.liveHRUnsubscribe()
        queue.enqueue(listOf(active, staleBackground))
        assertEquals(active, queue.beginNext())

        queue.replacePendingForTeardown(listOf(disable, unsubscribe))
        assertEquals(listOf(disable.label, unsubscribe.label), queue.pendingLabels)
        assertEquals(active, queue.completeActive())
        assertEquals(disable, queue.beginNext())
        assertEquals(disable, queue.completeActive())
        assertEquals(unsubscribe, queue.beginNext())
        assertEquals(unsubscribe, queue.completeActive())
        assertTrue(queue.isDrained)
    }

    @Test
    fun historyNeverPublishesIntoLiveState() {
        assertTrue(OuraLivePublication.permits(historyEnvelope = false))
        assertFalse(OuraLivePublication.permits(historyEnvelope = true))
        assertTrue(
            OuraLivePublication.requiresLiveHrShutdown(
                reachedStreaming = false,
                driverPhase = OuraDriverPhase.EnablingLiveHR,
            ),
        )
        assertFalse(
            OuraLivePublication.requiresLiveHrShutdown(
                reachedStreaming = false,
                driverPhase = OuraDriverPhase.Authenticating,
            ),
        )
        assertTrue(
            OuraLivePublication.permitsCurrentState(
                historyEnvelope = true,
                eventUnixSeconds = 1_010,
                now = 1_000,
            ),
        )
        assertFalse(
            OuraLivePublication.permitsCurrentState(
                historyEnvelope = true,
                eventUnixSeconds = 800,
                now = 1_000,
            ),
        )
        assertNull(
            OuraPendingAnchorPolicy.fallbackTimestamp(
                historyEnvelope = true,
                liveArrivalTimestamp = 123,
            ),
        )
        assertEquals(
            123,
            OuraPendingAnchorPolicy.fallbackTimestamp(
                historyEnvelope = false,
                liveArrivalTimestamp = 123,
            ),
        )
    }
}
