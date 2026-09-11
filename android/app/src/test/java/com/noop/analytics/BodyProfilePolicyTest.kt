package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BodyProfilePolicyTest {
    @Test
    fun adultBmi_requiresConfirmedAdultInputs() {
        assertNull(BodyProfilePolicy.adultBmi(30, 75.0, 178.0, false))
        assertNull(BodyProfilePolicy.adultBmi(19, 75.0, 178.0, true))
        assertEquals(
            23.671,
            BodyProfilePolicy.adultBmi(30, 75.0, 178.0, true)!!,
            0.001,
        )
    }

    @Test
    fun targetProgress_failsClosedForUnsupportedScreeningContexts() {
        assertEquals(
            BodyWeightTargetAvailability.MEASUREMENTS_UNCONFIRMED,
            BodyProfilePolicy.targetAvailability(30, 75.0, 178.0, 70.0, false),
        )
        assertEquals(
            BodyWeightTargetAvailability.ADULT_SCREENING_UNAVAILABLE,
            BodyProfilePolicy.targetAvailability(19, 75.0, 178.0, 70.0, true),
        )
        assertEquals(
            BodyWeightTargetAvailability.CURRENT_WEIGHT_NEEDS_CLINICAL_CONTEXT,
            BodyProfilePolicy.targetAvailability(30, 55.0, 178.0, 60.0, true),
        )
        assertEquals(
            BodyWeightTargetAvailability.TARGET_NEEDS_CLINICAL_CONTEXT,
            BodyProfilePolicy.targetAvailability(30, 75.0, 178.0, 55.0, true),
        )
        assertEquals(
            BodyWeightTargetAvailability.AVAILABLE,
            BodyProfilePolicy.targetAvailability(30, 75.0, 178.0, 70.0, true),
        )
    }
}
