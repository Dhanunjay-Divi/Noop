package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Golden parity with StrandAnalytics RrCoverageVerdictTests. */
class RrCoverageVerdictTest {

    @Test
    fun coverageVerdictsAndBoundaries() {
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE,
            HrvAnalyzer.classifyCoverage(1.0, 1.0),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(0.89, 0.88),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT,
            HrvAnalyzer.classifyCoverage(1.60, 1.02),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT,
            HrvAnalyzer.classifyCoverage(2.54, 1.99),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE,
            HrvAnalyzer.classifyCoverage(0.0, 0.0),
        )
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE,
            HrvAnalyzer.classifyCoverage(Double.NaN, Double.NaN),
        )

        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE))
        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED))
        assertTrue(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.UNMEASURABLE))
        assertFalse(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.SAME_SECOND_OVER_COUNT))
        assertFalse(HrvAnalyzer.beatSpreadIsTrustworthy(HrvAnalyzer.RrCoverageVerdict.CROSS_SECOND_OVER_COUNT))
    }

    @Test
    fun floorMirrorsCeilingAndIsInclusive() {
        assertEquals(
            HrvAnalyzer.COVERAGE_PLAUSIBLE_CEILING - 1.0,
            1.0 - HrvAnalyzer.COVERAGE_PLAUSIBLE_FLOOR,
            1e-12,
        )
        val floor = HrvAnalyzer.COVERAGE_PLAUSIBLE_FLOOR
        assertEquals(HrvAnalyzer.RrCoverageVerdict.PLAUSIBLE, HrvAnalyzer.classifyCoverage(floor, floor))
        assertEquals(
            HrvAnalyzer.RrCoverageVerdict.UNDER_COVERED,
            HrvAnalyzer.classifyCoverage(floor - 0.01, 9.9),
        )
    }

    @Test
    fun beatAccurateStreamIsTrusted() {
        val rr = List(60) { 1_000.0 }
        val ts = (0 until 60).map { it.toLong() }
        val fraction = HrvAnalyzer.beatAccurateFraction(ts, rr)
        assertEquals(1.0, fraction, 1e-9)
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(fraction))
    }

    @Test
    fun perfectlyCoveredBankedStreamStillRefusesBeatValues() {
        val rr = List(60) { 63_000.0 / 60.0 }
        val ts = (0 until 60).map { ((it / 6) * 7).toLong() }
        val verdict = HrvAnalyzer.classifyCoverage(
            HrvAnalyzer.rrCoverage(ts, rr),
            HrvAnalyzer.collapsedCoverage(ts, rr),
        )
        assertTrue("coverage verdict was $verdict", HrvAnalyzer.beatSpreadIsTrustworthy(verdict))

        val fraction = HrvAnalyzer.beatAccurateFraction(ts, rr)
        assertTrue(fraction < HrvAnalyzer.BEAT_ACCURACY_MIN_FRACTION)
        assertFalse(HrvAnalyzer.beatValuesAreTrustworthy(fraction))
    }

    @Test
    fun unknownBeatTimingStaysTrustedAndBoundaryIsInclusive() {
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(emptyList(), emptyList()), 1e-9)
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(listOf(5L), listOf(1_000.0)), 1e-9)
        assertEquals(1.0, HrvAnalyzer.beatAccurateFraction(listOf(0L, 1L), listOf(1_000.0)), 1e-9)
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(Double.NaN))
        assertTrue(HrvAnalyzer.beatValuesAreTrustworthy(HrvAnalyzer.BEAT_ACCURACY_MIN_FRACTION))
        assertFalse(HrvAnalyzer.beatValuesAreTrustworthy(HrvAnalyzer.BEAT_ACCURACY_MIN_FRACTION - 0.01))
    }
}
