package com.noop.data

import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
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

    @Test
    fun conservativeMetricInvalidationAdvancesRestAndGeneralRevisionsTogether() {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw UnsupportedOperationException("revision invalidation must not call ${method.name}")
        } as WhoopDao
        val repository = WhoopRepository(dao)

        repository.noteMetricsChanged()

        assertEquals(1L, repository.metricDataVersion.value)
        assertEquals(1L, repository.restDataVersion.value)
    }
}
