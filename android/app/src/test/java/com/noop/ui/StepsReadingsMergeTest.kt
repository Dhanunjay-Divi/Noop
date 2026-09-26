package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** Primary Steps detail must match Today: only measured imports qualify. */
class StepsReadingsMergeTest {

    private fun r(day: String, v: Double, src: String) = VitalReading(day, v, src)

    @Test
    fun measuredImportsAreTheOnlyDisplayedReadings() {
        val motionDerived = mapOf(
            "2026-07-13" to r("2026-07-13", 9_000.0, MOTION_DERIVED_STEPS_SOURCE),
            "2026-07-11" to r("2026-07-11", 4_000.0, MOTION_DERIVED_STEPS_SOURCE),
        )
        val imported = mapOf(
            "2026-07-13" to r("2026-07-13", 8_000.0, "health-connect"),
            "2026-07-10" to r("2026-07-10", 7_000.0, "apple-health"),
        )
        val out = mergeStepsReadings(motionDerived, imported)

        // Ascending by day, one reading per imported day. Motion-only days remain absent.
        assertEquals(listOf("2026-07-10", "2026-07-13"), out.map { it.day })
        assertEquals(8_000.0, out.first { it.day == "2026-07-13" }.value, 0.0)
        assertEquals("health-connect", out.first { it.day == "2026-07-13" }.source)
        assertEquals(7_000.0, out.first { it.day == "2026-07-10" }.value, 0.0)
    }

    @Test
    fun emptyInputsYieldEmpty() {
        assertEquals(emptyList<VitalReading>(), mergeStepsReadings(emptyMap(), emptyMap()))
    }

    @Test
    fun importedZeroIsValidButNegativeAndMissingAreRejected() {
        assertEquals(0, validImportedStepCount(0))
        assertEquals(12, validImportedStepCount(12))
        assertEquals(null, validImportedStepCount(-1))
        assertEquals(null, validImportedStepCount(null))
    }
}
