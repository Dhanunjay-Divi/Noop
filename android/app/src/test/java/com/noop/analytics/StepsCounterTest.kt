package com.noop.analytics

import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the shared windowed step kernel [StepsCounter.stepsInWindow] (#398). The same wrap-aware
 * positive-delta math the daily total uses (see StepsAnalyticsTest), but exercised directly and
 * order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
 * the caller's `stepTicksPerStep` calibration). Byte-for-byte twin of the Swift StepsCounterTests.
 */
class StepsCounterTest {

    private fun step(ts: Long, counter: Int, activityClass: Int? = null) = StepSample(
        deviceId = "my-whoop",
        ts = ts,
        counter = counter,
        activityClass = activityClass,
    )

    @Test fun sumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        assertEquals(120, StepsCounter.stepsInWindow(listOf(step(0, 100), step(60, 150), step(120, 220))))
    }

    @Test fun sortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        assertEquals(120, StepsCounter.stepsInWindow(listOf(step(120, 220), step(0, 100), step(60, 150))))
    }

    @Test fun handlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) and 0xFFFF = 56; then 20 -> 80 => 60. Total 116.
        assertEquals(116, StepsCounter.stepsInWindow(listOf(step(0, 65_500), step(60, 20), step(120, 80))))
    }

    @Test fun fewerThanTwoSamplesIsNull() {
        val empty = StepsCounter.analyze(emptyList())
        assertNull(empty.steps)
        assertEquals(false, empty.counterObserved)
        assertEquals(true, empty.allowsMotionFallback)
        assertEquals(false, empty.hasAuthoritativeCounterOutcome)

        val singleton = StepsCounter.analyze(listOf(step(0, 100)))
        assertNull(singleton.steps)
        assertEquals(true, singleton.counterObserved)
        assertEquals(false, singleton.allowsMotionFallback)
        assertEquals(false, singleton.hasAuthoritativeCounterOutcome)
    }

    @Test fun noForwardMovementIsNull() {
        // Flat counter across the window => no positive delta => null (not 0).
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 500), step(60, 500), step(120, 500))))
    }

    @Test fun dropsBigGapDeltaAsBoundary() {
        // A jump >= 512 is dropped; the real 40 + 30 survive => 70.
        assertEquals(70, StepsCounter.stepsInWindow(
            listOf(step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030))))
    }

    @Test fun maxStepDeltaBoundaryIsExclusive() {
        // Exactly MAX_STEP_DELTA (512) is dropped; 511 counts.
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 0), step(60, 512))))
        assertEquals(511, StepsCounter.stepsInWindow(listOf(step(0, 0), step(60, 511))))
    }

    @Test fun classZeroStationaryFourThousandTickBurstIsRejected() {
        val samples = (0..10).map { index ->
            step(index * 60L, index * 400, activityClass = 0)
        }

        val analysis = StepsCounter.analyze(samples)

        assertEquals(
            StepsCounter.Analysis.FilterMode.activityClassFiltered,
            analysis.filterMode,
        )
        assertEquals(10, analysis.deltaCount)
        assertEquals(0, analysis.keptDeltaCount)
        assertEquals(10, analysis.rejectedStillDeltaCount)
        assertEquals(4_000, analysis.unfilteredRawTicks)
        assertEquals(0, analysis.rawTicks)
        assertNull(analysis.steps)
        assertEquals(true, analysis.counterObserved)
        assertEquals(false, analysis.allowsMotionFallback)
        assertEquals(false, analysis.hasAuthoritativeCounterOutcome)
        assertEquals(4_000, analysis.stationaryOnlyLegacyTicks)
        assertEquals(
            2_000,
            StepsCounter.scaledSteps(
                rawTicks = requireNotNull(analysis.stationaryOnlyLegacyTicks),
                ticksPerStep = 2.0,
            ),
        )
        assertNull(StepsCounter.stepsInWindow(samples))
    }

    @Test fun headWashingHandGesturesDoNotIncreaseSteps() {
        // Regression: repetitive arm/hand motion while standing in place advanced the raw wrist counter
        // by about 4,000. Every delta is plausible and below the gap guard, so stationary classification,
        // not a size heuristic or heart-rate threshold, must reject the complete sequence.
        val counters = listOf(
            10_000, 10_180, 10_600, 10_860, 11_360, 11_670,
            12_060, 12_510, 12_790, 13_280, 13_600, 14_000,
        )
        val samples = counters.mapIndexed { index, counter ->
            step(index * 20L, counter, activityClass = 0)
        }
        val analysis = StepsCounter.analyze(
            samples,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )

        assertEquals(4_000, analysis.unfilteredRawTicks)
        assertEquals(counters.size - 1, analysis.rejectedStillDeltaCount)
        assertEquals(0, analysis.rawTicks)
        assertNull(analysis.steps)
        assertNull(
            StepsCounter.stepsInWindow(
                samples,
                StepsCounter.ClassificationPolicy.requireActivityClass,
            ),
        )
    }

    @Test fun continuousAllStillCoverageCanRepairExactLegacyValue() {
        val samples = (0..6).map { index ->
            step(index * 600L, index * 100, activityClass = 0)
        }
        val analysis = StepsCounter.analyze(
            samples,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )

        assertEquals(
            300,
            StepsCounter.stationaryLegacyRepairSteps(
                analysis = analysis,
                samples = samples,
                ticksPerStep = 2.0,
                dayStartTs = 0,
                observedThroughTs = 3_600,
            ),
        )
    }

    @Test fun shortStationaryBurstCannotRepairWholeDayValue() {
        val samples = (0..10).map { index ->
            step(43_200L + index * 60L, index * 400, activityClass = 0)
        }
        val analysis = StepsCounter.analyze(
            samples,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )

        assertEquals(4_000, analysis.stationaryOnlyLegacyTicks)
        assertNull(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis = analysis,
                samples = samples,
                ticksPerStep = 1.0,
                dayStartTs = 0,
                observedThroughTs = 86_399,
            ),
        )
    }

    @Test fun allStillCoverageWithInternalOrTrailingGapCannotRepair() {
        val internalGap = listOf(
            step(0, 0, activityClass = 0),
            step(600, 100, activityClass = 0),
            step(1_200, 200, activityClass = 0),
            step(3_000, 300, activityClass = 0),
            step(3_600, 400, activityClass = 0),
        )
        val internalAnalysis = StepsCounter.analyze(
            internalGap,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )
        assertNull(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis = internalAnalysis,
                samples = internalGap,
                ticksPerStep = 1.0,
                dayStartTs = 0,
                observedThroughTs = 3_600,
            ),
        )

        val trailingGap = (0..3).map { index ->
            step(index * 600L, index * 100, activityClass = 0)
        }
        val trailingAnalysis = StepsCounter.analyze(
            trailingGap,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )
        assertNull(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis = trailingAnalysis,
                samples = trailingGap,
                ticksPerStep = 1.0,
                dayStartTs = 0,
                observedThroughTs = 3_600,
            ),
        )
    }

    @Test fun repairFailsClosedWhenAnalysisAndCoveredRowsDiffer() {
        val samples = (0..6).map { index ->
            step(index * 600L, index * 100, activityClass = 0)
        } + step(4_200, 700, activityClass = 0)
        val analysis = StepsCounter.analyze(
            samples,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )

        assertNull(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis = analysis,
                samples = samples,
                ticksPerStep = 1.0,
                dayStartTs = 0,
                observedThroughTs = 3_600,
            ),
        )
    }

    @Test fun mixedStillAndWalkRetainsOnlyWalkDeltas() {
        val samples = listOf(
            step(0, 100, activityClass = 0),
            step(60, 300, activityClass = 0), // 200 still, rejected
            step(120, 450, activityClass = 1), // 150 walk, kept
            step(180, 550, activityClass = 0), // 100 still, rejected
            step(240, 700, activityClass = 2), // 150 run, kept
        )

        val analysis = StepsCounter.analyze(samples)

        assertEquals(300, analysis.rawTicks)
        assertEquals(600, analysis.unfilteredRawTicks)
        assertEquals(2, analysis.keptDeltaCount)
        assertEquals(2, analysis.rejectedStillDeltaCount)
        assertNull(analysis.stationaryOnlyLegacyTicks)
        assertEquals(300, StepsCounter.stepsInWindow(samples))
    }

    @Test fun unknownDeltaIsRejectedInsideClassedWindow() {
        val samples = listOf(
            step(0, 100, activityClass = 0),
            step(60, 150), // 50 unknown, rejected because class evidence exists
            step(120, 220, activityClass = 1), // 70 walk, kept
        )

        val analysis = StepsCounter.analyze(samples)

        assertEquals(
            StepsCounter.Analysis.FilterMode.activityClassFiltered,
            analysis.filterMode,
        )
        assertEquals(70, analysis.rawTicks)
        assertEquals(120, analysis.unfilteredRawTicks)
        assertEquals(1, analysis.keptDeltaCount)
        assertEquals(1, analysis.rejectedUnknownDeltaCount)
        assertNull(analysis.stationaryOnlyLegacyTicks)
        assertEquals(70, StepsCounter.stepsInWindow(samples))
    }

    @Test fun invalidActivityClassCountsAsUnknown() {
        val samples = listOf(
            step(0, 100, activityClass = 1),
            step(60, 180, activityClass = 7),
        )

        val analysis = StepsCounter.analyze(samples)

        assertEquals(0, analysis.rawTicks)
        assertEquals(1, analysis.rejectedUnknownDeltaCount)
        assertNull(analysis.stationaryOnlyLegacyTicks)
        assertNull(analysis.steps)
    }

    @Test fun allNullActivityClassesRetainLegacyRawMotionBehavior() {
        val samples = (0..10).map { index ->
            step(index * 60L, index * 400)
        }

        val analysis = StepsCounter.analyze(samples)

        assertEquals(
            StepsCounter.Analysis.FilterMode.legacyRawMotion,
            analysis.filterMode,
        )
        assertEquals(10, analysis.keptDeltaCount)
        assertEquals(4_000, analysis.unfilteredRawTicks)
        assertEquals(4_000, analysis.rawTicks)
        assertNull(analysis.stationaryOnlyLegacyTicks)
        assertEquals(true, analysis.counterObserved)
        assertEquals(false, analysis.allowsMotionFallback)
        assertEquals(true, analysis.hasAuthoritativeCounterOutcome)
        assertEquals(4_000, StepsCounter.stepsInWindow(samples))
    }

    @Test fun currentClasslessFourThousandTickBurstFailsClosed() {
        val samples = (0..10).map { index -> step(index * 60L, index * 400) }
        val analysis = StepsCounter.analyze(
            samples,
            StepsCounter.ClassificationPolicy.requireActivityClass,
        )

        assertEquals(
            StepsCounter.Analysis.FilterMode.activityClassRequiredMissing,
            analysis.filterMode,
        )
        assertEquals(0, analysis.keptDeltaCount)
        assertEquals(10, analysis.rejectedUnknownDeltaCount)
        assertEquals(4_000, analysis.unfilteredRawTicks)
        assertEquals(0, analysis.rawTicks)
        assertNull(analysis.stationaryOnlyLegacyTicks)
        assertNull(analysis.steps)
        assertEquals(true, analysis.counterObserved)
        assertEquals(false, analysis.allowsMotionFallback)
        assertEquals(false, analysis.hasAuthoritativeCounterOutcome)
    }

    @Test fun gapOnlyAndUnknownOnlyWindowsDoNotDisproveStoredSteps() {
        val gapOnly = StepsCounter.analyze(
            listOf(
                step(0, 100, activityClass = 0),
                step(60, 900, activityClass = 0),
            )
        )
        assertNull(gapOnly.steps)
        assertEquals(true, gapOnly.counterObserved)
        assertEquals(false, gapOnly.hasAuthoritativeCounterOutcome)
        assertNull(gapOnly.stationaryOnlyLegacyTicks)

        val unknownOnly = StepsCounter.analyze(
            listOf(
                step(0, 100, activityClass = 9),
                step(60, 200, activityClass = 9),
            )
        )
        assertNull(unknownOnly.steps)
        assertEquals(true, unknownOnly.counterObserved)
        assertEquals(false, unknownOnly.hasAuthoritativeCounterOutcome)
        assertNull(unknownOnly.stationaryOnlyLegacyTicks)
    }

    @Test fun stillMixedWithUnknownOrGapRemainsAmbiguous() {
        val stillAndUnknown = StepsCounter.analyze(
            listOf(
                step(0, 100, activityClass = 0),
                step(60, 200, activityClass = 0),
                step(120, 300, activityClass = 9),
            )
        )
        assertNull(stillAndUnknown.steps)
        assertEquals(1, stillAndUnknown.rejectedStillDeltaCount)
        assertEquals(1, stillAndUnknown.rejectedUnknownDeltaCount)
        assertEquals(false, stillAndUnknown.hasAuthoritativeCounterOutcome)
        assertNull(stillAndUnknown.stationaryOnlyLegacyTicks)

        val stillAndGap = StepsCounter.analyze(
            listOf(
                step(0, 100, activityClass = 0),
                step(60, 200, activityClass = 0),
                step(120, 900, activityClass = 0),
            )
        )
        assertNull(stillAndGap.steps)
        assertEquals(1, stillAndGap.rejectedStillDeltaCount)
        assertEquals(1, stillAndGap.rejectedGapDeltaCount)
        assertEquals(false, stillAndGap.hasAuthoritativeCounterOutcome)
        assertNull(stillAndGap.stationaryOnlyLegacyTicks)
    }

    @Test fun classedWindowRetainsWrapAndGapBehavior() {
        val samples = listOf(
            step(0, 65_500, activityClass = 1),
            step(60, 20, activityClass = 1), // wrap delta 56, kept
            step(120, 1_000, activityClass = 1), // 980 gap, rejected
            step(180, 1_060, activityClass = 2), // 60 run, kept
        )

        val analysis = StepsCounter.analyze(samples)

        assertEquals(116, analysis.rawTicks)
        assertEquals(2, analysis.keptDeltaCount)
        assertEquals(1, analysis.rejectedGapDeltaCount)
        assertEquals(116, StepsCounter.stepsInWindow(samples))
    }
}
