package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PostSyncRoutineNotificationBudgetTest {
    @Test
    fun firstEligibleRoutineLaneOwnsTheSync() {
        val budget = PostSyncRoutineNotificationBudget()

        assertNull(budget.claimedLane)
        assertFalse(budget.isClaimed)
        assertTrue(
            budget.claim(PostSyncRoutineNotificationBudget.Lane.AUTO_WORKOUT),
        )
        assertFalse(
            budget.claim(PostSyncRoutineNotificationBudget.Lane.ADAPTIVE_DAY),
        )
        assertEquals(
            PostSyncRoutineNotificationBudget.Lane.AUTO_WORKOUT,
            budget.claimedLane,
        )
    }

    @Test
    fun failedReservationCanReleaseSlotForNextLane() {
        val budget = PostSyncRoutineNotificationBudget()

        assertTrue(
            budget.reserve(PostSyncRoutineNotificationBudget.Lane.AUTO_WORKOUT),
        )
        assertFalse(budget.isClaimed)
        budget.release(PostSyncRoutineNotificationBudget.Lane.AUTO_WORKOUT)

        assertTrue(
            budget.reserve(PostSyncRoutineNotificationBudget.Lane.ADAPTIVE_DAY),
        )
        assertTrue(
            budget.commit(PostSyncRoutineNotificationBudget.Lane.ADAPTIVE_DAY),
        )
        assertTrue(budget.isClaimed)
        assertEquals(
            PostSyncRoutineNotificationBudget.Lane.ADAPTIVE_DAY,
            budget.claimedLane,
        )
    }

    @Test
    fun wrongLaneCannotCommitOrReleaseAnotherReservation() {
        val budget = PostSyncRoutineNotificationBudget()

        assertTrue(
            budget.reserve(PostSyncRoutineNotificationBudget.Lane.POST_WORKOUT_SUMMARY),
        )
        assertFalse(
            budget.commit(PostSyncRoutineNotificationBudget.Lane.MORNING_RECAP),
        )
        budget.release(PostSyncRoutineNotificationBudget.Lane.MORNING_RECAP)
        assertFalse(
            budget.reserve(PostSyncRoutineNotificationBudget.Lane.ADAPTIVE_DAY),
        )
        assertTrue(
            budget.commit(PostSyncRoutineNotificationBudget.Lane.POST_WORKOUT_SUMMARY),
        )
    }
}
