package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StressNudgeSessionRegistryTest {
    @Test fun overlapping_leases_are_balanced_and_release_is_idempotent() {
        val first = StressNudgeSessionRegistry.acquire()
        val second = StressNudgeSessionRegistry.acquire()
        assertTrue(StressNudgeSessionRegistry.active)

        first.release()
        assertTrue(StressNudgeSessionRegistry.active)
        first.release()
        assertTrue(StressNudgeSessionRegistry.active)

        second.release()
        assertFalse(StressNudgeSessionRegistry.active)
    }
}
