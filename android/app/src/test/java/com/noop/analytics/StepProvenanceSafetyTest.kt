package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.ui.VITALITY_WELLNESS_AGE_INPUT_CLAIM
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android parity guard for omitting un-sourced @57-derived DailyMetric steps from Wellness Age. */
class StepProvenanceSafetyTest {
    private fun day(index: Int) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = "2026-07-%02d".format(index),
        totalSleepMin = 450.0,
        restingHr = 55,
        avgHrv = 42.0,
        recovery = 70.0,
        strain = 12.0,
        steps = 54_321,
        activeKcalEst = 500.0,
    )

    @Test
    fun vitalityInputsOmitUnprovenancedDailySteps() {
        val inputs = IntelligenceEngine.vitalityInputs((1..14).map(::day), chronoAge = 40.0)

        assertNull(inputs.steps)
        assertFalse(VitalityEngine.contributions(inputs).any { it.key == "steps" })
        assertNotNull(VitalityEngine.compute(inputs))
    }

    @Test
    fun userFacingVitalityClaimNamesOnlyCurrentV2Inputs() {
        val claim = VITALITY_WELLNESS_AGE_INPUT_CLAIM.lowercase()
        assertFalse(claim.contains("steps"))
        assertFalse(claim.contains("activity"))
        assertTrue(claim.contains("profile age"))
    }
}
