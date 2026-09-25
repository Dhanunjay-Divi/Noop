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
        assertNull(StepsCounter.stepsInWindow(emptyList()))
        assertNull(StepsCounter.stepsInWindow(listOf(step(0, 100))))
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
        assertEquals(0, analysis.rawTicks)
        assertNull(analysis.steps)
        assertNull(StepsCounter.stepsInWindow(samples))
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
        assertEquals(2, analysis.keptDeltaCount)
        assertEquals(2, analysis.rejectedStillDeltaCount)
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
        assertEquals(1, analysis.keptDeltaCount)
        assertEquals(1, analysis.rejectedUnknownDeltaCount)
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
        assertEquals(4_000, analysis.rawTicks)
        assertEquals(4_000, StepsCounter.stepsInWindow(samples))
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
