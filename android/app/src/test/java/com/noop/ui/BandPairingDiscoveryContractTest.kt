package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BandPairingDiscoveryContractTest {
    @Test
    fun claimEligiblePickerShowsThreeNeutralLaunchRowsInRequiredOrder() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val typeStep = wizard
            .substringAfter("private fun TypeStep(")
            .substringBefore("/** A shared \"this tier is experimental\" note")

        val supplier = typeStep.indexOf("onPick(DeviceType.SupplierBand)")
        val compatible5 = typeStep.indexOf("onPick(DeviceType.Whoop5MG)")
        val compatible4 = typeStep.indexOf("onPick(DeviceType.Whoop4)")

        assertTrue(supplier >= 0)
        assertTrue(compatible5 > supplier)
        assertTrue(compatible4 > compatible5)
        assertTrue(
            wizard.contains(
                "R.string.appwide_onboarding_device_wizard_account_linked_title",
            ),
        )
        assertTrue(
            typeStep.contains(
                "R.string.appwide_onboarding_device_wizard_account_linked_subtitle",
            ),
        )
        assertTrue(
            typeStep.contains(
                "R.string.appwide_onboarding_device_wizard_compatible_band",
            ),
        )
        assertFalse(typeStep.contains("appwide_devices_supplier_display_model"))
        assertFalse(typeStep.contains("appwide_onboarding_device_wizard_whoop_subtitle"))
    }

    @Test
    fun unavailableAccountLinkedTransportStaysVisibleAndDisabled() {
        val wizard = source("AddDeviceWizard.kt").readText()
        val discovery = source("BandPairingDiscovery.kt").readText()
        val typeStep = wizard
            .substringAfter("private fun TypeStep(")
            .substringBefore("/** A shared \"this tier is experimental\" note")
        val supplierRow = typeStep
            .substringAfter("DeviceType.SupplierBand.title")
            .substringBefore("onPick(DeviceType.SupplierBand)")
        val optionRow = discovery
            .substringAfter("internal fun BandPairingOptionRow(")
            .substringBefore("internal fun shouldAnimateBandPairingDiscovery(")

        assertTrue(supplierRow.contains("enabled = supplierAvailable"))
        assertTrue(
            supplierRow.contains(
                "R.string.appwide_onboarding_device_wizard_account_linked_unavailable",
            ),
        )
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
        assertTrue(picker.contains("BandPairingDiscoveryStage(searching = searching)"))
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
