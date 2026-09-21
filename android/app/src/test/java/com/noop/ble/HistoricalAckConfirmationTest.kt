package com.noop.ble

import com.noop.protocol.CommandNumber
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoricalAckConfirmationTest {
    private fun historyWrite(trim: Long) = WhoopBleClient.PendingWrite(
        frame = byteArrayOf(0x01),
        withResponse = true,
        cmd = CommandNumber.HISTORICAL_DATA_RESULT,
        purpose = WhoopBleClient.WritePurpose.HISTORY_ACK,
        historyAckTrim = trim,
    )

    @Test
    fun `queued acknowledgement does not advance trim before successful callback`() {
        val trim = 42L
        val ledger = HistoricalAckLedger<String?>()
        ledger.stage(trim, "committed")
        val completionGate = HistoricalAckCompletionGate()
        completionGate.enqueued(trim)
        val deliveryGate = GattWriteDeliveryGate<WhoopBleClient.PendingWrite>()
        val write = historyWrite(trim)

        assertTrue(deliveryGate.begin(write, expectsCallback = true))
        assertEquals(GattWriteAction.WAIT_FOR_CALLBACK, deliveryGate.submitted(accepted = true))
        assertNull("enqueue is not acknowledgement", ledger.lastConfirmedTrim)

        val complete = completionGate.observeHistoryComplete()
        assertFalse("HISTORY_COMPLETE must wait for the final callback", complete.finishNow)
        assertEquals(1, complete.pendingAcknowledgements)

        val completedWrite = requireNotNull(deliveryGate.callback())
        val confirmedTrim = requireNotNull(
            completedWrite.confirmedHistoryAckTrim(writeSucceeded = true),
        )
        assertEquals(trim, confirmedTrim)
        val decision = completionGate.confirmed(confirmedTrim)
        val receipt = ledger.confirm(confirmedTrim)

        assertTrue(decision.matched)
        assertTrue(decision.finishNow)
        assertEquals("committed", receipt?.value)
        assertEquals(trim, ledger.lastConfirmedTrim)
    }

    @Test
    fun `failed callback never exposes a confirmed history trim`() {
        val trim = 73L
        val ledger = HistoricalAckLedger<Unit>()
        ledger.stage(trim, Unit)
        val completionGate = HistoricalAckCompletionGate()
        completionGate.enqueued(trim)
        val deliveryGate = GattWriteDeliveryGate<WhoopBleClient.PendingWrite>()
        val write = historyWrite(trim)

        assertTrue(deliveryGate.begin(write, expectsCallback = true))
        assertEquals(GattWriteAction.WAIT_FOR_CALLBACK, deliveryGate.submitted(accepted = true))
        val failedWrite = requireNotNull(deliveryGate.callback())

        assertNull(failedWrite.confirmedHistoryAckTrim(writeSucceeded = false))
        assertNull(ledger.lastConfirmedTrim)
        assertEquals(1, completionGate.pendingCount())

        completionGate.reset()
        ledger.clearPending()
        assertNull(ledger.lastConfirmedTrim)
        assertEquals(0, completionGate.pendingCount())
    }

    @Test
    fun `callback timeout leaves acknowledged state unchanged`() {
        val trim = 99L
        val ledger = HistoricalAckLedger<Unit>()
        ledger.stage(trim, Unit)
        val completionGate = HistoricalAckCompletionGate()
        completionGate.enqueued(trim)
        val deliveryGate = GattWriteDeliveryGate<WhoopBleClient.PendingWrite>()
        val write = historyWrite(trim)

        assertTrue(deliveryGate.begin(write, expectsCallback = true))
        assertEquals(GattWriteAction.WAIT_FOR_CALLBACK, deliveryGate.submitted(accepted = true))
        assertEquals(write, deliveryGate.timeout())

        assertNull(ledger.lastConfirmedTrim)
        assertEquals(1, completionGate.pendingCount())
        completionGate.reset()
        ledger.clearPending()
        assertNull(ledger.lastConfirmedTrim)
    }

    @Test
    fun `history complete finishes only after every pending acknowledgement succeeds`() {
        val completionGate = HistoricalAckCompletionGate()
        completionGate.enqueued(10L)
        completionGate.enqueued(11L)

        val complete = completionGate.observeHistoryComplete()
        assertTrue(complete.firstObservation)
        assertFalse(complete.finishNow)
        assertEquals(2, complete.pendingAcknowledgements)

        val first = completionGate.confirmed(10L)
        assertTrue(first.matched)
        assertFalse(first.finishNow)
        assertEquals(1, first.pendingAcknowledgements)

        val final = completionGate.confirmed(11L)
        assertTrue(final.matched)
        assertTrue(final.finishNow)
        assertEquals(0, final.pendingAcknowledgements)
    }

    @Test
    fun `trim correlation consumes the oldest exact duplicate`() {
        val ledger = HistoricalAckLedger<String>()
        ledger.stage(7L, "first")
        ledger.stage(8L, "other")
        ledger.stage(7L, "second")

        assertEquals("first", ledger.confirm(7L)?.value)
        assertEquals("second", ledger.confirm(7L)?.value)
        assertEquals("other", ledger.confirm(8L)?.value)
        assertNull(ledger.confirm(8L))
    }
}
