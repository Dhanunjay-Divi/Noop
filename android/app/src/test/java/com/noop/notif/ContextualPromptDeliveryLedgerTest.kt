package com.noop.notif

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ContextualPromptDeliveryLedgerTest {
    @Test fun failedReservationNeverPostsANotification() {
        val prefs = FakeSharedPreferences(commitResult = false)
        var postCount = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 1_000L,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            identity = "planned-a",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.FAILED, result.status)
        assertEquals(0, postCount)
        assertEquals(ContextualPromptDeliveryState(), ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun successfulPostStaysPendingUntilTheTopicCooldownIsDurable() {
        val prefs = FakeSharedPreferences()
        var postCount = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 2_000L,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            identity = "planned-a",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.ACCEPTED, result.status)
        assertTrue(checkNotNull(result.receipt).pending)
        assertTrue(checkNotNull(result.receipt).notificationPosted)
        assertEquals(1, postCount)
        val pending = checkNotNull(
            ContextualPromptDeliveryLedger.loadState(prefs)
                .pendingDeliveries[ContextualPromptDeliveryOwner.PLANNED_WORKOUT],
        )
        assertTrue(pending.notificationPosted)

        assertTrue(
            ContextualPromptDeliveryLedger.confirmPendingIfOwned(
                prefs = prefs,
                owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
                expectedAtMillis = 2_000L,
                expectedIdentity = "planned-a",
            ),
        )
        val delivered = ContextualPromptDeliveryLedger.loadState(prefs)
        assertFalse(
            delivered.pendingDeliveries.containsKey(
                ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            ),
        )
        assertEquals(
            2_000L,
            delivered.deliveries[ContextualPromptDeliveryOwner.PLANNED_WORKOUT],
        )

        val duplicate = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 4_000L,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            identity = "planned-a",
        ) {
            postCount += 1
            true
        }
        assertEquals(ContextualPromptPostStatus.ACCEPTED, duplicate.status)
        assertFalse(duplicate.notificationPosted)
        assertNotNull(duplicate.receipt)
        assertEquals(1, postCount)
    }

    @Test fun interruptedPostedMarkerSafelyRepostsTheSameIdentity() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, true, false),
        )
        var postCount = 0

        val interrupted = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 2_000L,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            identity = "planned-a",
        ) {
            postCount += 1
            true
        }
        assertEquals(ContextualPromptPostStatus.ACCEPTED, interrupted.status)
        assertFalse(
            checkNotNull(
                ContextualPromptDeliveryLedger.loadState(prefs)
                    .pendingDeliveries[ContextualPromptDeliveryOwner.PLANNED_WORKOUT],
            ).notificationPosted,
        )
        assertTrue(
            checkNotNull(
                ContextualPromptDeliveryLedger.loadState(prefs)
                    .pendingDeliveries[ContextualPromptDeliveryOwner.PLANNED_WORKOUT],
            ).notificationAttempted,
        )

        val recovered = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 3_000L,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            identity = "planned-a",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.ACCEPTED, recovered.status)
        assertTrue(checkNotNull(recovered.receipt).pending)
        assertEquals(3_000L, recovered.receipt?.atMillis)
        assertEquals(2, postCount)
    }

    @Test fun unpostedReservationDoesNotOwnOrCancelThePreviousVisibleSlot() {
        val previous = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 1_000L,
            identity = "sleep-a",
        )
        val withReservation = ContextualPromptDeliveryLedger.reservedState(
            state = previous,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-b",
        )

        val outcome = ContextualPromptDeliveryLedger.ownerReconciliation(
            withReservation,
            ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        )

        assertTrue(outcome.ownerRemoved)
        assertFalse(outcome.ownedNotificationSlot)
        assertEquals(
            1_000L,
            outcome.nextState.deliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
        )
    }

    @Test fun reservationPreservesAnUnfinishedCancellationTombstoneUntilPostingCompletes() {
        val beforeReservation = ContextualPromptDeliveryState(
            pendingCancellationSlots = setOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY),
            pendingCancellationCutoffs =
                mapOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY to 1_000L),
        )
        val reserved = ContextualPromptDeliveryLedger.reservedState(
            state = beforeReservation,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-b",
        )

        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                reserved.pendingCancellationSlots,
        )

        val attempted = ContextualPromptDeliveryLedger.attemptedState(
            state = reserved,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = 2_000L,
            expectedIdentity = "planned-b",
        )
        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                attempted.pendingCancellationSlots,
        )
        assertEquals(
            1_000L,
            attempted.pendingCancellationCutoffs[
                ContextualPromptNotificationSlot.ADAPTIVE_DAY
            ],
        )

        val posted = ContextualPromptDeliveryLedger.postedPendingState(
            state = attempted,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = 2_000L,
            expectedIdentity = "planned-b",
        )
        assertFalse(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                posted.pendingCancellationSlots,
        )
    }

    @Test fun failedOwnerRemovalCommitDoesNotCancelTheVisibleNotification() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, false),
        )
        val delivered = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-a",
        )
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, delivered))
        var cancellationCount = 0

        val outcome = ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(outcome.ownerRemoved)
        assertFalse(outcome.ownedNotificationSlot)
        assertEquals(0, cancellationCount)
        assertEquals(delivered, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun unpostedRetryCannotJumpANewerGlobalCooldown() {
        val pending = ContextualPromptDeliveryLedger.reservedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 1_000L,
            identity = "planned-a",
        )
        val withNewerDelivery = ContextualPromptDeliveryLedger.recordedState(
            state = pending,
            owner = ContextualPromptDeliveryOwner.VITAL_REVIEW,
            nowMillis = 2_000L,
            identity = "vital-b",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, withNewerDelivery))
        var postCount = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 3_000L,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            identity = "planned-a",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.GLOBAL_COOLDOWN, result.status)
        assertEquals(0, postCount)
    }

    @Test fun processDeathBeforePlatformAttemptDoesNotCreateHoursOfSuppression() {
        val reserved = ContextualPromptDeliveryLedger.reservedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
            nowMillis = 1_000L,
            identity = "stress-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, reserved))
        var postCount = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 2_000L,
            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
            identity = "stress-b",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.ACCEPTED, result.status)
        assertEquals(1, postCount)
    }

    @Test fun unresolvedPostedTopicBlocksADifferentIdentityAfterPrivateFailure() {
        val postedPending = ContextualPromptDeliveryLedger.postedPendingState(
            state = ContextualPromptDeliveryLedger.reservedState(
                state = ContextualPromptDeliveryState(),
                owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
                nowMillis = 1_000L,
                identity = "stress-a",
            ),
            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
            expectedAtMillis = 1_000L,
            expectedIdentity = "stress-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, postedPending))
        var postCount = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = ContextualPromptGlobalPolicy.COOLDOWN_MILLIS + 2_000L,
            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
            identity = "stress-b",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.GLOBAL_COOLDOWN, result.status)
        assertEquals(0, postCount)
    }

    @Test fun unresolvedTopicReservationExpiresAfterItsLongestCooldown() {
        val postedPending = ContextualPromptDeliveryLedger.postedPendingState(
            state = ContextualPromptDeliveryLedger.reservedState(
                state = ContextualPromptDeliveryState(),
                owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
                nowMillis = 1_000L,
                identity = "stress-a",
            ),
            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
            expectedAtMillis = 1_000L,
            expectedIdentity = "stress-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, postedPending))
        var postCount = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = 4L * 60L * 60L * 1_000L + 1_001L,
            owner = ContextualPromptDeliveryOwner.STRESS_BREATHING,
            identity = "stress-b",
        ) {
            postCount += 1
            true
        }

        assertEquals(ContextualPromptPostStatus.ACCEPTED, result.status)
        assertEquals(1, postCount)
    }

    @Test fun failedPlatformPostRestoresThePreviousOwnerState() {
        val prior = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 1_000L,
            identity = "sleep-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, prior))

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = ContextualPromptGlobalPolicy.COOLDOWN_MILLIS + 2_000L,
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            identity = "sleep-b",
            post = { false },
        )

        assertEquals(ContextualPromptPostStatus.FAILED, result.status)
        assertEquals(prior, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun thrownPlatformPostKeepsAnAmbiguousAttemptInsteadOfOrphaningItsSideEffect() {
        val prior = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 1_000L,
            identity = "sleep-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, prior))

        var platformSideEffects = 0
        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = ContextualPromptGlobalPolicy.COOLDOWN_MILLIS + 2_000L,
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            identity = "sleep-b",
            post = {
                platformSideEffects += 1
                throw IllegalStateException("after platform side effect")
            },
        )

        assertEquals(ContextualPromptPostStatus.FAILED, result.status)
        assertEquals(1, platformSideEffects)
        val state = ContextualPromptDeliveryLedger.loadState(prefs)
        val pending = checkNotNull(
            state.pendingDeliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
        )
        assertTrue(pending.notificationAttempted)
        assertFalse(pending.notificationPosted)
        assertEquals(
            prior.deliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
            state.deliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
        )
    }

    @Test fun expiringAnOldWorkoutCannotCancelANewerAdaptiveNotification() {
        val oldWorkout = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 1_000L,
            identity = "planned-a",
        )
        val newerAdaptive = ContextualPromptDeliveryLedger.postedPendingState(
            state = ContextualPromptDeliveryLedger.reservedState(
                state = oldWorkout,
                owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
                nowMillis = 2_000L,
                identity = "sleep-b",
            ),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            expectedAtMillis = 2_000L,
            expectedIdentity = "sleep-b",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, newerAdaptive))
        var cancellationCount = 0

        val cancelled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfOwned(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = 1_000L,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(cancelled)
        assertEquals(0, cancellationCount)
        assertEquals(newerAdaptive, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun failedPostedMarkerStillPreventsOldWorkoutExpiryFromCancellingReplacement() {
        val oldWorkout = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 1_000L,
            identity = "planned-a",
        )
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, true, true, false),
        )
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, oldWorkout))
        var platformSideEffects = 0

        val result = ContextualPromptDeliveryLedger.postIfAllowed(
            prefs = prefs,
            nowMillis = ContextualPromptGlobalPolicy.COOLDOWN_MILLIS + 2_000L,
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            identity = "sleep-b",
        ) {
            platformSideEffects += 1
            true
        }
        assertEquals(ContextualPromptPostStatus.ACCEPTED, result.status)
        assertEquals(1, platformSideEffects)
        val pending = checkNotNull(
            ContextualPromptDeliveryLedger.loadState(prefs)
                .pendingDeliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
        )
        assertTrue(pending.notificationAttempted)
        assertFalse(pending.notificationPosted)

        var cancellationCount = 0
        val cancelled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfOwned(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = 1_000L,
        ) {
            cancellationCount += 1
            true
        }
        assertFalse(cancelled)
        assertEquals(0, cancellationCount)
    }

    @Test fun naturalExpiryCanCancelItsExactVisibleOwnerWithoutDeletingCooldown() {
        val delivered = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 1_000L,
            identity = "planned-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, delivered))
        var cancellationCount = 0

        val cancelled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfOwned(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            expectedAtMillis = 1_000L,
        ) {
            cancellationCount += 1
            true
        }

        assertTrue(cancelled)
        assertEquals(1, cancellationCount)
        assertEquals(delivered, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun tombstoneCleanupWaitsWhileAReplacementAttemptMayBeVisible() {
        val attempted = ContextualPromptDeliveryLedger.attemptedState(
            state = ContextualPromptDeliveryLedger.reservedState(
                state = ContextualPromptDeliveryState(
                    pendingCancellationSlots =
                        setOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY),
                    pendingCancellationCutoffs =
                        mapOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY to 1_000L),
                ),
                owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
                nowMillis = 2_000L,
                identity = "sleep-b",
            ),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            expectedAtMillis = 2_000L,
            expectedIdentity = "sleep-b",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, attempted))
        var cancellationCount = 0

        val cancelled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(cancelled)
        assertEquals(0, cancellationCount)
        assertEquals(attempted, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun legacyTombstoneCannotCancelANewerAttemptedReplacement() {
        val attempted = ContextualPromptDeliveryLedger.attemptedState(
            state = ContextualPromptDeliveryLedger.reservedState(
                state = ContextualPromptDeliveryState(
                    pendingCancellationSlots =
                        setOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY),
                ),
                owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
                nowMillis = 2_000L,
                identity = "sleep-b",
            ),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            expectedAtMillis = 2_000L,
            expectedIdentity = "sleep-b",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, attempted))
        assertTrue(
            ContextualPromptDeliveryLedger.loadState(prefs)
                .pendingCancellationCutoffs.isEmpty(),
        )
        var cancellationCount = 0

        val cancelled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(cancelled)
        assertEquals(0, cancellationCount)
        assertEquals(attempted, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun legacyTombstoneWithoutAReplacementStillRetriesCleanup() {
        val legacy = ContextualPromptDeliveryState(
            pendingCancellationSlots =
                setOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY),
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, legacy))
        var cancellationCount = 0

        val cancelled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }

        assertTrue(cancelled)
        assertEquals(1, cancellationCount)
        assertEquals(
            ContextualPromptDeliveryState(),
            ContextualPromptDeliveryLedger.loadState(prefs),
        )
    }

    @Test fun failedPlatformCancellationKeepsTheDurableTombstone() {
        val delivered = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, delivered))

        val outcome = ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            onNotificationSlotOwnerRemoved = { false },
        )

        assertTrue(outcome.ownerRemoved)
        assertTrue(outcome.ownedNotificationSlot)
        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                ContextualPromptDeliveryLedger.loadState(prefs).pendingCancellationSlots,
        )
    }

    @Test fun forcedOptOutCancelsEvenWhenOwnerRemovalCannotCommit() {
        val delivered = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 2_000L,
            identity = "sleep-a",
        )
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, false),
        )
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, delivered))
        var cancellationCount = 0

        val result = ContextualPromptDeliveryLedger.forceCancelNotificationSlot(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(result.stateCommitted)
        assertTrue(result.notificationCancelled)
        assertEquals(1, cancellationCount)
        assertEquals(delivered, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun forcedOptOutRetainsRetryStateWhenPlatformCancellationFails() {
        val delivered = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, delivered))

        val result = ContextualPromptDeliveryLedger.forceCancelNotificationSlot(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
            cancel = { false },
        )

        assertTrue(result.stateCommitted)
        assertFalse(result.notificationCancelled)
        val state = ContextualPromptDeliveryLedger.loadState(prefs)
        assertFalse(
            state.deliveries.containsKey(ContextualPromptDeliveryOwner.PLANNED_WORKOUT),
        )
        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                state.pendingCancellationSlots,
        )
        assertEquals(
            2_000L,
            state.pendingCancellationCutoffs[
                ContextualPromptNotificationSlot.ADAPTIVE_DAY
            ],
        )
    }

    @Test fun retainedTombstoneCannotCancelANewerAttemptedReplacement() {
        val replacement = ContextualPromptDeliveryLedger.attemptedState(
            state = ContextualPromptDeliveryLedger.reservedState(
                state = ContextualPromptDeliveryState(
                    pendingCancellationSlots =
                        setOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY),
                    pendingCancellationCutoffs =
                        mapOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY to 1_000L),
                ),
                owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
                nowMillis = 3_000L,
                identity = "sleep-b",
            ),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            expectedAtMillis = 3_000L,
            expectedIdentity = "sleep-b",
        )
        val withStaleReservation = ContextualPromptDeliveryLedger.reservedState(
            state = replacement,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, withStaleReservation))
        var cancellationCount = 0

        val outcome = ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
        ) {
            cancellationCount += 1
            true
        }

        assertTrue(outcome.ownerRemoved)
        assertFalse(outcome.ownedNotificationSlot)
        assertEquals(0, cancellationCount)
        val state = ContextualPromptDeliveryLedger.loadState(prefs)
        assertTrue(
            state.pendingDeliveries.containsKey(ContextualPromptDeliveryOwner.ADAPTIVE_DAY),
        )
        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                state.pendingCancellationSlots,
        )
    }

    @Test fun durableUnownedCleanupMarkerSurvivesCancellationFailureAndRetries() {
        val prefs = FakeSharedPreferences()
        var cancellationCount = 0

        val first = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            false
        }
        assertFalse(first)
        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                ContextualPromptDeliveryLedger.loadState(prefs).pendingCancellationSlots,
        )

        val retried = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }
        assertTrue(retried)
        assertEquals(2, cancellationCount)
        assertFalse(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                ContextualPromptDeliveryLedger.loadState(prefs).pendingCancellationSlots,
        )
    }

    @Test fun unownedCleanupReportsAFailedFinalTombstoneCommit() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, false),
            applyFailedCommitsToMemory = true,
        )
        var cancellationCount = 0

        val handled = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(handled)
        assertEquals(1, cancellationCount)
    }

    @Test fun privateOrphanCutoffCancelsPastOlderOwnersWithoutDeletingTheirHistory() {
        val olderAdaptive = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 1_000L,
            identity = "sleep-a",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, olderAdaptive))
        var cancellationCount = 0

        val handled = ContextualPromptDeliveryLedger.cancelNotificationSlotThroughCutoff(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
            cutoffMillis = 2_000L,
        ) {
            cancellationCount += 1
            true
        }

        assertTrue(handled)
        assertEquals(1, cancellationCount)
        assertEquals(olderAdaptive, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun privateOrphanCutoffDefersToANewerSharedAttempt() {
        val newerAdaptive = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 3_000L,
            identity = "sleep-b",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, newerAdaptive))
        var cancellationCount = 0

        val handled = ContextualPromptDeliveryLedger.cancelNotificationSlotThroughCutoff(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
            cutoffMillis = 2_000L,
        ) {
            cancellationCount += 1
            true
        }

        assertTrue(handled)
        assertEquals(0, cancellationCount)
        assertEquals(newerAdaptive, ContextualPromptDeliveryLedger.loadState(prefs))
    }

    @Test fun privateOrphanCutoffHonorsANewerRetainedCancellationBoundary() {
        val retained = ContextualPromptDeliveryState(
            lastGlobalDeliveryMillis = 3_000L,
            deliveries = mapOf(
                ContextualPromptDeliveryOwner.ADAPTIVE_DAY to 3_000L,
            ),
            identities = mapOf(
                ContextualPromptDeliveryOwner.ADAPTIVE_DAY to "sleep-b",
            ),
            pendingCancellationSlots =
                setOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY),
            pendingCancellationCutoffs =
                mapOf(ContextualPromptNotificationSlot.ADAPTIVE_DAY to 4_000L),
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, retained))
        var cancellationCount = 0

        val handled = ContextualPromptDeliveryLedger.cancelNotificationSlotThroughCutoff(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
            cutoffMillis = 2_000L,
        ) {
            cancellationCount += 1
            true
        }

        assertTrue(handled)
        assertEquals(1, cancellationCount)
        val after = ContextualPromptDeliveryLedger.loadState(prefs)
        assertEquals(
            3_000L,
            after.deliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
        )
        assertFalse(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                after.pendingCancellationSlots,
        )
    }

    @Test fun privateOrphanCutoffKeepsItsTombstoneWhenFinalClearCannotCommit() {
        val prefs = FakeSharedPreferences(
            commitResults = listOf(true, false),
        )
        var cancellationCount = 0

        val handled = ContextualPromptDeliveryLedger.cancelNotificationSlotThroughCutoff(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
            cutoffMillis = 2_000L,
        ) {
            cancellationCount += 1
            true
        }

        assertFalse(handled)
        assertEquals(1, cancellationCount)
        assertTrue(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                ContextualPromptDeliveryLedger.loadState(prefs).pendingCancellationSlots,
        )
    }

    @Test fun tombstoneRetryIgnoresOlderDeliveryHistoryButDefersToNewerAttempts() {
        val olderAdaptive = ContextualPromptDeliveryLedger.recordedState(
            state = ContextualPromptDeliveryState(),
            owner = ContextualPromptDeliveryOwner.ADAPTIVE_DAY,
            nowMillis = 1_000L,
            identity = "sleep-a",
        )
        val newerWorkout = ContextualPromptDeliveryLedger.recordedState(
            state = olderAdaptive,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            nowMillis = 2_000L,
            identity = "planned-b",
        )
        val prefs = FakeSharedPreferences()
        assertTrue(ContextualPromptDeliveryLedger.saveState(prefs, newerWorkout))

        val failed = ContextualPromptDeliveryLedger.reconcileOwnerWithOutcome(
            prefs = prefs,
            owner = ContextualPromptDeliveryOwner.PLANNED_WORKOUT,
            onNotificationSlotOwnerRemoved = { false },
        )
        assertTrue(failed.ownerRemoved)
        val retained = ContextualPromptDeliveryLedger.loadState(prefs)
        assertEquals(
            2_000L,
            retained.pendingCancellationCutoffs[
                ContextualPromptNotificationSlot.ADAPTIVE_DAY
            ],
        )
        assertEquals(
            1_000L,
            retained.deliveries[ContextualPromptDeliveryOwner.ADAPTIVE_DAY],
        )

        var cancellationCount = 0
        val retried = ContextualPromptDeliveryLedger.cancelNotificationSlotIfUnowned(
            prefs = prefs,
            slot = ContextualPromptNotificationSlot.ADAPTIVE_DAY,
        ) {
            cancellationCount += 1
            true
        }
        assertTrue(retried)
        assertEquals(1, cancellationCount)
        assertFalse(
            ContextualPromptNotificationSlot.ADAPTIVE_DAY in
                ContextualPromptDeliveryLedger.loadState(prefs).pendingCancellationSlots,
        )
    }
}
