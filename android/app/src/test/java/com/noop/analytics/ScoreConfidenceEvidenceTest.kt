package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.RespSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.roundToInt

class ScoreConfidenceEvidenceTest {
    @Test
    fun stableEvidenceMaskRoundTrips() {
        val evidence = ScoreConfidence.restEvidenceFlags(
            hasSession = true,
            hasStagedSleep = true,
            asleepSeconds = 8.0 * 3_600,
            restorativeSeconds = 3.0 * 3_600,
            efficiency = 0.9,
            motionAvailable = true,
            gravitySparse = false,
            hasRREvidence = true,
            hasRespirationEvidence = true,
        )

        assertEquals(55, evidence.rawValue)
        assertEquals(
            evidence,
            ScoreConfidence.RestEvidenceFlags.fromPersistedValue(evidence.persistedValue),
        )
        assertEquals("sleep_performance", ScoreConfidence.sleepPerformanceSeriesKey)
        assertEquals("rest_confidence", ScoreConfidence.restConfidenceSeriesKey)
        assertEquals("rest_evidence_flags", ScoreConfidence.restEvidenceSeriesKey)
    }

    @Test
    fun evidenceDecoderRejectsUnknownAndInconsistentBits() {
        assertNull(ScoreConfidence.RestEvidenceFlags.fromPersistedValue(128.0))
        assertNull(ScoreConfidence.RestEvidenceFlags.fromPersistedValue(1.5))
        assertNull(ScoreConfidence.RestEvidenceFlags.fromPersistedValue(2.0))
        assertNull(ScoreConfidence.RestEvidenceFlags.fromPersistedValue(8.0))
        assertNull(ScoreConfidence.RestEvidenceFlags.fromPersistedValue(Double.NaN))
    }

    @Test
    fun cardiorespiratoryEvidenceLanesRemainIndependent() {
        val rrOnly = evidence(hasRr = true, hasRespiration = false)
        val respirationOnly = evidence(hasRr = false, hasRespiration = true)

        assertEquals(
            listOf(ScoreConfidence.RestLimitation.MISSING_RESPIRATION_EVIDENCE),
            ScoreConfidence.restAssessment(rrOnly).limitations,
        )
        assertEquals(
            listOf(ScoreConfidence.RestLimitation.MISSING_RR_EVIDENCE),
            ScoreConfidence.restAssessment(respirationOnly).limitations,
        )
    }

    @Test
    fun detailedStageSeriesKeysExcludeTotalSleep() {
        assertTrue(ScoreConfidence.isDetailedSleepStageSeriesKey("sleep_rem_min"))
        assertFalse(ScoreConfidence.isDetailedSleepStageSeriesKey("sleep_total_min"))
    }

    @Test
    fun editedStageMixRecomputesConfidenceFromPreservedSensorEvidence() {
        val beforeEdit = evidence(hasRr = true, hasRespiration = true, restorativeMinutes = 180.0)
        val afterEdit = evidence(hasRr = true, hasRespiration = true, restorativeMinutes = 20.0)

        assertEquals(ScoreConfidence.SOLID, ScoreConfidence.restAssessment(beforeEdit).confidence)
        assertEquals(ScoreConfidence.BUILDING, ScoreConfidence.restAssessment(afterEdit).confidence)
        assertTrue(
            afterEdit.contains(ScoreConfidence.RestEvidenceFlags.IMPLAUSIBLE_STAGE_MIX)
        )
    }

    @Test
    fun intelligenceRecomputesRestEvidenceFromEditedDailyStages() {
        val edited = DailyMetric(
            deviceId = "my-whoop-noop",
            day = "2026-08-25",
            totalSleepMin = 480.0,
            efficiency = 0.9,
            deepMin = 10.0,
            remMin = 10.0,
            lightMin = 460.0,
        )
        val raw = ScoreConfidence.RestRawEvidence(
            hasRREvidence = true,
            hasRespirationEvidence = true,
        )

        val evidence = IntelligenceEngine.restEvidenceAfterSleepEdits(
            daily = edited,
            motionAvailable = true,
            gravitySparse = false,
            rawEvidence = raw,
        )

        assertEquals(ScoreConfidence.BUILDING, ScoreConfidence.restAssessment(evidence).confidence)
        assertTrue(
            evidence.contains(ScoreConfidence.RestEvidenceFlags.IMPLAUSIBLE_STAGE_MIX)
        )
    }

    @Test
    fun editedWinnerUsesItsOwnRawAndMotionEvidence() {
        val firstStart = 100_000L
        val secondStart = 200_000L
        fun stages(start: Long, hours: Long): List<StageSegment> =
            listOf(StageSegment(start, start + hours * 3_600L, "light"))

        val first = DetectedSleep(
            start = firstStart,
            end = firstStart + 4L * 3_600L,
            efficiency = 1.0,
            stages = stages(firstStart, 4),
            restingHR = null,
            avgHRV = null,
        )
        val second = DetectedSleep(
            start = secondStart,
            end = secondStart + 2L * 3_600L,
            efficiency = 1.0,
            stages = stages(secondStart, 2),
            restingHR = null,
            avgHRV = null,
        )
        val daily = DailyMetric(
            deviceId = "my-whoop-noop",
            day = "2026-08-25",
            totalSleepMin = 240.0,
            efficiency = 1.0,
            deepMin = 0.0,
            remMin = 0.0,
            lightMin = 240.0,
        )
        val editedStages = AnalyticsEngine.encodeStages(stages(secondStart, 8))
        val edited = IntelligenceEngine.sleepEditedDaily(
            daily = daily,
            detected = listOf(first, second),
            editsByStart = mapOf(secondStart to editedStages),
            editOnsetByStart = mapOf(secondStart to secondStart),
            tzOffsetSeconds = 0,
            habitualMidsleepSec = null,
            fallbackMainSessionStarts = setOf(firstStart),
        )

        assertEquals(setOf(secondStart), edited.mainSessionStarts)
        assertEquals(480.0, edited.daily.totalSleepMin)
        assertFalse(
            IntelligenceEngine.restMotionAvailable(
                edited.mainSessionStarts,
                mapOf(firstStart to listOf(0.01, 0.02)),
            )
        )

        val rr = (firstStart until firstStart + 3_600L).map { ts ->
            RrInterval("test", ts, if (ts % 2L == 0L) 995 else 1_005)
        }
        val resp = (firstStart until firstStart + 3_600L).map { ts ->
            val phase = (ts - firstStart).toDouble()
            RespSample(
                deviceId = "test",
                ts = ts,
                raw = 1_000 +
                    (100 * kotlin.math.sin(2 * Math.PI * phase / 4)).roundToInt(),
            )
        }
        val raw = ScoreConfidence.restRawEvidence(
            sessions = listOf(first, second),
            rr = rr,
            resp = resp,
            offsetSec = 0,
            habitualMidsleepSec = null,
        ).selecting(edited.mainSessionStarts)

        assertFalse(raw.hasRREvidence)
        assertFalse(raw.hasRespirationEvidence)
    }

    @Test
    fun sparseRespirationWindowsDoNotCountAsEvidence() {
        val start = 1_700_000_000L
        val windowCount = AnalyticsEngine.REST_EVIDENCE_MINIMUM_WINDOWS
        val end = start + windowCount * AnalyticsEngine.REST_EVIDENCE_WINDOW_SECONDS
        val session = DetectedSleep(
            start = start,
            end = end,
            efficiency = 0.9,
            stages = listOf(StageSegment(start, end, "light")),
            restingHR = null,
            avgHRV = null,
        )
        val sparse = (0 until windowCount).flatMap { window ->
            (0 until 30).map { index ->
                val phase = (index % 4).toDouble() * 2 * Math.PI / 4
                RespSample(
                    deviceId = "test",
                    ts = start +
                        window * AnalyticsEngine.REST_EVIDENCE_WINDOW_SECONDS +
                        index * 10L,
                    raw = 1_000 + (100 * kotlin.math.sin(phase)).roundToInt(),
                )
            }
        }
        val oldEvidence = SleepStager.respRateAndRRV(
            sparse.take(30).map { it.raw.toDouble() }
        )
        assertTrue(oldEvidence.first.isFinite())
        assertTrue(oldEvidence.second.isFinite())

        val counts = AnalyticsEngine.mainSleepEvidenceCounts(
            mainGroup = listOf(session),
            rr = emptyList(),
            resp = sparse,
        )

        assertEquals(windowCount, counts.eligibleWindows)
        assertEquals(0, counts.validRespirationWindows)
        assertFalse(counts.resolved.hasRespirationEvidence)
    }

    @Test
    fun denseRespirationWindowsStillCountAsEvidence() {
        val start = 1_700_000_000L
        val windowCount = AnalyticsEngine.REST_EVIDENCE_MINIMUM_WINDOWS
        val end = start + windowCount * AnalyticsEngine.REST_EVIDENCE_WINDOW_SECONDS
        val session = DetectedSleep(
            start = start,
            end = end,
            efficiency = 0.9,
            stages = listOf(StageSegment(start, end, "light")),
            restingHR = null,
            avgHRV = null,
        )
        val dense = (start until end).map { ts ->
            val phase = ((ts - start) % 4L).toDouble() * 2 * Math.PI / 4
            RespSample(
                deviceId = "test",
                ts = ts,
                raw = 1_000 + (100 * kotlin.math.sin(phase)).roundToInt(),
            )
        }

        val counts = AnalyticsEngine.mainSleepEvidenceCounts(
            mainGroup = listOf(session),
            rr = emptyList(),
            resp = dense,
        )

        assertEquals(windowCount, counts.validRespirationWindows)
        assertTrue(counts.resolved.hasRespirationEvidence)
    }

    private fun evidence(
        hasRr: Boolean,
        hasRespiration: Boolean,
        restorativeMinutes: Double = 180.0,
    ) = ScoreConfidence.restEvidenceFlags(
        hasSession = true,
        hasStagedSleep = true,
        asleepSeconds = 480.0 * 60,
        restorativeSeconds = restorativeMinutes * 60,
        efficiency = 0.9,
        motionAvailable = true,
        gravitySparse = false,
        hasRREvidence = hasRr,
        hasRespirationEvidence = hasRespiration,
    )
}
