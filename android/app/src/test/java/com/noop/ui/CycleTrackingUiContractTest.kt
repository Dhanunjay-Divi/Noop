package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class CycleTrackingUiContractTest {

    private fun source(relativePath: String): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(
            File(root, relativePath),
            File(root, "app/$relativePath"),
            File(root, "android/app/$relativePath"),
        )
        val file = candidates.firstOrNull(File::isFile)
        assumeTrue("source unavailable: $relativePath", file != null)
        return file!!.readText()
    }

    @Test
    fun menstrualCycleRowIsDirectlyBelowSexInProfile() {
        val settings = source("src/main/java/com/noop/ui/SettingsScreen.kt")
        val sex = settings.indexOf("R.string.l10n_settings_screen_sex_e301dd60")
        val cycle = settings.indexOf("MenstrualCycleSettingsRow(", startIndex = sex)
        val weight = settings.indexOf("R.string.l10n_settings_screen_weight_69c0b815", startIndex = sex)
        assertTrue("sex, cycle, and weight rows must exist", sex >= 0 && cycle >= 0 && weight >= 0)
        assertTrue("menstrual cycle must sit between sex and weight", sex < cycle && cycle < weight)
    }

    @Test
    fun settingsAndViewModelKeepCycleSetupBehindTheProfileGate() {
        val settings = source("src/main/java/com/noop/ui/SettingsScreen.kt")
        val viewModel = source("src/main/java/com/noop/ui/AppViewModel.kt")
        assertTrue(settings.contains("if (cycleTracking || cycleProfileEligible)"))
        assertTrue(
            viewModel.contains(
                "if (enabled && !cycleOptInApplies(ProfileStore.from(appContext).sex)) return",
            ),
        )
    }

    @Test
    fun healthObservesProfileAndKeepsCycleSetupInItsNoDataBranch() {
        val health = source("src/main/java/com/noop/ui/HealthScreen.kt")
        assertTrue(health.contains("ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()"))
        val emptyStart = health.indexOf("if (days.isEmpty() && !live.connected)")
        val populatedStart = health.indexOf("} else {", startIndex = emptyStart)
        assertTrue(emptyStart >= 0 && populatedStart > emptyStart)
        assertTrue(health.substring(emptyStart, populatedStart).contains("SkinTempSuiteSection("))
        assertTrue(health.contains("v5Signals?.cycle ?: cycleTrackingLearningResult()"))
    }

    @Test
    fun circularGuideAndLoggedMarkerAreTruthful() {
        val cards = source("src/main/java/com/noop/ui/SkinTempCardsScreen.kt")
        assertTrue(cards.contains("private fun CycleTimelineRing("))
        assertTrue(cards.contains("if (hasLoggedStart)"))
        assertTrue(cards.contains("CycleTimelineRing(result, hasLoggedStart = starts.isNotEmpty())"))
        assertTrue(cards.contains("CycleTimelineLegend(hasLoggedStart = starts.isNotEmpty())"))
    }

    @Test
    fun cycleUiHasNoPositiveFertilityPredictionClaims() {
        val cards = source("src/main/java/com/noop/ui/SkinTempCardsScreen.kt").lowercase()
        listOf(
            "fertile window",
            "fertility window",
            "ovulation date",
            "predicted ovulation",
            "safe-day",
        ).forEach { phrase ->
            assertFalse("cycle UI contained prohibited phrase: $phrase", cards.contains(phrase))
        }
    }

    @Test
    fun v5AdapterUsesTheCurrentCivilDayForLoggedCycleMath() {
        val adapter = source("src/main/java/com/noop/analytics/V5HealthSignals.kt")
        assertTrue(adapter.contains("asOfDay = todayKey"))
    }
}
