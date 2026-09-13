package com.noop.ui

import com.noop.data.DailyMetric
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrendsAxisLabelsTest {

    @Test fun fewerThanTwoDatesHasNoAxisLabels() {
        assertEquals(emptyList<TrendAxisLabel>(), trendAxisLabels(emptyList()))
        assertEquals(emptyList<TrendAxisLabel>(), trendAxisLabels(listOf("2026-07-16")))
    }

    @Test fun twoDatesUseThePlotEndpointsWithoutDuplicatingTheFirstDate() {
        assertEquals(
            listOf(
                TrendAxisLabel("2026-07-15", TrendAxisAnchor.START),
                TrendAxisLabel("2026-07-16", TrendAxisAnchor.END),
            ),
            trendAxisLabels(listOf("2026-07-15", "2026-07-16")),
        )
    }

    @Test fun longerRangesUseStartCenterAndEndAnchors() {
        assertEquals(
            listOf(
                TrendAxisLabel("2026-07-12", TrendAxisAnchor.START),
                TrendAxisLabel("2026-07-14", TrendAxisAnchor.CENTER),
                TrendAxisLabel("2026-07-16", TrendAxisAnchor.END),
            ),
            trendAxisLabels(
                listOf(
                    "2026-07-12",
                    "2026-07-13",
                    "2026-07-14",
                    "2026-07-15",
                    "2026-07-16",
                ),
            ),
        )
    }

    @Test fun snapshotUsesTodayAnchoredQuarterWithoutChangingMetricValues() {
        val days = listOf(
            metric("2026-06-14", hrv = 35.0, rhr = 55, recovery = 10.0, strain = 15.0),
            metric("2026-06-15", hrv = 40.0, rhr = 53, recovery = 20.0, strain = 30.0),
            metric("2026-09-12", hrv = 60.0, rhr = 48, recovery = 80.0, strain = 70.0),
        )

        val snapshot = buildTrendsSnapshot(
            days = days,
            selected = TrendsRange.Quarter,
            sleepPerfByDay = mapOf(
                "2026-06-14" to 65.0,
                "2026-06-15" to 75.0,
                "2026-09-12" to 90.0,
            ),
            today = LocalDate.parse("2026-09-12"),
        )

        assertEquals(listOf(20.0, 80.0), snapshot.recovery.values)
        assertEquals(listOf(40.0, 60.0), snapshot.hrv.values)
        assertEquals(listOf(53.0, 48.0), snapshot.rhr.values)
        assertEquals(listOf(30.0, 70.0), snapshot.strain.values)
        assertEquals(listOf(75.0, 90.0), snapshot.rest.values)
        assertEquals(TrendsRange.Quarter, snapshot.recovery.effective)
        assertFalse(snapshot.recovery.widened)
    }

    @Test fun snapshotWidensSparseQuarterToAllHistory() {
        val snapshot = buildTrendsSnapshot(
            days = listOf(metric("2025-01-01", recovery = 55.0)),
            selected = TrendsRange.Quarter,
            sleepPerfByDay = emptyMap(),
            today = LocalDate.parse("2026-09-12"),
        )

        assertEquals(listOf(55.0), snapshot.recovery.values)
        assertEquals(TrendsRange.All, snapshot.recovery.effective)
        assertTrue(snapshot.recovery.widened)
    }

    private fun metric(
        day: String,
        hrv: Double? = null,
        rhr: Int? = null,
        recovery: Double? = null,
        strain: Double? = null,
    ) = DailyMetric(
        deviceId = "test",
        day = day,
        restingHr = rhr,
        avgHrv = hrv,
        recovery = recovery,
        strain = strain,
    )
}
