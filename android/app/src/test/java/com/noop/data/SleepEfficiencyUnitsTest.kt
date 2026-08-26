package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SleepEfficiencyUnitsTest {
    @Test
    fun explicitPercentConvertsToFraction() {
        assertEquals(0.923, SleepEfficiencyUnits.fractionFromPercent(92.3)!!, 1e-12)
        assertEquals(0.0, SleepEfficiencyUnits.fractionFromPercent(0.0)!!, 0.0)
        assertEquals(1.0, SleepEfficiencyUnits.fractionFromPercent(100.0)!!, 0.0)
    }

    @Test
    fun legacySeriesPercentAndCurrentFractionNormalizeIdentically() {
        assertEquals(0.923, SleepEfficiencyUnits.canonicalFraction(92.3)!!, 1e-12)
        assertEquals(0.923, SleepEfficiencyUnits.canonicalFraction(0.923)!!, 1e-12)
        assertEquals(92.3, SleepEfficiencyUnits.displayPercent(0.923)!!, 1e-12)
        assertEquals(92.3, SleepEfficiencyUnits.displayPercent(92.3)!!, 1e-12)
    }

    @Test
    fun mixedScaleExportAcceptsPercentAndFractionWithoutDoubleDivision() {
        assertEquals(
            0.92,
            SleepEfficiencyUnits.fractionFromFlexibleExport(92.0)!!,
            1e-12,
        )
        assertEquals(
            0.92,
            SleepEfficiencyUnits.fractionFromFlexibleExport(0.92)!!,
            1e-12,
        )
        assertEquals(1.0, SleepEfficiencyUnits.fractionFromFlexibleExport(1.01)!!, 0.0)
        assertEquals(1.0, SleepEfficiencyUnits.fractionFromFlexibleExport(1.5)!!, 0.0)
        assertEquals(
            0.015001,
            SleepEfficiencyUnits.fractionFromFlexibleExport(1.5001)!!,
            1e-12,
        )
        assertEquals(1.0, SleepEfficiencyUnits.fractionFromFlexibleExport(100.1)!!, 0.0)
    }

    @Test
    fun strictBoundariesRejectInvalidWhileFlexibleBoundaryMatchesAppleClamp() {
        for (value in listOf(-1.0, 100.1, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNull(SleepEfficiencyUnits.fractionFromPercent(value))
            assertNull(SleepEfficiencyUnits.canonicalFraction(value))
        }
        for (value in listOf(-1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertNull(SleepEfficiencyUnits.fractionFromFlexibleExport(value))
        }
        // Flexible parser parity accepts and clamps this; stored-series normalization stays strict.
        assertEquals(1.0, SleepEfficiencyUnits.fractionFromFlexibleExport(100.1)!!, 0.0)
        assertNull(SleepEfficiencyUnits.canonicalFraction(100.1))
    }

    @Test
    fun onlySleepEfficiencySeriesIsUnitNormalized() {
        val legacy = MetricSeriesRow("device", "2026-08-25", "sleep_efficiency", 92.0)
        val normalized = SleepEfficiencyUnits.normalizedSeriesRow(legacy)!!
        assertEquals(0.92, normalized.value, 1e-12)

        val unrelated = MetricSeriesRow("device", "2026-08-25", "recovery", 92.0)
        assertEquals(unrelated, SleepEfficiencyUnits.normalizedSeriesRow(unrelated))
        assertNull(
            SleepEfficiencyUnits.normalizedSeriesRow(
                legacy.copy(value = Double.NaN),
            ),
        )
    }
}
