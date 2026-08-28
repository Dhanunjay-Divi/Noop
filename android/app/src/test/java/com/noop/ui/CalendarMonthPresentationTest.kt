package com.noop.ui

import com.noop.data.DailyMetric
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarMonthPresentationTest {
    @Test
    fun everyCalendarMetricOpensItsMatchingDayOverview() {
        assertEquals(DayOverviewScope.ACTIVITY, CalendarMetric.EFFORT.dayOverviewScope())
        assertEquals(DayOverviewScope.RECOVERY, CalendarMetric.RECOVERY.dayOverviewScope())
        assertEquals(DayOverviewScope.SLEEP, CalendarMetric.SLEEP.dayOverviewScope())
        assertEquals(DayOverviewScope.STRESS, CalendarMetric.STRESS.dayOverviewScope())
        assertEquals(DayOverviewScope.ENERGY, CalendarMetric.ENERGY.dayOverviewScope())
        assertEquals(DayOverviewScope.NUTRITION, CalendarMetric.NUTRITION.dayOverviewScope())
    }

    @Test
    fun calendarCellsShowTheMetricAndCompactLargeTotals() {
        assertEquals("72", calendarMetricCellValue(CalendarMetric.RECOVERY, 71.6, Locale.US))
        assertEquals("1.4", calendarMetricCellValue(CalendarMetric.STRESS, 1.36, Locale.US))
        assertEquals("1.2k", calendarMetricCellValue(CalendarMetric.ENERGY, 1_249.0, Locale.US))
        assertEquals("2k", calendarMetricCellValue(CalendarMetric.NUTRITION, 2_000.0, Locale.US))
        assertEquals("1k", calendarMetricCellValue(CalendarMetric.ENERGY, 999.6, Locale.US))
    }

    @Test
    fun fixedScaleMetricsKeepTheirOwnMeaning() {
        assertEquals(
            72.5,
            calendarNormalizedProgress(CalendarMetric.RECOVERY, 72.5, emptyList()),
            1e-9,
        )
        assertEquals(
            50.0,
            calendarNormalizedProgress(CalendarMetric.STRESS, 1.5, emptyList()),
            1e-9,
        )
        assertEquals(
            100.0,
            calendarNormalizedProgress(CalendarMetric.EFFORT, 140.0, emptyList()),
            1e-9,
        )
    }

    @Test
    fun quantityMetricsScaleOnlyAgainstObservedPositiveDays() {
        assertEquals(
            50.0,
            calendarNormalizedProgress(
                CalendarMetric.ENERGY,
                400.0,
                listOf(Double.NaN, -1.0, 400.0, 800.0),
            ),
            1e-9,
        )
        assertEquals(
            0.0,
            calendarNormalizedProgress(CalendarMetric.NUTRITION, 0.0, emptyList()),
            1e-9,
        )
    }

    @Test
    fun missingCalendarValuesRemainMissingRatherThanZero() {
        val day = "2026-08-28"
        val snapshot = CalendarMonthSnapshot(
            dailyByDay = mapOf(
                day to DailyMetric(
                    deviceId = "test",
                    day = day,
                    recovery = 81.0,
                    strain = 43.0,
                ),
            ),
        )

        assertEquals(81.0, calendarMetricValue(CalendarMetric.RECOVERY, day, snapshot)!!, 1e-9)
        assertEquals(43.0, calendarMetricValue(CalendarMetric.EFFORT, day, snapshot)!!, 1e-9)
        assertNull(calendarMetricValue(CalendarMetric.SLEEP, day, snapshot))
        assertNull(calendarMetricValue(CalendarMetric.ENERGY, day, snapshot))
    }

    @Test
    fun calendarUsesOnlyReliableDerivedStressAndLetsImportedValuesWin() {
        val history = (1..8).map { number ->
            val key = "2026-08-%02d".format(number)
            DailyMetric(
                deviceId = "test",
                day = key,
                restingHr = 58 + number % 4,
                avgHrv = 64.0 + (number * 2) % 5,
            )
        }
        val derived = calendarStressByDay(
            days = history,
            preferred = emptyMap(),
            fromDay = "2026-08-01",
            throughDay = "2026-08-31",
        )
        assertFalse(derived.containsKey("2026-08-07"))
        assertTrue(derived.containsKey("2026-08-08"))

        val imported = calendarStressByDay(
            days = history,
            preferred = mapOf("2026-08-08" to 2.75),
            fromDay = "2026-08-01",
            throughDay = "2026-08-31",
        )
        assertEquals(2.75, imported["2026-08-08"]!!, 1e-9)

        val oneSignal = history.map { it.copy(avgHrv = null) }
        assertTrue(
            calendarStressByDay(
                days = oneSignal,
                preferred = emptyMap(),
                fromDay = "2026-08-01",
                throughDay = "2026-08-31",
            ).isEmpty(),
        )
    }
}
