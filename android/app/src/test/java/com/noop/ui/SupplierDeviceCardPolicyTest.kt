package com.noop.ui

import com.noop.R
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SupplierDeviceCardPolicyTest {
    @Test
    fun onlyActiveWhoopCardOffersConnectionActions() {
        assertTrue(
            deviceCardShowsWhoopConnectionActions(
                isActive = true,
                isWhoop = true,
            ),
        )
        assertFalse(
            deviceCardShowsWhoopConnectionActions(
                isActive = false,
                isWhoop = true,
            ),
        )
        assertFalse(
            deviceCardShowsWhoopConnectionActions(
                isActive = true,
                isWhoop = false,
            ),
        )
    }

    @Test
    fun supplierProfileClaimsOnlyDisplayHeartRateAndConnectedBattery() {
        val profile = deviceProfile(
            device(
                sourceKind = SourceKind.veepoo,
                status = DeviceStatus.active,
                capabilities = "hr,hrv,strainLoad",
            ),
            stringResolver = ::supplierString,
        )

        assertEquals("NOOP Band", profile.displayModel)
        assertEquals("Heart rate (live display only) · Battery", profile.captures)
        assertEquals(
            "Live display only. No history or scores are stored from this source",
            profile.powers,
        )
        assertTrue(profile.footnote.contains("Heart rate expires when updates stop"))
        assertTrue(profile.footnote.contains("only while the band is connected"))

        val claimedCapabilities = "${profile.captures} ${profile.powers}"
        assertFalse(claimedCapabilities.contains("HRV", ignoreCase = true))
        assertFalse(claimedCapabilities.contains("Strain", ignoreCase = true))
        assertFalse(claimedCapabilities.contains("Effort", ignoreCase = true))
    }

    @Test
    fun archivedSupplierCardCarriesNoDirectActivationCallback() {
        val devicesScreen = source("DevicesScreen.kt").readText()
        val removedDevicesStart = devicesScreen.indexOf("items(removedDevices)")
        val removedDevicesEnd = devicesScreen.indexOf("item { WhoopFirstFooter() }")

        assertTrue(removedDevicesStart >= 0)
        assertTrue(removedDevicesEnd > removedDevicesStart)
        val removedDevicesBlock = devicesScreen.substring(removedDevicesStart, removedDevicesEnd)
        assertTrue(removedDevicesBlock.contains("onMakeActive = null"))
        assertFalse(removedDevicesBlock.contains("onMakeActive = {"))
    }

    @Test
    fun archivedSupplierPairsAgainInsteadOfDirectActivation() {
        val action = archivedDevicePrimaryAction(
            device = device(SourceKind.veepoo, DeviceStatus.archived),
            supplierPairingAvailable = true,
        )

        assertEquals(ArchivedDevicePrimaryAction.PairAgain, action)
        assertEquals(R.string.appwide_devices_pair_again, action?.labelRes)
        assertEquals(AddDeviceStart.SupplierBandPairing, action?.wizardStart)
    }

    @Test
    fun archivedSupplierActionIsHiddenWithoutThePairingAdapter() {
        assertNull(
            archivedDevicePrimaryAction(
                device = device(SourceKind.veepoo, DeviceStatus.archived),
                supplierPairingAvailable = false,
            ),
        )
    }

    @Test
    fun ordinaryArchivedTransportKeepsItsExistingActivationAction() {
        val action = archivedDevicePrimaryAction(
            device = device(SourceKind.liveBLE, DeviceStatus.archived),
            supplierPairingAvailable = false,
        )

        assertEquals(ArchivedDevicePrimaryAction.MakeActive, action)
        assertEquals(
            R.string.l10n_add_device_wizard_make_active_75690bb8,
            action?.labelRes,
        )
        assertNull(action?.wizardStart)
    }

    @Test
    fun activeOrPairedRowsNeverUseAnArchivedPrimaryAction() {
        assertNull(
            archivedDevicePrimaryAction(
                device = device(SourceKind.veepoo, DeviceStatus.active),
                supplierPairingAvailable = true,
            ),
        )
        assertNull(
            archivedDevicePrimaryAction(
                device = device(SourceKind.liveBLE, DeviceStatus.paired),
                supplierPairingAvailable = true,
            ),
        )
    }

    @Test
    fun customerDevicesEntryRequiresOwnershipAndAdapterForSupplierPairing() {
        val devicesScreen = source("DevicesScreen.kt").readText()

        assertTrue(
            devicesScreen.contains(
                "val ownershipConfigured = remember { " +
                    "OwnershipConfiguration.load() != null }",
            ),
        )
        assertTrue(
            devicesScreen.contains(
                "val supplierPairingAvailable = supplierBandOnboardingAvailable(",
            ),
        )
        assertTrue(
            devicesScreen.contains(
                "supplierPairingAvailable = supplierPairingAvailable",
            ),
        )
        assertTrue(
            devicesScreen.contains(
                "allowSupplierBand = supplierPairingAvailable",
            ),
        )
    }

    @Test
    fun supplierRemovalConsumesTransactionalFallbackBeforeShowingReplacementDialog() {
        val devicesScreen = source("DevicesScreen.kt").readText()
        val removalBlock = devicesScreen
            .substringAfter("// --- Remove confirm ---")
            .substringBefore("// --- Restart strap confirm")

        assertTrue(
            removalBlock.contains(
                "val archiveResult = viewModel.archivePairedDevice(device.id)",
            ),
        )
        assertTrue(
            removalBlock.contains(
                "shouldPromptForReplacementAfterArchive(",
            ),
        )
        assertFalse(
            shouldPromptForReplacementAfterArchive(
                wasActive = true,
                archiveResult = ArchivedDeviceResult(
                    archived = true,
                    activeDeviceId = "fallback-band",
                ),
                hasRemainingDevice = true,
            ),
        )
        assertTrue(
            shouldPromptForReplacementAfterArchive(
                wasActive = true,
                archiveResult = ArchivedDeviceResult(
                    archived = true,
                    activeDeviceId = null,
                ),
                hasRemainingDevice = true,
            ),
        )
        assertFalse(
            shouldPromptForReplacementAfterArchive(
                wasActive = true,
                archiveResult = ArchivedDeviceResult(
                    archived = false,
                    activeDeviceId = null,
                ),
                hasRemainingDevice = true,
            ),
        )
    }

    private fun device(
        sourceKind: SourceKind,
        status: DeviceStatus,
        capabilities: String = "hr",
    ) = PairedDeviceRow(
        id = "test-device",
        brand = if (sourceKind == SourceKind.veepoo) "NOOP" else "WHOOP",
        model = if (sourceKind == SourceKind.veepoo) "Supplier band" else "5.0 MG",
        nickname = null,
        sourceKind = sourceKind.name,
        capabilities = capabilities,
        status = status.name,
        addedAt = 0,
        lastSeenAt = 0,
    )

    private fun supplierString(id: Int): String = when (id) {
        R.string.appwide_devices_supplier_display_model -> "NOOP Band"
        R.string.appwide_devices_supplier_captures ->
            "Heart rate (live display only) · Battery"
        R.string.appwide_devices_supplier_powers ->
            "Live display only. No history or scores are stored from this source"
        R.string.appwide_devices_supplier_footnote ->
            "Heart rate expires when updates stop. Battery is shown only while the band is connected."
        else -> error("Unexpected supplier string resource: $id")
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
