package com.noop.analytics

import kotlin.math.roundToInt

/**
 * HydrationGoal — the pure, testable daily fluid-goal engine for the Hydration tracker (MVP).
 *
 * Kotlin twin of the Swift `HydrationGoal` helper; keep every constant + rounding rule BYTE-IDENTICAL so
 * iOS and Android resolve the same goal from the same inputs. No I/O, no Android types — a closed-form
 * function over the user's biological sex and today's Effort/strain score, unit-tested on the JVM.
 *
 * Daily GOAL (ml) = sexBaseline + effortBump, rounded to the nearest 50.
 *   - sexBaseline: male 2960, female 2160, unspecified/other 2560 (read from the profile sex field;
 *     `UserProfile.sex` carries "male" | "female" | "nonbinary"). These are DRINK-water targets: the
 *     EFSA/IOM total-water references (3700/2700/3200) minus the ~20% obtained from food, so the number
 *     shown is what the user must actually drink. Do not restore the raw total-water figures here.
 *   - effortBump: when today's Effort/strain (0..100) is available, round(effort / 100 * 700), capped
 *     to 0..700; when there's no Effort yet, 0.
 *
 * The output never depends on how much the user has logged — it's a TARGET, derived only from the body
 * profile and the day's load. Logging totals live in the metric-series store, not here.
 */
object HydrationGoal {

    // ACCURACY CORRECTION (2026-08-22, peer review): 3700/2700/3200 ml are the IOM(2005)/EFSA TOTAL WATER
    // Adequate Intakes and INCLUDE the ~20% of daily water that comes from FOOD. NOOP logs DRINKS, so
    // using them directly over-stated the target by ~500-800 ml and disagreed with the 35 ml/kg weight
    // path by ~1 L. The beverage fraction converts them onto the drink-water construct.
    // BYTE-IDENTICAL to the Swift twin.

    /** IOM/EFSA total-water Adequate Intakes (ml/day) — all sources, food included. */
    const val TOTAL_WATER_AI_MALE: Int = 3700
    const val TOTAL_WATER_AI_FEMALE: Int = 2700
    const val TOTAL_WATER_AI_OTHER: Int = 3200

    /** Share of total water intake that comes from beverages (~80%; the rest from food). */
    const val BEVERAGE_FRACTION_PERCENT: Int = 80

    /** Baseline DRINK-water targets (ml) = total-water AI * beverage fraction. male ~2960, female ~2160. */
    const val BASELINE_MALE: Int = TOTAL_WATER_AI_MALE * BEVERAGE_FRACTION_PERCENT / 100
    const val BASELINE_FEMALE: Int = TOTAL_WATER_AI_FEMALE * BEVERAGE_FRACTION_PERCENT / 100
    const val BASELINE_OTHER: Int = TOTAL_WATER_AI_OTHER * BEVERAGE_FRACTION_PERCENT / 100

    /** The most extra fluid a hard day can add (ml). The effort bump is capped here. */
    const val MAX_EFFORT_BUMP: Int = 700

    /** Goals are rounded to the nearest multiple of this (ml) so the readout is a clean round number. */
    const val ROUND_TO: Int = 50

    /** Quick-log amounts (ml). Each tap adds one of these to the day total. */
    const val SIP_ML: Int = 30
    const val CUP_ML: Int = 237
    const val BOTTLE_ML: Int = 500

    /**
     * The sex baseline (ml) for a profile `sex` tag. Anything that isn't "male" / "female" (i.e.
     * "nonbinary", unspecified, an unknown value) falls to the neutral [BASELINE_OTHER]. Case- and
     * whitespace-insensitive, matching the Swift normalisation.
     */
    fun baselineForSex(sex: String): Int = when (sex.trim().lowercase()) {
        "male", "m" -> BASELINE_MALE
        "female", "f" -> BASELINE_FEMALE
        else -> BASELINE_OTHER
    }

    /**
     * The effort bump (ml) for an Effort/strain score in 0..100, or 0 when [effort] is null (no Effort
     * scored yet). `round(effort / 100 * 700)`, then clamped into 0..[MAX_EFFORT_BUMP] so an out-of-range
     * input can't push the goal past the cap or below the baseline.
     *
     * A non-finite effort (NaN/Inf) is treated as "no Effort" (0), matching the Swift twin's
     * `guard let effort, effort.isFinite`. Without this, NaN reaches `roundToInt()`, which throws
     * IllegalArgumentException on Kotlin/JVM — the same input Swift absorbs and returns 0 for. That was
     * both an Android-only crash and a parity break.
     */
    fun effortBump(effort: Double?): Int {
        if (effort == null || !effort.isFinite()) return 0
        val raw = (effort / 100.0 * MAX_EFFORT_BUMP).roundToInt()
        return raw.coerceIn(0, MAX_EFFORT_BUMP)
    }

    /**
     * The daily goal (ml): [baselineForSex] + [effortBump], rounded to the nearest [ROUND_TO]. [effort]
     * is today's Effort/strain (0..100) or null when not yet scored. Pure — no store reads.
     */
    fun dailyGoalMl(sex: String, effort: Double?): Int {
        val raw = baselineForSex(sex) + effortBump(effort)
        return roundToNearest(raw, ROUND_TO)
    }

    /** Round [value] to the nearest multiple of [step] (step > 0). Half rounds up, matching Swift's
     *  `(value / step).rounded() * step`. */
    fun roundToNearest(value: Int, step: Int): Int {
        if (step <= 0) return value
        return ((value + step / 2) / step) * step
    }

    // R3: metric-aware inputs (weight + heat) — BYTE-IDENTICAL to the Swift twin. These EXTEND the goal
    // without changing dailyGoalMl(sex, effort); that overload still returns the sex-baseline result so
    // existing history/tests are unaffected. GOAL = round50(weightBaseline + effortBump + heatBump).

    /** ~35 ml per kg body mass per day — the standard adult maintenance estimate. */
    const val ML_PER_KG: Int = 35
    /** The weight-derived baseline is clamped to a sane adult range (ml). */
    const val WEIGHT_BASELINE_FLOOR: Int = 1500
    const val WEIGHT_BASELINE_CEIL: Int = 5000
    /** Heat bump: extra ml per whole °C of skin-temp elevation above baseline, and its cap. */
    const val HEAT_BUMP_PER_DEG: Int = 300
    const val MAX_HEAT_BUMP: Int = 600

    /** Baseline ml: weight-based (round(35*kg) clamped) when [weightKg] is finite and > 0, else the sex
     *  baseline. Null/non-finite/<=0 weight -> sex baseline (back-compat). */
    fun weightBaselineMl(sex: String, weightKg: Double?): Int {
        if (weightKg == null || !weightKg.isFinite() || weightKg <= 0.0) return baselineForSex(sex)
        val raw = (ML_PER_KG * weightKg).roundToInt()
        return raw.coerceIn(WEIGHT_BASELINE_FLOOR, WEIGHT_BASELINE_CEIL)
    }

    /** Heat bump (ml) from skin-temp deviation in °C above baseline: round(devC*300) clamped 0..600.
     *  Null/non-finite, absolute imported temperatures, implausible deviations, or non-positive
     *  deviations -> 0. */
    fun heatBumpMl(skinTempDevC: Double?): Int {
        val dev = VitalBands.skinTempDeviation(skinTempDevC) ?: return 0
        if (dev <= 0.0) return 0
        val raw = (dev * HEAT_BUMP_PER_DEG).roundToInt()
        return raw.coerceIn(0, MAX_HEAT_BUMP)
    }

    /** The metric-aware daily goal (ml): round50(weightBaseline + effortBump + heatBump). With
     *  weightKg == null and skinTempDevC == null this equals dailyGoalMl(sex, effort). */
    fun dailyGoalMl(sex: String, weightKg: Double?, effort: Double?, skinTempDevC: Double?): Int {
        val raw = weightBaselineMl(sex, weightKg) + effortBump(effort) + heatBumpMl(skinTempDevC)
        return roundToNearest(raw, ROUND_TO)
    }

    /** Evenly spaced reminder minutes-of-day within waking hours [wakeHour, sleepHour); quiet hours
     *  (sleep) are never disturbed. [count] reminders at the interior boundaries of count equal segments.
     *  [] for non-positive count or window. BYTE-IDENTICAL to the Swift twin. */
    fun reminderMinutesOfDay(wakeHour: Int, sleepHour: Int, count: Int): List<Int> {
        if (count <= 0) return emptyList()
        val wake = wakeHour.coerceIn(0, 23)
        val sleep = sleepHour.coerceIn(0, 24)
        val startMin = wake * 60
        val endMin = sleep * 60
        if (endMin <= startMin) return emptyList()
        val span = endMin - startMin
        val out = ArrayList<Int>(count)
        for (i in 1..count) {
            out.add(startMin + (span * i) / (count + 1))
        }
        return out
    }
}
