package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** Primary Steps detail must match Today: measured imports win over classified band motion and the
 * gravity-only calibrated estimate is not part of this merge. */
class StepsReadingsMergeTest {

    private fun r(day: String, v: Double, src: String) = VitalReading(day, v, src)

    @Test
    fun measuredImportWinsByDisplayPrecedence() {
        val motionDerived = mapOf(
            "2026-07-13" to r("2026-07-13", 9_000.0, MOTION_DERIVED_STEPS_SOURCE),
        )
        val imported = mapOf(
            "2026-07-13" to r("2026-07-13", 8_000.0, "health-connect"),
            "2026-07-10" to r("2026-07-10", 7_000.0, "apple-health"),
        )
        val out = mergeStepsReadings(motionDerived, imported)

        // Ascending by day, one reading per day across the union.
        assertEquals(listOf("2026-07-10", "2026-07-13"), out.map { it.day })
        assertEquals(8_000.0, out.first { it.day == "2026-07-13" }.value, 0.0)
        assertEquals("health-connect", out.first { it.day == "2026-07-13" }.source)
        assertEquals("Motion-derived estimate", provenanceDisplayLabel(MOTION_DERIVED_STEPS_SOURCE))
        // Imported measured steps fill a day with no @57 estimate.
        assertEquals(7_000.0, out.first { it.day == "2026-07-10" }.value, 0.0)
    }

    @Test
    fun emptyInputsYieldEmpty() {
        assertEquals(emptyList<VitalReading>(), mergeStepsReadings(emptyMap(), emptyMap()))
    }
}
