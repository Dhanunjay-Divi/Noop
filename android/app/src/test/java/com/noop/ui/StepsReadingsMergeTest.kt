package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #377: the Steps detail must resolve steps with the SAME precedence as the Today Steps tile —
 * measured Apple/Health Connect steps win over WHOOP motion estimates, which in turn win over the
 * calibrated fallback.
 */
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
        val calibratedEstimate = mapOf(
            "2026-07-13" to r("2026-07-13", 60_000.0, CALIBRATED_MOTION_STEPS_SOURCE),
            "2026-07-11" to r("2026-07-11", 60_000.0, CALIBRATED_MOTION_STEPS_SOURCE),
        )
        val out = mergeStepsReadings(motionDerived, imported, calibratedEstimate)

        // Ascending by day, one reading per day across the union.
        assertEquals(listOf("2026-07-10", "2026-07-11", "2026-07-13"), out.map { it.day })
        assertEquals(8_000.0, out.first { it.day == "2026-07-13" }.value, 0.0)
        assertEquals("health-connect", out.first { it.day == "2026-07-13" }.source)
        assertEquals("Motion-derived estimate", provenanceDisplayLabel(MOTION_DERIVED_STEPS_SOURCE))
        // Imported measured steps fill a day with no @57 estimate.
        assertEquals(7_000.0, out.first { it.day == "2026-07-10" }.value, 0.0)
        // The estimate still shows where there is genuinely nothing else (matches the card's "est." fallback).
        assertEquals(60_000.0, out.first { it.day == "2026-07-11" }.value, 0.0)
        assertEquals("Calibrated motion estimate", provenanceDisplayLabel(CALIBRATED_MOTION_STEPS_SOURCE))
    }

    @Test
    fun emptyInputsYieldEmpty() {
        assertEquals(emptyList<VitalReading>(), mergeStepsReadings(emptyMap(), emptyMap(), emptyMap()))
    }
}
