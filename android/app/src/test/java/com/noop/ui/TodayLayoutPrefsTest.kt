package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-logic coverage for the Today section-order persistence (#today-layout): default order, encode/decode
 * round-trip, reorder, and the never-hide "insert missing section at its default position" invariant. No
 * Android context — these are the pure functions the editor + Today render rely on. Mirrors the macOS
 * TodayLayoutPrefs tests.
 */
class TodayLayoutPrefsTest {

    @Test
    fun emptyOrUnset_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(null))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(""))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("   "))
    }

    @Test
    fun encodeDecode_pinsHeroAndRoundTripsSecondaryOrder() {
        val reordered = listOf(
            TodaySection.HEART_RATE, TodaySection.HERO, TodaySection.YOUR_CARDS,
            TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
            TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS, TodaySection.WHY,
            TodaySection.TARGET, TodaySection.WATCH, TodaySection.JOURNAL,
        )
        val encoded = TodayLayoutPrefs.encode(reordered)
        assertEquals(
            "hero,heartRate,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,why,target,watch,journal",
            encoded,
        )
        assertEquals(
            listOf(
                TodaySection.HERO, TodaySection.HEART_RATE, TodaySection.YOUR_CARDS,
                TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
                TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS, TodaySection.WHY,
                TodaySection.TARGET, TodaySection.WATCH, TodaySection.JOURNAL,
            ),
            TodayLayoutPrefs.decodeOrder(encoded),
        )
    }

    @Test
    fun decode_normalizesOlderSavedHeroPosition() {
        assertEquals(
            listOf(
                TodaySection.HERO, TodaySection.LIVE_SESSION, TodaySection.WHY,
                TodaySection.TARGET, TodaySection.WATCH, TodaySection.SYNTHESIS,
                TodaySection.KEY_METRICS, TodaySection.WORKOUTS, TodaySection.HEART_RATE,
                TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS, TodaySection.JOURNAL,
            ),
            TodayLayoutPrefs.decodeOrder("heartRate,hero,yourCards"),
        )
    }

    /** The v1 upgrade path: an order saved by the FIRST cut (6 sections — no hero/liveSession, which were
     *  pinned then) must surface the two new sections at the TOP (their default position), not teleport
     *  them to the bottom of the user's saved order. */
    @Test
    fun decode_savedOrderFromFirstCut_insertsHeroAndSessionAtTheirDefaultPosition() {
        val firstCut = "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"
        assertEquals(
            listOf(
                TodaySection.HERO, TodaySection.LIVE_SESSION,
                TodaySection.WHY, TodaySection.TARGET, TodaySection.WATCH,
                TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.WORKOUTS,
                TodaySection.HEART_RATE, TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS,
                // journal follows everything saved -> appended:
                TodaySection.JOURNAL,
            ),
            TodayLayoutPrefs.decodeOrder(firstCut),
        )
    }

    @Test
    fun decode_insertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved_neverHides() {
        // A saved order that omits WORKOUTS + YOUR_CARDS (and the newer hero/liveSession) must still
        // surface all of them, each before the first saved section that follows it in the default order.
        val partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        val decoded = TodayLayoutPrefs.decodeOrder(partial)
        assertEquals(TodaySection.entries.size, decoded.size)
        assertEquals(
            listOf(
                // Every missing section before heartRate inserts in default order.
                TodaySection.HERO, TodaySection.LIVE_SESSION,
                TodaySection.WHY, TodaySection.TARGET, TodaySection.WATCH, TodaySection.WORKOUTS,
                TodaySection.HEART_RATE, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
                TodaySection.RECOVERY_VITALS,
                // yourCards then journal follow everything saved -> appended in default order.
                TodaySection.YOUR_CARDS, TodaySection.JOURNAL,
            ),
            decoded,
        )
    }

    @Test
    fun decode_dropsUnknownTokensAndCollapsesDuplicates() {
        val messy = "yourCards,BOGUS,yourCards,heartRate, ,heartRate"
        val decoded = TodayLayoutPrefs.decodeOrder(messy)
        assertEquals(TodaySection.entries.size, decoded.size)
        assertEquals(
            listOf(
                // Every missing section's default index precedes yourCards(7), so each inserts before it,
                // accumulating in default order; the saved yourCards→heartRate order is preserved at the end.
                TodaySection.HERO, TodaySection.LIVE_SESSION,
                TodaySection.WHY, TodaySection.TARGET, TodaySection.WATCH, TodaySection.SYNTHESIS,
                TodaySection.KEY_METRICS, TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS,
                TodaySection.YOUR_CARDS, TodaySection.HEART_RATE,
                // journal follows everything -> appended last.
                TodaySection.JOURNAL,
            ),
            decoded,
        )
    }

    @Test
    fun allJunk_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("nope,,zzz"))
    }

    /** defaultOrder must cover EVERY entry: the never-hide merge sorts by default index, so an entry
     *  missing from the default order could otherwise be dropped or mis-sorted. Twin of the Swift test. */
    @Test
    fun defaultOrderCoversEveryEntry() {
        assertEquals(TodaySection.entries.toSet(), TodaySection.defaultOrder.toSet())
        assertEquals(TodaySection.entries.size, TodaySection.defaultOrder.size)
    }

    @Test
    fun sectionRawKeysAreStableAndUnique() {
        val raws = TodaySection.entries.map { it.raw }
        assertEquals("raw keys must be unique (they're the persisted identity)", raws.size, raws.toSet().size)
        // Pin the exact wire strings — they cross the .noopbak boundary and must match macOS byte-for-byte.
        assertEquals(
            listOf(
                "hero", "liveSession", "synthesis", "why", "target", "watch", "keyMetrics",
                "workouts", "heartRate", "recoveryVitals", "yourCards", "journal",
            ),
            raws,
        )
    }
}
