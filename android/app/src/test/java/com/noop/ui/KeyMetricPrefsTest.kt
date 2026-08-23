package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class KeyMetricPrefsTest {

    @Test
    fun freshInstallDefaultsToRecoveryEffortAndSleep() {
        val expected = listOf(KeyMetric.CHARGE, KeyMetric.EFFORT, KeyMetric.REST)
        assertEquals(expected, KeyMetric.defaultSelection)
        assertEquals(expected, KeyMetricPrefs.decodeEnabled(null))
        assertEquals(expected, KeyMetricPrefs.decodeEnabled(""))
        assertEquals(expected, KeyMetricPrefs.decodeEnabled("   "))
    }

    @Test
    fun selectionContractMatchesProductLimitAndCatalog() {
        assertEquals(3, KeyMetricPrefs.MIN_SELECTION_COUNT)
        assertEquals(5, KeyMetricPrefs.MAX_SELECTION_COUNT)
        assertEquals(KeyMetric.entries.toSet(), KeyMetric.defaultOrder.toSet())
    }

    @Test
    fun shortLegacySelectionKeepsUserOrderAndFillsToThree() {
        assertEquals(
            listOf(KeyMetric.STEPS, KeyMetric.HRV, KeyMetric.CHARGE),
            KeyMetricPrefs.decodeEnabled("steps,hrv"),
        )
        assertEquals(
            "bloodOxygen,charge,effort",
            KeyMetricPrefs.encode(listOf(KeyMetric.BLOOD_OXYGEN)),
        )
    }

    @Test
    fun fullCatalogKeepsPinsFirstWithoutRemovingPriorMetrics() {
        val catalog = KeyMetricPrefs.catalogOrder(
            listOf(KeyMetric.STEPS, KeyMetric.HRV, KeyMetric.BLOOD_OXYGEN),
        )
        assertEquals(
            listOf(KeyMetric.STEPS, KeyMetric.HRV, KeyMetric.BLOOD_OXYGEN),
            catalog.take(3),
        )
        assertEquals(KeyMetric.entries.size, catalog.size)
        assertEquals(KeyMetric.entries.toSet(), catalog.toSet())
    }

    @Test
    fun decodePreservesOrderDeduplicatesAndCapsOlderSelections() {
        assertEquals(
            listOf(
                KeyMetric.STEPS,
                KeyMetric.HRV,
                KeyMetric.BLOOD_OXYGEN,
                KeyMetric.RESTING_HR,
                KeyMetric.CALORIES,
            ),
            KeyMetricPrefs.decodeEnabled(
                "steps, hrv,steps,bloodOxygen,restingHr,calories,weight,effort",
            ),
        )
    }

    @Test
    fun decodeAllUnknownFallsBackToCoreDefaults() {
        assertEquals(
            KeyMetric.defaultSelection,
            KeyMetricPrefs.decodeEnabled("retiredMetric,unknown"),
        )
    }

    @Test
    fun encodeAlsoEnforcesDedupeCapAndNonemptySelection() {
        assertEquals(
            "steps,hrv,bloodOxygen,restingHr,calories",
            KeyMetricPrefs.encode(
                listOf(
                    KeyMetric.STEPS,
                    KeyMetric.HRV,
                    KeyMetric.STEPS,
                    KeyMetric.BLOOD_OXYGEN,
                    KeyMetric.RESTING_HR,
                    KeyMetric.CALORIES,
                    KeyMetric.WEIGHT,
                ),
            ),
        )
        assertEquals("charge,effort,rest", KeyMetricPrefs.encode(emptyList()))
    }
}
