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

    @Test fun onboardingDelegatesPairingToTheSourceAwareWizard() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val addDevice = source(userDir, "AddDeviceWizard.kt").readText()
        val connectStep = onboarding
            .substringAfter("private fun ConnectStep(")
            .substringBefore(
                "// A short celebration after a real device source is saved.",
            )

        assertTrue(onboarding.contains("AddDeviceWizard("))
        assertTrue(onboarding.contains("onboardingCompletedDeviceSetupSource("))
        assertTrue(onboarding.contains("AddDeviceSelectionScope.ClaimEligibleBands"))
        assertTrue(onboarding.contains("SourceCoordinator.isWhoop(device)"))
        assertTrue(onboarding.contains("\"onboarding.device_setup\""))
        assertTrue(connectStep.contains("appwide_onboarding_device_setup_action"))
        assertFalse(connectStep.contains("viewModel.connect("))
        assertFalse(connectStep.contains("rememberRequestScan"))
        assertTrue(
            Regex("""runCatching\s*\{\s*viewModel\.pairedDevices\(\)""")
                .findAll(onboarding)
                .count() == 1,
        )
        assertTrue(
            onboarding.split("refreshDeviceSetupSource(").size - 1 >= 3,
        )
        assertTrue(onboarding.contains("\"read_failed\""))
        assertTrue(
            addDevice.contains(
                "selectionScope: AddDeviceSelectionScope =\n" +
                    "        AddDeviceSelectionScope.AllDevices",
            ),
        )
        assertTrue(addDevice.contains("type.isWhoop || type == DeviceType.SupplierBand"))
        assertTrue(addDevice.contains("fun launchDurableRegistration("))
        assertTrue(addDevice.contains("withContext(NonCancellable) { mutation() }"))
        assertTrue(addDevice.contains("\"device.registration\""))
        assertFalse(addDevice.contains("supplierCommitFailed"))
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_whoop_subtitle",
            ),
        )
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_whoop_one_phone_body",
            ),
        )
        assertTrue(
            addDevice.contains(
                "viewModel.registerDevice(device, makeActive = makeActive)\n" +
                    "                true",
            ),
        )
        assertTrue(addDevice.contains("onSuccess = onClose"))
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

    @Test fun progressUsesTheSharedThreadPulseInsteadOfACompletionMark() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val doneStep = onboarding
            .substringAfter("private fun DoneStep()")
            .substringBefore("// MARK: - Pieces")
        val footer = onboarding
            .substringAfter("private fun OnboardingFooter(")
            .substringBefore("@Composable\nprivate fun OnboardingContent(")

        assertFalse(doneStep.contains("CompletionThreadMark()"))
        assertFalse(onboarding.contains("private fun CompletionThreadMark()"))
        assertTrue(doneStep.contains("horizontalAlignment = Alignment.CenterHorizontally"))
        assertTrue(doneStep.contains("textAlign = TextAlign.Center"))
        assertTrue(footer.contains("rememberInfiniteTransition"))
        assertTrue(footer.contains("pulsePhase"))
        assertTrue(footer.contains("Canvas("))
        assertTrue(footer.contains("Brush.horizontalGradient("))
    }

    @Test fun everyPostClaimPageAndCompletionRequireCurrentOwnership() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val planAction = onboarding
            .substringAfter("OnboardingPage.Plan -> {")
            .substringBefore("OnboardingPage.Bluetooth ->")
        val moveTo = onboarding
            .substringAfter("fun moveTo(target: Int, direction: String) {")
            .substringBefore("// The bonded celebration only makes sense")

        assertTrue(
            onboarding.contains(
                "OnboardingPage.Plan ->\n" +
                    "                        !ownershipState.busy && postClaimOwnershipReady",
            ),
        )
        assertTrue(
            moveTo.contains("resolvedOnboardingOwnershipDestination("),
        )
        assertTrue(
            moveTo.indexOf("resolvedOnboardingOwnershipDestination(") <
                moveTo.indexOf("prefs.edit()"),
        )
        assertTrue(
            onboarding.contains(
                "if (!reconciliationComplete) {\n" +
                    "        return null",
            ),
        )
        assertTrue(
            onboarding.contains(
                "page.requiresCurrentOwnershipClaim &&\n" +
                    "            !postClaimOwnershipReady",
            ),
        )
        assertTrue(
            onboarding.contains(
                "val requiresCurrentOwnershipClaim: Boolean\n" +
                    "        get() = ordinal > Ownership.ordinal",
            ),
        )
        assertTrue(onboarding.contains("fun complete() {"))
        assertTrue(onboarding.contains("if (!postClaimOwnershipReady) {"))
        assertTrue(
            onboarding.contains(
                "resolvedOnboardingOwnershipDestination(\n" +
                    "                            requested = page,",
            ),
        )
        assertTrue(
            planAction.indexOf("ownershipCanAccessPostClaimOnboarding(") <
                planAction.indexOf("ownership.selectPlan(selectedPlan)"),
        )
        assertTrue(
            planAction.lastIndexOf("ownershipCanAccessPostClaimOnboarding(") >
                planAction.indexOf("ownership.selectPlan(selectedPlan)"),
        )
    }

    private fun source(userDir: String, name: String): File =
        listOf(
            File(userDir, "src/main/java/com/noop/ui/$name"),
            File(userDir, "app/src/main/java/com/noop/ui/$name"),
            File(userDir, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $name from $userDir")
}
