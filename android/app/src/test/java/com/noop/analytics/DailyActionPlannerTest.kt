package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyActionPlannerTest {
    private val today = "2026-08-22"

    private fun readiness(
        level: ReadinessEngine.Level = ReadinessEngine.Level.BALANCED,
        confidence: ScoreConfidence = ScoreConfidence.SOLID,
        day: String? = "2026-08-22",
    ) = ReadinessEngine.Readiness(
        level = level,
        headline = "Within range",
        summary = "Available measured signals are close to your recent baseline.",
        signals = listOf(
            ReadinessEngine.Signal("hrv", "HRV", "in your normal range", ReadinessEngine.Flag.NEUTRAL),
            ReadinessEngine.Signal("rhr", "Resting HR", "in your normal range", ReadinessEngine.Flag.NEUTRAL),
        ),
        effortVariety = null,
        asOfDay = day,
        confidence = confidence,
        baselineDays = 20,
    )

    private fun history(
        count: Int = 14,
        value: (Int) -> Double = { if (it % 2 == 0) 40.0 else 60.0 },
    ) = (1..count).map {
        DailyActionPlanner.EffortDay("2026-08-%02d".format(it), value(it))
    }

    private fun plannedWorkout(
        day: String = "2026-08-22",
        startSec: Long = 1_003_600L,
        endSec: Long = 1_007_200L,
    ) = DailyActionPlanner.PlannedWorkout(day, startSec, endSec)

    private fun usualSleep(todayMinutes: Double = 360.0) =
        (14..20).map {
            DailyActionPlanner.SleepDay("2026-08-%02d".format(it), 450.0)
        } + DailyActionPlanner.SleepDay(today, todayMinutes)

    @Test fun readyRangeUsesPersonalHistoryAndNeverRisesForPrimed() {
        val balanced = DailyActionPlanner.plan(today, readiness(), DailyActionPlanner.CheckIn.AS_USUAL, history())
        val primed = DailyActionPlanner.plan(
            today, readiness(ReadinessEngine.Level.PRIMED), DailyActionPlanner.CheckIn.AS_USUAL, history(),
        )
        assertEquals(DailyActionPlanner.Availability.READY, balanced.availability)
        assertEquals(DailyActionPlanner.EffortRange(40, 60), balanced.target)
        assertEquals(ScoreConfidence.SOLID, balanced.confidence)
        assertEquals(balanced.target, primed.target)
        assertTrue(primed.limitations.any { it.contains("never raises") })
    }

    @Test fun sameDaySelfCheckIsRequired() {
        val plan = DailyActionPlanner.plan(
            today, readiness(), DailyActionPlanner.CheckIn.UNANSWERED, history(),
        )
        assertEquals(DailyActionPlanner.Availability.CHECK_IN_NEEDED, plan.availability)
        assertNull(plan.target)
        assertEquals(DailyActionPlanner.Action.COMPLETE_CHECK_IN, plan.action)
    }

    @Test fun howUserFeelsOverridesWearableRead() {
        val below = DailyActionPlanner.plan(
            today, readiness(ReadinessEngine.Level.PRIMED),
            DailyActionPlanner.CheckIn.BELOW_USUAL, history(),
        )
        val unwell = DailyActionPlanner.plan(
            today, readiness(ReadinessEngine.Level.PRIMED),
            DailyActionPlanner.CheckIn.PAIN_OR_UNWELL, history(),
        )
        assertEquals(DailyActionPlanner.Availability.RECOVERY_SHIFT, below.availability)
        assertEquals(DailyActionPlanner.Action.CHOOSE_EASY_DAY, below.action)
        assertNull(below.target)
        assertEquals(DailyActionPlanner.Availability.STOP, unwell.availability)
        assertEquals(DailyActionPlanner.Action.STOP_AND_ASSESS, unwell.action)
        assertNull(unwell.target)
    }

    @Test fun measuredRecoveryShiftWithholdsInsteadOfLoweringTarget() {
        listOf(ReadinessEngine.Level.STRAINED, ReadinessEngine.Level.RUNDOWN).forEach { level ->
            val plan = DailyActionPlanner.plan(
                today, readiness(level), DailyActionPlanner.CheckIn.AS_USUAL, history(),
            )
            assertEquals(DailyActionPlanner.Availability.RECOVERY_SHIFT, plan.availability)
            assertNull(plan.target)
            assertEquals(DailyActionPlanner.Action.CHOOSE_EASY_DAY, plan.action)
        }
    }

    @Test fun staleOrThinEvidenceNeverProducesRange() {
        val stale = DailyActionPlanner.plan(
            today, readiness(day = "2026-08-21"), DailyActionPlanner.CheckIn.AS_USUAL, history(),
        )
        val oneSignal = DailyActionPlanner.plan(
            today, readiness(confidence = ScoreConfidence.BUILDING),
            DailyActionPlanner.CheckIn.AS_USUAL, history(),
        )
        val thinHistory = DailyActionPlanner.plan(
            today, readiness(), DailyActionPlanner.CheckIn.AS_USUAL, history(6),
        )
        assertNull(stale.target)
        assertNull(oneSignal.target)
        assertNull(thinHistory.target)
        assertEquals(DailyActionPlanner.Availability.CALIBRATING, thinHistory.availability)
    }

    @Test fun historyWindowExcludesTodayFutureInvalidAndAveragesDuplicates() {
        val rows = history(7) { 50.0 } + listOf(
            DailyActionPlanner.EffortDay("2026-08-01", 70.0),
            DailyActionPlanner.EffortDay(today, 100.0),
            DailyActionPlanner.EffortDay("2026-08-23", 100.0),
            DailyActionPlanner.EffortDay("2026-07-20", 100.0),
            DailyActionPlanner.EffortDay("not-a-day", 100.0),
            DailyActionPlanner.EffortDay("2026-08-08", 101.0),
        )
        val values = DailyActionPlanner.effortValues(rows, today)
        assertEquals(7, values.size)
        assertEquals(60.0, values.first(), 0.0)
        assertFalse(values.contains(100.0))
    }

    @Test fun stableHistoryGetsUsefulBoundedRange() {
        assertEquals(
            DailyActionPlanner.EffortRange(0, 10),
            DailyActionPlanner.planningRange(List(7) { 0.0 }),
        )
        assertEquals(
            DailyActionPlanner.EffortRange(90, 100),
            DailyActionPlanner.planningRange(List(7) { 100.0 }),
        )
    }

    @Test fun oneSleepActionUsesSupportedPlannerRecovery() {
        val normal = DailyActionPlanner.plan(
            today, readiness(), DailyActionPlanner.CheckIn.AS_USUAL, history(),
            sleepRecoveryMinutes = 15, sleepConfidence = ScoreConfidence.SOLID,
        )
        val recovery = DailyActionPlanner.plan(
            today, readiness(), DailyActionPlanner.CheckIn.AS_USUAL, history(),
            sleepRecoveryMinutes = 30, sleepConfidence = ScoreConfidence.BUILDING,
        )
        assertEquals(DailyActionPlanner.Action.KEEP_SLEEP_WINDOW, normal.action)
        assertEquals(DailyActionPlanner.Action.PROTECT_EXTRA_SLEEP, recovery.action)
        assertEquals(DailyActionPlanner.EvidenceSource.SLEEP_PLAN, recovery.evidence.last().source)
    }

    @Test fun plannedWorkoutUsesPersonalUsualSleepWhenHistoryIsSupported() {
        val plan = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(),
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = history(),
            recentSleep = usualSleep(),
            plannedWorkout = plannedWorkout(),
            nowSec = 1_000_000L,
        )

        assertEquals(
            DailyActionPlanner.WorkoutAdjustment(
                startSec = 1_003_600L,
                durationMinutes = 60,
                reason = DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT,
                measuredSleepMinutes = 360,
                referenceSleepMinutes = 450,
                sleepDeficitMinutes = 90,
                sleepReference = DailyActionPlanner.SleepReference.PERSONAL_USUAL,
                confidence = ScoreConfidence.SOLID,
            ),
            plan.workoutAdjustment,
        )
    }

    @Test fun plannedWorkoutFallsBackToExplicitSleepTargetWhileBaselineBuilds() {
        val plan = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(),
            checkIn = DailyActionPlanner.CheckIn.UNANSWERED,
            recentEffort = emptyList(),
            recentSleep = listOf(DailyActionPlanner.SleepDay(today, 410.0)),
            sleepTargetMinutes = 480,
            sleepTargetIsExplicit = true,
            plannedWorkout = plannedWorkout(),
            nowSec = 1_000_000L,
        )

        assertEquals(DailyActionPlanner.Availability.CHECK_IN_NEEDED, plan.availability)
        assertEquals(
            DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT,
            plan.workoutAdjustment?.reason,
        )
        assertEquals(70, plan.workoutAdjustment?.sleepDeficitMinutes)
        assertEquals(
            DailyActionPlanner.SleepReference.EXPLICIT_TARGET,
            plan.workoutAdjustment?.sleepReference,
        )
        assertEquals(ScoreConfidence.BUILDING, plan.workoutAdjustment?.confidence)
    }

    @Test fun implicitDefaultSleepTargetCannotCreatePersonalizedDeficit() {
        val plan = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(),
            checkIn = DailyActionPlanner.CheckIn.UNANSWERED,
            recentEffort = emptyList(),
            recentSleep = listOf(DailyActionPlanner.SleepDay(today, 360.0)),
            sleepTargetMinutes = 480,
            plannedWorkout = plannedWorkout(),
            nowSec = 1_000_000L,
        )

        assertNull(plan.workoutAdjustment)
    }

    @Test fun recoveryShiftCanSupportWorkoutAdjustmentWithoutSleepDuration() {
        val plan = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(
                level = ReadinessEngine.Level.STRAINED,
                confidence = ScoreConfidence.BUILDING,
            ),
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = history(),
            plannedWorkout = plannedWorkout(),
            nowSec = 1_000_000L,
        )

        assertEquals(
            DailyActionPlanner.WorkoutAdjustmentReason.RECOVERY_SHIFT,
            plan.workoutAdjustment?.reason,
        )
        assertNull(plan.workoutAdjustment?.measuredSleepMinutes)
        assertEquals(ScoreConfidence.BUILDING, plan.workoutAdjustment?.confidence)
    }

    @Test fun thinSleepDifferenceAndInvalidWorkoutTimingFailClosed() {
        val thinDifference = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(),
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = history(),
            recentSleep = usualSleep(todayMinutes = 406.0),
            plannedWorkout = plannedWorkout(),
            nowSec = 1_000_000L,
        )
        val alreadyStarted = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(level = ReadinessEngine.Level.STRAINED),
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = history(),
            plannedWorkout = plannedWorkout(startSec = 999_000L, endSec = 1_002_600L),
            nowSec = 1_000_000L,
        )
        val wrongDay = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(level = ReadinessEngine.Level.STRAINED),
            checkIn = DailyActionPlanner.CheckIn.AS_USUAL,
            recentEffort = history(),
            plannedWorkout = plannedWorkout(day = "2026-08-23"),
            nowSec = 1_000_000L,
        )

        assertNull(thinDifference.workoutAdjustment)
        assertNull(alreadyStarted.workoutAdjustment)
        assertNull(wrongDay.workoutAdjustment)
    }

    @Test fun painOrUnwellSuppressesPlannedWorkoutAdjustment() {
        val plan = DailyActionPlanner.plan(
            today = today,
            readiness = readiness(level = ReadinessEngine.Level.STRAINED),
            checkIn = DailyActionPlanner.CheckIn.PAIN_OR_UNWELL,
            recentEffort = history(),
            recentSleep = usualSleep(),
            plannedWorkout = plannedWorkout(),
            nowSec = 1_000_000L,
        )

        assertEquals(DailyActionPlanner.Availability.STOP, plan.availability)
        assertNull(plan.workoutAdjustment)
    }
}
