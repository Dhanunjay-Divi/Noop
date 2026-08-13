package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ReadinessEngineTests.swift.
 * Same fixtures (28 baseline days + today), same assertions.
 */
class ReadinessEngineTest {

    private fun d(
        i: Int,
        hrv: Double?,
        rhr: Int?,
        strain: Double?,
        resp: Double? = null,
    ): DailyMetric = DailyMetric(
        deviceId = "test",
        day = "2024-03-%02d".format(i),
        restingHr = rhr,
        avgHrv = hrv,
        strain = strain,
        respRateBpm = resp,
    )

    /** 28 baseline days with gentle variation (so SD > 0), then `today` as day 29. */
    private fun baseline(
        todayHrv: Double?,
        todayRhr: Int?,
        todayStrain: Double?,
        todayResp: Double? = null,
        baseStrain: Double = 10.0,
    ): List<DailyMetric> {
        val days = mutableListOf<DailyMetric>()
        for (i in 1..28) {
            days.add(
                d(
                    i,
                    hrv = if (i % 2 == 0) 62.0 else 58.0,
                    rhr = if (i % 2 == 0) 54 else 50,
                    strain = baseStrain,
                    resp = if (i % 2 == 0) 14.5 else 13.5,
                )
            )
        }
        days.add(d(29, hrv = todayHrv, rhr = todayRhr, strain = todayStrain, resp = todayResp))
        return days
    }

    @Test
    fun insufficientWhenEmpty() {
        assertEquals(ReadinessEngine.Level.INSUFFICIENT, ReadinessEngine.evaluate(emptyList()).level)
    }

    @Test
    fun primedWhenSignalsAligned() {
        // Today: HRV well above baseline, resting HR below, load steady.
        val r = ReadinessEngine.evaluate(baseline(todayHrv = 72.0, todayRhr = 46, todayStrain = 10.0))
        assertEquals(ReadinessEngine.Level.PRIMED, r.level)
        assertEquals(ReadinessEngine.Flag.GOOD, r.signals.firstOrNull { it.key == "hrv" }?.flag)
        assertEquals(ReadinessEngine.Flag.GOOD, r.signals.firstOrNull { it.key == "rhr" }?.flag)
        assertEquals(ReadinessEngine.Flag.NEUTRAL, r.signals.firstOrNull { it.key == "acwr" }?.flag)
        assertEquals(
            "Your measured recovery trends are aligned with your recent baseline.",
            r.summary,
        )
        assertEquals("Aligned", r.headline)
        assertFalse(r.summary.contains("load", ignoreCase = true))
        assertFalse(r.summary.contains("train", ignoreCase = true))
    }

    @Test
    fun rundownWhenTwoRecoverySignalsDown() {
        // Today: HRV suppressed AND resting HR elevated -> two "bad" recovery signals.
        val r = ReadinessEngine.evaluate(baseline(todayHrv = 50.0, todayRhr = 60, todayStrain = 10.0))
        assertEquals(ReadinessEngine.Level.RUNDOWN, r.level)
        assertEquals("Multiple shifts", r.headline)
        assertFalse(r.summary.contains("rest today", ignoreCase = true))
        assertFalse(r.summary.contains("train", ignoreCase = true))
    }

    @Test
    fun recentLoadSpikeIsDescriptiveOnly() {
        // With no evaluable recovery signals, even an extreme ratio remains context—not readiness.
        val days = mutableListOf<DailyMetric>()
        for (i in 1..21) days.add(d(i, hrv = 60.0, rhr = 52, strain = 5.0))
        for (i in 22..28) days.add(d(i, hrv = 60.0, rhr = 52, strain = 15.0))
        days.add(d(29, hrv = 60.0, rhr = 52, strain = 15.0))
        val r = ReadinessEngine.evaluate(days)
        assertEquals(ReadinessEngine.Flag.NEUTRAL, r.signals.firstOrNull { it.key == "acwr" }?.flag)
        assertEquals(ReadinessEngine.Level.INSUFFICIENT, r.level)
        assertNotNull(r.acwr)
        assertTrue(r.acwr!! > 1.5)
        val load = r.signals.firstOrNull { it.key == "acwr" }
        assertEquals("Recent-load ratio", load?.label)
        assertTrue(load?.detail?.contains("7-day mean is") == true)
        assertFalse(load?.detail?.contains("injury", ignoreCase = true) == true)
        assertFalse(load?.detail?.contains("sweet spot", ignoreCase = true) == true)
        assertFalse(r.summary.contains("train", ignoreCase = true))
    }

    @Test
    fun recentLoadRatioCannotChangeRecoveryDrivenReadiness() {
        val steady = baseline(todayHrv = 72.0, todayRhr = 46, todayStrain = 10.0)
        val spiking = steady.mapIndexed { index, row ->
            // Eight identical final-field changes used to cancel in the XOR cache fingerprint.
            if (index >= 21) row.copy(strain = 100.0) else row
        }

        val steadyReadiness = ReadinessEngine.evaluate(steady)
        val spikeReadiness = ReadinessEngine.evaluate(spiking)
        assertEquals(ReadinessEngine.Level.PRIMED, steadyReadiness.level)
        assertEquals(steadyReadiness.level, spikeReadiness.level)
        assertEquals(steadyReadiness.headline, spikeReadiness.headline)
        assertEquals(steadyReadiness.summary, spikeReadiness.summary)
        assertEquals(ReadinessEngine.Flag.NEUTRAL, spikeReadiness.signals.first { it.key == "acwr" }.flag)
        assertTrue(spikeReadiness.acwr!! > steadyReadiness.acwr!!)
    }

    @Test
    fun trainingMonotonyCannotDowngradeAlignedRecovery() {
        val days = baseline(todayHrv = 72.0, todayRhr = 46, todayStrain = 10.0).toMutableList()
        // Keep enough non-zero variation for the Foster ratio, but make the recent week deliberately
        // uniform enough to produce the descriptive Training variety watch signal.
        val recent = listOf(10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 11.0, 10.0)
        recent.forEachIndexed { offset, strain ->
            val index = 21 + offset
            days[index] = days[index].copy(strain = strain)
        }

        val read = ReadinessEngine.evaluate(days)
        assertNotNull(read.signals.firstOrNull { it.key == "monotony" })
        assertEquals(ReadinessEngine.Level.PRIMED, read.level)
        assertEquals("Aligned", read.headline)
    }

    @Test
    fun respRateRiseFlags() {
        // Today resp rate well above baseline (~14) -> a shifted signal is present.
        val r = ReadinessEngine.evaluate(
            baseline(todayHrv = 60.0, todayRhr = 52, todayStrain = 10.0, todayResp = 18.0)
        )
        assertTrue(r.signals.any { it.key == "respRate" })
        assertFalse(
            r.signals.first { it.key == "respRate" }.detail.contains("sick", ignoreCase = true)
        )
    }

    @Test
    fun respRate_implausibleOutlierProducesNoSignal() {
        // A physiologically implausible RSA value (outside the 8-25 bpm sanity band) must produce
        // NO resp signal, even though it is far above baseline — this rejects degenerate RSA outputs
        // so they can't drive readiness toward STRAINED/RUNDOWN. (respRateRiseFlags above confirms a
        // genuine in-band elevation still flags after the threshold raise.)
        val r = ReadinessEngine.evaluate(
            baseline(todayHrv = 60.0, todayRhr = 52, todayStrain = 10.0, todayResp = 40.0)
        )
        assertTrue(r.signals.none { it.key == "respRate" })
    }

    @Test
    fun explicitTodayWithoutMatchingRowIsInsufficient() {
        // Stale historical import: newest row is 2024-03-29, but the device's real calendar day is later.
        // An explicit `today` with no matching row must read INSUFFICIENT — NOT synthesize off the newest
        // stored (stale) row (issue #23/#24).
        val days = baseline(todayHrv = 72.0, todayRhr = 46, todayStrain = 10.0)
        assertEquals(ReadinessEngine.Level.INSUFFICIENT, ReadinessEngine.evaluate(days, today = "2026-06-08").level)
        // The day that IS present still computes (no regression for current data).
        assertTrue(ReadinessEngine.evaluate(days, today = "2024-03-29").level != ReadinessEngine.Level.INSUFFICIENT)
        // The legacy no-`today` path is unchanged — still falls back to the most recent row.
        assertTrue(ReadinessEngine.evaluate(days).level != ReadinessEngine.Level.INSUFFICIENT)
    }

    @Test
    fun historicalReadinessIgnoresFutureLoadRows() {
        val days = baseline(todayHrv = 60.0, todayRhr = 52, todayStrain = 10.0).toMutableList()
        val historical = ReadinessEngine.evaluate(days, today = "2024-03-29")
        days.add(
            DailyMetric(
                deviceId = "test", day = "2024-03-30", restingHr = 52, avgHrv = 60.0,
                strain = 100.0, respRateBpm = 14.0,
            )
        )

        val withFuture = ReadinessEngine.evaluate(days, today = "2024-03-29")
        assertEquals(historical.acwr, withFuture.acwr)
        assertEquals(
            historical.signals.firstOrNull { it.key == "acwr" },
            withFuture.signals.firstOrNull { it.key == "acwr" },
        )
    }

    @Test
    fun sparseRowsAcrossMonthsDoNotBecomeTwentyEightDayLoad() {
        val days = mutableListOf<DailyMetric>()
        for (month in 1..12) {
            for (day in listOf(1, 15)) {
                days.add(
                    DailyMetric(
                        deviceId = "test", day = "2024-%02d-%02d".format(month, day),
                        restingHr = 52, avgHrv = 60.0, strain = 10.0, respRateBpm = 14.0,
                    )
                )
            }
        }

        val result = ReadinessEngine.evaluate(days, today = "2024-12-15")
        assertNull(result.acwr)
        assertTrue(result.signals.none { it.key == "acwr" })
    }

    @Test
    fun trainingLoadContextRequiresSeparateAdditiveInput() {
        val days = baseline(todayHrv = 60.0, todayRhr = 52, todayStrain = 10.0)
        // DailyMetric.strain exists, but a nonlinear score must never silently feed ATL/CTL.
        val withoutAdditiveLoad = ReadinessEngine.evaluate(
            days = days,
            today = "2024-03-29",
            additiveLoadEntries = emptyList(),
        )
        assertNull(withoutAdditiveLoad.trainingLoad)

        val additive = (1..29).map {
            TrainingLoadModel.Entry("2024-03-%02d".format(it), 50.0)
        }
        val withAdditiveLoad = ReadinessEngine.evaluate(
            days = days,
            today = "2024-03-29",
            additiveLoadEntries = additive,
        )
        assertEquals(ReadinessEngine.evaluate(days, today = "2024-03-29"), withAdditiveLoad.readiness)
        assertEquals("2024-03-29", withAdditiveLoad.trainingLoad?.day)
        assertEquals(50.0, withAdditiveLoad.trainingLoad?.atl!!, 0.0)
        assertEquals(50.0, withAdditiveLoad.trainingLoad?.ctl!!, 0.0)
        assertEquals(0.0, withAdditiveLoad.trainingLoad?.tsb!!, 0.0)
    }

    @Test
    fun statsHelpers() {
        assertEquals(4.0, ReadinessEngine.mean(listOf(2.0, 4.0, 6.0))!!, 1e-12)
        assertEquals(2.0, ReadinessEngine.sampleSD(listOf(2.0, 4.0, 6.0))!!, 0.0001)
        assertNull(ReadinessEngine.sampleSD(listOf(5.0)))
        assertNull(ReadinessEngine.mean(emptyList()))
    }
}
