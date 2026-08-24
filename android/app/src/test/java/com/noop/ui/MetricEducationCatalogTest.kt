package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MetricEducationCatalogTest {
    @Test
    fun everyBuiltInExploreMetricHasSpecificEducation() {
        val builtIns = setOf("recovery", "strain", "hrv", "rhr", "sleep", "efficiency", "spo2", "resp")

        for (key in builtIns) {
            assertTrue("$key must not use generic education", AndroidMetricKnowledge.educationFor(key).isMetricSpecific)
        }
    }

    @Test
    fun everyKnownImportedExploreMetricHasSpecificEducation() {
        val knownImported = setOf(
            "avg_hr",
            "max_hr",
            "calories_in",
            "protein_g",
            "carbs_g",
            "fat_g",
            "mood",
            "body_temp",
            "basal_body_temp",
        )

        for (key in knownImported) {
            assertTrue(key in AndroidMetricKnowledge.specificallySupportedKeys)
            assertTrue("$key must not use generic education", AndroidMetricKnowledge.educationFor(key).isMetricSpecific)
        }
    }

    @Test
    fun aliasesResolveToTheSameEducationWithoutDuplicatingCopy() {
        val aliases = listOf(
            "strain" to "effort",
            "hrv" to "avg_hrv",
            "rhr" to "resting_hr",
            "sleep" to "sleep_total_min",
            "efficiency" to "sleep_efficiency",
            "spo2" to "spo2_pct",
            "resp" to "resp_rate",
        )

        for ((canonical, alias) in aliases) {
            assertTrue(alias in AndroidMetricKnowledge.specificallySupportedKeys)
            assertTrue(AndroidMetricKnowledge.educationFor(canonical) === AndroidMetricKnowledge.educationFor(alias))
        }
    }

    @Test
    fun unknownImportedMetricFailsClosedToGenericEducation() {
        val generic = AndroidMetricKnowledge.educationFor("future_sensor_value")

        assertFalse(generic.isMetricSpecific)
        assertNotEquals(0, generic.whatItIs)
        assertNotEquals(0, generic.howMeasured)
        assertNotEquals(0, generic.limitations)
    }
}
