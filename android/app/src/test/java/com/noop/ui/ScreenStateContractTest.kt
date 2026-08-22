package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source contract for the Compose state vocabulary and its first production adopters. */
class ScreenStateContractTest {
    private fun source(relative: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/$relative"),
            File(root, "app/src/main/java/com/noop/ui/$relative"),
            File(root, "android/app/src/main/java/com/noop/ui/$relative"),
        ).firstOrNull(File::isFile)?.readText()
    }

    @Test
    fun stateVocabularyAccessibilityAndMotionFallbackStayComplete() {
        val components = source("Components.kt")
        assumeTrue("Components.kt unavailable from ${System.getProperty("user.dir")}", components != null)
        val text = components!!

        listOf("Loading", "Empty", "Partial", "Stale", "Error").forEach {
            assertTrue("ScreenStateKind.$it is missing", text.contains("ScreenStateKind.$it"))
        }
        assertTrue(text.contains("rememberPoseStill()"))
        assertTrue(text.contains("clearAndSetSemantics"))
        assertTrue(text.contains("R.string.appwide_a11y_state_format"))
        assertTrue(text.contains("val stateDescription = stringResource("))
        assertTrue(text.contains("contentDescription = stateDescription"))
        assertTrue(text.contains("actionLabel != null && onAction != null"))
        assertTrue(text.contains(
            "ScreenStateCard(kind = ScreenStateKind.Partial, title = title, body = body"
        ))
    }

    @Test
    fun initialProductionScreensUseExplicitStates() {
        val nutrition = source("NutritionLogScreen.kt")
        val workouts = source("WorkoutsScreen.kt")
        val rhythm = source("RhythmScreen.kt")
        assumeTrue("Production screen sources unavailable", nutrition != null && workouts != null && rhythm != null)

        assertTrue(nutrition!!.contains("ScreenStateKind.Loading"))
        assertTrue(nutrition.contains("ScreenStateKind.Empty"))
        assertFalse(nutrition.contains("NutritionEmptyCard"))
        assertTrue(nutrition.contains("R.string.nutrition_state_loading_title"))
        assertTrue(nutrition.contains("R.string.nutrition_state_empty_title"))
        assertFalse(nutrition.contains("title = \"Loading nutrition\""))

        assertTrue(workouts!!.contains("ScreenStateKind.Loading"))
        assertTrue(workouts.contains("ScreenStateKind.Empty"))
        assertTrue(workouts.contains("onAction = onAdd"))
        assertTrue(workouts.contains("R.string.state_workouts_empty_body"))

        assertTrue(rhythm!!.contains("ScreenStateKind.Empty"))
        assertTrue(rhythm.contains("R.string.state_rhythm_empty_body"))
    }

    @Test
    fun nutritionSurfaceExplainsMixedSourcesAndUsesValidatedRepeat() {
        val nutrition = source("NutritionLogScreen.kt")
        assumeTrue("NutritionLogScreen.kt unavailable", nutrition != null)
        val text = nutrition!!

        assertTrue(text.contains("totals.hasMixedSources ->"))
        assertTrue(text.contains("NutritionLogContract.repeatedManualEntry("))
        assertTrue(text.contains("NutritionLogContract.parseUserNumber(clean)"))
        assertTrue(text.contains("R.string.nutrition_repeat_body"))
        assertTrue(text.contains("R.string.nutrition_repeat_action_format"))
        assertFalse(text.contains("Recent manual meals only. You can edit the new entry afterward."))
        assertFalse(text.contains("onClickLabel = \"Log \${nutritionEntryTitle(entry)} again\""))
        assertFalse(text.contains("replace(',', '.')"))
    }
}
