package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/** Value-for-value parity with StrandAnalytics SleepPlannerTests. */
class SleepPlannerTest {
    @Test
    fun basicPlan_wrapsAcrossMidnight() {
        val plan = SleepPlanner.plan(7 * 60, 8 * 60, 30, 0.0, 7)
        assertEquals(23 * 60, plan.bedtimeMinute)
        assertEquals(22 * 60 + 30, plan.windDownMinute)
        assertEquals(8 * 60, plan.sleepOpportunityMinutes)
        assertEquals(ScoreConfidence.SOLID, plan.confidence)
    }

    @Test
    fun debt_addsRoundedBoundedRecovery() {
        val plan = SleepPlanner.plan(6 * 60 + 30, 8 * 60, 45, -210.0, 7)
        assertEquals(30, plan.recoveryMinutes)
        assertEquals(8 * 60 + 30, plan.sleepOpportunityMinutes)
        assertEquals(22 * 60, plan.bedtimeMinute)
        assertEquals(21 * 60 + 15, plan.windDownMinute)
    }

    @Test
    fun largeDebt_cannotAddMoreThanOneHour() {
        assertEquals(60, SleepPlanner.recoveryMinutes(-2_000.0, 7))
    }

    @Test
    fun surplusAndBalancedHistory_neverReduceTarget() {
        listOf(480.0, 0.0, -30.0).forEach { balance ->
            val plan = SleepPlanner.plan(420, 480, 30, balance, 14)
            assertEquals(0, plan.recoveryMinutes)
            assertEquals(480, plan.sleepOpportunityMinutes)
        }
    }

    @Test
    fun thinHistory_calibratesWithoutDebtAdjustment() {
        val plan = SleepPlanner.plan(420, 480, 30, -500.0, 2)
        assertEquals(0, plan.recoveryMinutes)
        assertEquals(ScoreConfidence.CALIBRATING, plan.confidence)
    }

    @Test
    fun goalModes_areExplicitAndBounded() {
        val target = SleepPlanner.plan(
            420, 480, 30, -420.0, 7, SleepGoalMode.TARGET,
        )
        assertEquals(0, target.recoveryMinutes)
        assertEquals(480, target.sleepOpportunityMinutes)

        val balance = SleepPlanner.plan(
            420, 480, 30, -420.0, 7, SleepGoalMode.BALANCE,
        )
        assertEquals(60, balance.recoveryMinutes)

        val extra = SleepPlanner.plan(
            420, 480, 30, 120.0, 7, SleepGoalMode.EXTRA_OPPORTUNITY,
        )
        assertEquals(30, extra.recoveryMinutes)
        assertEquals(510, extra.sleepOpportunityMinutes)
    }

    @Test
    fun observedTiming_usesShortestCircularShift() {
        val plan = SleepPlanner.plan(
            7 * 60, 8 * 60, 30, null, 7, SleepGoalMode.TARGET,
        )
        assertEquals(0, SleepPlanner.observedTimingShiftMinutes(plan, 3 * 60 * 60L))
        assertEquals(240, SleepPlanner.observedTimingShiftMinutes(plan, 23 * 60 * 60L))
        assertEquals(null, SleepPlanner.observedTimingShiftMinutes(plan, null))
    }

    @Test
    fun inputs_clampToSafeBounds() {
        val short = SleepPlanner.plan(-1, 60, -20, null, -3)
        assertEquals(1439, short.wakeMinute)
        assertEquals(300, short.baseSleepMinutes)
        assertEquals(short.bedtimeMinute, short.windDownMinute)
        assertEquals(0, short.historyNights)

        val long = SleepPlanner.plan(2_000, 1_000, 999, null, 4)
        assertEquals(560, long.wakeMinute)
        assertEquals(660, long.baseSleepMinutes)
        assertEquals(SleepPlanner.wrappedMinute(long.bedtimeMinute - 120), long.windDownMinute)
        assertEquals(ScoreConfidence.BUILDING, long.confidence)
    }
}
