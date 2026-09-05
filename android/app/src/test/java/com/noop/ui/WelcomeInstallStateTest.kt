package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class WelcomeInstallStateTest {
    @Test
    fun freshInstallRemainsPendingThroughInterruptedOnboarding() {
        assertEquals(
            ReleaseWelcomeInstallState(pending = true, completed = false),
            ReleaseWelcomeInstallState.prepared(
                onboarded = false,
                storedPending = false,
                storedCompleted = false,
            ),
        )
        assertEquals(
            ReleaseWelcomeInstallState(pending = true, completed = false),
            ReleaseWelcomeInstallState.prepared(
                onboarded = true,
                storedPending = true,
                storedCompleted = false,
            ),
        )
    }

    @Test
    fun existingInstallMigratesWithoutFirstInstallGlow() {
        assertEquals(
            ReleaseWelcomeInstallState(pending = false, completed = true),
            ReleaseWelcomeInstallState.prepared(
                onboarded = true,
                storedPending = false,
                storedCompleted = false,
            ),
        )
    }

    @Test
    fun completingWelcomePermanentlyClearsPendingState() {
        assertEquals(
            ReleaseWelcomeInstallState(pending = false, completed = true),
            ReleaseWelcomeInstallState(pending = true, completed = false).completingWelcome(),
        )
        assertEquals(
            ReleaseWelcomeInstallState(pending = false, completed = true),
            ReleaseWelcomeInstallState.prepared(
                onboarded = true,
                storedPending = true,
                storedCompleted = true,
            ),
        )
    }

    @Test
    fun welcomeIsDueOnlyForAGenuinelyNewerVersion() {
        assertEquals(
            true,
            ReleaseWelcomeInstallState.isReleaseDue(
                currentVersion = "9.10.0",
                lastSeenVersion = "9.2.0",
            ),
        )
        assertEquals(
            false,
            ReleaseWelcomeInstallState.isReleaseDue(
                currentVersion = "9.2.1",
                lastSeenVersion = "9.2.1",
            ),
        )
        assertEquals(
            false,
            ReleaseWelcomeInstallState.isReleaseDue(
                currentVersion = "9.2.0",
                lastSeenVersion = "9.2.1",
            ),
        )
    }
}
