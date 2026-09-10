package com.noop.ui

import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.ScoreConfidence
import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Test

class PlannedWorkoutTodayDemoTest {
    @Test
    fun fixtureReproducesTheCrossPlatformSleepAndCalendarScenario() {
        val zone = ZoneId.of("America/New_York")
        val fixture = requireNotNull(
            plannedWorkoutTodayDemoContext(
                dayKey = "2026-09-10",
                zoneId = zone,
            ),
        )
        assertEquals(372.0, fixture.recentSleep.first().minutes)
        assertEquals(450.0, fixture.recentSleep.drop(1).mapNotNull { it.minutes }.average(), 0.0)
        assertEquals(60L * 60L, fixture.workout.endSec - fixture.workout.startSec)

        val plan = DailyActionPlanner.plan(
            today = "2026-09-10",
            readiness = ReadinessEngine.Readiness(
                level = ReadinessEngine.Level.BALANCED,
                headline = "Within range",
                summary = "Available measured signals are close to your recent baseline.",
                signals = emptyList(),
                effortVariety = null,
                asOfDay = "2026-09-10",
                confidence = ScoreConfidence.SOLID,
                baselineDays = 14,
            ),
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = emptyList(),
            recentSleep = fixture.recentSleep,
            plannedWorkout = fixture.workout,
            nowSec = fixture.nowSec,
        )

        assertEquals(78, plan.workoutAdjustment?.sleepDeficitMinutes)
        val localStart = Instant.ofEpochSecond(fixture.workout.startSec).atZone(zone)
        assertEquals(17, localStart.hour)
        assertEquals(30, localStart.minute)
    }
}
