package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Goal-formula tests for the Hydration tracker (MVP). Mirrors the Swift HydrationGoalTests so the daily
 * goal stays byte-parity across iOS and Android: drink-water baseline + effort bump + nearest-50
 * rounding + caps.
 *
 * Goldens are computed by hand from the closed-form rule:
 *   goal = round50(sexBaseline + clamp(round(effort/100 * 700), 0, 700))
 */
class HydrationGoalTest {

    // ── Sex baseline ────────────────────────────────────────────────────────────

    @Test fun baseline_male() = assertEquals(2960, HydrationGoal.baselineForSex("male"))
    @Test fun baseline_female() = assertEquals(2160, HydrationGoal.baselineForSex("female"))
    @Test fun baseline_nonbinary_is_other() = assertEquals(2560, HydrationGoal.baselineForSex("nonbinary"))
    @Test fun baseline_unknown_is_other() = assertEquals(2560, HydrationGoal.baselineForSex("unspecified"))
    @Test fun baseline_empty_is_other() = assertEquals(2560, HydrationGoal.baselineForSex(""))

    @Test fun baseline_is_case_and_space_insensitive() {
        assertEquals(2960, HydrationGoal.baselineForSex("  MALE "))
        assertEquals(2160, HydrationGoal.baselineForSex("Female"))
        assertEquals(2960, HydrationGoal.baselineForSex("M"))
        assertEquals(2160, HydrationGoal.baselineForSex("f"))
    }

    // ── Effort bump (round + cap) ────────────────────────────────────────────────

    @Test fun bump_null_effort_is_zero() = assertEquals(0, HydrationGoal.effortBump(null))
    @Test fun bump_zero_effort_is_zero() = assertEquals(0, HydrationGoal.effortBump(0.0))
    @Test fun bump_full_effort_is_max() = assertEquals(700, HydrationGoal.effortBump(100.0))

    @Test fun bump_mid_effort_rounds() {
        // 50/100 * 700 = 350
        assertEquals(350, HydrationGoal.effortBump(50.0))
        // 37/100 * 700 = 259
        assertEquals(259, HydrationGoal.effortBump(37.0))
        // 1/100 * 700 = 7
        assertEquals(7, HydrationGoal.effortBump(1.0))
    }

    @Test fun bump_clamps_out_of_range() {
        assertEquals(0, HydrationGoal.effortBump(-20.0))
        assertEquals(700, HydrationGoal.effortBump(150.0))
    }

    // ── Daily goal (baseline + bump, rounded to nearest 50) ───────────────────────

    @Test fun goal_no_effort_is_rounded_baseline() {
        assertEquals(2950, HydrationGoal.dailyGoalMl("male", null))
        assertEquals(2150, HydrationGoal.dailyGoalMl("female", null))
        assertEquals(2550, HydrationGoal.dailyGoalMl("nonbinary", null))
    }

    @Test fun goal_full_effort_caps_at_baseline_plus_700() {
        // 2960 + 700 = 3660 → 3650
        assertEquals(3650, HydrationGoal.dailyGoalMl("male", 100.0))
        // 2160 + 700 = 2860 → 2850
        assertEquals(2850, HydrationGoal.dailyGoalMl("female", 100.0))
    }

    @Test fun goal_rounds_to_nearest_50() {
        // male: 2960 + round(37/100*700=259) = 3219 → nearest 50 = 3200
        assertEquals(3200, HydrationGoal.dailyGoalMl("male", 37.0))
        // female: 2160 + round(63/100*700=441) = 2601 → nearest 50 = 2600
        assertEquals(2600, HydrationGoal.dailyGoalMl("female", 63.0))
        // other: 2560 + round(13/100*700=91) = 2651 → nearest 50 = 2650
        assertEquals(2650, HydrationGoal.dailyGoalMl("nonbinary", 13.0))
    }

    @Test fun goal_round_half_up() {
        // 3225 is exactly between 3200 and 3250 → rounds up to 3250.
        assertEquals(3250, HydrationGoal.roundToNearest(3225, 50))
        // 3224 → 3200, 3226 → 3250
        assertEquals(3200, HydrationGoal.roundToNearest(3224, 50))
        assertEquals(3250, HydrationGoal.roundToNearest(3226, 50))
    }

    // ── Quick-log amounts (the three tap sizes) ──────────────────────────────────

    @Test fun quick_log_amounts() {
        assertEquals(30, HydrationGoal.SIP_ML)
        assertEquals(237, HydrationGoal.CUP_ML)
        assertEquals(500, HydrationGoal.BOTTLE_ML)
    }

    @Test fun heat_bump_rejects_absolute_and_implausible_skin_temperature() {
        assertEquals(150, HydrationGoal.heatBumpMl(0.5))
        assertEquals(0, HydrationGoal.heatBumpMl(34.2))
        assertEquals(0, HydrationGoal.heatBumpMl(9.0))
        assertEquals(0, HydrationGoal.heatBumpMl(Double.POSITIVE_INFINITY))
    }
}
