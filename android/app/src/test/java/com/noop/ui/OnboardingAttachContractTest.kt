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
        assertFalse(text.contains("viewModel.live.collectAsState()"))
        assertTrue(
            text.contains(
                "val deviceSetupComplete = registrySetupSource != null",
            ),
        )
        assertTrue(text.contains("registrySetupSourceName by rememberSaveable"))
        assertTrue(text.contains("registrySetupReadComplete"))
    }

    @Test fun onboardingRemovesLegacyBandNoticeButKeepsHistoryImport() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val changelog = source(userDir, "AppChangelog.kt").readText()

        assertFalse(changelog.contains("WHOOP 4.0 is the supported path"))
        assertTrue(onboarding.contains("l10n_onboarding_screen_bring_your_history"))
        assertTrue(onboarding.contains("l10n_onboarding_screen_import_whoop_export"))
    }

    @Test fun onboardingPageSurvivesActivityRecreationAndKeepsDurableCheckpoint() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val pageState = onboarding
            .substringAfter("var savedPageIndex by")
            .substringBefore("val pageIndex")
        val moveTo = onboarding
            .substringAfter("fun moveTo(")
            .substringBefore("fun acceptDeviceSetupSource(")

        assertTrue(pageState.contains("rememberSaveable("))
        assertTrue(pageState.contains("ONBOARDING_PROGRESS_SCHEMA"))
        assertTrue(pageState.contains("ownershipConfigured"))
        assertFalse(pageState.contains("remember {"))
        assertTrue(moveTo.contains("encodedOnboardingProgress(next)"))
        assertTrue(moveTo.contains(".apply()"))
        assertTrue(moveTo.contains("savedPageIndex = destination"))
        assertTrue(
            moveTo.indexOf(".apply()") <
                moveTo.indexOf("savedPageIndex = destination"),
        )
        assertTrue(onboarding.contains("onboardingNeedsDeviceSetupRead(page)"))
        assertTrue(
            onboarding.contains(
                "onboardingNeedsDeviceSetupRead(page) &&\n" +
                    "            !registrySetupReadComplete",
            ),
        )
    }

    @Test fun onboardingDelegatesPairingToTheSourceAwareWizard() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val deviceSetupPolicy =
            source(userDir, "OnboardingDeviceSetupPolicy.kt").readText()
        val addDevice = source(userDir, "AddDeviceWizard.kt").readText()
        val connectStep = onboarding
            .substringAfter("private fun ConnectStep(")
            .substringBefore("@Composable\nprivate fun BondedStep()")

        assertTrue(onboarding.contains("AddDeviceWizard("))
        assertTrue(onboarding.contains("onboardingCompletedDeviceSetupSource("))
        assertTrue(onboarding.contains("AddDeviceSelectionScope.ClaimEligibleBands"))
        assertFalse(onboarding.contains("AddDeviceSelectionScope.AllDevices"))
        assertTrue(
            onboarding.contains(
                "val deviceSetupComplete = registrySetupSource != null",
            ),
        )
        assertFalse(onboarding.contains("live.bonded || registrySetupSource"))
        assertFalse(onboarding.contains("LaunchedEffect(live.bonded)"))
        assertTrue(deviceSetupPolicy.contains("SourceCoordinator.isWhoop(device)"))
        assertTrue(
            deviceSetupPolicy.contains(
                "source == SourceKind.veepoo && !supplierAvailable",
            ),
        )
        assertTrue(
            deviceSetupPolicy.contains(
                "supplierRegistrationUsable(device.id)",
            ),
        )
        assertTrue(onboarding.contains("\"onboarding.device_setup\""))
        assertTrue(connectStep.contains("appwide_onboarding_device_setup_action"))
        assertFalse(connectStep.contains("viewModel.connect("))
        assertFalse(connectStep.contains("rememberRequestScan"))
        assertTrue(
            Regex("""runCatching\s*\{\s*viewModel\.pairedDevices\(\)""")
                .findAll(onboarding)
                .count() == 1,
        )
        assertFalse(onboarding.contains("registrySetupBaseline"))
        assertFalse(onboarding.contains("previousDevices = baseline"))
        assertFalse(onboarding.contains("wizardCompletionSource"))
        assertFalse(onboarding.contains("onAddedSource ="))
        assertTrue(
            Regex(
                """onClose\s*=\s*\{\s*showAddDeviceWizard\s*=\s*false\s*""" +
                    """scope\.launch\s*\{\s*refreshDeviceSetupSource""",
            ).containsMatchIn(onboarding),
        )
        assertTrue(
            onboarding.split("refreshDeviceSetupSource(").size - 1 >= 3,
        )
        assertTrue(onboarding.contains("\"read_failed\""))
        assertTrue(
            addDevice.contains(
                "selectionScope: AddDeviceSelectionScope,",
            ),
        )
        assertFalse(
            addDevice.contains("selectionScope: AddDeviceSelectionScope ="),
        )
        assertTrue(addDevice.contains("type.isWhoop || type == DeviceType.SupplierBand"))
        assertTrue(addDevice.contains("fun launchDurableRegistration("))
        assertTrue(addDevice.contains("withContext(NonCancellable) { mutation() }"))
        assertTrue(addDevice.contains("\"device.registration\""))
        assertFalse(addDevice.contains("supplierCommitFailed"))
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_compatible_band",
            ),
        )
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_whoop_one_phone_body",
            ),
        )
        assertTrue(
            addDevice.contains(
                "viewModel.registerDevice(device, makeActive = makeActive)",
            ),
        )
        assertFalse(
            addDevice.contains(
                "viewModel.registerDevice(device, makeActive = makeActive)\n" +
                    "                true",
            ),
        )
        assertTrue(addDevice.contains("onAddedSource: (SourceKind) -> Unit = {}"))
        assertTrue(addDevice.contains("onAddedSource(committedSource)"))
        assertTrue(addDevice.contains("onAddedSource(SourceKind.veepoo)"))
        assertFalse(addDevice.contains("onSuccess = onClose"))
    }

    @Test fun unconfiguredAccountStepUsesTheGeneratedFailClosedBoundary() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()

        for (key in listOf(
            "appwide_onboarding_account_unconfigured_title",
            "appwide_onboarding_account_unconfigured_subtitle",
            "appwide_onboarding_account_release_title",
            "appwide_onboarding_account_release_body",
            "appwide_onboarding_account_unconfigured_footer",
        )) {
            assertTrue(key, onboarding.contains("R.string.$key"))
        }
        assertFalse(onboarding.contains("R.string.appwide_onboarding_account_local_title"))
        assertFalse(onboarding.contains("R.string.appwide_onboarding_account_local_body"))
        assertTrue(onboarding.contains("OnboardingPage.Account -> AccountAvailabilityStep()"))
        assertTrue(onboarding.contains("OnboardingPage.Account -> accountStepReady"))
        assertTrue(onboarding.contains("if (!accountStepReady) return"))
        assertTrue(
            onboarding.contains("targetPage == OnboardingPage.Account &&"),
        )
        assertTrue(
            onboarding.contains("instrumentationHarness != null"),
        )
        assertTrue(
            onboarding.contains("OnboardingInstrumentationHarnessRegistry.current()"),
        )
        val mainActivity = source(userDir, "MainActivity.kt").readText()
        assertTrue(
            mainActivity.contains(
                "onboardingInstrumentationHarness.OperationalShellBoundary()",
            ),
        )
        assertTrue(
            onboarding.contains("OwnershipAccountScreen()"),
        )
        assertTrue(
            onboarding.contains(
                "allowSupplierBand = supplierOnboardingAvailable",
            ),
        )
        assertTrue(
            onboarding.contains(
                "source == SourceKind.veepoo && !supplierOnboardingAvailable",
            ),
        )
    }

    @Test fun claimEligibleWizardStartsUnifiedScanAndKeepsSupplierAsSecondaryRoute() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val addDevice = source(userDir, "AddDeviceWizard.kt").readText()
        val pickerCall = addDevice
            .substringAfter("t.isWhoop -> WhoopPickStep(")
            .substringBefore("t == DeviceType.GymEquipment")
        val picker = addDevice
            .substringAfter("private fun WhoopPickStep(")
            .substringBefore("@Composable\nprivate fun HrPickStep(")

        assertTrue(addDevice.contains(
            "selectionScope == AddDeviceSelectionScope.ClaimEligibleBands",
        ))
        assertTrue(addDevice.contains(
            "automaticallyScansLaunchBands -> WizardStep.Pick",
        ))
        assertTrue(addDevice.contains(
            "automaticallyScansLaunchBands -> DeviceType.Whoop4",
        ))
        assertTrue(addDevice.contains("LaunchedEffect(automaticallyScansLaunchBands)"))
        assertTrue(addDevice.contains("viewModel.presentWhoopScan(WhoopModel.WHOOP4)"))
        assertTrue(pickerCall.contains(
            "automaticallyScansLaunchBands && supplierAvailable",
        ))
        assertTrue(pickerCall.contains("onOpenSupplierBand"))
        assertTrue(
            picker.contains(
                "R.string.appwide_action_pair_another_supported_band",
            ),
        )
        assertTrue(picker.contains("contentDescription = pairAnotherSupportedBand"))
        assertFalse(picker.contains("DeviceType.HrStrap"))
        assertFalse(picker.contains("DeviceType.GymEquipment"))
        assertFalse(picker.contains("DeviceType.Oura"))
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_compatible_5_title",
            ),
        )
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_compatible_4_title",
            ),
        )
    }

    @Test fun supplierPairingCopyUsesAppWideLocalizationAndCallerAvailabilityGate() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val addDevice = source(userDir, "AddDeviceWizard.kt").readText()

        assertTrue(
            addDevice.contains(
                "val supplierAvailable = allowSupplierBand && " +
                    "viewModel.supplierBandAvailable",
            ),
        )
        assertTrue(addDevice.contains("resolvedAddDeviceStart(start, supplierAvailable)"))
        assertTrue(
            addDevice.contains(
                "t == DeviceType.SupplierBand && supplierAvailable",
            ),
        )
        assertTrue(addDevice.contains("if (supplierAvailable)"))
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_account_linked_title",
            ),
        )
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_account_linked_subtitle",
            ),
        )
        assertFalse(
            addDevice.contains(
                "R.string.appwide_onboarding_device_wizard_account_linked_unavailable",
            ),
        )
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_supplier_android_password_help",
            ),
        )
        assertTrue(
            addDevice.contains(
                "appwide_onboarding_device_wizard_supplier_android_ready",
            ),
        )
        assertFalse(
            addDevice.contains(
                "Band verified. Live heart rate is display-only and is not saved or scored.",
            ),
        )
        assertFalse(
            addDevice.contains(
                "This opens the local transport; it is not ownership proof.",
            ),
        )
        assertFalse(addDevice.contains("supplierCommitFailed"))
    }

    @Test fun supplierCommitPublishesTheCoordinatorDeviceIdWithoutASecondRegistryRead() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val viewModel = source(userDir, "AppViewModel.kt").readText()
        val commit = viewModel
            .substringAfter("suspend fun commitSupplierBandPairing(")
            .substringBefore("fun cancelSupplierBandPairing")

        assertTrue(commit.contains("commitVeepooPairing(nickname) ?: return false"))
        assertTrue(commit.contains("noteActiveDeviceId(committedDeviceId)"))
        assertTrue(commit.contains("_selectedDeviceId.value = committedDeviceId"))
        assertFalse(commit.contains("deviceRegistry.activeDeviceId()"))
    }

    @Test fun dailyRhythmMapsEverydayToolsWithoutEnablingThem() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val flowPolicy = source(userDir, "OnboardingFlowPolicy.kt").readText()
        val activePages = flowPolicy
            .substringAfter("): List<OnboardingPage> = listOf(")
            .substringBefore(")\n\ninternal data class OnboardingAccountCopy")

        assertTrue(onboarding.contains("OnboardingPage.DailyRhythm -> DailyRhythmStep()"))
        assertTrue(flowPolicy.contains("DailyRhythm(\"Continue\")"))
        assertFalse(activePages.contains("OnboardingPage.DailyRhythm"))
        var previousPage = -1
        for (page in listOf(
            "Welcome",
            "Bluetooth",
            "Connect",
            "Account",
            "Ownership",
            "Profile",
            "Plan",
            "Done",
        )) {
            val pageIndex = activePages.indexOf("OnboardingPage.$page")
            assertTrue(page, pageIndex > previousPage)
            previousPage = pageIndex
        }
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

    @Test fun accountBandAndSupplierClaimAreIndependentFailClosedGates() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val onboarding = source(userDir, "OnboardingScreen.kt").readText()
        val flowPolicy = source(userDir, "OnboardingFlowPolicy.kt").readText()
        val moveTo = onboarding
            .substringAfter("fun moveTo(")
            .substringBefore("fun acceptDeviceSetupSource(")

        assertTrue(
            onboarding.contains(
                "OnboardingPage.Account -> accountStepReady",
            ),
        )
        assertTrue(
            onboarding.contains(
                "OnboardingPage.Connect -> deviceSetupComplete",
            ),
        )
        assertTrue(
            onboarding.contains(
                "OnboardingPage.Ownership -> claimStepReady",
            ),
        )
        assertTrue(
            onboarding.contains(
                "OnboardingPage.Plan ->\n" +
                    "                        ownershipReconciliationComplete &&\n" +
                    "                            postClaimOwnershipReady",
            ),
        )
        assertTrue(
            moveTo.contains("resolvedOnboardingDestination("),
        )
        assertTrue(
            moveTo.indexOf("resolvedOnboardingDestination(") <
                moveTo.indexOf("prefs.edit()"),
        )
        assertTrue(
            flowPolicy.contains(
                "if (!deviceSetupComplete) return OnboardingPage.Connect",
            ),
        )
        assertTrue(
            flowPolicy.contains(
                "if (requested == OnboardingPage.Account) " +
                    "return OnboardingPage.Account",
            ),
        )
        assertTrue(
            flowPolicy.contains(
                "if (!ownershipConfigured) return OnboardingPage.Account",
            ),
        )
        assertTrue(flowPolicy.contains("if (!reconciliationComplete) return null"))
        assertTrue(flowPolicy.contains("!accountStepCanContinue("))
        assertTrue(flowPolicy.contains("!claimStepCanContinue("))
        assertTrue(flowPolicy.contains("return OnboardingPage.Ownership"))
        assertTrue(
            onboarding.contains(
                "supplierClaimRequired = registrySetupSource == SourceKind.veepoo",
            ),
        )
        assertTrue(onboarding.contains("fun complete() {"))
        assertTrue(
            onboarding.contains(
                "requested = OnboardingPage.Done,\n" +
                    "            ownershipConfigured = ownershipConfigured,",
            ),
        )
        assertTrue(
            onboarding.contains(
                "private const val ONBOARDING_PROGRESS_KEY = " +
                    "\"noop.onboarding.progress.v2\"",
            ),
        )
        assertTrue(
            onboarding.contains(
                ".remove(LEGACY_ONBOARDING_PROGRESS_KEY)",
            ),
        )
    }

    @Test fun returningOnboardedUserBypassesFirstRunScreen() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val main = source(userDir, "MainActivity.kt").readText()
        val gate = main
            .substringAfter("if (!onboarded && !demoBypass) {")
            .substringBefore("// Existing, onboarded user:")

        assertTrue(gate.contains("OnboardingScreen("))
        assertTrue(gate.contains("putBoolean(NoopPrefs.KEY_ONBOARDED, true)"))
        assertTrue(gate.contains("onboarded = true"))
        assertTrue(gate.contains("return"))
        assertFalse(gate.contains("AppRoot("))
        assertTrue(main.substringAfter(gate).contains("AppRoot("))
    }

    private fun source(userDir: String, name: String): File =
        listOf(
            File(userDir, "src/main/java/com/noop/ui/$name"),
            File(userDir, "app/src/main/java/com/noop/ui/$name"),
            File(userDir, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile) ?: error("Could not locate $name from $userDir")
}
