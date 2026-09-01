package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the first-frame Activity-attach crash fixed upstream in 3b5e22fb. */
class OnboardingAttachContractTest {
    @Test fun onboardingCollectorsDoNotRequireALifecycleCompositionLocal() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val source = listOf(
            File(userDir, "src/main/java/com/noop/ui/OnboardingScreen.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/OnboardingScreen.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/OnboardingScreen.kt"),
        ).firstOrNull(File::isFile) ?: error("Could not locate OnboardingScreen.kt from $userDir")
        val text = source.readText()
        assertFalse(text.contains("collectAsStateWithLifecycle"))
        assertFalse(text.contains("LocalLifecycleOwner"))
        assertTrue(text.contains("viewModel.live.collectAsState()"))
    }

    @Test fun onboardingRemovesLegacyBandNoticeButKeepsHistoryImport() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val changelog = source(userDir, "AppChangelog.kt").readText()

        assertFalse(changelog.contains("WHOOP 4.0 is the supported path"))
        assertTrue(onboarding.contains("l10n_onboarding_screen_bring_your_history"))
        assertTrue(onboarding.contains("l10n_onboarding_screen_import_whoop_export"))
    }

    @Test fun dailyRhythmMapsEverydayToolsWithoutEnablingThem() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()

        assertTrue(onboarding.contains("OnboardingPage.DailyRhythm -> DailyRhythmStep()"))
        assertTrue(onboarding.contains("DailyRhythm(\"Continue\")"))
        assertTrue(
            onboarding.indexOf("DailyRhythm(\"Continue\")") <
                onboarding.indexOf("Done(\"Enter NOOP\")"),
        )
        for (key in listOf(
            "onboarding_rhythm_morning_body",
            "onboarding_rhythm_quick_body",
            "onboarding_rhythm_journal_body",
            "onboarding_rhythm_automations_body",
        )) {
            assertTrue(key, onboarding.contains("R.string.$key"))
        }

        val step = onboarding
            .substringAfter("private fun DailyRhythmStep()")
            .substringBefore("/** A small fixed-palette look-swatch")
        assertFalse(step.contains("setEnabled("))
        assertFalse(step.contains("launch("))
        assertFalse(step.contains("Switch("))
    }

    @Test fun completionUsesTheCenteredNoopThreadMark() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val doneStep = onboarding
            .substringAfter("private fun DoneStep()")
            .substringBefore("@Composable\nprivate fun CompletionThreadMark()")
        val threadMark = onboarding
            .substringAfter("private fun CompletionThreadMark()")
            .substringBefore("// MARK: - Pieces")

        assertTrue(doneStep.contains("CompletionThreadMark()"))
        assertTrue(doneStep.contains("horizontalAlignment = Alignment.CenterHorizontally"))
        assertTrue(doneStep.contains("textAlign = TextAlign.Center"))
        assertTrue(threadMark.contains("Canvas("))
        assertTrue(threadMark.contains(".size(116.dp)"))
        assertTrue(threadMark.contains("Brush.linearGradient("))
    }

    private fun source(userDir: String, name: String): File =
        listOf(
            File(userDir, "src/main/java/com/noop/ui/$name"),
            File(userDir, "app/src/main/java/com/noop/ui/$name"),
            File(userDir, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $name from $userDir")
}
