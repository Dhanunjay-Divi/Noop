package com.noop.ui

import com.noop.ownership.OwnershipPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingOwnershipStepSelectionTest {
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
    fun unconfiguredCoreModeOmitsAccountStepAndKeepsProfile() {
        val pages = onboardingPages(ownershipConfigured = false)

        assertFalse(pages.contains(OnboardingPage.Ownership))
        assertTrue(pages.contains(OnboardingPage.Profile))
        assertEquals(
            pages.indexOf(OnboardingPage.Bonded) + 1,
            pages.indexOf(OnboardingPage.Profile),
        )
    }

    @Test
    fun unconfiguredCoreModeResumesSavedAccountStepAtProfile() {
        val pages = onboardingPages(ownershipConfigured = false)

        assertEquals(
            pages.indexOf(OnboardingPage.Profile),
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
