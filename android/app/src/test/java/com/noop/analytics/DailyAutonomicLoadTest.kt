package com.noop.analytics

import kotlin.math.exp
import kotlin.math.sqrt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyAutonomicLoadTest {
    @Test
    fun needsSevenStrictlyPriorDays() {
        val sixPrior = (1..6).map {
            day(it, rhr = 58.0 + it % 3, hrv = 66.0 + it * 2)
        }
        val cold = DailyAutonomicLoad.readout(
            sixPrior + day(7, rhr = 66.0, hrv = 55.0),
        )
        assertNull(cold.value)
        assertEquals(DailyAutonomicLoad.Confidence.UNAVAILABLE, cold.confidence)
        assertEquals(6, cold.baselineDays)

        val scored = DailyAutonomicLoad.readout(
            sixPrior +
                day(7, rhr = 61.0, hrv = 75.0) +
                day(8, rhr = 66.0, hrv = 55.0),
        )
        assertNotNull(scored.value)
        assertEquals(7, scored.baselineDays)
        assertEquals("2026-01-08", scored.asOf)
    }

    @Test
    fun twoSignalGoldenValueMatchesAppleImplementation() {
        val rhr = listOf(60.0, 61.0, 59.0, 62.0, 58.0, 60.0, 60.0)
        val hrv = listOf(70.0, 72.0, 68.0, 74.0, 66.0, 70.0, 70.0)
        val prior = rhr.zip(hrv).mapIndexed { index, pair ->
            day(index + 1, pair.first, pair.second)
        }
        val readout = DailyAutonomicLoad.readout(
            prior + day(8, rhr = 62.0, hrv = 66.0),
        )
        val raw = (62.0 - 60.0) / sqrt(10.0 / 7.0) +
            (70.0 - 66.0) / sqrt(40.0 / 7.0)
        val expected = 3.0 / (1.0 + exp(-raw))

        assertEquals(expected, readout.value!!, 1e-12)
        assertEquals(DailyAutonomicLoad.Confidence.RELIABLE, readout.confidence)
        assertEquals(
            listOf(
                DailyAutonomicLoad.Signal.RESTING_HEART_RATE,
                DailyAutonomicLoad.Signal.HEART_RATE_VARIABILITY,
            ),
            readout.observedSignals,
        )
    }

    @Test
    fun oneSignalAndZeroSpreadNeverBecomeReliable() {
        val oneSignal = (1..8).map { day(it, rhr = null, hrv = 60.0 + it) }
        val limited = DailyAutonomicLoad.readout(
            oneSignal + day(9, rhr = null, hrv = 58.0),
        )
        assertNotNull(limited.value)
        assertEquals(DailyAutonomicLoad.Confidence.LIMITED, limited.confidence)

        val flat = (1..8).map { day(it, rhr = 60.0, hrv = 70.0) }
        val unavailable = DailyAutonomicLoad.readout(
            flat + day(9, rhr = 60.0, hrv = 70.0),
        )
        assertNull(unavailable.value)
        assertTrue(
            unavailable.limitations.contains(
                DailyAutonomicLoad.Limitation.RESTING_HEART_RATE_BASELINE_HAS_NO_SPREAD,
            ),
        )
    }

    @Test
    fun futureDaysCannotRewriteHistoricalPoints() {
        val firstEight = (1..8).map {
            day(it, rhr = 58.0 + it % 5, hrv = 65.0 + (it * 3) % 8)
        }
        val original = DailyAutonomicLoad.causalTrend(firstEight)
        val withFuture = DailyAutonomicLoad.causalTrend(
            firstEight +
                day(9, rhr = 120.0, hrv = 12.0) +
                day(10, rhr = 45.0, hrv = 120.0),
        )

        assertEquals(original, withFuture.take(original.size))
        assertTrue(original.take(7).all { it.value == null })
        assertNotNull(original.last().value)
    }

    private fun day(number: Int, rhr: Double?, hrv: Double?) =
        DailyAutonomicLoad.Day(
            day = "2026-01-%02d".format(number),
            restingHeartRate = rhr,
            hrv = hrv,
        )
}
