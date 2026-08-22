package com.noop.alarm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

class WindDownSchedulerTest {

    private fun millis(
        zone: TimeZone,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
    ): Long = Calendar.getInstance(zone).apply {
        clear()
        set(year, month - 1, day, hour, minute, 0)
    }.timeInMillis

    @Test
    fun schedulesTodayWhenLocalTimeIsStillAhead() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 8, 22, 20, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 8, 22, 22, 0), next)
    }

    @Test
    fun schedulesTomorrowWhenLocalTimeHasPassed() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 8, 22, 23, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 8, 23, 22, 0), next)
    }

    @Test
    fun preservesWallClockAcrossSpringDstInsteadOfAddingTwentyFourHours() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 3, 7, 23, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 3, 8, 22, 0), next)
        assertEquals(23L * 60L * 60L * 1_000L, next - millis(zone, 2026, 3, 7, 22, 0))
    }

    @Test
    fun preservesWallClockAcrossFallDstInsteadOfAddingTwentyFourHours() {
        val zone = TimeZone.getTimeZone("America/New_York")
        val now = millis(zone, 2026, 10, 31, 23, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertEquals(millis(zone, 2026, 11, 1, 22, 0), next)
        assertEquals(25L * 60L * 60L * 1_000L, next - millis(zone, 2026, 10, 31, 22, 0))
    }

    @Test
    fun exactCurrentMinuteRollsForward() {
        val zone = TimeZone.getTimeZone("UTC")
        val now = millis(zone, 2026, 8, 22, 22, 0)

        val next = WindDownScheduler.nextOccurrenceEpochMillis(22 * 60, now, zone)

        assertTrue(next > now)
        assertEquals(millis(zone, 2026, 8, 23, 22, 0), next)
    }
}
