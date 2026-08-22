package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class SafetyShellContractTest {
    private fun source(vararg candidates: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return candidates
            .map { File(root, it) }
            .firstOrNull(File::isFile)
            ?.readText()
    }

    @Test
    fun safetySetupIsPartOfOnboardingBeforeAppearance() {
        val onboarding = source(
            "src/main/java/com/noop/ui/OnboardingScreen.kt",
            "app/src/main/java/com/noop/ui/OnboardingScreen.kt",
            "android/app/src/main/java/com/noop/ui/OnboardingScreen.kt",
        )
        assumeTrue("Onboarding source unavailable", onboarding != null)
        val text = onboarding!!

        assertTrue(text.contains("SafetyContacts(\"Finish later\")"))
        assertTrue(text.contains("OnboardingPage.SafetyContacts -> SafetyContactsStep()"))
        assertTrue(text.contains("SafetyContactsSetup(controller = controller)"))
        assertTrue(
            text.indexOf("SafetyContacts(\"Finish later\")") <
                text.indexOf("Appearance(\"Continue\")"),
        )
    }

    @Test
    fun floatingQuickActionLauncherKeepsCompleteThreeByThreeInventory() {
        val appRoot = source(
            "src/main/java/com/noop/ui/AppRoot.kt",
            "app/src/main/java/com/noop/ui/AppRoot.kt",
            "android/app/src/main/java/com/noop/ui/AppRoot.kt",
        )
        assumeTrue("AppRoot source unavailable", appRoot != null)
        val text = appRoot!!
        val actions = text
            .substringAfter("private val quickActions: List<QuickAction> = listOf(")
            .substringBefore("\n)\n\n@Composable\nprivate fun QuickActionLauncher")

        assertEquals(9, Regex("""QuickAction\(""").findAll(actions).count())
        for (title in listOf(
            "Workout", "Strength", "Meal", "Journal", "Hydration",
            "HRV", "Breathe", "Intervals", "Live HR",
        )) {
            assertTrue(title, actions.contains("QuickAction(\"$title\""))
        }
        assertTrue(text.contains("FloatingQuickAddButton(onClick = onQuickActions)"))
        assertTrue(text.contains("quickActions.chunked(3)"))
    }

    @Test
    fun safetyCenterRemainsReachableFromPersistentShell() {
        val appRoot = source(
            "src/main/java/com/noop/ui/AppRoot.kt",
            "app/src/main/java/com/noop/ui/AppRoot.kt",
            "android/app/src/main/java/com/noop/ui/AppRoot.kt",
        )
        assumeTrue("AppRoot source unavailable", appRoot != null)
        val text = appRoot!!

        assertTrue(text.contains(
            "composable(Destination.Safety.route) { SafetyCenterScreen() }",
        ))
        assertTrue(text.contains(
            "modifier = Modifier.clickable { onNavigate(Destination.Safety.route) }",
        ))
        assertTrue(text.contains("GlassBottomBar("))
    }
}
