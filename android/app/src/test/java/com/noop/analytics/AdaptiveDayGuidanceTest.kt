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
        sleepTargetMinutes: Int = 8 * 60,
        sleepTargetIsExplicit: Boolean = true,
        today: String = "2027-01-15",
        nowSec: Long = dayStart + 12 * 60 * 60L,
        routineHistoryStartSec: Long? = null,
    ) = AdaptiveDayGuidance.Input(
        today = today,
        nowSec = nowSec,
        currentTimeZoneOffsetSec = 0,
        sleepTargetMinutes = sleepTargetMinutes,
        sleepTargetIsExplicit = sleepTargetIsExplicit,
        sleepDays = sleepDays,
        sleepWindows = windows,
        timeZoneChange = change,
        routineHistoryStartSec = routineHistoryStartSec,
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
            windows = listOf(window(-1, 23 * 60, 6 * 60)),
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

        assertNull(result)
    }

    @Test fun currentMeasuredSleepDoesNotBorrowFreshWindowFromAnotherDay() {
        val result = AdaptiveDayGuidance.recommendation(input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-16", 360.0)),
            windows = listOf(window(-1, 23 * 60, 6 * 60)),
            today = "2027-01-16",
        ))

        assertNull(result)
    }

    @Test fun implicitReferenceTargetDoesNotTriggerTargetBasedGuidance() {
        val result = AdaptiveDayGuidance.recommendation(input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-15", 360.0)),
            windows = listOf(window(-1, 23 * 60, 6 * 60)),
            sleepTargetIsExplicit = false,
        ))

        assertNull(result)
    }

    @Test fun lateNightThatIsNotShorterThanPersonalPatternIsNotRoutineRecovery() {
        val history = (2..8).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 6 * 60)
        }
        val result = AdaptiveDayGuidance.recommendation(input(
            windows = history + window(0, 60, 6 * 60),
        ))

        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, result?.kind)
    }

    @Test fun fragmentedLatestNightUsesCombinedDuration() {
        val history = (2..8).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        }
        val latest = listOf(
            window(0, 60, 4 * 60),
            window(0, 5 * 60, 4 * 60),
        )

        assertNull(AdaptiveDayGuidance.recommendation(input(windows = history + latest)))
    }

    @Test fun nearbySubThreeHourFragmentsMergeBeforeEligibilityAndKeepEarliestOnset() {
        val history = (2..8).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        }
        val latest = listOf(
            window(-1, 23 * 60, 2 * 60),
            window(0, 2 * 60, 5 * 60),
        )

        assertNull(AdaptiveDayGuidance.recommendation(input(
            windows = history + latest,
            sleepTargetIsExplicit = false,
        )))
    }

    @Test fun distantMorningNapDoesNotExtendTheOvernightCluster() {
        val result = AdaptiveDayGuidance.recommendation(input(
            windows = listOf(
                window(-1, 23 * 60, 5 * 60),
                window(0, 8 * 60, 2 * 60),
            ),
            sleepTargetMinutes = 6 * 60 + 30,
        ))

        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, result?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.BUILDING, result?.confidence)
    }

    @Test fun shortSessionCannotPromoteDailyAggregateToStrongEvidence() {
        val result = AdaptiveDayGuidance.recommendation(input(
            sleepDays = listOf(AdaptiveDayGuidance.SleepDay("2027-01-15", 360.0)),
            windows = listOf(window(0, 60, 3 * 60)),
        ))

        assertEquals(AdaptiveDayGuidance.Kind.SLEEP_RECOVERY, result?.kind)
        assertEquals(AdaptiveDayGuidance.Confidence.BUILDING, result?.confidence)
    }

    @Test fun travelResetExcludesOldZoneHistoryUntilNewRoutineBuilds() {
        val resetAt = dayStart - 8L * 86_400L
        val oldHistory = (9..14).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        }
        val newHistory = (2..7).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        }
        val latest = window(0, 60, 5 * 60)

        assertNull(AdaptiveDayGuidance.recommendation(input(
            windows = oldHistory + latest,
            sleepTargetIsExplicit = false,
            routineHistoryStartSec = resetAt,
        )))
        assertEquals(
            AdaptiveDayGuidance.Kind.ROUTINE_RECOVERY,
            AdaptiveDayGuidance.recommendation(input(
                windows = newHistory + latest,
                sleepTargetIsExplicit = false,
                routineHistoryStartSec = resetAt,
            ))?.kind,
        )
    }

    @Test fun travelResetExcludesWindowThatStartedBeforeTheReset() {
        val crossing = window(-6, 23 * 60, 8 * 60)
        val resetAt = crossing.startSec + 2 * 60 * 60L
        val postResetHistory = (2..5).map { nightsAgo ->
            window(-nightsAgo, 23 * 60, 8 * 60)
        }
        val latest = window(0, 60, 5 * 60)

        assertNull(AdaptiveDayGuidance.recommendation(input(
            windows = listOf(crossing) + postResetHistory + latest,
            sleepTargetIsExplicit = false,
            routineHistoryStartSec = resetAt,
        )))
    }
}
