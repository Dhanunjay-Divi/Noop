package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

class HydrationSourceMergeTest {
    @Test
    fun confirmedSourcesAreNotBlindlyAdded() {
        assertEquals(1_200.0, HydrationStore.observedTotal(1_200.0, 1_000.0), 0.0)
        assertEquals(1_000.0, HydrationStore.observedTotal(null, 1_000.0), 0.0)
    }

    @Test
    fun invalidAndNegativeTotalsCannotFabricateIntake() {
        assertEquals(0.0, HydrationStore.observedTotal(Double.NaN, -250.0), 0.0)
        assertEquals(500.0, HydrationStore.observedTotal(Double.POSITIVE_INFINITY, 500.0), 0.0)
    }
}
