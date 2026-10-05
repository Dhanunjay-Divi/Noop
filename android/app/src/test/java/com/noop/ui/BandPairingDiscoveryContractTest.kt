package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BandPairingDiscoveryContractTest {
    @Test
    fun claimEligiblePickerStartsCombinedScanWithoutModelChoiceRows() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val picker = wizard
            .substringAfter("private fun WhoopPickStep(")
            .substringBefore("@Composable\nprivate fun HrPickStep(")

        assertTrue(wizard.contains(
            "selectionScope == AddDeviceSelectionScope.ClaimEligibleBands",
        ))
        assertTrue(wizard.contains(
            "automaticallyScansLaunchBands -> WizardStep.Pick",
        ))
        assertTrue(wizard.contains(
            "viewModel.selectedModel.value",
        ))
        assertTrue(wizard.contains(
            "automaticallyScansLaunchBands -> launchWhoopType",
        ))
        assertTrue(wizard.contains(
            "viewModel.presentWhoopScan(launchWhoopModel)",
        ))
        assertTrue(wizard.contains("onRescan = { startScan(t) }"))
        assertFalse(wizard.contains("automaticallyScansLaunchBands -> DeviceType.Whoop4"))
        assertFalse(wizard.contains("viewModel.presentWhoopScan(WhoopModel.WHOOP4)"))
        assertTrue(picker.contains("found.sortedByDescending { it.rssi }"))
        assertTrue(picker.contains("strap.model.registrationLabel()"))
        assertTrue(picker.contains("onOpenSupplierBand?.let"))
        assertFalse(picker.contains("BandPairingOptionRow("))
    }

    @Test
    fun optionalSupplierPrepBackRestoresTheUnifiedScan() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val backHandler = wizard
            .substringAfter("fun goBack()")
            .substringBefore("val confirmAdvertisedName")
        val pickerCall = wizard
            .substringAfter("t.isWhoop -> WhoopPickStep(")
            .substringBefore("t == DeviceType.GymEquipment")

        assertTrue(
            pickerCall.contains(
                "supplierPrepOrigin = SupplierPrepOrigin.UnifiedScan",
            ),
        )
        assertTrue(
            backHandler.contains(
                "supplierPrepBackTarget(supplierPrepOrigin)",
            ),
        )
        assertTrue(backHandler.contains("type = launchWhoopType"))
        assertTrue(backHandler.contains("step = WizardStep.Pick"))
        assertTrue(backHandler.contains("viewModel.presentWhoopScan(launchWhoopModel)"))
    }

    @Test
    fun unavailableAccountLinkedTransportIsNotRenderedAsADeadRow() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val discovery = source("BandPairingDiscovery.kt").readText()
        val typeStep = wizard
            .substringAfter("private fun TypeStep(")
            .substringBefore("/** A shared \"this tier is experimental\" note")
        val optionRow = discovery
            .substringAfter("internal fun BandPairingOptionRow(")
            .substringBefore("internal fun shouldAnimateBandPairingDiscovery(")

        assertTrue(typeStep.contains("if (supplierAvailable)"))
        assertFalse(typeStep.contains(
            "R.string.appwide_onboarding_device_wizard_account_linked_unavailable",
        ))
        assertTrue(optionRow.contains(".heightIn(min = 64.dp)"))
        assertTrue(
            optionRow.contains(
                ".clickable(enabled = enabled, role = Role.Button, onClick = onClick)",
            ),
        )
        assertFalse(optionRow.contains(".semantics"))
        assertTrue(optionRow.contains("Palette.statusWarningText"))
        assertTrue(discovery.contains("RoundedCornerShape(8.dp)"))
    }

    @Test
    fun discoveryStageIsSharedStaticAtReadyAndMotionGatedWhileSearching() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val discovery = source("BandPairingDiscovery.kt").readText()
        val typeStep = wizard
            .substringAfter("private fun TypeStep(")
            .substringBefore("/** A shared \"this tier is experimental\" note")
        val picker = wizard
            .substringAfter("private fun PickList(")
            .substringBefore("@Composable\nprivate fun DiscoveredRow(")
        val stage = discovery
            .substringAfter("internal fun BandPairingDiscoveryStage(")

        assertTrue(typeStep.contains("BandPairingDiscoveryStage(searching = false)"))
        assertTrue(picker.contains("BandPairingDiscoveryStage("))
        assertTrue(picker.contains("searching = searching"))
        assertTrue(picker.contains("supportingWarning = if (searching)"))
        assertFalse(picker.contains("CircularProgressIndicator("))
        assertTrue(picker.contains("if (!searching)"))
        assertTrue(stage.contains("rememberPoseStill()"))
        assertTrue(stage.contains("val sweep = if (animate)"))
        assertTrue(stage.contains("rememberInfiniteTransition("))
        assertTrue(stage.contains("RoundedCornerShape(8.dp)"))
        assertTrue(stage.contains("appwide_onboarding_device_wizard_idle"))
        assertTrue(
            stage.contains(
                "l10n_add_device_wizard_make_sure_it_s_awake_and_8c40e59f",
            ),
        )
    }

    @Test
    fun discoveryAnimationRunsOnlyForActiveSearchWithMotionEnabled() {
        assertTrue(
            shouldAnimateBandPairingDiscovery(
                searching = true,
                motionSuppressed = false,
            ),
        )
        assertFalse(
            shouldAnimateBandPairingDiscovery(
                searching = false,
                motionSuppressed = false,
            ),
        )
        assertFalse(
            shouldAnimateBandPairingDiscovery(
                searching = true,
                motionSuppressed = true,
            ),
        )
        assertFalse(
            shouldAnimateBandPairingDiscovery(
                searching = false,
                motionSuppressed = true,
            ),
        )
    }

    private fun source(name: String): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/$name"),
            File(userDir, "app/src/main/java/com/noop/ui/$name"),
            File(userDir, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate $name from $userDir")
    }
}
