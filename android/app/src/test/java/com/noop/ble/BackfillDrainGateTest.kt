package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class BackfillDrainGateTest {
    @Test fun producerBeforeEmptyHandoffLeavesWorkForCurrentOwner() {
        val gate = BackfillDrainGate<Int>()
        val lease = gate.enqueue(1)!!
        assertEquals(1, gate.pollOrRelease(lease))
        assertNull(gate.enqueue(2))
        assertEquals(2, gate.pollOrRelease(lease))
        assertNull(gate.pollOrRelease(lease))
    }

    @Test fun producerAfterEmptyHandoffStartsReplacementDrain() {
        val gate = BackfillDrainGate<Int>()
        val first = gate.enqueue(1)!!
        assertEquals(1, gate.pollOrRelease(first))
        assertNull(gate.pollOrRelease(first))
        val replacement = gate.enqueue(2)
        assertNotNull(replacement)
        assertEquals(2, gate.pollOrRelease(replacement!!))
        assertNull(gate.pollOrRelease(replacement))
    }

    @Test fun resetMakesLateOldDrainHarmlessToNewConnection() {
        val gate = BackfillDrainGate<Int>()
        val old = gate.enqueue(1)!!
        assertNull(gate.enqueue(99))
        gate.reset()
        val fresh = gate.enqueue(2)!!
        assertNull(gate.pollOrRelease(old))
        gate.release(old)
        assertEquals(2, gate.pollOrRelease(fresh))
        assertNull(gate.pollOrRelease(fresh))
    }

    @Test fun exceptionalReleaseLetsNextProducerOwnDrain() {
        val gate = BackfillDrainGate<Int>()
        val failed = gate.enqueue(1)!!
        assertEquals(1, gate.pollOrRelease(failed))
        gate.release(failed)
        val replacement = gate.enqueue(2)!!
        assertEquals(2, gate.pollOrRelease(replacement))
        assertNull(gate.pollOrRelease(replacement))
    }
}
