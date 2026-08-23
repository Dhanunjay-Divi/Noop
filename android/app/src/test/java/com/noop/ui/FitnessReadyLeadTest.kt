package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class FitnessReadyLeadTest {
    @Test
    fun progressIncludesBothRequiredCoverageGates() {
        assertEquals(
            "Calibration progress: resting heart rate 4 of 4 nights; activity 1 of 4 days.",
            fitnessReadyLead(rhrDays = 4, activityDays = 1, hasAge = true, hasSex = true),
        )
    }

    @Test
    fun readyAndUnsupportedProfileStatesAreExplicit() {
        assertEquals(
            "Resting heart rate and activity coverage are ready. Refresh to calculate your Fitness Age.",
            fitnessReadyLead(rhrDays = 7, activityDays = 7, hasAge = true, hasSex = true),
        )
        assertEquals(
            "Fitness Age needs a supported profile: age 20–80 and a male or female model coefficient.",
            fitnessReadyLead(rhrDays = 7, activityDays = 7, hasAge = false, hasSex = true),
        )
    }
}
