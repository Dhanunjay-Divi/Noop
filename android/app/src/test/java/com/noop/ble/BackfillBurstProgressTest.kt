package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class BackfillBurstProgressTest {
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
}
