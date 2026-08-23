package com.noop.analytics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgeMetricProfileTest {
    @Test
    fun legacyRowsAreAcceptedOnlyUntilProvenanceIsRequired() {
        val current = AgeMetricProfile.fitnessAgeToken(40.0, "female")
        assertTrue(AgeMetricProfile.accepts(null, current, provenanceRequired = false))
        assertFalse(AgeMetricProfile.accepts(null, current, provenanceRequired = true))
    }

    @Test
    fun validAgeAndSexCorrectionsChangeTheToken() {
        val original = AgeMetricProfile.fitnessAgeToken(40.0, "female")
        assertNotEquals(original, AgeMetricProfile.fitnessAgeToken(41.0, "female"))
        assertNotEquals(original, AgeMetricProfile.fitnessAgeToken(40.0, "male"))
        assertFalse(AgeMetricProfile.accepts(
            original, AgeMetricProfile.fitnessAgeToken(41.0, "female"), provenanceRequired = false,
        ))
    }

    @Test
    fun removingWaistInvalidatesOnlyTheOptionalVo2Token() {
        assertNotNull(AgeMetricProfile.vo2maxEstimateToken(40.0, "female", 82.0))
        assertNull(AgeMetricProfile.vo2maxEstimateToken(40.0, "female", 0.0))
        assertNotNull(AgeMetricProfile.fitnessAgeToken(40.0, "female"))
    }

    @Test
    fun fitnessAgeV2NeverAcceptsMissingOrLegacyCalibrationMarkers() {
        val fitness = AgeMetricProfile.fitnessAgeToken(40.0, "female")
        val vo2 = AgeMetricProfile.vo2maxEstimateToken(40.0, "female", 82.0)

        assertFalse(AgeMetricProfile.acceptsFitnessAge(null, fitness))
        assertFalse(AgeMetricProfile.acceptsFitnessAge(391.0, fitness))
        assertTrue(AgeMetricProfile.acceptsFitnessAge(fitness, fitness))
        assertFalse(AgeMetricProfile.acceptsVO2maxEstimate(null, vo2))
        assertTrue(AgeMetricProfile.acceptsVO2maxEstimate(vo2, vo2))
        assertNotEquals(AgeMetricProfile.LEGACY_FITNESS_AGE_KEY, AgeMetricProfile.FITNESS_AGE_KEY)
        assertNotEquals(
            AgeMetricProfile.LEGACY_VO2MAX_ESTIMATE_KEY,
            AgeMetricProfile.VO2MAX_ESTIMATE_KEY,
        )
    }

    @Test
    fun vitalityV2NeverAcceptsAMissingOrLegacyMarker() {
        val current = AgeMetricProfile.vitalityToken(40.0)

        assertFalse(AgeMetricProfile.acceptsVitality(null, current))
        assertFalse(AgeMetricProfile.acceptsVitality(39.0, current))
        assertTrue(AgeMetricProfile.acceptsVitality(current, current))
        assertNotEquals(AgeMetricProfile.LEGACY_VITALITY_KEY, AgeMetricProfile.VITALITY_KEY)
    }
}
