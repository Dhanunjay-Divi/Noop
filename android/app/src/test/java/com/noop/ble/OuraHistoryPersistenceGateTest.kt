package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class OuraHistoryPersistenceGateTest {
    @Test
    fun terminalSummaryWaitsForAcknowledgedWrite() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        assertTrue(gate.register(generation))
        assertNull(gate.requestFinish(drainCompleted = true))
        assertFalse(gate.shouldStartTimeout)

        val result = gate.completeWrite(generation, succeeded = true)
        assertTrue(result.accepted)
        assertNull(result.resolution)
        assertEquals(
            OuraHistoryPersistenceGate.Resolution(
                drainCompleted = true,
                allWritesSucceeded = true,
            ),
            gate.seal(),
        )
    }

    @Test
    fun oneFailureBlocksWholeOutOfOrderDrain() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        assertTrue(gate.register(generation))
        assertTrue(gate.register(generation))
        assertNull(gate.requestFinish(drainCompleted = true))

        assertNull(gate.completeWrite(generation, succeeded = true).resolution)
        assertNull(gate.completeWrite(generation, succeeded = false).resolution)
        assertEquals(
            OuraHistoryPersistenceGate.Resolution(
                drainCompleted = true,
                allWritesSucceeded = false,
            ),
            gate.seal(),
        )
    }

    @Test
    fun forcedStopCanResolveSafeProgressOnlyAfterAllWrites() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        assertTrue(gate.register(generation))
        assertNull(gate.requestFinish(drainCompleted = false))
        assertNull(gate.completeWrite(generation, succeeded = true).resolution)
        assertEquals(
            OuraHistoryPersistenceGate.Resolution(
                drainCompleted = false,
                allWritesSucceeded = true,
            ),
            gate.seal(),
        )
    }

    @Test
    fun staleCompletionCannotMutateReconnectGeneration() {
        val gate = OuraHistoryPersistenceGate()
        val oldGeneration = gate.begin()
        assertTrue(gate.register(oldGeneration))
        gate.invalidate()

        val currentGeneration = gate.begin()
        assertTrue(gate.register(currentGeneration))
        assertNull(gate.requestFinish(drainCompleted = true))
        val stale = gate.completeWrite(oldGeneration, succeeded = false)
        assertFalse(stale.accepted)
        assertEquals(1, gate.pendingWriteCount)
        assertFalse(gate.sawWriteFailure)

        assertNull(gate.completeWrite(currentGeneration, succeeded = true).resolution)
        assertEquals(
            OuraHistoryPersistenceGate.Resolution(
                drainCompleted = true,
                allWritesSucceeded = true,
            ),
            gate.seal(),
        )
    }

    @Test
    fun timeoutInvalidatesAndLateSuccessIsIgnored() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        assertTrue(gate.register(generation))
        assertNull(gate.requestFinish(drainCompleted = true))
        assertNull(gate.seal())
        assertTrue(gate.shouldStartTimeout)
        assertTrue(gate.timeOut(generation))
        assertFalse(gate.isActive)

        val late = gate.completeWrite(generation, succeeded = true)
        assertFalse(late.accepted)
        assertNull(late.resolution)
    }

    @Test
    fun explicitTeardownInvalidatesSealedBarrierBeforeLateRoomCompletion() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        assertTrue(gate.register(generation))
        assertNull(gate.requestFinish(drainCompleted = true))
        assertNull(gate.seal())

        gate.invalidate()

        val late = gate.completeWrite(generation, succeeded = true)
        assertFalse(late.accepted)
        assertNull(late.resolution)
        assertFalse(gate.isActive)
    }

    @Test
    fun lateWriteAfterSummaryJoinsBeforeRequestBoundary() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        assertTrue(gate.register(generation))
        assertNull(gate.requestFinish(drainCompleted = true))
        assertTrue(gate.register(generation))
        assertNull(gate.seal())

        assertNull(gate.completeWrite(generation, succeeded = true).resolution)
        assertEquals(
            OuraHistoryPersistenceGate.Resolution(
                drainCompleted = true,
                allWritesSucceeded = true,
            ),
            gate.completeWrite(generation, succeeded = true).resolution,
        )
    }

    @Test
    fun hypnogramReceiptRetainsTheOriginalGeneration() {
        val receipts = OuraHypnogramReceiptTracker()
        assertNull(receipts.rotate(toGeneration = 7))
        assertEquals(
            OuraHypnogramReceiptTracker.Receipt(historyGeneration = 7),
            receipts.rotate(toGeneration = 8),
        )
        assertEquals(
            OuraHypnogramReceiptTracker.Receipt(historyGeneration = 8),
            receipts.pendingReceipt,
        )
    }

    @Test
    fun concurrentRoomCompletionsCannotLosePendingCount() {
        val gate = OuraHistoryPersistenceGate()
        val generation = gate.begin()
        val count = 200
        val pool = Executors.newFixedThreadPool(8)
        val registered = CountDownLatch(count)
        repeat(count) {
            pool.execute {
                assertTrue(gate.register(generation))
                registered.countDown()
            }
        }
        assertTrue(registered.await(5, TimeUnit.SECONDS))
        assertEquals(count, gate.pendingWriteCount)
        assertNull(gate.requestFinish(drainCompleted = true))

        val completed = CountDownLatch(count)
        repeat(count) {
            pool.execute {
                gate.completeWrite(generation, succeeded = true)
                completed.countDown()
            }
        }
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        pool.shutdownNow()
        assertEquals(0, gate.pendingWriteCount)
        assertEquals(
            OuraHistoryPersistenceGate.Resolution(
                drainCompleted = true,
                allWritesSucceeded = true,
            ),
            gate.seal(),
        )
        assertFalse(gate.isActive)
    }
}
