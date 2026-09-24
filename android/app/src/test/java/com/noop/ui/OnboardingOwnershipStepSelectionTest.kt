package com.noop.ui

import com.noop.R
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.ownership.OwnershipPhase
import org.junit.Assert.assertEquals
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
    fun accountCopyBranchesBetweenConfiguredAndExplorationModes() {
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
    fun configuredOwnershipIncludesAccountStepWithoutConstructingRuntimeService() {
        val pages = onboardingPages(ownershipConfigured = true)

        assertTrue(pages.contains(OnboardingPage.Ownership))
        assertEquals(
            pages.indexOf(OnboardingPage.Bonded) + 1,
            pages.indexOf(OnboardingPage.Ownership),
        )
        assertEquals(
            pages.indexOf(OnboardingPage.Ownership) + 1,
            pages.indexOf(OnboardingPage.Profile),
        )
    }

    @Test
    fun unconfiguredCoreModeKeepsAccountStepVisibleBeforeProfile() {
        val pages = onboardingPages(ownershipConfigured = false)

        assertTrue(pages.contains(OnboardingPage.Ownership))
        assertTrue(pages.contains(OnboardingPage.Profile))
        assertEquals(
            pages.indexOf(OnboardingPage.Bonded) + 1,
            pages.indexOf(OnboardingPage.Ownership),
        )
        assertEquals(
            pages.indexOf(OnboardingPage.Ownership) + 1,
            pages.indexOf(OnboardingPage.Profile),
        )
    }

    @Test
    fun unconfiguredCoreModeResumesSavedAccountStepExactly() {
        val pages = onboardingPages(ownershipConfigured = false)

        assertEquals(
            pages.indexOf(OnboardingPage.Ownership),
            restoredOnboardingPageIndex(
                storedPage = OnboardingPage.Ownership.storageValue,
                pages = pages,
            ),
        )
    }

    @Test
    fun activeCheckpointsResumeAtTheirExactPage() {
        listOf(true, false).forEach { ownershipConfigured ->
            val pages = onboardingPages(ownershipConfigured)

            pages.forEachIndexed { expectedIndex, page ->
                assertEquals(
                    "$page with ownershipConfigured=$ownershipConfigured",
                    expectedIndex,
                    restoredOnboardingPageIndex(
                        storedPage = page.storageValue,
                        pages = pages,
                    ),
                )
            }
        }
    }

    @Test
    fun transientOwnershipBootstrapDoesNotResolveOrPersistRedirect() {
        OnboardingPage.entries
            .filter(OnboardingPage::requiresCurrentOwnershipClaim)
            .forEach { page ->
                assertNull(
                    "$page must stay restored until bootstrap reconciliation settles",
                    resolvedOnboardingOwnershipDestination(
                        requested = page,
                        ownershipConfigured = true,
                        reconciliationComplete = false,
                        phase = OwnershipPhase.SIGNED_OUT,
                    ),
                )
            }
    }

    @Test
    fun resolvedUnclaimedOwnershipRedirectsPostOwnershipPages() {
        OnboardingPage.entries
            .filter(OnboardingPage::requiresCurrentOwnershipClaim)
            .forEach { page ->
                assertEquals(
                    OnboardingPage.Ownership,
                    resolvedOnboardingOwnershipDestination(
                        requested = page,
                        ownershipConfigured = true,
                        reconciliationComplete = true,
                        phase = OwnershipPhase.SIGNED_OUT,
                    ),
                )
            }
    }

    @Test
    fun resolvedClaimedOwnershipPreservesPostOwnershipPages() {
        listOf(OwnershipPhase.CLAIMED, OwnershipPhase.COMPLETE).forEach { phase ->
            OnboardingPage.entries
                .filter(OnboardingPage::requiresCurrentOwnershipClaim)
                .forEach { page ->
                    assertEquals(
                        page,
                        resolvedOnboardingOwnershipDestination(
                            requested = page,
                            ownershipConfigured = true,
                            reconciliationComplete = true,
                            phase = phase,
                        ),
                    )
                }
        }
    }

    @Test
    fun unconfiguredCoreModeNeverWaitsForOwnershipReconciliation() {
        assertEquals(
            OnboardingPage.Done,
            resolvedOnboardingOwnershipDestination(
                requested = OnboardingPage.Done,
                ownershipConfigured = false,
                reconciliationComplete = false,
                phase = OwnershipPhase.UNAVAILABLE,
            ),
        )
    }

    @Test
    fun unconfiguredAccountStepContinuesWithoutClaimOrReconciliation() {
        assertTrue(
            ownershipStepCanContinue(
                ownershipConfigured = false,
                reconciliationComplete = false,
                phase = OwnershipPhase.UNAVAILABLE,
            ),
        )
    }

    @Test
    fun unconfiguredScanNamesTheOfflinePathExplicitly() {
        assertTrue(
            onboardingContinuesWithoutBand(
                ownershipConfigured = false,
                deviceSetupComplete = false,
            ),
        )
        assertTrue(
            !onboardingContinuesWithoutBand(
                ownershipConfigured = true,
                deviceSetupComplete = false,
            ),
        )
        assertTrue(
            !onboardingContinuesWithoutBand(
                ownershipConfigured = false,
                deviceSetupComplete = true,
            ),
        )
    }

    @Test
    fun untouchedSeedAndImportsDoNotCompleteDeviceSetup() {
        val seed = pairedDevice(
            id = "my-whoop",
            peripheralId = null,
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
        )
        val imported = pairedDevice(
            id = "wearable-import",
            peripheralId = null,
            sourceKind = SourceKind.fileImport,
            status = DeviceStatus.paired,
        )
        val activityFile = pairedDevice(
            id = "activity-file",
            peripheralId = null,
            sourceKind = SourceKind.activityFile,
            status = DeviceStatus.paired,
        )

        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(seed, imported, activityFile),
                requiresClaimEligibleBand = true,
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun genericLiveBleOnlyCompletesOptionalDeviceSetup() {
        val genericStrap = pairedDevice(
            id = "polar-h10",
            brand = "Polar",
            peripheralId = "opaque-peripheral",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
        )

        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(genericStrap),
                requiresClaimEligibleBand = true,
                supplierAvailable = false,
            ),
        )
        assertEquals(
            SourceKind.liveBLE,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(genericStrap),
                requiresClaimEligibleBand = false,
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun supplierRegistryCommitCompletesConfiguredBandSetup() {
        val supplier = pairedDevice(
            id = "supplier-band",
            brand = "Supplier",
            peripheralId = "opaque-peripheral",
            sourceKind = SourceKind.veepoo,
            status = DeviceStatus.active,
        )

        assertEquals(
            SourceKind.veepoo,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(supplier),
                requiresClaimEligibleBand = true,
                supplierAvailable = true,
            ),
        )
        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(supplier),
                requiresClaimEligibleBand = true,
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun canonicalWhoopRowCompletesConfiguredBandSetup() {
        val whoop = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = "opaque-peripheral",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.active,
        )

        assertEquals(
            SourceKind.liveBLE,
            onboardingCompletedDeviceSetupSource(
                devices = listOf(whoop),
                requiresClaimEligibleBand = true,
                supplierAvailable = false,
            ),
        )
    }

    @Test
    fun configuredSetupRejectsMismatchedWhoopMetadataAndBlankIdentity() {
        val mismatched = pairedDevice(
            id = "not-a-band",
            brand = "WHOOP",
            peripheralId = "opaque-peripheral",
            sourceKind = SourceKind.ftms,
            status = DeviceStatus.active,
        )
        val blankIdentity = pairedDevice(
            id = "whoop-test-band",
            brand = "WHOOP",
            peripheralId = " ",
            sourceKind = SourceKind.liveBLE,
            status = DeviceStatus.paired,
        )

        assertNull(
            onboardingCompletedDeviceSetupSource(
                devices = listOf(mismatched, blankIdentity),
                requiresClaimEligibleBand = true,
                supplierAvailable = true,
            ),
        )
    }

    @Test
    fun configuredAccountStepRequiresSettledClaimOrCompletion() {
        assertTrue(
            !ownershipStepCanContinue(
                ownershipConfigured = true,
                reconciliationComplete = true,
                phase = OwnershipPhase.SIGNED_OUT,
            ),
        )
        assertTrue(
            !ownershipStepCanContinue(
                ownershipConfigured = true,
                reconciliationComplete = false,
                phase = OwnershipPhase.CLAIMED,
            ),
        )
        assertTrue(
            !ownershipStepCanContinue(
                ownershipConfigured = true,
                reconciliationComplete = true,
                phase = OwnershipPhase.ACCOUNT_READY,
            ),
        )
        listOf(OwnershipPhase.CLAIMED, OwnershipPhase.COMPLETE).forEach { phase ->
            assertTrue(
                ownershipStepCanContinue(
                    ownershipConfigured = true,
                    reconciliationComplete = true,
                    phase = phase,
                ),
            )
        }
    }

    @Test
    fun absentOrUnrecognizedCheckpointStartsAtWelcome() {
        val pages = onboardingPages(ownershipConfigured = false)
        val welcomeIndex = pages.indexOf(OnboardingPage.Welcome)

        assertEquals(
            welcomeIndex,
            restoredOnboardingPageIndex(storedPage = null, pages = pages),
        )
        assertEquals(
            welcomeIndex,
            restoredOnboardingPageIndex(storedPage = "not-a-page", pages = pages),
        )
    }

    private fun pairedDevice(
        id: String,
        brand: String = "Test",
        peripheralId: String?,
        sourceKind: SourceKind,
        status: DeviceStatus,
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
        lastSeenAt = 1,
    )
}
