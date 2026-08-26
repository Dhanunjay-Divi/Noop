package com.noop.ui

import com.noop.analytics.ScoreConfidence
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepConfidenceFallbackTest {
    @Test
    fun legacyStagedSleepRequiresDeepOrRem() {
        assertFalse(
            "awake/light-only segments are not staged sleep evidence",
            hasEngineStagedSleep(Stages(awake = 30.0, light = 390.0, deep = 0.0, rem = 0.0)),
        )
        assertTrue(hasEngineStagedSleep(Stages(awake = 30.0, light = 389.0, deep = 1.0, rem = 0.0)))
        assertTrue(hasEngineStagedSleep(Stages(awake = 30.0, light = 389.0, deep = 0.0, rem = 1.0)))
    }

    @Test
    fun persistedEvidenceKeepsRrAndRespirationIndependent() {
        val evidence = ScoreConfidence.restEvidenceFlags(
            hasSession = true,
            hasStagedSleep = true,
            asleepSeconds = 8.0 * 3_600,
            restorativeSeconds = 3.0 * 3_600,
            efficiency = 0.9,
            motionAvailable = true,
            gravitySparse = false,
            hasRREvidence = true,
            hasRespirationEvidence = false,
        )
        val legacy = legacyAssessment()

        val resolved = resolvedRestAssessment(ScoreConfidence.BUILDING, evidence, legacy)

        assertEquals(ScoreConfidence.BUILDING, resolved.confidence)
        assertEquals(
            listOf(ScoreConfidence.RestLimitation.MISSING_RESPIRATION_EVIDENCE),
            resolved.limitations,
        )
    }

    @Test
    fun legacyTierCannotImplyCardiorespiratoryEvidence() {
        val resolved = resolvedRestAssessment(
            ScoreConfidence.SOLID,
            persistedEvidence = null,
            legacyAssessment = legacyAssessment(),
        )

        assertEquals(ScoreConfidence.BUILDING, resolved.confidence)
        assertEquals(
            listOf(
                ScoreConfidence.RestLimitation.MISSING_RR_EVIDENCE,
                ScoreConfidence.RestLimitation.MISSING_RESPIRATION_EVIDENCE,
            ),
            resolved.limitations,
        )
    }

    private fun legacyAssessment() = ScoreConfidence.restAssessment(
        hasSession = true,
        hasStagedSleep = true,
        asleepSeconds = 8.0 * 3_600,
        restorativeSeconds = 3.0 * 3_600,
        efficiency = 0.9,
        motionUnavailable = false,
        hasRREvidence = false,
        hasRespirationEvidence = false,
    )
}
