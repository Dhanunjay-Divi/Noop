package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChargeFormulaUpgradeGateTest {
    @Test
    fun v2ForcesOneFullHistoryPassUntilCompletionIsRecorded() {
        assertEquals("noop-charge-v2", ChargeFormulaUpgradeGate.CURRENT_REVISION)
        assertEquals(4_000, ChargeFormulaUpgradeGate.HISTORY_DAYS)
        assertTrue(ChargeFormulaUpgradeGate.needsRescore(null))
        assertTrue(ChargeFormulaUpgradeGate.needsRescore("noop-charge-v1"))
        assertFalse(ChargeFormulaUpgradeGate.needsRescore("noop-charge-v2"))
    }
}
