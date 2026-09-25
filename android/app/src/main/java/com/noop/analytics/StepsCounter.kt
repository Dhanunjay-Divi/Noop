package com.noop.analytics

import com.noop.data.StepSample

/**
 * Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
 * total ([AnalyticsEngine.analyzeDay]) and any windowed total (a manual workout's `[start, end]`, #398).
 *
 * `step_motion_counter@57` is a CUMULATIVE u16 running counter: it climbs while you move, holds flat when
 * still, and wraps at 65536. The motion-tick total over a set of records is the SUM of WRAP-AWARE
 * increments of that counter — `delta = (cur - prev) and 0xFFFF` — with a per-user `stepTicksPerStep`
 * calibration applied by the caller AFTERWARDS (this returns the raw pre-calibration tick total, so the two
 * callers can never disagree on the counter math). The raw total is an ESTIMATE (@57 counts motion ticks,
 * not validated steps), not cloud/clinical parity.
 *
 * Twin of the Swift `StepsCounter`.
 */
object StepsCounter {
    /**
     * The largest wrap-aware increment treated as real motion between two adjacent 1 Hz records. A delta
     * at/above this is a big time-gap / disconnect boundary between sync sessions (or a firmware reboot,
     * byte-indistinguishable from a u16 wrap), NOT real steps — dropped so gaps don't inflate the total.
     * Real 1 Hz motion never ticks this fast between adjacent records. (#132/#276/#316)
     */
    const val MAX_STEP_DELTA = 512

    enum class ClassificationPolicy {
        /** Preserve the historical raw-motion estimate for explicit legacy analysis. */
        allowLegacyRawMotion,

        /**
         * Current counter-capable hardware must provide walk/run evidence. An all-unclassified window
         * remains observed but ambiguous, yields no steps, and cannot enable another motion fallback.
         */
        requireActivityClass,
    }

    /**
     * Pure counter analysis shared by production totals and bounded diagnostics. It exposes aggregate counts,
     * never timestamps, identifiers, or per-sample counter values.
     */
    data class Analysis(
        val filterMode: FilterMode,
        val sampleCount: Int,
        val deltaCount: Int,
        val keptDeltaCount: Int,
        val rejectedStillDeltaCount: Int,
        val rejectedUnknownDeltaCount: Int,
        val rejectedGapDeltaCount: Int,
        val zeroDeltaCount: Int,
        val rawTicks: Int,
    ) {
        enum class FilterMode {
            legacyRawMotion,
            activityClassFiltered,
            activityClassRequiredMissing,
        }

        val steps: Int?
            get() = rawTicks.takeIf { it > 0 }

        /**
         * True when this window contains at least one counter row, including flat, discontinuous, or
         * class-rejected motion. Callers must not treat such a window as hardware without a counter.
         */
        val counterObserved: Boolean
            get() = sampleCount > 0

        /** Gravity may stand in only when no counter row exists at all. */
        val allowsMotionFallback: Boolean
            get() = !counterObserved

        /** Only retained walk/run evidence may replace older computed evidence. */
        val hasAuthoritativeCounterOutcome: Boolean
            get() = steps != null
    }

    /**
     * Analyze wrap-aware motion-counter deltas in timestamp order.
     *
     * Legacy windows with no non-null activity class preserve the prior raw-motion behavior. Once any class
     * evidence exists anywhere in the window, a delta is locomotion only when its later sample is walk (1) or
     * run (2). Still (0), unknown (null), and any other class are rejected. Gap/reset deltas remain rejected
     * before activity classification.
     */
    fun analyze(
        samples: List<StepSample>,
        classificationPolicy: ClassificationPolicy = ClassificationPolicy.allowLegacyRawMotion,
    ): Analysis {
        val sorted = samples.sortedBy { it.ts }
        val hasActivityClass = sorted.any { it.activityClass != null }
        val filterMode = when {
            hasActivityClass -> Analysis.FilterMode.activityClassFiltered
            classificationPolicy == ClassificationPolicy.requireActivityClass ->
                Analysis.FilterMode.activityClassRequiredMissing
            else -> Analysis.FilterMode.legacyRawMotion
        }

        var rawTicks = 0
        var keptDeltaCount = 0
        var rejectedStillDeltaCount = 0
        var rejectedUnknownDeltaCount = 0
        var rejectedGapDeltaCount = 0
        var zeroDeltaCount = 0

        for (i in 1 until sorted.size) {
            val later = sorted[i]
            val delta = (later.counter - sorted[i - 1].counter) and 0xFFFF
            when {
                delta == 0 -> zeroDeltaCount += 1
                delta >= MAX_STEP_DELTA -> rejectedGapDeltaCount += 1
                filterMode == Analysis.FilterMode.legacyRawMotion -> {
                    rawTicks += delta
                    keptDeltaCount += 1
                }
                else -> when (later.activityClass) {
                    1, 2 -> {
                        rawTicks += delta
                        keptDeltaCount += 1
                    }
                    0 -> rejectedStillDeltaCount += 1
                    else -> rejectedUnknownDeltaCount += 1
                }
            }
        }

        return Analysis(
            filterMode = filterMode,
            sampleCount = sorted.size,
            deltaCount = (sorted.size - 1).coerceAtLeast(0),
            keptDeltaCount = keptDeltaCount,
            rejectedStillDeltaCount = rejectedStillDeltaCount,
            rejectedUnknownDeltaCount = rejectedUnknownDeltaCount,
            rejectedGapDeltaCount = rejectedGapDeltaCount,
            zeroDeltaCount = zeroDeltaCount,
            rawTicks = rawTicks,
        )
    }

    /**
     * Raw wrap-aware motion-tick total across [samples] — the sum of positive consecutive
     * `step_motion_counter@57` increments in `[1, MAX_STEP_DELTA)`. Sorts by `ts` internally, so the caller
     * may pass an unsorted window (already filtered to the range it cares about). Returns `null` when there
     * are fewer than two samples or no forward movement (so "no data" stays distinct from a real zero). The
     * caller applies its `stepTicksPerStep` calibration to the returned ticks.
     */
    fun stepsInWindow(
        samples: List<StepSample>,
        classificationPolicy: ClassificationPolicy = ClassificationPolicy.allowLegacyRawMotion,
    ): Int? = analyze(samples, classificationPolicy).steps
}
