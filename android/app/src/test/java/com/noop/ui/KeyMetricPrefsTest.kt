package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class KeyMetricPrefsTest {

    @Test
    fun freshInstallDefaultsToSecondarySignalsWithoutRepeatingTheHero() {
        val expected = listOf(
            KeyMetric.HRV,
            KeyMetric.RESTING_HR,
            KeyMetric.BLOOD_OXYGEN,
            KeyMetric.RESPIRATORY,
            KeyMetric.STEPS,
            KeyMetric.WEIGHT,
        )
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
        assertEquals(6, KeyMetricPrefs.MAX_SELECTION_COUNT)
        assertEquals(KeyMetric.entries.toSet(), KeyMetric.defaultOrder.toSet())
        assertEquals(
            listOf(
                "charge",
                "rest",
                "effort",
                "hrv",
                "restingHr",
                "bloodOxygen",
                "respiratory",
                "skinTemp",
                "steps",
                "calories",
                "weight",
                "hydration",
                "stress",
                "vitality",
            ),
            KeyMetric.defaultOrder.map(KeyMetric::raw),
        )
    }

    @Test
    fun newTodayReadyMetricsUseStableAppleParityIdsAndGroups() {
        assertEquals(KeyMetric.STRESS, KeyMetric.fromRaw("stress"))
        assertEquals(KeyMetric.VITALITY, KeyMetric.fromRaw("vitality"))
        assertEquals(KeyMetric.SKIN_TEMP, KeyMetric.fromRaw("skinTemp"))
        assertEquals(KeyMetric.HYDRATION, KeyMetric.fromRaw("hydration"))
        assertEquals(KeyMetricGroup.WELLBEING, KeyMetric.STRESS.group)
        assertEquals(KeyMetricGroup.WELLBEING, KeyMetric.VITALITY.group)
        assertEquals(KeyMetricGroup.VITALS, KeyMetric.SKIN_TEMP.group)
        assertEquals(KeyMetricGroup.ACTIVITY, KeyMetric.WEIGHT.group)
        assertEquals(KeyMetricGroup.ACTIVITY, KeyMetric.HYDRATION.group)
        assertEquals(false, KeyMetric.VITALITY.isBoundedProgress)
    }

    @Test
    fun savedSelectionsContainingNewMetricsRoundTripWithoutReordering() {
        val selection = listOf(
            KeyMetric.STRESS,
            KeyMetric.SKIN_TEMP,
            KeyMetric.HYDRATION,
            KeyMetric.VITALITY,
        )
        assertEquals(selection, KeyMetricPrefs.decodeEnabled(KeyMetricPrefs.encode(selection)))
        assertEquals("stress,skinTemp,hydration,vitality", KeyMetricPrefs.encode(selection))
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
                KeyMetric.WEIGHT,
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
            "steps,hrv,bloodOxygen,restingHr,calories,weight",
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
        assertEquals(
            "hrv,restingHr,bloodOxygen,respiratory,steps,weight",
            KeyMetricPrefs.encode(emptyList()),
        )
    }
}
