package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
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
    private fun onboardingSource(): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/OnboardingScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/OnboardingScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/OnboardingScreen.kt"),
        ).first(File::isFile).readText()
    }

    private fun settingsSource(): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/SettingsScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/SettingsScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/SettingsScreen.kt"),
        ).first(File::isFile).readText()
    }

    private fun resourceFile(directory: String): File {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/res/$directory/strings.xml"),
            File(root, "app/src/main/res/$directory/strings.xml"),
            File(root, "android/app/src/main/res/$directory/strings.xml"),
        ).first(File::isFile)
    }

    private fun resourceValue(source: String, key: String): String =
        Regex("""<string name="$key">([^<]*)</string>""")
            .find(source)
            ?.groupValues
            ?.get(1)
            ?: error("Missing string resource $key")

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

    @Test
    fun productPlanStepPersistsSelectionAndUsesLocalizedActions() {
        val source = onboardingSource()

        assertTrue(source.contains("OnboardingPage.Plan -> ProductPlanStep("))
        assertTrue(source.contains("ownership.selectPlan(selectedPlan)"))
        assertTrue(source.contains("if ("))
        assertTrue(source.contains("saved &&"))
        assertTrue(source.contains("pageIndex == submittedPage"))
        assertTrue(source.contains("R.string.ownership_plan_continue_noop"))
        assertTrue(source.contains("R.string.ownership_plan_save_plus"))
        assertTrue(source.contains("R.string.ownership_plan_saving"))
        assertTrue(source.contains("OnboardingPage.Ownership ->"))
        assertTrue(source.contains("OwnershipAccountScreen()"))
        assertTrue(source.contains("ONBOARDING_PROGRESS_KEY"))
        assertTrue(source.contains("\"onboarding.progress\""))
        assertTrue(source.contains("enabled = primaryEnabled"))
        assertTrue(
            source.contains(
                "OnboardingPage.Plan ->\n" +
                    "                        !ownershipState.busy && " +
                    "postClaimOwnershipReady",
            ),
        )
        assertTrue(source.contains("requiresCurrentOwnershipClaim"))
        assertTrue(source.contains("Column(verticalArrangement = Arrangement.spacedBy(1.dp))"))
        assertTrue(source.contains("remove(ONBOARDING_PROGRESS_KEY)"))
    }

    @Test
    fun localFirstCopyDoesNotPromiseOptionalCloudCanNeverBeUsed() {
        val onboarding = onboardingSource()
        val settings = settingsSource()

        assertFalse(onboarding.contains("all your data, none of the cloud"))
        assertFalse(settings.contains("all your data, none of the cloud"))
        assertTrue(settings.contains("core health data stays local by default"))

        val taglineKey =
            "l10n_onboarding_screen_all_your_data_none_of_the_6fc6f26d"
        val detailKey =
            "l10n_onboarding_screen_a_private_window_into_your_recovery_b8dd2ff2"
        val expected = mapOf(
            "values" to Pair(
                "your health data, local by default",
                "A private window into your recovery, sleep and effort. Core data is read from NOOP Band and processed on this phone; cloud features are optional.",
            ),
            "values-de" to Pair(
                "deine Gesundheitsdaten, standardmäßig lokal",
                "Ein privater Einblick in deine Erholung, deinen Schlaf und deine Belastung. Kerndaten werden direkt von NOOP Band gelesen und auf diesem Telefon verarbeitet; Cloud-Funktionen sind optional.",
            ),
            "values-es" to Pair(
                "tus datos de salud, locales de forma predeterminada",
                "Una ventana privada a tu recuperación, sueño y esfuerzo. Los datos principales se leen directamente de NOOP Band y se procesan en este teléfono; las funciones en la nube son opcionales.",
            ),
            "values-fr" to Pair(
                "vos données de santé, locales par défaut",
                "Une fenêtre privée sur votre récupération, votre sommeil et votre effort. Les données principales sont lues directement depuis NOOP Band et traitées sur ce téléphone ; les fonctions cloud sont facultatives.",
            ),
            "values-pt-rPT" to Pair(
                "os teus dados de saúde, locais por predefinição",
                "Uma visão privada da tua recuperação, sono e esforço. Os dados principais são lidos diretamente da NOOP Band e processados neste telemóvel; as funcionalidades na cloud são opcionais.",
            ),
            "values-zh" to Pair(
                "健康数据默认保留在本地",
                "这是了解您身体恢复、睡眠和负荷的专属窗口。核心数据直接从 NOOP Band 读取并在本机处理；云端功能完全可选。",
            ),
        )
        expected.forEach { (directory, copy) ->
            val resources = resourceFile(directory).readText()
            assertEquals(copy.first, resourceValue(resources, taglineKey))
            assertEquals(copy.second, resourceValue(resources, detailKey))
        }
    }
}
