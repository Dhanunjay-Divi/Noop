package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PostBackfillAnalysisRetryPolicyTest {
    @Test
    fun futureBoundaryUsesRemainingDelay() {
        assertEquals(
            25_000L,
            PostBackfillAnalysisRetryPolicy.initialDelayMillis(
                retryAtEpochMillis = 125_000L,
                nowEpochMillis = 100_000L,
            ),
        )
    }

    @Test
    fun elapsedBoundaryRunsPromptlyWithoutZeroDelayLoop() {
        assertEquals(
            1_000L,
            PostBackfillAnalysisRetryPolicy.initialDelayMillis(
                retryAtEpochMillis = 90_000L,
                nowEpochMillis = 100_000L,
            ),
        )
    }

    @Test
    fun durableWorkNameDependsOnlyOnBoundaryNotSourceIdentity() {
        val name = PostBackfillAnalysisRetryPolicy.workName(125_000L)

        assertEquals("noop_post_backfill_analysis_retry_v1:125000", name)
        assertTrue(name.startsWith("noop_post_backfill_analysis_retry_v1:"))
        assertFalse(name.contains("band"))
        assertFalse(name.contains("device"))
        assertFalse(name.contains("source"))
    }
}
