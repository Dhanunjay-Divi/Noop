package com.noop.ui

import com.noop.analytics.ChargeFormulaUpgradeGate
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.RestFormulaUpgradeGate
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

    @Test
    fun restV2ForcesOneFullHistoryPassUntilCompletionIsRecorded() {
        assertEquals("noop-rest-v2", RestFormulaUpgradeGate.CURRENT_REVISION)
        assertEquals(4_000, RestFormulaUpgradeGate.HISTORY_DAYS)
        assertTrue(RestFormulaUpgradeGate.needsRescore(null))
        assertTrue(RestFormulaUpgradeGate.needsRescore("noop-rest-v1"))
        assertFalse(RestFormulaUpgradeGate.needsRescore("noop-rest-v2"))
        assertEquals(
            123L,
            RestFormulaUpgradeGate.traversalAnchor(
                migrationRequired = true,
                anchorRevision = "noop-charge-v2|noop-rest-v2",
                storedAnchor = 123L,
            ),
        )
        assertEquals(
            null,
            RestFormulaUpgradeGate.traversalAnchor(
                migrationRequired = true,
                anchorRevision = "noop-rest-v1",
                storedAnchor = 123L,
            ),
        )
        assertEquals(
            456L,
            RestFormulaUpgradeGate.traversalAnchor(
                migrationRequired = true,
                anchorRevision = "noop-rest-v2",
                storedAnchor = 456L,
            ),
        )
        assertEquals(
            null,
            RestFormulaUpgradeGate.traversalAnchor(
                migrationRequired = false,
                anchorRevision = "noop-charge-v2|noop-rest-v2",
                storedAnchor = 123L,
            ),
        )
        assertEquals(
            RestFormulaUpgradeGate.Progress.Advance(456L),
            RestFormulaUpgradeGate.progress(
                passCompleted = true,
                resolvableHistorySatisfied = false,
                nextResolvableHistoryAnchor = 456L,
                wasRequired = true,
                traversalWasSelected = true,
            ),
        )
        assertEquals(
            RestFormulaUpgradeGate.Progress.Complete("noop-rest-v2"),
            RestFormulaUpgradeGate.progress(
                passCompleted = true,
                resolvableHistorySatisfied = true,
                nextResolvableHistoryAnchor = null,
                wasRequired = true,
                traversalWasSelected = true,
            ),
        )
        assertEquals(
            RestFormulaUpgradeGate.Progress.Retry,
            RestFormulaUpgradeGate.progress(
                passCompleted = false,
                resolvableHistorySatisfied = false,
                nextResolvableHistoryAnchor = 456L,
                wasRequired = true,
                traversalWasSelected = true,
            ),
        )
        assertEquals(
            RestFormulaUpgradeGate.Progress.Retry,
            RestFormulaUpgradeGate.progress(
                passCompleted = true,
                resolvableHistorySatisfied = true,
                nextResolvableHistoryAnchor = null,
                wasRequired = true,
                traversalWasSelected = false,
            ),
        )
    }

    @Test
    fun formulaTraversalReconcilesAnEmptyHistoricalScoreWindow() {
        assertFalse(
            IntelligenceEngine.shouldReconcileComputedScoreRange(
                hasFreshScores = false,
                traversingFormulaHistory = false,
            ),
        )
        assertTrue(
            IntelligenceEngine.shouldReconcileComputedScoreRange(
                hasFreshScores = true,
                traversingFormulaHistory = false,
            ),
        )
        assertTrue(
            IntelligenceEngine.shouldReconcileComputedScoreRange(
                hasFreshScores = false,
                traversingFormulaHistory = true,
            ),
        )
    }
}
