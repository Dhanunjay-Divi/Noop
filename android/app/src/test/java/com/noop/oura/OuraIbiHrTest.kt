package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OuraIbiHrTest {
    private fun ibi(ringTimestamp: Long, milliseconds: Int) =
        OuraIBI(ringTimestamp = ringTimestamp, ibiMs = milliseconds)

    @Test
    fun perRecordMedianHrGroupsAndOrdersRecords() {
        val result = OuraIbiHr.perRecordMedianHR(
            listOf(
                ibi(200, 900),
                ibi(100, 1_020),
                ibi(100, 980),
                ibi(200, 910),
                ibi(100, 1_000),
            ),
        )

        assertEquals(
            listOf(
                OuraHR(ringTimestamp = 100, bpm = 60, ibiMs = 1_000),
                OuraHR(ringTimestamp = 200, bpm = 66, ibiMs = 905),
            ),
            result,
        )
    }

    @Test
    fun invalidIntervalsAreOmittedRatherThanClamped() {
        assertEquals(
            listOf(OuraHR(ringTimestamp = 1, bpm = 60, ibiMs = 1_000)),
            OuraIbiHr.perRecordMedianHR(listOf(ibi(1, 100), ibi(1, 1_000), ibi(1, 3_000))),
        )
        assertTrue(OuraIbiHr.perRecordMedianHR(listOf(ibi(2, 100), ibi(2, 5_000))).isEmpty())
    }

    @Test
    fun queuedHistoryEventsMaterializeAfterAnchorWithoutDuplicatingExistingHr() {
        val queued = listOf<OuraEvent>(
            OuraEvent.Ibi(ibi(300, 1_000)),
            OuraEvent.Ibi(ibi(300, 1_020)),
        )
        val materialized = OuraIbiHr.appendingDerivedHrToHistoryEvents(queued)

        assertEquals(
            listOf(OuraHR(ringTimestamp = 300, bpm = 59, ibiMs = 1_010)),
            materialized.mapNotNull { (it as? OuraEvent.Hr)?.value },
        )

        val existing = OuraHR(ringTimestamp = 300, bpm = 61, ibiMs = 984)
        val withExisting = OuraIbiHr.appendingDerivedHrToHistoryEvents(
            queued + OuraEvent.Hr(existing),
        )
        assertEquals(listOf(existing), withExisting.mapNotNull { (it as? OuraEvent.Hr)?.value })
    }
}
