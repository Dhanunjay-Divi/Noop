package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HydrationSourceMergeTest {
    @Test
    fun confirmedSourcesAreNotBlindlyAdded() {
        assertEquals(
            1_200.0,
            requireNotNull(HydrationStore.observedTotal(1_200.0, 1_000.0)),
            0.0,
        )
        assertEquals(
            1_000.0,
            requireNotNull(HydrationStore.observedTotal(null, 1_000.0)),
            0.0,
        )
    }

    @Test
    fun invalidAndNegativeTotalsCannotFabricateIntake() {
        assertNull(HydrationStore.observedTotal(Double.NaN, -250.0))
        assertEquals(
            500.0,
            requireNotNull(
                HydrationStore.observedTotal(Double.POSITIVE_INFINITY, 500.0),
            ),
            0.0,
        )
    }

    @Test
    fun displayPolicyKeepsMissingAndClearedTotalsUnlogged() {
        assertNull(HydrationStore.confirmedTotal(null))
        assertNull(HydrationStore.confirmedTotal(0.0))
        assertNull(HydrationStore.confirmedTotal(-1.0))
        assertEquals(
            "Not logged",
            HydrationStore.cardValue(null, 3_200, "Not logged"),
        )
        assertEquals(
            "1.2 / 3.2 L",
            HydrationStore.cardValue(1_200.0, 3_200, "Not logged"),
        )
    }
}
