package com.noop.ble

import android.content.Intent
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
    fun durableWorkNameIsStableAndContainsNoSourceOrBoundaryIdentity() {
        val name = PostBackfillAnalysisRetryPolicy.WORK_NAME

        assertEquals("noop_post_backfill_analysis_retry_v2", name)
        assertFalse(name.contains("band"))
        assertFalse(name.contains("device"))
        assertFalse(name.contains("source"))
        assertFalse(name.contains("125000"))
    }

    @Test
    fun workSpecCarriesBoundaryDelayAndResourceConstraints() {
        val spec = PostBackfillAnalysisRetryPolicy.workSpec(
            retryAtEpochMillis = 125_000L,
            nowEpochMillis = 100_000L,
            workId = "fixed-work-id",
        )

        assertEquals("fixed-work-id", spec.workId)
        assertEquals(125_000L, spec.retryAtEpochMillis)
        assertEquals(25_000L, spec.initialDelayMillis)
        assertTrue(spec.requiresBatteryNotLow)
        assertTrue(spec.requiresStorageNotLow)
        assertEquals(PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION, spec.protocolVersion)
    }

    @Test
    fun workerEntryRunsOnlyCompleteV2Requests() {
        assertEquals(
            PostBackfillRetryWorkerEntryDecision.RUN_V2,
            postBackfillRetryWorkerEntryDecision(
                protocolVersion = PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION,
                retryAtEpochMillis = 125_000L,
            ),
        )
        assertEquals(
            PostBackfillRetryWorkerEntryDecision.EXIT_LEGACY,
            postBackfillRetryWorkerEntryDecision(
                protocolVersion = 1,
                retryAtEpochMillis = 125_000L,
            ),
        )
        assertEquals(
            PostBackfillRetryWorkerEntryDecision.EXIT_LEGACY,
            postBackfillRetryWorkerEntryDecision(
                protocolVersion = 0,
                retryAtEpochMillis = Long.MIN_VALUE,
            ),
        )
        assertEquals(
            PostBackfillRetryWorkerEntryDecision.EXIT_LEGACY,
            postBackfillRetryWorkerEntryDecision(
                protocolVersion = PostBackfillAnalysisRetryPolicy.PROTOCOL_VERSION,
                retryAtEpochMillis = Long.MIN_VALUE,
            ),
        )
    }

    @Test
    fun clockAndDateChangesRequireScheduleReconciliation() {
        assertTrue(
            PostBackfillAnalysisRetryPolicy.handlesClockChange(
                Intent.ACTION_TIMEZONE_CHANGED,
            ),
        )
        assertTrue(
            PostBackfillAnalysisRetryPolicy.handlesClockChange(
                Intent.ACTION_TIME_CHANGED,
            ),
        )
        assertTrue(
            PostBackfillAnalysisRetryPolicy.handlesClockChange(
                Intent.ACTION_DATE_CHANGED,
            ),
        )
        assertFalse(PostBackfillAnalysisRetryPolicy.handlesClockChange(Intent.ACTION_SCREEN_ON))
        assertFalse(PostBackfillAnalysisRetryPolicy.handlesClockChange(null))
    }

    @Test
    fun persistedSourceReadDistinguishesPresentEmptyAndFailure() {
        val present = WhoopBleClient.classifyPersistedPostBackfillSources {
            setOf("", "source-a")
        }
        assertEquals(
            PostBackfillPendingSourceRead.PRESENT,
            present.state(),
        )
        assertEquals(
            setOf("source-a"),
            (present as PostBackfillPendingSourcesRead.Available).sourceIds,
        )
        assertEquals(
            PostBackfillPendingSourceRead.EMPTY,
            WhoopBleClient.classifyPersistedPostBackfillSources {
                setOf("", " ")
            }.state(),
        )
        assertEquals(
            PostBackfillPendingSourceRead.FAILED,
            WhoopBleClient.classifyPersistedPostBackfillSources {
                error("preferences unavailable")
            }.state(),
        )
    }
}
