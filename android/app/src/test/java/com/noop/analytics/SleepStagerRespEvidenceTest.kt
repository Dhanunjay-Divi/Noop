package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepStagerRespEvidenceTest {
    @Test fun evidenceSeparatesMissingMeasuredAndDegenerateBars() {
        assertEquals(SleepStager.RespEvidence.UNMEASURED, SleepStager.RespEvidence.of(Double.NaN, 0.5, 1.0))
        assertEquals(SleepStager.RespEvidence.REGULAR, SleepStager.RespEvidence.of(0.4, 0.5, 1.0))
        assertEquals(SleepStager.RespEvidence.MEASURED_MID_BAND, SleepStager.RespEvidence.of(0.7, 0.5, 1.0))
        assertEquals(SleepStager.RespEvidence.IRREGULAR, SleepStager.RespEvidence.of(1.1, 0.5, 1.0))
        assertEquals(SleepStager.RespEvidence.BARS_DEGENERATE, SleepStager.RespEvidence.of(0.5, 0.5, 0.5))
    }

    @Test fun newRepresentationPreservesFormerClassifierLabels() {
        val moves = listOf(0.0, 0.12, 0.2)
        val hrs = listOf(50.0, 60.0, 80.0, Double.NaN)
        val hrVars = listOf(0.0, 5.0)
        val rmssds = listOf(20.0, 60.0, Double.NaN)
        val rrvs = listOf(0.4, 0.7, 1.1, Double.NaN)
        val bars = listOf(0.5 to 1.0, 0.5 to 0.5, null to null)

        fun former(f: SleepStager.EpochFeatures, low: Double?, high: Double?, sparse: Boolean): String {
            val hasHr = f.hr.isFinite()
            val hrLow = hasHr && f.hr <= 55
            val hrHigh = hasHr && f.hr >= 70
            val parasympOk = !f.rmssd.isFinite() || f.rmssd >= 50
            val hrVarHigh = f.hrVar.isFinite() && f.hrVar >= 1
            val cardiac = hrHigh || hrVarHigh
            val wakeCardiac = if (sparse) hrHigh else cardiac
            val irregular = f.rrv.isFinite() && high != null && f.rrv >= high
            val regular = !f.rrv.isFinite() || (low != null && f.rrv <= low)
            val still = f.moveFrac <= SleepStager.stageStillMoveFrac
            val moving = f.moveFrac >= SleepStager.stageWakeMoveFrac
            if (moving && (wakeCardiac || !hasHr)) return "wake"
            if (still && parasympOk && hrLow && regular) return "deep"
            if (still && cardiac && irregular) return "rem"
            if (still && hrHigh && hrVarHigh && !f.rrv.isFinite()) return "rem"
            return "light"
        }

        var checked = 0
        for (move in moves) for (hr in hrs) for (hrVar in hrVars) for (rmssd in rmssds) for (rrv in rrvs) {
            for ((low, high) in bars) for (sparse in listOf(false, true)) {
                val f = SleepStager.EpochFeatures(
                    index = 0, midTs = 0.0, count = 0.0, moveFrac = move, ckSleep = true,
                    hr = hr, hrVar = hrVar, rmssd = rmssd, sdnn = 0.0,
                    respRate = if (rrv.isFinite()) 14.0 else Double.NaN, rrv = rrv, clock = 0.5,
                )
                assertEquals(
                    former(f, low, high, sparse),
                    SleepStager.classifyOne(f, 55.0, 70.0, 50.0, 1.0, high, low, sparse),
                )
                checked += 1
            }
        }
        assertTrue(checked > 1_000)
    }
}
