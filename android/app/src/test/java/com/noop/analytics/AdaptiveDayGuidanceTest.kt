package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AdaptiveDayGuidanceTest {
    private val dayStart = 1_800_000_000L - (1_800_000_000L % 86_400L)

    private fun window(dayOffset: Int, onsetMinute: Int, durationMinutes: Int) =
        AdaptiveDayGuidance.SleepWindow(
            startSec = dayStart + dayOffset * 86_400L + onsetMinute * 60L,
            endSec = dayStart + dayOffset * 86_400L +
                (onsetMinute + durationMinutes) * 60L,
        )

    private fun input(
        sleepDays: List<AdaptiveDayGuidance.SleepDay> = emptyList(),
        windows: List<AdaptiveDayGuidance.SleepWindow> = emptyList(),
        change: AdaptiveDayGuidance.TimeZoneChange? = null,
    ) = AdaptiveDayGuidance.Input(
        today = "2027-01-15",
        nowSec = dayStart + 12 * 60 * 60L,
        currentTimeZoneOffsetSec = 0,
        sleepTargetMinutes = 8 * 60,
        sleepDays = sleepDays,
        sleepWindows = windows,
        timeZoneChange = change,
    )

    @Test fun twoHourTravelChangeWinsAndOneHourDstDoesNotTrigger() {
        val now = dayStart + 12 * 60 * 60L
        val travel = AdaptiveDayGuidance.recommendation(input(change =
            AdaptiveDayGuidance.TimeZoneChange(
                previousOffsetSec = -5 * 60 * 60,
                currentOffsetSec = 60 * 60,
                observedAtSec = now - 60,
            ),
        ))
        assertEquals(AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT, travel?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.STRONG, travel?.confidence)

        val dst = AdaptiveDayGuidance.recommendation(input(change =
            AdaptiveDayGuidance.TimeZoneChange(
                previousOffsetSec = -5 * 60 * 60,
                currentOffsetSec = -4 * 60 * 60,
                observedAtSec = now - 60,
            ),
        ))
        assertNull(dst)
    }

    @Test fun dateLineTravelUsesShortestWallClockShift() {
        assertEquals(
            2 * 60 * 60,
            AdaptiveDayGuidance.normalizedTravelDeltaSeconds(
                previousOffsetSec = 12 * 60 * 60,
                currentOffsetSec = -10 * 60 * 60,
            ),
        )
        assertEquals(
            0,
            AdaptiveDayGuidance.normalizedTravelDeltaSeconds(
                previousOffsetSec = -10 * 60 * 60,
                currentOffsetSec = 14 * 60 * 60,
            ),
        )

        val now = dayStart + 12 * 60 * 60L
        val twoHourShift = AdaptiveDayGuidance.recommendation(input(change =
            AdaptiveDayGuidance.TimeZoneChange(
                previousOffsetSec = 12 * 60 * 60,
                currentOffsetSec = -10 * 60 * 60,
                observedAtSec = now - 60,
            ),
        ))
        assertEquals(AdaptiveDayGuidance.Kind.TRAVEL_ADJUSTMENT, twoHourShift?.kind)

        val sameLocalClock = AdaptiveDayGuidance.recommendation(input(change =
            AdaptiveDayGuidance.TimeZoneChange(
                previousOffsetSec = -10 * 60 * 60,
                currentOffsetSec = 14 * 60 * 60,
                observedAtSec = now - 60,
            ),
        ))
        assertNull(sameLocalClock)
    }

    @Test fun lateShortNightNeedsPersonalRoutineAndOutranksShortSleep() {
        val windows = (2..8).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        } + window(0, 60, 5 * 60)

        val result = AdaptiveDayGuidance.recommendation(input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-15", 300.0)),
            windows = windows,
        ))

        assertEquals(AdaptiveDayGuidance.Kind.ROUTINE_RECOVERY, result?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.STRONG, result?.confidence)
        assertEquals(
            listOf("personal-sleep-timing", "later-onset", "shorter-sleep"),
            result?.evidence,
        )
    }

    @Test fun routineShiftFailsClosedWithoutFivePriorNights() {
        val windows = (2..5).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        } + window(0, 60, 5 * 60)

        val result = AdaptiveDayGuidance.recommendation(input(windows = windows))

        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, result?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.BUILDING, result?.confidence)
    }

    @Test fun fragmentedWindowsCannotImpersonateFiveRoutineNights() {
        val history = (-4..-2).flatMap { dayOffset ->
            listOf(
                window(dayOffset, 20 * 60, 3 * 60),
                window(dayOffset, 23 * 60 + 30, 7 * 60),
            )
        }
        val result = AdaptiveDayGuidance.recommendation(input(
            windows = history + window(0, 60, 5 * 60),
        ))

        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, result?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.BUILDING, result?.confidence)
    }

    @Test fun currentMeasuredShortSleepTriggersButStaleDayDoesNot() {
        val current = AdaptiveDayGuidance.recommendation(input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-15", 360.0)),
        ))
        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, current?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.STRONG, current?.confidence)

        val stale = AdaptiveDayGuidance.recommendation(input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-14", 300.0)),
        ))
        assertNull(stale)
    }

    @Test fun currentMeasuredSleepDoesNotBorrowAStaleWindowTimestamp() {
        val value = input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-15", 360.0)),
            windows = listOf(window(-10, 23 * 60, 6 * 60)),
        )

        val result = AdaptiveDayGuidance.recommendation(value)

        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, result?.kind)
        assertEquals(value.nowSec, result?.observedAtSec)
    }
}
