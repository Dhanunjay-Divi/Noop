package com.noop.analytics

import com.noop.data.DailyMetric
import java.time.LocalDate
import kotlin.math.sqrt

/**
 * V5HealthSignals — the small, pure adapter that turns the app's cached merged [DailyMetric] history into
 * the per-night z-scored inputs the three v5 skin-temp-suite engines consume, and runs them once per
 * analytics pass. It owns NO I/O and NO state: the caller (AppViewModel) hands it the already-loaded
 * `recentDays` list + a few prefs/profile flags and gets back a [Snapshot] of engine RESULTS to publish.
 *
 * Why a lightweight z here (not the full [Baselines] EWMA): the cards only need a deviation-against-your-
 * own-recent-range read ("further from your baseline than usual"), and the cached daily columns already
 * carry RHR / HRV / skin-temp-deviation / respiration. A rolling mean+SD over the trailing window is the
 * honest, transparent statistic the spec asks for (an observation about your own number) and keeps this
 * pass cheap + DB-free. The engines themselves (CyclePhaseEngine / CircadianEngine / IllnessSignalEngine)
 * are the byte-for-byte cross-platform maths; this file is only the Android-side input plumbing.
 *
 * NON-CLINICAL: every output is an approximation about the user's own series — never a diagnosis. Cycle
 * awareness is OPT-IN (the caller gates on a default-OFF pref before reading [Snapshot.cycle]).
 *
 * See docs/superpowers/specs/2026-06-19-v5-skin-temp-suite-design.md and the umbrella IA (§2.4 Health hub).
 */
object V5HealthSignals {

    /** Trailing window (nights) for the rolling baseline used to z-score each signal. */
    private const val BASELINE_WINDOW = 30

    /** Minimum trailing nights before a z-score is trusted (mirrors Baselines.minNightsTrust intent). */
    private const val MIN_BASELINE_NIGHTS = 14

    /** The published engine results for the Health hub's skin-temp suite, all already decided. */
    data class Snapshot(
        val cycle: CyclePhaseEngine.Result,
        val bodyClock: CircadianEngine.PhaseEstimate?,
        val illness: IllnessSignalEngine.Result,
        /**
         * Parallel Mahalanobis illness-distance read (IllnessDistance), computed on the SAME illness-ward
         * z-vector as [illness] but NEVER gating the alert: [IllnessSignalEngine] stays the sole fire gate.
         * This only surfaces a "how strong" confidence readout in the Heads-Up card when the engine has
         * already raised. Nullable so an absent illness pass leaves it null. (Augment-only, Option A.)
         */
        val illnessDistance: IllnessDistance.Result?,
        /** True once there are enough trusted nights for any of these to be more than "learning". */
        val baselineTrusted: Boolean,
    )

    /**
     * Run the three engines over [days] (oldest→newest). [cycleOptedIn] gates whether the cycle classifier
     * is run at all (it returns a cheap LEARNING result when off, so the caller can publish unconditionally
     * and the UI's opt-in card still shows). [loggedPeriodStarts] are optional "yyyy-MM-dd" period-start
     * days. [journalContext] supplies nearby explanatory context for the illness result.
     */
    fun evaluate(
        days: List<DailyMetric>,
        cycleOptedIn: Boolean,
        loggedPeriodStarts: List<String> = emptyList(),
        journalContext: IllnessSignalEngine.Context = IllnessSignalEngine.Context(),
        habitualWakeHour: Double = 7.0,
        todayKey: String = days.maxOfOrNull { it.day } ?: LocalDate.now().toString(),
        illnessAssessment: IllnessWatch.Assessment? = null,
    ): Snapshot {
        val cycleBaselineTrusted = days.count { hasAnyVital(it) } >= MIN_BASELINE_NIGHTS

        // ── Per-night z-scores against each signal's trailing rolling baseline ──
        val nights = ArrayList<CyclePhaseEngine.Night>(days.size)
        for ((i, d) in days.withIndex()) {
            val window = days.subList(maxOf(0, i - BASELINE_WINDOW), i)
            nights.add(
                CyclePhaseEngine.Night(
                    day = d.day,
                    tempZ = skinTempZAgainst(d.skinTempDevC, window),
                    rhrZ = zAgainst(d.restingHr?.toDouble(), window) { it.restingHr?.toDouble() },
                    hrvZ = zAgainst(d.avgHrv, window) { it.avgHrv },
                )
            )
        }

        // ── Cycle awareness (opt-in) ──
        val cycle = if (cycleOptedIn) {
            CyclePhaseEngine.classify(
                nights,
                baselineUsable = cycleBaselineTrusted,
                loggedPeriodStarts = loggedPeriodStarts,
                asOfDay = todayKey,
            )
        } else {
            CyclePhaseEngine.Result(
                phase = CyclePhaseEngine.Phase.LEARNING,
                confidence = CyclePhaseEngine.Confidence.LEARNING,
                cycleDayLow = null, cycleDayHigh = null, cycleLengthDays = null,
                nextPeriodWindow = null, shiftMarkers = emptyList(),
                note = "Turn on cycle awareness to read a coarse phase from your nightly temperature.",
                noteKinds = listOf(CyclePhaseEngine.NoteKind.TURN_ON_AWARENESS),
            )
        }

        // ── Illness heads-up ──
        // One adapter supplies the Health card, banner/notifier, and background service. Per-signal
        // freshness and trust therefore cannot diverge from one surface to another.
        val assessment = illnessAssessment
            ?: IllnessWatch.assess(days, todayKey, journalContext)

        // ── Body clock: needs per-hour rest-activity bins we don't bank here; the planner is on-demand.
        //    Leave null so the BodyClockCard reads its honest "Calibrating" empty state until a future
        //    activity-bin source lands (the engine is wired + ready, the input pipe is the gap). ──
        val bodyClock: CircadianEngine.PhaseEstimate? = null

        return Snapshot(
            cycle = cycle,
            bodyClock = bodyClock,
            illness = assessment.result,
            illnessDistance = assessment.distance,
            baselineTrusted = assessment.prepared.baselineTrusted,
        )
    }

    /** A day is "usable" for the baseline if it carries at least one of the four illness/cycle vitals. */
    private fun hasAnyVital(d: DailyMetric): Boolean =
        d.restingHr != null || d.avgHrv != null || d.skinTempDevC != null || d.respRateBpm != null

    /**
     * Z-score [value] against the trailing [window]'s rolling mean + sample SD for [selector]. Returns
     * null when the value is absent or there isn't enough trailing data to trust the spread. A floor on
     * the SD prevents a near-constant series from exploding the z.
     */
    private inline fun zAgainst(
        value: Double?,
        window: List<DailyMetric>,
        selector: (DailyMetric) -> Double?,
    ): Double? {
        if (value == null) return null
        val xs = window.mapNotNull(selector)
        if (xs.size < MIN_BASELINE_NIGHTS) return null
        val mean = xs.average()
        val variance = xs.sumOf { (it - mean) * (it - mean) } / (xs.size - 1).coerceAtLeast(1)
        val sd = sqrt(variance).coerceAtLeast(1e-6)
        return (value - mean) / sd
    }

    /** Mixed-semantics skin-temperature z-score for cycle awareness. The current value only sees
     *  trailing rows of its own kind, and both absolute/deviation paths retain a 0.3 C noise floor. */
    private fun skinTempZAgainst(value: Double?, window: List<DailyMetric>): Double? {
        if (value == null || !value.isFinite()) return null
        val absolute = VitalBands.isAbsoluteSkinTemp(value)
        val validValue = if (absolute) {
            val cfg = Baselines.metricCfg.getValue("skin_temp")
            value.takeIf { it in cfg.minVal..cfg.maxVal }
        } else {
            VitalBands.skinTempDeviation(value)
        } ?: return null
        val xs = window.mapNotNull { row ->
            val candidate = row.skinTempDevC ?: return@mapNotNull null
            if (VitalBands.isAbsoluteSkinTemp(candidate) != absolute) return@mapNotNull null
            if (absolute) {
                val cfg = Baselines.metricCfg.getValue("skin_temp")
                candidate.takeIf { it.isFinite() && it in cfg.minVal..cfg.maxVal }
            } else {
                VitalBands.skinTempDeviation(candidate)
            }
        }
        if (xs.size < MIN_BASELINE_NIGHTS) return null
        val mean = xs.average()
        val variance = xs.sumOf { (it - mean) * (it - mean) } / (xs.size - 1).coerceAtLeast(1)
        val sd = sqrt(variance).coerceAtLeast(VitalBands.skinTempDeviationCfg.floorSpread)
        return (validValue - mean) / sd
    }
}
