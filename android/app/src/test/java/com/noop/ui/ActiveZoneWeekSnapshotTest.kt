package com.noop.ui

import com.noop.data.MetricSeriesRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ActiveZoneWeekSnapshotTest {
    private fun row(day: String, key: String, value: Double) =
        MetricSeriesRow("test-noop", day, key, value)

    @Test
    fun completeIncludedDaysAggregateAndMeasuredZeroSurvives() {
        val days = setOf("2026-08-25", "2026-08-26")
        val result = activeZoneWeekSnapshot(
            moderate = listOf(
                row("2026-08-25", "moderate", 30.0),
                row("2026-08-26", "moderate", 0.0),
                row("2026-08-19", "moderate", 999.0),
            ),
            vigorous = listOf(
                row("2026-08-25", "vigorous", 15.0),
                row("2026-08-26", "vigorous", 0.0),
            ),
            observed = listOf(
                row("2026-08-25", "observed", 600.0),
                row("2026-08-26", "observed", 720.0),
            ),
            includedDays = days,
        )!!

        assertEquals(2, result.daysWithData)
        assertEquals(30.0, result.minutes.moderateMinutes, 0.0)
        assertEquals(15.0, result.minutes.vigorousMinutes, 0.0)
        assertEquals(60.0, result.minutes.creditedMinutes, 0.0)
        assertEquals(1_320.0, result.minutes.observedMinutes, 0.0)
    }

    @Test
    fun partialOrMissingRowsStayMissing() {
        assertNull(
            activeZoneWeekSnapshot(
                moderate = listOf(row("2026-08-26", "moderate", 0.0)),
                vigorous = emptyList(),
                observed = listOf(row("2026-08-26", "observed", 600.0)),
                includedDays = setOf("2026-08-26"),
            ),
        )
        assertNull(activeZoneWeekSnapshot(emptyList(), emptyList(), emptyList(), setOf("2026-08-26")))
    }

    @Test
    fun upgradeGateForcesOneBoundedBackfill() {
        assertEquals("noop-active-zone-v1", ActiveZoneUpgradeGate.CURRENT_REVISION)
        assertEquals(21, ActiveZoneUpgradeGate.HISTORY_DAYS)
        assertTrue(ActiveZoneUpgradeGate.needsRescore(null))
        assertFalse(ActiveZoneUpgradeGate.needsRescore("noop-active-zone-v1"))
    }
}
