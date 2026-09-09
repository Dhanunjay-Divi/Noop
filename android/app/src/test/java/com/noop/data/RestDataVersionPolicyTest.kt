package com.noop.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RestDataVersionPolicyTest {
    @Test
    fun advancesForEverySleepSurfaceSeriesOrDailyMetricChanges() {
        listOf(
            "sleep_performance",
            "sleep_consistency",
            "sleep_need_min",
            "sleep_debt_min",
            "rest_confidence",
            "rest_evidence_flags",
        ).forEach { key ->
            assertTrue(RestDataVersionPolicy.shouldAdvance(listOf(key), false))
        }
        assertTrue(RestDataVersionPolicy.shouldAdvance(emptyList(), true))
        assertFalse(RestDataVersionPolicy.shouldAdvance(listOf("hydration_ml", "mood"), false))
        assertFalse(RestDataVersionPolicy.shouldAdvance(emptyList(), false))
    }
}
