package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryRestBaselineTest {
    private fun baseline(mean: Double, sigma: Double): BaselineState =
        BaselineState(
            baseline = mean,
            spread = sigma / 1.253,
            nValid = 20,
            nightsSinceUpdate = 0,
            status = BaselineStatus.TRUSTED,
        )

    @Test fun personalRestCenterRemovesPersistentSleepPenalty() {
        val hrv = baseline(50.0, 6.0)
        val rhr = baseline(55.0, 3.0)
        val coldStart = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = null,
            sleepPerf = 0.75,
        )!!
        val personalized = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = null,
            sleepPerf = 0.75, restQualityBaseline = baseline(0.75, 0.04),
        )!!

        assertTrue(personalized > coldStart)
        assertEquals(57.93, personalized, 0.5)
    }

    @Test fun percentScaleAndNonFiniteRestAreDropped() {
        val hrv = baseline(50.0, 6.0)
        val rhr = baseline(55.0, 3.0)
        fun score(rest: Double?): Double = RecoveryScorer.recovery(
            hrv = 55.0, rhr = 52.0, resp = null,
            hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = null,
            sleepPerf = rest,
        )!!

        val omitted = score(null)
        assertEquals(omitted, score(75.0), 1e-9)
        assertEquals(omitted, score(Double.NaN), 1e-9)
        assertEquals(omitted, score(Double.POSITIVE_INFINITY), 1e-9)
        assertNotEquals(omitted, score(0.75), 1e-9)
    }

    @Test fun personalRestCenterKeepsFixedScale() {
        val hrv = baseline(50.0, 6.0)
        val rhr = baseline(55.0, 3.0)
        fun score(spread: Double): Double = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = null,
            sleepPerf = 0.87,
            restQualityBaseline = BaselineState(
                baseline = 0.75, spread = spread, nValid = 20,
                nightsSinceUpdate = 0, status = BaselineStatus.TRUSTED,
            ),
        )!!

        assertEquals(score(0.001), score(0.2), 1e-9)
    }
}
