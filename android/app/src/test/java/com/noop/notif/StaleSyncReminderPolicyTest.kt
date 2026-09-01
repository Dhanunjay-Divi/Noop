package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class StaleSyncReminderPolicyTest {
    @Test
    fun reminderRequiresBackgroundPairingAuthorizationAndMatchingGeneration() {
        assertSame(
            StaleSyncReminderDueAction.Post,
            StaleSyncReminderPolicy.dueAction(
                appBackgrounded = true,
                hasPairedBand = true,
                notificationsAuthorized = true,
                expectedGeneration = "current",
                currentGeneration = "current",
                baselineFreshnessAt = 100,
                currentFreshnessAt = 100,
                nowEpochSeconds = 100 + StaleSyncReminderPolicy.DELAY_SECONDS,
            ),
        )

        assertSame(
            StaleSyncReminderDueAction.Suppress,
            StaleSyncReminderPolicy.dueAction(
                false, true, true, "current", "current", 100, 100, 200,
            ),
        )
        assertSame(
            StaleSyncReminderDueAction.Suppress,
            StaleSyncReminderPolicy.dueAction(
                true, false, true, "current", "current", 100, 100, 200,
            ),
        )
        assertSame(
            StaleSyncReminderDueAction.Suppress,
            StaleSyncReminderPolicy.dueAction(
                true, true, false, "current", "current", 100, 100, 200,
            ),
        )
        assertSame(
            StaleSyncReminderDueAction.Suppress,
            StaleSyncReminderPolicy.dueAction(
                true, true, true, "old", "current", 100, 100, 200,
            ),
        )
    }

    @Test
    fun durableProgressRearmsWithoutWaitingForTheSyncSessionToSettle() {
        assertEquals(
            StaleSyncReminderDueAction.Rearm(
                baselineFreshnessAt = 101,
                delaySeconds = StaleSyncReminderPolicy.DELAY_SECONDS - 30,
            ),
            StaleSyncReminderPolicy.dueAction(
                appBackgrounded = true,
                hasPairedBand = true,
                notificationsAuthorized = true,
                expectedGeneration = "current",
                currentGeneration = "current",
                baselineFreshnessAt = 100,
                currentFreshnessAt = 101,
                nowEpochSeconds = 131,
            ),
        )
    }

    @Test
    fun delayedWorkerPostsWhenLatestDurableProgressIsAlreadyTwoHoursOld() {
        assertSame(
            StaleSyncReminderDueAction.Post,
            StaleSyncReminderPolicy.dueAction(
                appBackgrounded = true,
                hasPairedBand = true,
                notificationsAuthorized = true,
                expectedGeneration = "current",
                currentGeneration = "current",
                baselineFreshnessAt = 100,
                currentFreshnessAt = 101,
                nowEpochSeconds = 101 + StaleSyncReminderPolicy.DELAY_SECONDS,
            ),
        )
    }
}
