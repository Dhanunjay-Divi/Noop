package com.noop.ui

import com.noop.analytics.ReadinessEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * A1/S4/S5 parity twins of the iOS TodayChargeTapCollapseTests: the one-word readiness read kept on the
 * hero (#205), the collapsed "Synced from: ..." footer summary (S5), and full-catalog metric ordering.
 */
class TodayChargeTapCollapseTest {

    @Test
    fun readinessWord_mapsEveryLevel() {
        assertEquals("Aligned", readinessWord(ReadinessEngine.Level.PRIMED))
        assertEquals("Within range", readinessWord(ReadinessEngine.Level.BALANCED))
        assertEquals("Recheck", readinessWord(ReadinessEngine.Level.STRAINED))
        assertEquals("Multiple shifts", readinessWord(ReadinessEngine.Level.RUNDOWN))
    }

    @Test
    fun readinessWord_insufficientHasNoWord() {
        assertNull(readinessWord(ReadinessEngine.Level.INSUFFICIENT))
    }

    @Test
    fun syncedFromSummary_listsOnlySourcesWithData() {
        assertEquals(
            "Synced from: Noop Band, Apple Watch",
            syncedFromSummary(hasWhoop = true, hasApple = true, hasXiaomi = false),
        )
        assertEquals(
            "Synced from: Noop Band",
            syncedFromSummary(hasWhoop = true, hasApple = false, hasXiaomi = false),
        )
        assertEquals(
            "Synced from: Noop Band, Apple Watch, Mi Band",
            syncedFromSummary(hasWhoop = true, hasApple = true, hasXiaomi = true),
        )
    }

    @Test
    fun syncedFromSummary_appleHealthReadsAsAppleWatch() {
        assertEquals(
            "Synced from: Apple Watch",
            syncedFromSummary(hasWhoop = false, hasApple = true, hasXiaomi = false),
        )
    }

    @Test
    fun syncedFromSummary_healthConnectReadsAsHealthConnect() {
        // #176: a Health-Connect-only user must NOT see "Synced from: Apple Watch".
        assertEquals(
            "Synced from: Health Connect",
            syncedFromSummary(hasWhoop = false, hasApple = false, hasHealthConnect = true, hasXiaomi = false),
        )
        assertEquals(
            "Synced from: Noop Band, Health Connect",
            syncedFromSummary(hasWhoop = true, hasApple = false, hasHealthConnect = true, hasXiaomi = false),
        )
        assertEquals(
            "Synced from: Noop Band, Apple Watch, Health Connect",
            syncedFromSummary(hasWhoop = true, hasApple = true, hasHealthConnect = true, hasXiaomi = false),
        )
    }

    @Test
    fun syncedFromSummary_noSourcesIsHonest() {
        assertEquals(
            "No sources yet",
            syncedFromSummary(hasWhoop = false, hasApple = false, hasXiaomi = false),
        )
    }

    @Test
    fun expandedMetricsKeepPinsFirstAndRestoreTheWholeCatalog() {
        val pins = listOf(KeyMetric.STEPS, KeyMetric.HRV, KeyMetric.BLOOD_OXYGEN)
        val expanded = KeyMetricPrefs.catalogOrder(pins)
        assertEquals(pins, expanded.take(pins.size))
        assertEquals(KeyMetric.entries.toSet(), expanded.toSet())
        assertEquals(KeyMetric.entries.size, expanded.size)
    }
}
