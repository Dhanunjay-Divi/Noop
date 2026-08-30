package com.noop.ui

import com.noop.data.DailyMetric
import com.noop.data.WorkoutRow
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkoutActivityCalendarSummaryTest {
    private val zone = ZoneId.of("America/New_York")

    private fun epoch(day: String, hour: Int = 12): Long =
        LocalDateTime.parse("${day}T${hour.toString().padStart(2, '0')}:00:00")
            .atZone(zone)
            .toEpochSecond()

    private fun row(
        day: String,
        durationSeconds: Double? = 1_800.0,
        hour: Int = 12,
        fallbackSeconds: Long = 1_800,
    ): WorkoutRow {
        val start = epoch(day, hour)
        return WorkoutRow(
            deviceId = "test-noop",
            startTs = start,
            endTs = start + fallbackSeconds,
            sport = "Running",
            source = "manual",
            durationS = durationSeconds,
        )
    }

    @Test
    fun countsStartDaysAndTotalsOnlyTheInclusiveThirtyDayWindow() {
        val summary = workoutActivityCalendarSummary(
            rows = listOf(
                row("2026-07-29"),
                row("2026-07-30", durationSeconds = 3_600.0),
                row("2026-07-30", durationSeconds = 900.0),
                row("2026-08-27", durationSeconds = 1_200.0),
                row("2026-08-28"),
            ),
            firstDay = LocalDate.parse("2026-07-30"),
            lastDay = LocalDate.parse("2026-08-27"),
            zoneId = zone,
        )

        assertEquals(2, summary.activeDays)
        assertEquals(2, summary.countsByDay[LocalDate.parse("2026-07-30")])
        assertEquals(1, summary.countsByDay[LocalDate.parse("2026-08-27")])
        assertFalse(summary.countsByDay.containsKey(LocalDate.parse("2026-07-29")))
        assertEquals(95, summary.totalMinutes)
    }

    @Test
    fun malformedStoredDurationFallsBackToNonNegativeTimestampSpan() {
        val summary = workoutActivityCalendarSummary(
            rows = listOf(
                row("2026-08-27", durationSeconds = Double.NaN, fallbackSeconds = 125),
                row("2026-08-27", durationSeconds = -10.0, fallbackSeconds = -30),
            ),
            firstDay = LocalDate.parse("2026-08-27"),
            lastDay = LocalDate.parse("2026-08-27"),
            zoneId = zone,
        )

        assertEquals(1, summary.activeDays)
        assertEquals(2, summary.countsByDay[LocalDate.parse("2026-08-27")])
        assertEquals(2, summary.totalMinutes)
    }

    @Test
    fun workoutWindowsUseCalendarDaysAcrossDaylightSavingTime() {
        val window = WorkoutDateWindow.trailingCalendarDays(
            count = 7,
            endingOn = LocalDate.parse("2026-03-10"),
            zoneId = zone,
        )

        assertTrue(window.intersects(row("2026-03-04")))
        assertTrue(window.intersects(row("2026-03-10")))
        assertFalse(window.intersects(row("2026-03-03")))
        assertEquals((7 * 86_400L) - 3_600L, window.upperBound - window.lowerBound)
    }

    @Test
    fun customWorkoutDatesAreInclusiveAndKeepBoundaryOverlaps() {
        val window = WorkoutDateWindow.custom(
            first = LocalDate.parse("2026-08-10"),
            second = LocalDate.parse("2026-08-12"),
            zoneId = zone,
        )
        val crossesIntoRange = row(
            day = "2026-08-09",
            hour = 23,
            fallbackSeconds = 7_200,
        )

        assertTrue(window.intersects(crossesIntoRange))
        assertTrue(window.intersects(row("2026-08-12", hour = 23)))
        assertFalse(window.intersects(row("2026-08-13")))
    }

    @Test
    fun dayOverviewNormalizesFractionAndLegacyPercentEfficiency() {
        assertEquals(89.9, dayOverviewSleepEfficiencyPercent(0.899)!!, 1e-9)
        assertEquals(89.9, dayOverviewSleepEfficiencyPercent(89.9)!!, 1e-9)

        fun daily(efficiency: Double) = DailyMetric(
            deviceId = "test",
            day = "2026-08-28",
            totalSleepMin = 450.0,
            efficiency = efficiency,
            deepMin = 90.0,
            remMin = 105.0,
            lightMin = 255.0,
        )

        val canonical = dayOverviewSleepScore(daily(0.899))
        val legacy = dayOverviewSleepScore(daily(89.9))
        assertNotNull(canonical)
        assertNotNull(legacy)
        assertEquals(canonical!!, legacy!!, 1e-9)
    }

    @Test
    fun dayOverviewRejectsInvalidEfficiency() {
        assertNull(dayOverviewSleepEfficiencyPercent(-1.0))
        assertNull(dayOverviewSleepEfficiencyPercent(100.1))
    }

    @Test
    fun activityOverviewExcludesWholeDayHealthMetrics() {
        assertFalse(DayOverviewScope.ACTIVITY.includesWholeDayMetrics)
        assertTrue(DayOverviewScope.ALL.includesWholeDayMetrics)
    }

    @Test
    fun focusedOverviewScopesLoadAndFilterOnlyRelevantData() {
        assertTrue(DayOverviewScope.ACTIVITY.includesSessions)
        assertFalse(DayOverviewScope.ACTIVITY.loadsMetricRows)
        assertFalse(DayOverviewScope.RECOVERY.includesSessions)
        assertTrue(DayOverviewScope.RECOVERY.loadsMetricRows)
        assertTrue(DayOverviewScope.ENERGY.includesSessions)
        assertTrue(DayOverviewScope.ENERGY.loadsMetricRows)

        assertTrue(DayOverviewScope.SLEEP.includesSupplementalMetric("sleep_consistency"))
        assertFalse(DayOverviewScope.SLEEP.includesSupplementalMetric("protein_g"))
        assertFalse(DayOverviewScope.RECOVERY.includesSupplementalMetric("sleep_consistency"))
        assertTrue(DayOverviewScope.ENERGY.includesSupplementalMetric("basal_kcal"))
        assertFalse(DayOverviewScope.ENERGY.includesSupplementalMetric("active_kcal"))
        assertTrue(DayOverviewScope.NUTRITION.includesSupplementalMetric("protein_g"))
        assertFalse(DayOverviewScope.NUTRITION.includesSupplementalMetric("calories_in"))
    }
}
