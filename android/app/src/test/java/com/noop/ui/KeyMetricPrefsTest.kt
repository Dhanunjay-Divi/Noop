package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class KeyMetricPrefsTest {

    @Test
    fun freshInstallDefaultsToSecondarySignalsWithoutRepeatingTheHero() {
        val expected = listOf(KeyMetric.HRV, KeyMetric.RESTING_HR, KeyMetric.BLOOD_OXYGEN)
        val heroMetrics = setOf(KeyMetric.CHARGE, KeyMetric.REST, KeyMetric.EFFORT)
        assertEquals(expected, KeyMetric.defaultSelection)
        assertEquals(expected, KeyMetricPrefs.decodeEnabled(null))
        assertEquals(expected, KeyMetricPrefs.decodeEnabled(""))
        assertEquals(expected, KeyMetricPrefs.decodeEnabled("   "))
        assertEquals(emptySet<KeyMetric>(), expected.toSet().intersect(heroMetrics))
    }

    @Test
    fun explicitExistingCoreSelectionRemainsUnchanged() {
        val existing = listOf(KeyMetric.CHARGE, KeyMetric.EFFORT, KeyMetric.REST)
        assertEquals(existing, KeyMetricPrefs.decodeEnabled("charge,effort,rest"))
        assertEquals("charge,effort,rest", KeyMetricPrefs.encode(existing))
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
            listOf(KeyMetric.STEPS, KeyMetric.HRV, KeyMetric.RESTING_HR),
            KeyMetricPrefs.decodeEnabled("steps,hrv"),
        )
        assertEquals(
            "bloodOxygen,hrv,restingHr",
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
    fun decodeAllUnknownFallsBackToFreshDefaults() {
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
        assertEquals("hrv,restingHr,bloodOxygen", KeyMetricPrefs.encode(emptyList()))
    }
}
