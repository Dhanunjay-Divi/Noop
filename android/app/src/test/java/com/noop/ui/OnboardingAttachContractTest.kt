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

    private fun source(userDir: String, name: String): File =
        listOf(
            File(userDir, "src/main/java/com/noop/ui/$name"),
            File(userDir, "app/src/main/java/com/noop/ui/$name"),
            File(userDir, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $name from $userDir")
}
