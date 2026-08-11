package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Guards the independent onboarding Weight and Height controls. Stored values remain SI while display
 * choices can be mixed, and old combined Metric/Imperial preferences resolve safely on upgrade.
 *
 * These tests pin that wiring contract so a rename of the key or a raw value can't silently leave the
 * onboarding picker writing one place while the formatter reads another (the bug #781 fixed). Mirrors the
 * macOS OnboardingUnitsPickerTests case-for-case.
 */
class OnboardingUnitsPickerTest {

    /** Onboarding, Settings and the formatter must share the same stable keys. */
    @Test
    fun independentKeysAreStable() {
        assertEquals("units.mass", NoopPrefs.KEY_MASS_UNIT)
        assertEquals("units.height", NoopPrefs.KEY_HEIGHT_UNIT)
    }

    @Test
    fun rawValuesRoundTripThroughResolver() {
        assertEquals(MassUnit.KILOGRAMS, MassUnit.fromRaw("kg"))
        assertEquals(MassUnit.POUNDS, MassUnit.fromRaw("lb"))
        assertEquals(HeightUnit.CENTIMETERS, HeightUnit.fromRaw("cm"))
        assertEquals(HeightUnit.FEET_INCHES, HeightUnit.fromRaw("ft_in"))
    }

    @Test
    fun legacyCombinedPreferenceMigratesWithoutChangingPresentation() {
        assertEquals(MassUnit.KILOGRAMS, UnitPrefs.resolveMass(UnitSystem.METRIC, null))
        assertEquals(HeightUnit.CENTIMETERS, UnitPrefs.resolveHeight(UnitSystem.METRIC, null))
        assertEquals(MassUnit.POUNDS, UnitPrefs.resolveMass(UnitSystem.IMPERIAL, null))
        assertEquals(HeightUnit.FEET_INCHES, UnitPrefs.resolveHeight(UnitSystem.IMPERIAL, null))
    }

    @Test
    fun weightAndHeightCanUseMixedCombinations() {
        val kg = 74.5
        val cm = 178.0
        assertEquals("74.5 kg", UnitFormatter.massFromKilograms(kg, MassUnit.KILOGRAMS))
        assertEquals("5′ 10″", UnitFormatter.heightFromCentimeters(cm, HeightUnit.FEET_INCHES))
        assertNotEquals(
            UnitFormatter.massFromKilograms(kg, MassUnit.KILOGRAMS),
            UnitFormatter.massFromKilograms(kg, MassUnit.POUNDS),
        )
        assertNotEquals(
            UnitFormatter.heightFromCentimeters(cm, HeightUnit.CENTIMETERS),
            UnitFormatter.heightFromCentimeters(cm, HeightUnit.FEET_INCHES),
        )
    }

    @Test
    fun explicitIndependentChoiceWinsOverLegacySystem() {
        assertEquals(MassUnit.KILOGRAMS, UnitPrefs.resolveMass(UnitSystem.IMPERIAL, "kg"))
        assertEquals(HeightUnit.FEET_INCHES, UnitPrefs.resolveHeight(UnitSystem.METRIC, "ft_in"))
    }
}
