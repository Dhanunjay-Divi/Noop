package com.noop.ui

import com.noop.analytics.SleepStageTotals
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.TimeZone

class SleepHistoricalTimezoneTest {
    private val savedTimeZone = TimeZone.getDefault()

    @Before
    fun useNewYork() {
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"))
    }

    @After
    fun restoreTimeZone() {
        TimeZone.setDefault(savedTimeZone)
    }

    @Test
    fun mainSleepUsesOffsetAtHistoricalWakeInsteadOfCurrentOffset() {
        // 2026-01-11 04:30...05:30 UTC = 23:30...00:30 EST, midpoint 00:00.
        val early = SleepSession(
            deviceId = "band",
            startTs = 1_768_105_800L,
            endTs = 1_768_109_400L,
        )
        // 2026-01-11 11:00...12:00 UTC = 06:00...07:00 EST, midpoint 06:30.
        val late = SleepSession(
            deviceId = "band",
            startTs = 1_768_129_200L,
            endTs = 1_768_132_800L,
        )
        val blocks = listOf(early, late)

        assertEquals(-18_000L, uiTzOffsetSec(late.endTs))
        assertEquals(
            early,
            blocks[SleepStageTotals.mainNightIndex(
                blocks.map { SleepStageTotals.NightBlock(it.startTs, it.endTs) },
                -14_400L,
            )!!],
        )
        assertEquals(late, mainSleepBlock(blocks))
        assertEquals(listOf(late), mainSleepGroup(blocks))
    }

    @Test
    fun selectedNightUsesBridgedGroupsFinalLocalWakeDay() {
        val zone = ZoneId.of("America/New_York")
        val firstStart = LocalDate.parse("2026-08-20")
            .atTime(20, 0)
            .atZone(zone)
            .toEpochSecond()
        val firstEnd = LocalDate.parse("2026-08-20")
            .atTime(23, 55)
            .atZone(zone)
            .toEpochSecond()
        val secondStart = LocalDate.parse("2026-08-21")
            .atTime(0, 5)
            .atZone(zone)
            .toEpochSecond()
        val finalWake = LocalDate.parse("2026-08-21")
            .atTime(1, 0)
            .atZone(zone)
            .toEpochSecond()
        val first = SleepSession(
            deviceId = "band",
            startTs = firstStart,
            endTs = firstEnd,
            stagesJSON = """{"awake":15,"light":120,"deep":60,"rem":40}""",
        )
        val second = SleepSession(
            deviceId = "band",
            startTs = secondStart,
            endTs = finalWake,
            stagesJSON = """{"awake":5,"light":30,"deep":10,"rem":10}""",
        )
        val wakeDay = DailyMetric(
            deviceId = "band",
            day = "2026-08-21",
            totalSleepMin = 270.0,
            deepMin = 70.0,
            remMin = 50.0,
            lightMin = 150.0,
        )

        val selected = selectNight(
            navDays = listOf(listOf(first, second)),
            days = listOf(wakeDay),
            offset = 0,
        )!!

        assertEquals(first, selected.session)
        assertEquals("2026-08-21", selected.dayKey)
        assertEquals(finalWake, selected.heroWakeTs)
    }
}
