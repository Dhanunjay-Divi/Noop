package com.noop.ble

import com.noop.data.InsertCounts
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.testing.FakeSharedPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * Pins the success-side observability the log forensics flagged as the blind spot (#150): NOOP logged
 * FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a banking strap from a
 * broken one. Covers the pure tally + summary helpers driving the new
 * "Backfill: session persisted N rows (M with motion) across K night(s)" line. Mirrors the Swift
 * BackfillerSessionTallyTests.
 */
class BackfillerSessionTallyTest {

    private class SimulatedStorageFull :
        RuntimeException("private-user-content-must-not-reach-diagnostics")

    private class RecordingCursorStore : TrimCursorStore {
        val writes = mutableListOf<Pair<String, Long>>()

        override suspend fun set(name: String, value: Long) {
            writes += name to value
        }

        override suspend fun get(name: String): Long? = null
    }

    private fun storageFullRepository(): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, _, _ -> throw SimulatedStorageFull() } as WhoopDao
        return WhoopRepository(dao)
    }

    private fun bytes(hex: String): ByteArray =
        ByteArray(hex.length / 2) {
            ((hex[it * 2].digitToInt(16) shl 4) or hex[it * 2 + 1].digitToInt(16)).toByte()
        }

    private val v25RecordFrame: ByteArray
        get() = bytes(
            "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06" +
                "c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44",
        )

    private val historyEndFrame: ByteArray
        get() = byteArrayOf(
            0xaa.toByte(), 0x15, 0x00, 0x16, 0x31, 0x00, 0x02, 0xff.toByte(),
            0xf0.toByte(), 0x53, 0x65, 0x05, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x40, 0xe2.toByte(), 0x01, 0x00, 0x5a, 0x85.toByte(),
            0x0d, 0x5e,
        )

    // Rows include every score-bearing stream and durable physiological history. Battery is housekeeping;
    // motion remains the gravity subset.
    @Test fun chunkTallySumsAllDurablePhysiologicalRows() {
        val counts = InsertCounts(
            hr = 10,
            rr = 4,
            events = 9,
            battery = 7,
            spo2 = 3,
            skinTemp = 2,
            steps = 8,
            resp = 1,
            gravity = 5,
            sleepState = 6,
            ppgWaveform = 7,
        )
        val (rows, motion, nights) = Backfiller.chunkTally(counts, emptyList())
        assertEquals(10 + 4 + 9 + 3 + 2 + 8 + 1 + 5 + 6 + 7, rows)
        assertEquals(5, motion)
        assertTrue(nights.isEmpty())
    }

    // nights collapse timestamps to distinct day-keys (ts / 86400): a chunk crossing a day boundary
    // counts two nights; same-day samples count once.
    @Test fun chunkTallyNightsAreDistinctDayKeys() {
        val day0 = 1_700_000_000L
        val sameDay = day0 + 3_600L
        val nextDay = day0 + 86_400L
        val (_, _, nights) = Backfiller.chunkTally(InsertCounts(), listOf(day0, sameDay, nextDay))
        assertEquals(setOf(day0 / 86_400L, nextDay / 86_400L), nights)
        assertEquals(2, nights.size)
    }

    // Silent when nothing persisted, so a console-only / caught-up session doesn't claim a false success.
    @Test fun sessionSummaryNullWhenNoRows() {
        assertNull(Backfiller.sessionSummaryLine(0, 0, 0, 0))
    }

    @Test fun sessionSummaryFormat() {
        assertEquals(
            "Backfill: session persisted 240 rows (180 with motion, 12 skin-temp) across 3 night(s).",
            Backfiller.sessionSummaryLine(240, 180, 12, 3),
        )
    }

    // #727: a strap banking HR/RR-only records (no DSP sleep block) persists rows but ZERO skin-temp,
    // so the line surfaces that 0 and "skin temp never appears" reports are self-diagnosing from the log.
    @Test fun sessionSummaryShowsZeroSkinTemp() {
        assertEquals(
            "Backfill: session persisted 872 rows (172 with motion, 0 skin-temp) across 1 night(s).",
            Backfiller.sessionSummaryLine(872, 172, 0, 1),
        )
    }

    // #783: trim=0xFFFFFFFF on a fresh run that banked NOTHING means "no banked history": the genuine
    // clock/charge guidance with the "fully charge it" hint.
    @Test fun noCursorLineNoRowsGivesNoHistoryGuidance() {
        val line = Backfiller.noCursorLine(0)
        assertTrue(line.contains("no banked history to offload"))
        assertTrue(line.contains("fully charge"))
    }

    // #783: trim=0xFFFFFFFF AFTER the auto-continuation has already persisted rows means "caught up",
    // NOT "no history". It must NOT emit the scary fully-charge guidance.
    @Test fun noCursorLineAfterRowsGivesCaughtUpLine() {
        val line = Backfiller.noCursorLine(240)
        assertTrue(line.contains("reached the end of available history"))
        assertTrue(line.contains("240 row(s)"))
        assertFalse(line.contains("no banked history"))
        assertFalse(line.contains("fully charge"))
    }

    // #42: trim=0xFFFFFFFF on the EMPTY tail of an auto-continue burst (this session banked 0 rows, but an
    // earlier session in the burst did \u2014 continuedAfterRows=true) means "caught up", NOT "no history". It
    // must NOT emit the scary fully-charge guidance even though rowsPersisted is 0.
    @Test fun noCursorLineContinuedAfterRowsGivesCaughtUpLine() {
        val line = Backfiller.noCursorLine(0, continuedAfterRows = true)
        assertTrue(line.contains("caught up"))
        assertFalse(line.contains("no banked history"))
        assertFalse(line.contains("fully charge"))
    }

    // #42: continuedAfterRows only softens the ZERO-row tail; a genuinely empty FRESH run (default false)
    // still gets the honest no-history guidance.
    @Test fun noCursorLineFreshEmptyStillGivesNoHistoryGuidance() {
        assertTrue(Backfiller.noCursorLine(0, continuedAfterRows = false).contains("no banked history"))
    }

    // No em-dash leaks into either branch (project hard rule).
    @Test fun noCursorLineHasNoEmDash() {
        assertFalse(Backfiller.noCursorLine(0).contains("\u2014"))
        assertFalse(Backfiller.noCursorLine(5).contains("\u2014"))
        assertFalse(Backfiller.noCursorLine(0, continuedAfterRows = true).contains("\u2014"))
    }

    // ---- #773 corrupt future-RTC detection ----

    // A genuine offload is PAST-dated; a past timestamp is never flagged.
    @Test fun futureRtcNotFlaggedForPastDate() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isCorruptFutureRtc(now - 86_400L, now))
        assertFalse(Backfiller.isCorruptFutureRtc(now, now))
    }

    // Ordinary forward skew under the 1-day tolerance is NOT a corrupt clock (no false alarm).
    @Test fun futureRtcToleratesSmallSkew() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isCorruptFutureRtc(now + 3_600L, now))
        // Exactly at the tolerance boundary is still OK (strictly greater trips it).
        assertFalse(Backfiller.isCorruptFutureRtc(now + Backfiller.FUTURE_RTC_TOLERANCE_SECONDS, now))
    }

    // A date days into the future can only be a corrupt strap RTC, so it's flagged.
    @Test fun futureRtcFlaggedForFarFutureDate() {
        val now = 1_700_000_000L
        assertTrue(Backfiller.isCorruptFutureRtc(now + 10L * 86_400L, now))
    }

    // The recovery hint names the cause + fix, reports days-ahead, and has no em-dash. Byte-identical to Swift.
    @Test fun futureRtcLineWording() {
        val now = 1_700_000_000L
        val line = Backfiller.futureRtcLine(now + 10L * 86_400L, now)
        assertTrue(line.contains("10 day(s) in the FUTURE"))
        assertTrue(line.contains("clock (RTC) is corrupt"))
        assertTrue(line.contains("Fully charge"))
        assertFalse(line.contains("\u2014"))
    }

    // ---- #1 records-bearing 0xFFFFFFFF END must NOT false-alarm "no banked history" ----

    /**
     * #1: the no-cursor (0xFFFFFFFF) gate must pick its line on the row count that ALREADY includes THIS
     * END's own rows. A bad-clock/flash strap can emit records on the same no-cursor END; before the fix
     * the gate read sessionRowsPersisted at the TOP of finishChunk, before this chunk's rows were tallied,
     * so a records-bearing END logged the alarming "no banked history" line. The relocation moves the gate
     * AFTER `sessionRowsPersisted += rows`. This pins that ordering by replaying finishChunk's exact field
     * sequence through the SAME production helpers (chunkTally -> add rows -> noCursorLine): with this
     * END's rows added first, the no-cursor line is the neutral caught-up one, never the false alarm.
     */
    @Test fun recordsBearingNoCursorEndDoesNotFalseAlarm() {
        // This END carries records (a v25-style chunk decoding to gravity rows): chunkTally yields rows > 0.
        val counts = InsertCounts(gravity = 3)
        var sessionRowsPersisted = 0
        // finishChunk's persist-block ordering: tally THIS chunk, THEN add to the session total...
        val (rows, _, _) = Backfiller.chunkTally(counts, listOf(1_700_000_000L, 1_700_000_001L, 1_700_000_002L))
        sessionRowsPersisted += rows
        // ...and ONLY THEN does the relocated no-cursor gate read sessionRowsPersisted.
        val line = Backfiller.noCursorLine(sessionRowsPersisted)
        assertTrue("this END's own rows must be in the count", sessionRowsPersisted > 0)
        assertFalse("a records-bearing 0xFFFFFFFF END must NOT emit the false no-history alarm",
            line.contains("no banked history to offload"))
        assertFalse(line.contains("fully charge"))
        assertTrue("it should be the neutral caught-up line instead",
            line.contains("reached the end of available history"))
    }

    /**
     * #1 (the critical other half): a genuinely empty session (a 0xFFFFFFFF END with no accumulated
     * records, so zero rows persisted) STILL gets the real no-history guidance. The relocation must not
     * silence the legitimate case: with no persist block running, sessionRowsPersisted stays 0 and the
     * gate emits the genuine warning.
     */
    @Test fun trulyEmptyNoCursorEndStillWarnsNoHistory() {
        val sessionRowsPersisted = 0 // empty END: the persist block never runs, total stays 0
        val line = Backfiller.noCursorLine(sessionRowsPersisted)
        assertTrue("a truly-empty no-cursor session must still warn the strap has no banked history",
            line.contains("no banked history to offload"))
        assertTrue(line.contains("fully charge"))
    }

    @Test fun storageFullDuringDecodedInsertHoldsCursorAndLaterAcknowledgements() = runBlocking {
        val cursorStore = RecordingCursorStore()
        val requestedTrims = mutableListOf<Long>()
        val logs = mutableListOf<String>()
        val backfiller = Backfiller(
            repository = storageFullRepository(),
            deviceId = "test",
            cursorStore = cursorStore,
            log = logs::add,
            ackTrim = { _, trim, _ ->
                requestedTrims += trim
                true
            },
        )
        backfiller.begin(DeviceFamily.WHOOP4)

        backfiller.ingest(v25RecordFrame)
        backfiller.ingest(historyEndFrame)

        assertTrue(backfiller.persistStalled)
        assertTrue(cursorStore.writes.isEmpty())
        assertTrue(requestedTrims.isEmpty())
        assertEquals(0, backfiller.pendingHistoricalAckCount)
        assertNull(backfiller.lastAckedTrim)
        assertTrue(logs.any { it.contains("failure=decoded_store_write") })
        assertTrue(logs.none { it.contains("private-user-content") })
        assertTrue(logs.none { it.contains("SimulatedStorageFull") })

        // An empty end after the failed records-bearing chunk must not trim past it.
        backfiller.ingest(historyEndFrame)

        assertTrue(cursorStore.writes.isEmpty())
        assertTrue(requestedTrims.isEmpty())
        assertEquals(0, backfiller.pendingHistoricalAckCount)
        assertNull(backfiller.lastAckedTrim)
    }

    @Test fun failedCursorCommitHoldsAcknowledgementAndUsesFixedFailureCategory() = runBlocking {
        val requestedTrims = mutableListOf<Long>()
        val logs = mutableListOf<String>()
        val backfiller = Backfiller(
            repository = storageFullRepository(),
            deviceId = "test",
            cursorStore = PrefsTrimCursorStore(
                FakeSharedPreferences(commitResult = false),
            ),
            log = logs::add,
            ackTrim = { _, trim, _ ->
                requestedTrims += trim
                true
            },
        )
        backfiller.begin(DeviceFamily.WHOOP4)

        backfiller.ingest(historyEndFrame)

        assertTrue(backfiller.persistStalled)
        assertTrue(requestedTrims.isEmpty())
        assertEquals(0, backfiller.pendingHistoricalAckCount)
        assertNull(backfiller.lastAckedTrim)
        assertTrue(logs.any { it.contains("failure=cursor_store_write") })
        assertTrue(logs.none { it.contains("TrimCursorPersistenceException") })
        assertTrue(logs.none { it.contains("trim cursor commit failed") })
    }
}
