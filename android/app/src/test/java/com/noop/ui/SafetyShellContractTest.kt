package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun requiredAccountOnboardingKeepsOptionalSetupOutOfTheMandatoryFlow() {
        val pages = onboardingPages(ownershipConfigured = true)

        assertEquals(
            listOf(
                OnboardingPage.Welcome,
                OnboardingPage.Bluetooth,
                OnboardingPage.Connect,
                OnboardingPage.Account,
                OnboardingPage.Ownership,
                OnboardingPage.Profile,
                OnboardingPage.Plan,
                OnboardingPage.Done,
            ),
            pages,
        )
        assertFalse(pages.contains(OnboardingPage.SafetyContacts))
        assertFalse(pages.contains(OnboardingPage.Appearance))
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
        assertTrue(text.contains("MovableNoopCommandLens("))
        assertTrue(text.contains("onClick = { showQuickActions = true }"))
        val commandLens = text
            .substringAfter("private fun MovableNoopCommandLens(")
            .substringBefore("\n}\n\n/**")
        assertTrue(commandLens.contains("Canvas(modifier = Modifier.size(14.dp))"))
        assertTrue(commandLens.contains("sweepAngle = 288f"))
        assertTrue(commandLens.contains("drawCircle("))
        assertTrue(commandLens.contains("radius = 2.25.dp.toPx()"))
        assertFalse(commandLens.contains("val monogram = Path()"))
        assertFalse(commandLens.contains("Icons.Filled.ChatBubble"))
        assertTrue(commandLens.contains("NoopCommandLensPrefs"))
        assertTrue(commandLens.contains("detectDragGestures"))
        assertFalse(commandLens.contains("Icons.Filled.Add"))
        assertTrue(text.contains("quickActions.chunked(3)"))
        assertTrue(text.contains("NoopModalSystemBars()"))
        assertTrue(text.contains("DialogWindowProvider"))
        assertTrue(text.contains("window.navigationBarColor = navigationBarColor"))
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
            "MoreQuickAccessItem(R.string.nav_safety, Icons.Filled.Shield, Destination.Safety.route, critical = true)",
        ))
        assertTrue(text.contains(
            "Destination.Safety, Destination.SmartAlarm, Destination.Automations",
        ))
        assertTrue(text.contains("GlassBottomBar("))
    }
}
