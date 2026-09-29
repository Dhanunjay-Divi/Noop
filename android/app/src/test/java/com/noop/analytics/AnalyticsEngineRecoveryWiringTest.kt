package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalyticsEngineRecoveryWiringTest {
    private data class Night(
        val hr: List<HrSample>,
        val rr: List<RrInterval>,
        val gravity: List<GravitySample>,
    )

    private fun night(day: String, hours: Int = 7): Night {
        val end = LocalDate.parse(day)
            .atStartOfDay()
            .toEpochSecond(ZoneOffset.UTC) + 6 * 3_600L
        val start = end - hours * 3_600L
        val hr = (start until end).map {
            HrSample(deviceId = "test", ts = it, bpm = 50)
        }
        val gravity = (start until end).map {
            GravitySample(deviceId = "test", ts = it, x = 0.0, y = 0.0, z = 1.0)
        }
        val rr = ArrayList<RrInterval>()
        var ts = start
        var high = false
        while (ts < end) {
            rr += RrInterval(
                deviceId = "test",
                ts = ts,
                rrMs = if (high) 1_205 else 1_195,
            )
            high = !high
            ts += 2
        }
        return Night(hr = hr, rr = rr, gravity = gravity)
    }

    @Test
    fun productionRecoveryOmitsOptionalIndexAndActivityBalanceTerms() {
        val day = "2021-06-17"
        val night = night(day)
        val hrvBase = Baselines.foldHistory(
            List(Baselines.minNightsTrust) { 10.0 },
            Baselines.hrvCfg,
        )
        val rhrBase = Baselines.foldHistory(
            List(Baselines.minNightsTrust) { 50.0 },
            Baselines.restingHRCfg,
        )
        val result = AnalyticsEngine.analyzeDay(
            day = day,
            hr = night.hr,
            rr = night.rr,
            gravity = night.gravity,
            profile = UserProfile(age = 30.0),
            baselines = ProfileBaselines(hrv = hrvBase, restingHR = rhrBase),
        )

        val hrv = requireNotNull(result.daily.avgHrv)
        val rhr = requireNotNull(result.daily.restingHr).toDouble()
        val production = requireNotNull(result.recovery)
        val expectedWithoutUnapprovedTerms = RecoveryScorer.recovery(
            hrv = hrv,
            rhr = rhr,
            resp = result.daily.respRateBpm,
            hrvBaseline = hrvBase,
            rhrBaseline = rhrBase,
            respBaseline = null,
            sleepPerf = result.rest?.div(100.0),
            restQualityBaseline = null,
            skinTempDev = result.daily.skinTempDevC,
            recoveryIndexSlope = null,
            effortBaseline = null,
            priorDayEffort = null,
        )
        assertNotNull(expectedWithoutUnapprovedTerms)
        assertEquals(expectedWithoutUnapprovedTerms!!, production, 1e-12)

        val effortBase = BaselineState(
            baseline = 50.0,
            spread = 5.0,
            nValid = Baselines.minNightsTrust,
            nightsSinceUpdate = 0,
            status = BaselineStatus.TRUSTED,
        )
        val scoreIfOptionalTermsWereWired = RecoveryScorer.recovery(
            hrv = hrv,
            rhr = rhr,
            resp = result.daily.respRateBpm,
            hrvBaseline = hrvBase,
            rhrBaseline = rhrBase,
            respBaseline = null,
            sleepPerf = result.rest?.div(100.0),
            restQualityBaseline = null,
            skinTempDev = result.daily.skinTempDevC,
            recoveryIndexSlope = -10.0,
            effortBaseline = effortBase,
            priorDayEffort = 0.0,
        )
        assertNotNull(scoreIfOptionalTermsWereWired)
        assertTrue(
            "the fixture must detect either optional term being admitted to production",
            abs(scoreIfOptionalTermsWereWired!! - production) > 1.0,
        )
    }
}
