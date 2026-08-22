package com.noop.analytics

import kotlin.math.abs
import kotlin.math.ceil

enum class SleepGoalMode(val persistedValue: String) {
    TARGET("target"),
    BALANCE("balance"),
    EXTRA_OPPORTUNITY("extraOpportunity");

    companion object {
        fun fromPersisted(value: String?): SleepGoalMode =
            entries.firstOrNull { it.persistedValue == value } ?: BALANCE
    }
}

/**
 * One deterministic contract for tonight's sleep opportunity.
 *
 * This is deliberately not a clinical prescription. It combines the user's wake
 * time and explicit sleep target with a short wind-down buffer and, when enough
 * history exists, a bounded contribution from the recent arithmetic sleep balance.
 * Mirrors StrandAnalytics/SleepPlanner.swift value-for-value.
 */
data class SleepPlan(
    val wakeMinute: Int,
    val bedtimeMinute: Int,
    val windDownMinute: Int,
    val baseSleepMinutes: Int,
    val goalMode: SleepGoalMode,
    val recoveryMinutes: Int,
    val sleepOpportunityMinutes: Int,
    val debtBalanceMinutes: Double?,
    val historyNights: Int,
    val confidence: ScoreConfidence,
)

object SleepPlanner {
    const val MINIMUM_SLEEP_MINUTES = 5 * 60
    const val MAXIMUM_SLEEP_MINUTES = 11 * 60
    const val MAXIMUM_RECOVERY_MINUTES = 60
    const val RECOVERY_STEP_MINUTES = 15
    const val MINIMUM_DEBT_NIGHTS = 3
    const val SOLID_HISTORY_NIGHTS = 7

    fun plan(
        wakeMinute: Int,
        sleepTargetMinutes: Int,
        windDownLeadMinutes: Int,
        debtBalanceMinutes: Double?,
        historyNights: Int,
        goalMode: SleepGoalMode = SleepGoalMode.BALANCE,
    ): SleepPlan {
        val wake = wrappedMinute(wakeMinute)
        val base = sleepTargetMinutes.coerceIn(MINIMUM_SLEEP_MINUTES, MAXIMUM_SLEEP_MINUTES)
        val lead = windDownLeadMinutes.coerceIn(0, 120)
        val nights = historyNights.coerceAtLeast(0)
        val balanceRecovery = recoveryMinutes(debtBalanceMinutes, nights)
        val recovery = when (goalMode) {
            SleepGoalMode.TARGET -> 0
            SleepGoalMode.BALANCE -> balanceRecovery
            SleepGoalMode.EXTRA_OPPORTUNITY ->
                balanceRecovery.coerceAtLeast(30).coerceAtMost(MAXIMUM_RECOVERY_MINUTES)
        }
        val opportunity = base + recovery
        val bedtime = wrappedMinute(wake - opportunity)
        val windDown = wrappedMinute(bedtime - lead)
        val confidence = when {
            nights < MINIMUM_DEBT_NIGHTS -> ScoreConfidence.CALIBRATING
            nights < SOLID_HISTORY_NIGHTS -> ScoreConfidence.BUILDING
            else -> ScoreConfidence.SOLID
        }
        return SleepPlan(
            wakeMinute = wake,
            bedtimeMinute = bedtime,
            windDownMinute = windDown,
            baseSleepMinutes = base,
            goalMode = goalMode,
            recoveryMinutes = recovery,
            sleepOpportunityMinutes = opportunity,
            debtBalanceMinutes = debtBalanceMinutes,
            historyNights = nights,
            confidence = confidence,
        )
    }

    /**
     * Spread recent debt over the nights that produced it, round upward to an
     * actionable 15-minute increment, and cap tonight's addition at one hour.
     * A surplus, the ±30-minute deadband, or fewer than three nights adds nothing.
     */
    fun recoveryMinutes(debtBalanceMinutes: Double?, historyNights: Int): Int {
        val balance = debtBalanceMinutes ?: return 0
        if (historyNights < MINIMUM_DEBT_NIGHTS || balance >= -SleepDebt.ON_TARGET_BAND_MIN) return 0
        val averageDeficit = abs(balance) / historyNights.toDouble()
        val stepped = ceil(averageDeficit / RECOVERY_STEP_MINUTES).toInt() * RECOVERY_STEP_MINUTES
        return stepped.coerceIn(RECOVERY_STEP_MINUTES, MAXIMUM_RECOVERY_MINUTES)
    }

    fun wrappedMinute(minute: Int): Int {
        val day = 24 * 60
        return ((minute % day) + day) % day
    }

    /**
     * Signed shortest difference between tonight's planned midpoint and the midpoint observed in
     * prior main sleeps. This is behavioral timing context, not a chronotype or medical inference.
     */
    fun observedTimingShiftMinutes(plan: SleepPlan, habitualMidsleepSeconds: Long?): Int? {
        val seconds = habitualMidsleepSeconds ?: return null
        val observed = wrappedMinute((seconds / 60L).toInt())
        val planned = wrappedMinute(plan.bedtimeMinute + plan.sleepOpportunityMinutes / 2)
        var delta = planned - observed
        if (delta > 12 * 60) delta -= 24 * 60
        if (delta < -(12 * 60)) delta += 24 * 60
        return delta
    }
}
