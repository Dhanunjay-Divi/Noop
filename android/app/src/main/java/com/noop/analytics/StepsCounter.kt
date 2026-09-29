package com.noop.analytics

import com.noop.data.StepSample
import kotlin.math.roundToLong

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

    /**
     * Maximum tolerated missing coverage at a day edge or between rows before an all-still window becomes
     * too sparse to repair a previously persisted whole-day value. This is not a gait threshold.
     */
    const val STATIONARY_REPAIR_MAX_COVERAGE_GAP_SECONDS = 15 * 60L

    enum class ClassificationPolicy {
        /** Preserve the historical raw-motion estimate for explicit legacy analysis. */
        allowLegacyRawMotion,

        /**
         * Research-only compatibility policy for fixtures that exercise the former @63 still/walk/run
         * interpretation. @63 overlaps `motion_wear_quality` and is not production gait evidence.
         */
        requireActivityClass,

        /**
         * Production compatible-band policy. The counter is observed motion, not a validated pedometer, and
         * legacy `activityClass` values came from the disputed @63 byte. Reject every positive delta.
         */
        rejectUnverifiedBandCounter,
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
        /** Positive, in-range ticks before classification. Never published as current steps. */
        val unfilteredRawTicks: Int,
        val rawTicks: Int,
    ) {
        enum class FilterMode {
            legacyRawMotion,
            activityClassFiltered,
            activityClassRequiredMissing,
            unverifiedBandCounterRejected,
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

        /** Only a legacy/research policy can currently retain counter evidence. */
        val hasAuthoritativeCounterOutcome: Boolean
            get() = steps != null

        /**
         * The exact raw-motion total the former algorithm would have published when every usable positive
         * delta is explicitly still. Persistence may use it only as a conditional compare-and-clear value.
         */
        val stationaryOnlyLegacyTicks: Int?
            get() = unfilteredRawTicks.takeIf {
                filterMode == FilterMode.activityClassFiltered &&
                    keptDeltaCount == 0 &&
                    rejectedStillDeltaCount > 0 &&
                    rejectedUnknownDeltaCount == 0 &&
                    rejectedGapDeltaCount == 0 &&
                    it > 0
            }
    }

    /** Shared calibration for daily, workout, trace, and stale-value repair paths. */
    fun scaledSteps(rawTicks: Int, ticksPerStep: Double): Int? {
        if (rawTicks <= 0) return null
        val scaled = (rawTicks.toDouble() / maxOf(ticksPerStep, 0.5))
            .roundToLong()
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
        return scaled.takeIf { it > 0 }
    }

    /**
     * Return the exact stale raw-motion value disproved by a continuously observed all-still day.
     *
     * Rejecting a short stationary burst is valid for new step publication, but that burst cannot disprove
     * the rest of a persisted day. Repair therefore requires edge-to-edge coverage through
     * [observedThroughTs] with no large internal gap. Persistence still uses compare-and-clear.
     */
    fun stationaryLegacyRepairSteps(
        analysis: Analysis,
        samples: List<StepSample>,
        ticksPerStep: Double,
        dayStartTs: Long,
        observedThroughTs: Long,
        maxCoverageGapSeconds: Long = STATIONARY_REPAIR_MAX_COVERAGE_GAP_SECONDS,
    ): Int? {
        val legacyTicks = analysis.stationaryOnlyLegacyTicks ?: return null
        if (maxCoverageGapSeconds <= 0L || observedThroughTs < dayStartTs) return null

        val covered = samples
            .asSequence()
            .filter { it.ts in dayStartTs..observedThroughTs }
            .sortedBy { it.ts }
            .toList()
        if (
            covered.size < 2 ||
            covered.size != analysis.sampleCount ||
            covered.first().ts - dayStartTs > maxCoverageGapSeconds ||
            observedThroughTs - covered.last().ts > maxCoverageGapSeconds
        ) {
            return null
        }
        for (index in 1 until covered.size) {
            val gap = covered[index].ts - covered[index - 1].ts
            if (gap <= 0L || gap > maxCoverageGapSeconds) return null
        }
        return scaledSteps(legacyTicks, ticksPerStep)
    }

    /**
     * Analyze wrap-aware motion-counter deltas in timestamp order.
     *
     * Legacy windows with no non-null activity class preserve the prior raw-motion behavior. The research
     * policy retains the former class filter. Production rejects every positive counter delta because neither
     * @57 motion nor the overlapping @63 byte is validated gait evidence. Gap/reset deltas remain rejected
     * before policy filtering.
     */
    fun analyze(
        samples: List<StepSample>,
        classificationPolicy: ClassificationPolicy = ClassificationPolicy.allowLegacyRawMotion,
    ): Analysis {
        val sorted = samples.sortedBy { it.ts }
        val hasActivityClass = sorted.any { it.activityClass != null }
        val filterMode = when {
            classificationPolicy == ClassificationPolicy.rejectUnverifiedBandCounter ->
                Analysis.FilterMode.unverifiedBandCounterRejected
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
        var unfilteredRawTicks = 0

        for (i in 1 until sorted.size) {
            val later = sorted[i]
            val delta = (later.counter - sorted[i - 1].counter) and 0xFFFF
            when {
                delta == 0 -> zeroDeltaCount += 1
                delta >= MAX_STEP_DELTA -> rejectedGapDeltaCount += 1
                filterMode == Analysis.FilterMode.legacyRawMotion -> {
                    unfilteredRawTicks += delta
                    rawTicks += delta
                    keptDeltaCount += 1
                }
                filterMode == Analysis.FilterMode.unverifiedBandCounterRejected -> {
                    unfilteredRawTicks += delta
                    rejectedUnknownDeltaCount += 1
                }
                else -> {
                    unfilteredRawTicks += delta
                    when (later.activityClass) {
                        1, 2 -> {
                            rawTicks += delta
                            keptDeltaCount += 1
                        }
                        0 -> rejectedStillDeltaCount += 1
                        else -> rejectedUnknownDeltaCount += 1
                    }
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
            unfilteredRawTicks = unfilteredRawTicks,
            rawTicks = rawTicks,
        )
    }

    /**
     * Policy-filtered wrap-aware motion-tick total across [samples]. Production callers must pass
     * [ClassificationPolicy.rejectUnverifiedBandCounter]; the defaults remain for compatibility tests.
     */
    fun stepsInWindow(
        samples: List<StepSample>,
        classificationPolicy: ClassificationPolicy = ClassificationPolicy.allowLegacyRawMotion,
    ): Int? = analyze(samples, classificationPolicy).steps
}
