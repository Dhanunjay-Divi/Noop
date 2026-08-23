package com.noop.analytics

import com.noop.data.DailyMetric
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IllnessSignalPipelineTest {
    private fun day(
        offset: Long,
        rhr: Int? = 50,
        hrv: Double? = 60.0,
        skin: Double? = 0.0,
        respiration: Double? = 14.0,
    ) = DailyMetric(
        deviceId = "test",
        day = LocalDate.parse("2026-08-23").plusDays(offset).toString(),
        restingHr = rhr,
        avgHrv = hrv,
        skinTempDevC = skin,
        respRateBpm = respiration,
    )

    @Test fun freshCorroboratedShiftUsesOnlyTrustedPerSignalBaselines() {
        val days = (-30L..-3L).map { offset ->
            day(
                offset,
                rhr = 50 + if (offset % 2L == 0L) 1 else -1,
                hrv = 60.0 + if (offset % 2L == 0L) 2.0 else -2.0,
            )
        } + listOf(
            day(-1, rhr = 60, hrv = 40.0, skin = 0.9, respiration = 18.0),
            day(0, rhr = 60, hrv = 40.0, skin = 0.9, respiration = 18.0),
        )
        val prepared = IllnessSignalPipeline.prepare(days, "2026-08-23")
        assertEquals(4, prepared.trustedSignalCount)
        assertTrue(prepared.baselineTrusted)
        val result = IllnessSignalEngine.evaluate(
            prepared.inputs,
            IllnessSignalEngine.Context(baselineTrusted = prepared.baselineTrusted),
            prepared.firedLabels,
        )
        assertEquals(IllnessSignalEngine.Level.RAISED, result.level)
        assertTrue(result.signalCount >= 2)
    }

    @Test fun trustedQuietSignalsAreNotReportedAsStillLearning() {
        val days = (-30L..-3L).map(::day) + listOf(day(-1), day(0))
        val prepared = IllnessSignalPipeline.prepare(days, "2026-08-23")
        assertTrue(prepared.baselineTrusted)
        val result = IllnessSignalEngine.evaluate(
            prepared.inputs,
            IllnessSignalEngine.Context(baselineTrusted = prepared.baselineTrusted),
            prepared.firedLabels,
        )
        assertEquals(IllnessSignalEngine.Level.QUIET, result.level)
        assertTrue(result.copy.contains("No corroborated shift"))
        assertFalse(result.copy.contains("learning"))
    }

    @Test fun sparseRowsDoNotCompressCalendarGapsIntoTrustedHistory() {
        val days = (-60L..-33L).map(::day) + listOf(
            day(-1, 65, 30.0, 1.2, 20.0),
            day(0, 65, 30.0, 1.2, 20.0),
        )
        val prepared = IllnessSignalPipeline.prepare(days, "2026-08-23")
        assertEquals(0, prepared.trustedSignalCount)
        assertFalse(prepared.baselineTrusted)
        assertFalse(prepared.inputs.restingHR?.present ?: true)
    }

    @Test fun untrustedSkinCannotInflateAResultBackedByOnlyOneTrustedSignal() {
        val days = (-30L..-3L).map {
            day(it, rhr = 50, hrv = null, skin = null, respiration = null)
        } + listOf(
            day(-1, rhr = 65, hrv = null, skin = 1.5, respiration = null),
            day(0, rhr = 65, hrv = null, skin = 1.5, respiration = null),
        )
        val prepared = IllnessSignalPipeline.prepare(days, "2026-08-23")
        assertEquals(1, prepared.trustedSignalCount)
        assertFalse(prepared.baselineTrusted)
        assertFalse(prepared.inputs.skinTemp?.present ?: true)
    }

    @Test fun staleFutureAndNonFiniteRowsCannotBecomeCurrentEvidence() {
        val days = (-30L..-3L).map(::day) + listOf(
            day(-5, 70, 20.0, 1.0, 20.0),
            day(1, 80, 10.0, 2.0, 25.0),
            day(0, 50, Double.NaN, Double.POSITIVE_INFINITY, 14.0),
        )
        val prepared = IllnessSignalPipeline.prepare(days, "2026-08-23")
        assertNull(prepared.hrv)
        assertNull(prepared.skinTemp)
        assertEquals("2026-08-23", prepared.restingHR?.latestDay)
        assertEquals("2026-08-23", prepared.respiration?.latestDay)
    }
}
