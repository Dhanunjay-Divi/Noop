package com.noop.ui

import com.noop.R
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.ownership.OwnershipPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingOwnershipStepSelectionTest {
    @Test
    fun accountModeMatchesRuntimeConfiguration() {
        assertEquals(
            OnboardingAccountMode.CONFIGURED,
            onboardingAccountMode(ownershipConfigured = true),
        )
        assertEquals(
            OnboardingAccountMode.EXPLORATION,
            onboardingAccountMode(ownershipConfigured = false),
        )
    }

    @Test
    fun supplierBandRequiresBothOwnershipConfigurationAndAdapter() {
        assertTrue(
            supplierBandOnboardingAvailable(
                adapterAvailable = true,
                ownershipConfigured = true,
            ),
        )
        assertFalse(
            supplierBandOnboardingAvailable(
                adapterAvailable = true,
                ownershipConfigured = false,
            ),
        )
        assertFalse(
            supplierBandOnboardingAvailable(
                adapterAvailable = false,
                ownershipConfigured = true,
            ),
        )
        assertEquals(
            AddDeviceStart.DevicePicker,
            resolvedAddDeviceStart(
                requested = AddDeviceStart.SupplierBandPairing,
                supplierAvailable = false,
            ),
        )
        assertEquals(
            AddDeviceStart.SupplierBandPairing,
            resolvedAddDeviceStart(
                requested = AddDeviceStart.SupplierBandPairing,
                supplierAvailable = true,
            ),
        )
    }

    @Test
    fun accountCopyPreservesConfiguredAndLocalFirstBoundaries() {
        assertEquals(
            OnboardingAccountCopy(
                dataBoundaryTitle =
                    R.string.onboarding_data_boundary_configured_title,
                dataBoundaryBody =
                    R.string.onboarding_data_boundary_configured_body,
                bluetoothBoundaryBody =
                    R.string.onboarding_bluetooth_boundary_configured,
            ),
            onboardingAccountCopy(OnboardingAccountMode.CONFIGURED),
        )
        assertEquals(
            OnboardingAccountCopy(
                dataBoundaryTitle =
                    R.string.onboarding_data_boundary_exploration_title,
                dataBoundaryBody =
                    R.string.onboarding_data_boundary_exploration_body,
                bluetoothBoundaryBody =
                    R.string.onboarding_bluetooth_boundary_exploration,
            ),
            onboardingAccountCopy(OnboardingAccountMode.EXPLORATION),
        )
    }

    @Test
    fun activeFlowIsTheConciseEightStageAccountFirstSequence() {
        val expected = listOf(
            OnboardingPage.Welcome,
            OnboardingPage.Account,
            OnboardingPage.Bluetooth,
            OnboardingPage.Connect,
            OnboardingPage.Ownership,
            OnboardingPage.Profile,
            OnboardingPage.Plan,
            OnboardingPage.Done,
        )

        assertEquals(expected, onboardingPages(ownershipConfigured = true))
        assertEquals(expected, onboardingPages(ownershipConfigured = false))
    }

    @Test
    fun newProgressSchemaRejectsLegacyOrMalformedCheckpoints() {
        val pages = onboardingPages(ownershipConfigured = false)
        val welcome = pages.indexOf(OnboardingPage.Welcome)

        listOf(
            null,
            "profile",
            "1:profile",
            "2:not-a-page",
            "3:profile",
        ).forEach { stored ->
            assertEquals(
                stored,
                welcome,
                restoredOnboardingPageIndex(stored, pages),
            )
        }
    }

    @Test
    fun currentProgressSchemaCanResumeOnlyAnActivePage() {
        val pages = onboardingPages(ownershipConfigured = false)

        pages.forEachIndexed { expectedIndex, page ->
            assertEquals(
                page.name,
                expectedIndex,
                restoredOnboardingPageIndex(
                    storedPage = encodedOnboardingProgress(page),
                    pages = pages,
                ),
            )
        }
        assertEquals(
            pages.indexOf(OnboardingPage.Welcome),
            restoredOnboardingPageIndex(
                storedPage = encodedOnboardingProgress(OnboardingPage.Import),
                pages = pages,
            ),
        )
    }

    @Test
    fun configuredAccountGateStopsUntilAnAccountCanProceed() {
        val ready = setOf(
            OwnershipPhase.ACCOUNT_READY,
            OwnershipPhase.POSSESSION_UNAVAILABLE,
            OwnershipPhase.CLAIMING,
            OwnershipPhase.CLAIMED,
            OwnershipPhase.COMPLETE,
            OwnershipPhase.REPLACEMENT_REQUIRED,
            OwnershipPhase.AUTHORIZING_REPLACEMENT,
        )

        OwnershipPhase.entries.forEach { phase ->
            assertEquals(
                phase.name,
                phase in ready,
                accountStepCanContinue(
                    ownershipConfigured = true,
                    reconciliationComplete = true,
                    phase = phase,
                ),
            )
        }
        assertFalse(
            accountStepCanContinue(
                ownershipConfigured = true,
                reconciliationComplete = false,
                phase = OwnershipPhase.COMPLETE,
            ),
        )
        assertTrue(
            accountStepCanContinue(
                ownershipConfigured = false,
                reconciliationComplete = false,
                phase = OwnershipPhase.UNAVAILABLE,
            ),
        )
    }

    @Test
    fun restoredPostSetupPageReconcilesThroughAccountThenBand() {
        assertEquals(
            OnboardingPage.Account,
            destination(
                requested = OnboardingPage.Profile,
                configured = true,
                phase = OwnershipPhase.SIGNED_OUT,
                setupComplete = false,
            ),
        )
        assertEquals(
            OnboardingPage.Connect,
            destination(
                requested = OnboardingPage.Profile,
                configured = true,
                phase = OwnershipPhase.ACCOUNT_READY,
                setupComplete = false,
            ),
        )
        assertEquals(
            OnboardingPage.Connect,
            destination(
                requested = OnboardingPage.Profile,
                configured = false,
                phase = OwnershipPhase.UNAVAILABLE,
                setupComplete = false,
            ),
        )
    }

    @Test
    fun unsettledConfiguredAccountDoesNotPersistAReconciledRedirect() {
        assertNull(
            resolvedOnboardingDestination(
                requested = OnboardingPage.Profile,
                ownershipConfigured = true,
                reconciliationComplete = false,
                phase = OwnershipPhase.SIGNED_OUT,
                deviceSetupComplete = false,
                supplierClaimRequired = false,
            ),
        )
    }

    @Test
    fun whoopSetupDoesNotRequireSupplierOwnershipClaim() {
        assertTrue(
            claimStepCanContinue(
                supplierClaimRequired = false,
                claimed = false,
                reconciliationComplete = true,
            ),
        )
        assertEquals(
            OnboardingPage.Profile,
            destination(
                requested = OnboardingPage.Profile,
                configured = true,
                phase = OwnershipPhase.ACCOUNT_READY,
                setupComplete = true,
                supplierClaimRequired = false,
            ),
        )
    }

    @Test
    fun supplierSetupRequiresASettledClaimBeforeProfile() {
        assertFalse(
            claimStepCanContinue(
                supplierClaimRequired = true,
                claimed = false,
                reconciliationComplete = true,
            ),
        )
        assertEquals(
            OnboardingPage.Ownership,
            destination(
                requested = OnboardingPage.Profile,
                configured = true,
                phase = OwnershipPhase.ACCOUNT_READY,
                setupComplete = true,
                supplierClaimRequired = true,
            ),
        )
        assertEquals(
            OnboardingPage.Profile,
            destination(
                requested = OnboardingPage.Profile,
                configured = true,
                phase = OwnershipPhase.CLAIMED,
                setupComplete = true,
                supplierClaimRequired = true,
            ),
        )
    }

    @Test
    fun onlySupportedWhoopOrSupplierRowsCompleteLaunchSetup() {
        val generic = pairedDevice(
            id = "polar-h10",
            brand = "Polar",
            peripheralId = "opaque-generic",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
        )
        val imported = pairedDevice(
            id = "wearable-import",
            peripheralId = null,
            sourceKind = SourceKind.fileImport,
            status = DeviceStatus.paired,
        )
        val untouchedSeed = pairedDevice(
            id = "my-whoop",
            brand = "WHOOP",
            peripheralId = null,
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
        )

        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(generic, imported, untouchedSeed),
                supplierAvailable = true,
            ),
        )

        val whoop = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
        )
        assertEquals(
            SourceKind.liveBLE,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(whoop),
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun supplierRowRequiresTheSupplierAdapter() {
        val supplier = pairedDevice(
            id = "supplier-band",
            brand = "NOOP",
            peripheralId = "opaque-supplier",
            sourceKind = SourceKind.veepoo,
            status = DeviceStatus.active,
        )

        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(supplier),
                supplierAvailable = false,
            ),
        )
        assertEquals(
            SourceKind.veepoo,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(supplier),
                supplierAvailable = true,
            ),
        )
    }

    @Test
    fun registryFallbackPrefersTheActiveSupportedBand() {
        val oldWhoop = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
            lastSeenAt = 100,
        )
        val newSupplier = pairedDevice(
            id = "supplier-band",
            brand = "NOOP",
            peripheralId = "opaque-supplier",
            sourceKind = SourceKind.veepoo,
            status = DeviceStatus.paired,
            lastSeenAt = 200,
        )

        assertEquals(
            SourceKind.liveBLE,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(oldWhoop, newSupplier),
                supplierAvailable = true,
            ),
        )
    }

    @Test
    fun unavailableActiveSupplierDoesNotFallBackToAnOlderPairedBand() {
        val supplier = pairedDevice(
            id = "supplier-band",
            brand = "NOOP",
            peripheralId = "opaque-supplier",
            sourceKind = SourceKind.veepoo,
            status = DeviceStatus.active,
            lastSeenAt = 200,
        )
        val oldWhoop = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.paired,
            lastSeenAt = 100,
        )

        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(oldWhoop, supplier),
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun newestPairedSupportedBandIsUsedOnlyWhenNoActiveRowExists() {
        val oldWhoop = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.paired,
            lastSeenAt = 100,
        )
        val newSupplier = pairedDevice(
            id = "supplier-band",
            brand = "NOOP",
            peripheralId = "opaque-supplier",
            sourceKind = SourceKind.veepoo,
            status = DeviceStatus.paired,
            lastSeenAt = 200,
        )

        assertEquals(
            SourceKind.veepoo,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(oldWhoop, newSupplier),
                supplierAvailable = true,
            ),
        )
    }

    @Test
    fun pairedSupportedBandWinsOverTheEmptyLegacyActiveSeed() {
        val emptySeed = pairedDevice(
            id = "my-whoop",
            brand = "WHOOP",
            peripheralId = null,
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
            lastSeenAt = 100,
        )
        val pairedBand = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.paired,
            lastSeenAt = 200,
        )

        assertEquals(
            SourceKind.liveBLE,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(emptySeed, pairedBand),
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun postConnectPagesRequireADurableRegistryRefresh() {
        assertFalse(onboardingNeedsDeviceSetupRead(OnboardingPage.Welcome))
        assertFalse(onboardingNeedsDeviceSetupRead(OnboardingPage.Account))
        assertFalse(onboardingNeedsDeviceSetupRead(OnboardingPage.Bluetooth))
        assertTrue(onboardingNeedsDeviceSetupRead(OnboardingPage.Connect))
        assertTrue(onboardingNeedsDeviceSetupRead(OnboardingPage.Ownership))
        assertTrue(onboardingNeedsDeviceSetupRead(OnboardingPage.Profile))
        assertTrue(onboardingNeedsDeviceSetupRead(OnboardingPage.Plan))
        assertTrue(onboardingNeedsDeviceSetupRead(OnboardingPage.Done))
    }

    private fun destination(
        requested: OnboardingPage,
        configured: Boolean,
        phase: OwnershipPhase,
        setupComplete: Boolean,
        supplierClaimRequired: Boolean = false,
    ): OnboardingPage? = resolvedOnboardingDestination(
        requested = requested,
        ownershipConfigured = configured,
        reconciliationComplete = true,
        phase = phase,
        deviceSetupComplete = setupComplete,
        supplierClaimRequired = supplierClaimRequired,
    )

    private fun pairedDevice(
        id: String,
        brand: String = "Test",
        peripheralId: String?,
        sourceKind: SourceKind,
        status: DeviceStatus,
        lastSeenAt: Long = 1,
    ): PairedDeviceRow = PairedDeviceRow(
        id = id,
        brand = brand,
        model = "Test",
        nickname = null,
        peripheralId = peripheralId,
        sourceKind = sourceKind.name,
        capabilities = "hr",
        status = status.name,
        addedAt = 1,
        lastSeenAt = lastSeenAt,
    )
}
