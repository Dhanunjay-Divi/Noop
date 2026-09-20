package com.noop.ui

import com.noop.R
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
                bonded = false,
            ),
        )
        assertTrue(
            !onboardingContinuesWithoutBand(
                ownershipConfigured = true,
                bonded = false,
            ),
        )
        assertTrue(
            !onboardingContinuesWithoutBand(
                ownershipConfigured = false,
                bonded = true,
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
}
