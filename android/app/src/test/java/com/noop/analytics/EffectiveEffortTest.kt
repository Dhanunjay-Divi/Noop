package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class EffectiveEffortTest {
    @Test fun liveAheadWinsAndStoredFloorsUnderRead() {
        assertEquals(2.3, StrainScorer.effectiveEffort(2.3, 0.5)!!, 1e-9)
        assertEquals(38.3, StrainScorer.effectiveEffort(0.0, 38.3)!!, 1e-9)
    }

    @Test fun singleSourceAndNoSourceRemainHonest() {
        assertEquals(12.5, StrainScorer.effectiveEffort(null, 12.5)!!, 1e-9)
        assertEquals(4.0, StrainScorer.effectiveEffort(4.0, null)!!, 1e-9)
        assertNull(StrainScorer.effectiveEffort(null, null))
        assertEquals(0.0, StrainScorer.effectiveEffort(0.0, 0.0)!!, 1e-9)
    }
}
