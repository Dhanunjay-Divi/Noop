package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraHistoryDrainTest {
    @Test
    fun completesAtZeroAndContinuesWhileBytesShrink() {
        val drain = OuraHistoryDrain()
        assertTrue(drain.onSummary(400_873, moreData = true, elapsedSeconds = 1.0))
        assertTrue(drain.onSummary(200_000, moreData = true, elapsedSeconds = 2.0))
        assertFalse(drain.onSummary(0, moreData = false, elapsedSeconds = 3.0))
    }

    @Test
    fun stallAndDeadlineGuardsStopAStuckDrain() {
        val stalled = OuraHistoryDrain()
        assertTrue(stalled.onSummary(1_000, true, 1.0))
        assertTrue(stalled.onSummary(1_000, true, 2.0))
        assertTrue(stalled.onSummary(1_000, true, 3.0))
        assertFalse(stalled.onSummary(1_000, true, 4.0))

        val overdue = OuraHistoryDrain()
        assertFalse(overdue.onSummary(500, true, OuraHistoryDrain.MAX_DRAIN_SECONDS + 0.1))
    }

    @Test
    fun storedCursorAdvancesOnlyWhenForwardAndAnchored() {
        val drain = OuraHistoryDrain()
        drain.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 1_000)
        assertEquals(1_000L, drain.resumeCursorAtDrainEnd(1_000, resolvesUnderAnchor = false))
        assertEquals(3_453_828L, drain.resumeCursorAtDrainEnd(1_000, resolvesUnderAnchor = true))
    }

    @Test
    fun preResumeStoredDataFlagsRebootAndForcesFullPull() {
        val drain = OuraHistoryDrain()
        drain.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart = 1_000)
        drain.noteStoredRingTime(500, resumeCursorAtFetchStart = 1_000)
        assertTrue(drain.sawPreResumeData)
        assertEquals(0L, drain.resumeCursorAtDrainEnd(1_000, resolvesUnderAnchor = true))
    }

    @Test
    fun continuationUsesNewestObservedEnvelopeAndRearmsPerRequest() {
        val drain = OuraHistoryDrain()
        drain.noteSeenRingTime(2_000)
        drain.noteSeenRingTime(3_595_428)
        drain.noteSeenRingTime(3_000)
        assertEquals(3_595_429L, drain.continuationCursor(lastRequestCursor = 1_000))
        assertNull(drain.continuationCursor(lastRequestCursor = 3_595_429))
        assertEquals(0L, drain.maxStoredRingTime)
    }

    @Test
    fun continuationRejectsEmptyNonAdvancingAndCorruptBatches() {
        val drain = OuraHistoryDrain()
        assertNull(drain.continuationCursor(lastRequestCursor = 1_000))
        drain.noteSeenRingTime(900)
        assertNull(drain.continuationCursor(lastRequestCursor = 1_000))

        val corrupt = OuraHistoryDrain()
        corrupt.noteSeenRingTime(OuraHistoryDrain.MAX_PLAUSIBLE_RESUME_TICKS + 1)
        assertNull(corrupt.continuationCursor(lastRequestCursor = 0))
    }

    @Test
    fun rawUnknownEnvelopeStillAdvancesTransportContinuation() {
        val unknown = OuraRecord(type = 0x99, ringTimestamp = 42_424, payload = intArrayOf(1, 2))
        val driver = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        assertTrue("fixture must decode to no semantic events", driver.ingest(unknown).isEmpty())

        val drain = OuraHistoryDrain()
        // The live source records OuraRecord.ringTimestamp before ingest, so unknown records still count.
        drain.noteSeenRingTime(unknown.ringTimestamp)
        assertEquals(42_425L, drain.continuationCursor(lastRequestCursor = 40_000))
    }

    @Test
    fun loadedCursorSanitizeAndResetClearAllState() {
        assertEquals(3_453_828L, OuraHistoryDrain.sanitizeLoadedCursor(3_453_828))
        assertEquals(0L, OuraHistoryDrain.sanitizeLoadedCursor(-1))
        assertEquals(
            0L,
            OuraHistoryDrain.sanitizeLoadedCursor(OuraHistoryDrain.MAX_PLAUSIBLE_RESUME_TICKS + 1),
        )

        val drain = OuraHistoryDrain()
        drain.noteStoredRingTime(500, resumeCursorAtFetchStart = 1_000)
        drain.noteSeenRingTime(2_000)
        drain.onSummary(1_000, true, 1.0)
        drain.reset()
        assertEquals(0L, drain.maxStoredRingTime)
        assertEquals(0L, drain.maxSeenRingTime)
        assertEquals(0, drain.eventsSinceLastRequest)
        assertFalse(drain.sawPreResumeData)
        assertTrue(drain.onSummary(1_000, true, 1.0))
    }

    @Test
    fun eventEnvelopeTimestampIsAvailableWithoutAUtcAnchor() {
        assertEquals(4_242L, OuraEvent.Temp(OuraTemp(4_242, 36.2)).envelopeRingTimestamp)
        assertEquals(
            8_000L,
            OuraEvent.SleepPhaseEvent(OuraSleepPhase(8_000, 0, OuraSleepStage.DEEP))
                .envelopeRingTimestamp,
        )
        assertEquals(9_000L, OuraEvent.DebugTextEvent(9_000, "state").envelopeRingTimestamp)
        assertNull(OuraEvent.Battery(OuraBattery(percent = 80)).envelopeRingTimestamp)
    }
}
