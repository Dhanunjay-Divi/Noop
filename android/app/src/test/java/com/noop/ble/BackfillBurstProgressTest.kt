package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackfillBurstProgressTest {
    @Test
    fun onlyInsertedRowsOrChangedTrimCountAsDurableProgress() {
        assertTrue(HistorySyncDurableProgressPolicy.advances(1, 42, 42))
        assertTrue(HistorySyncDurableProgressPolicy.advances(0, 43, 42))
        assertFalse(HistorySyncDurableProgressPolicy.advances(0, 42, 42))
    }

    @Test
    fun accumulatesRowsRangeAndBatchesAcrossSlices() {
        val first = BackfillBurstProgress()
            .acknowledgingBatch()
            .adding(BackfillCommittedChunk(rows = 20, oldestUnix = 200, newestUnix = 300))
        val continued = first
            .acknowledgingBatch()
            .adding(BackfillCommittedChunk(rows = 7, oldestUnix = 100, newestUnix = 450))

        assertEquals(2, continued.batches)
        assertEquals(27, continued.rows)
        assertEquals(100L, continued.oldestUnix)
        assertEquals(450L, continued.newestUnix)
    }

    @Test
    fun ignoresNegativeRowsAndMissingRangeEndpoints() {
        val progress = BackfillBurstProgress(rows = 5, oldestUnix = 100, newestUnix = 200)
            .adding(BackfillCommittedChunk(rows = -3, oldestUnix = null, newestUnix = null))

        assertEquals(5, progress.rows)
        assertEquals(100L, progress.oldestUnix)
        assertEquals(200L, progress.newestUnix)
    }

    @Test
    fun durableProgressPolicyMovesFromStartingToWaitingToStalled() {
        assertEquals(
            HistorySyncProgressActivity.STARTING,
            HistorySyncDurableProgressPolicy.activity(100, null, 109),
        )
        assertEquals(
            HistorySyncProgressActivity.WAITING,
            HistorySyncDurableProgressPolicy.activity(100, null, 110),
        )
        assertFalse(HistorySyncDurableProgressPolicy.shouldStop(100, null, 189))
        assertTrue(HistorySyncDurableProgressPolicy.shouldStop(100, null, 190))
    }

    @Test
    fun durableReceiptRestartsDeadlineAndClockRollbackDoesNotFalseStall() {
        assertEquals(
            HistorySyncProgressActivity.ADVANCING,
            HistorySyncDurableProgressPolicy.activity(100, 150, 159),
        )
        assertEquals(
            HistorySyncProgressActivity.WAITING,
            HistorySyncDurableProgressPolicy.activity(100, 150, 160),
        )
        assertTrue(HistorySyncDurableProgressPolicy.shouldStop(100, 150, 240))
        assertEquals(
            HistorySyncProgressActivity.ADVANCING,
            HistorySyncDurableProgressPolicy.activity(100, 150, 120),
        )
    }

    @Test
    fun cachedAutomaticSyncCollapsesAfterBriefDisclosure() {
        assertEquals(
            HistorySyncPresentationState.EXPANDED,
            HistorySyncPresentationPolicy.state(
                isSyncing = true,
                hasCachedContent = true,
                startedAt = 100,
                lastDurableProgressAt = 101,
                now = 102,
            ),
        )
        assertEquals(
            HistorySyncPresentationState.COMPACT,
            HistorySyncPresentationPolicy.state(
                isSyncing = true,
                hasCachedContent = true,
                startedAt = 100,
                lastDurableProgressAt = 101,
                now = 103,
            ),
        )
    }

    @Test
    fun noDataManualAndStalledSyncStayExplicit() {
        assertEquals(
            HistorySyncPresentationState.EXPANDED,
            HistorySyncPresentationPolicy.state(
                isSyncing = true,
                hasCachedContent = false,
                startedAt = 100,
                lastDurableProgressAt = 150,
                now = 170,
            ),
        )
        assertEquals(
            HistorySyncPresentationState.EXPANDED,
            HistorySyncPresentationPolicy.state(
                isSyncing = true,
                userInitiated = true,
                hasCachedContent = true,
                startedAt = 100,
                lastDurableProgressAt = 150,
                now = 170,
            ),
        )
        assertEquals(
            HistorySyncPresentationState.ATTENTION,
            HistorySyncPresentationPolicy.state(
                isSyncing = true,
                hasCachedContent = true,
                startedAt = 100,
                lastDurableProgressAt = null,
                now = 190,
            ),
        )
        assertEquals(
            HistorySyncPresentationState.HIDDEN,
            HistorySyncPresentationPolicy.state(
                isSyncing = false,
                hasCachedContent = true,
                startedAt = 100,
                lastDurableProgressAt = null,
                now = 190,
            ),
        )
    }
}
