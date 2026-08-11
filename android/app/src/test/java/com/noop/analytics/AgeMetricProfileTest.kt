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
}
