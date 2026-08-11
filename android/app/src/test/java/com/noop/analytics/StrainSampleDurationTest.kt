package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** Per-interval TRIMP regression fixtures. Kotlin/Swift twins intentionally use the same shapes. */
class StrainSampleDurationTest {
    private val restingHR = 60.0
    private val maxHR = 190.0
    private val reserve = maxHR - restingHR
    private val hardHR = (restingHR + 0.85 * reserve).toInt() // Edwards zone 4

    private fun series(vararg timestamps: Long): List<HrSample> =
        timestamps.map { HrSample(deviceId = "t", ts = it, bpm = hardHR) }

    private fun uniform(count: Int, stepSeconds: Long): List<HrSample> =
        (0 until count).map { HrSample(deviceId = "t", ts = it * stepSeconds, bpm = hardHR) }

    @Test
    fun uniformSeriesMatchesPreviouslyShippedFormula() {
        val samples = uniform(120, 30)
        val oldValue = samples.sumOf {
            StrainScorer.zoneWeight(it.bpm.toDouble(), restingHR, reserve)
        }.toDouble() * StrainScorer.sampleDurationMinutes(samples)
        val newValue = StrainScorer.edwardsTRIMP(
            samples, restingHR, reserve, StrainScorer.sampleDurationsMinutes(samples)
        )

        assertEquals(oldValue, newValue, 1e-9)
        assertEquals(240.0, newValue, 1e-9)
    }

    @Test
    fun mixedCadenceUsesEveryAdjacentInterval() {
        val live = (0 until 10).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = hardHR) }
        val banked = (0 until 120).map {
            HrSample(deviceId = "t", ts = 60L + it * 30L, bpm = hardHR)
        }
        val samples = live + banked
        val trimp = StrainScorer.edwardsTRIMP(
            samples, restingHR, reserve, StrainScorer.sampleDurationsMinutes(samples)
        )

        assertTrue("expected the banked intervals to count (got $trimp)", trimp > 230.0)
    }

    @Test
    fun addingLowHeartRateContextCannotShrinkWorkoutTRIMP() {
        val workout = (0 until 120).map {
            HrSample(deviceId = "t", ts = 1_000L + it * 30L, bpm = hardHR)
        }
        val idle = (0 until 60).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = 55) }
        fun trimp(samples: List<HrSample>) = StrainScorer.edwardsTRIMP(
            samples, restingHR, reserve, StrainScorer.sampleDurationsMinutes(samples)
        )

        assertTrue(trimp(idle + workout) >= trimp(workout) - 1e-9)
    }

    @Test
    fun dropoutGapIsCapped() {
        assertEquals(
            listOf(StrainScorer.maxSampleGapMin, StrainScorer.maxSampleGapMin),
            StrainScorer.sampleDurationsMinutes(series(0, 3 * 3_600L)),
        )
    }

    @Test
    fun normalSparseCadenceIsNotCapped() {
        assertEquals(listOf(0.5, 0.5, 0.5), StrainScorer.sampleDurationsMinutes(uniform(3, 30)))
    }

    @Test
    fun durationEdgesPreserveFallbacks() {
        assertEquals(emptyList<Double>(), StrainScorer.sampleDurationsMinutes(emptyList()))
        assertEquals(listOf(StrainScorer.fallbackSampleMin), StrainScorer.sampleDurationsMinutes(series(5)))
        assertTrue(
            StrainScorer.sampleDurationsMinutes(series(7, 7))
                .all { abs(it - StrainScorer.fallbackSampleMin) < 1e-9 }
        )
    }

    @Test
    fun extremeTimestampsCannotOverflow() {
        assertEquals(
            listOf(StrainScorer.maxSampleGapMin, StrainScorer.maxSampleGapMin),
            StrainScorer.sampleDurationsMinutes(series(Long.MIN_VALUE, Long.MAX_VALUE)),
        )
        assertEquals(0.0, StrainScorer.observedCoverageSeconds(series(Long.MIN_VALUE, Long.MAX_VALUE)), 0.0)
    }

    @Test
    fun isolatedReadingsDoNotQualifyAsObservedCoverage() {
        val isolated = (0 until StrainScorer.minReadings).map {
            HrSample(deviceId = "t", ts = it * 3_600L, bpm = hardHR)
        }
        assertEquals(0.0, StrainScorer.observedCoverageSeconds(isolated), 0.0)
        assertEquals(null, StrainScorer.strain(isolated, maxHR, restingHR))
    }

    @Test
    fun mismatchedDurationInputIsBoundedToAvailablePairs() {
        val value = StrainScorer.edwardsTRIMP(
            series(0, 30), restingHR, reserve, durations = listOf(0.5)
        )
        assertEquals(2.0, value, 1e-9)
    }
}
