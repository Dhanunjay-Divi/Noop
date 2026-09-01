package com.noop.notif

import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyReviewReminderPolicyTest {
    private val zone = ZoneId.of("America/New_York")

    @Test
    fun nextRun_usesTodayWhenFutureAndTomorrowWhenPast() {
        val morning = ZonedDateTime.of(2026, 8, 31, 7, 30, 0, 0, zone)
        assertEquals(
            ZonedDateTime.of(2026, 8, 31, 8, 0, 0, 0, zone),
            DailyReviewReminderPolicy.nextRun(morning, 8 * 60),
        )

        val evening = ZonedDateTime.of(2026, 8, 31, 20, 0, 0, 0, zone)
        assertEquals(
            ZonedDateTime.of(2026, 9, 1, 19, 0, 0, 0, zone),
            DailyReviewReminderPolicy.nextRun(evening, 19 * 60),
        )
    }

    @Test
    fun nextRun_keepsTodayDuringFinalSecondBeforeReminder() {
        val justBefore = ZonedDateTime.of(2026, 8, 31, 7, 59, 59, 500_000_000, zone)

        assertEquals(
            ZonedDateTime.of(2026, 8, 31, 8, 0, 0, 0, zone),
            DailyReviewReminderPolicy.nextRun(justBefore, 8 * 60),
        )
    }

    @Test
    fun deliveryGate_rejectsEarlyExecution() {
        val scheduled = ZonedDateTime.of(2026, 8, 31, 19, 0, 0, 0, zone)
        assertFalse(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.minusSeconds(1),
            ),
        )
    }

    @Test
    fun deliveryGate_rejectsWrongDayAndExcessiveDelay() {
        val scheduled = ZonedDateTime.of(2026, 8, 31, 19, 0, 0, 0, zone)
        assertTrue(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.plusMinutes(DailyReviewReminderPolicy.DELIVERY_GRACE_MINUTES),
            ),
        )
        assertFalse(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.plusMinutes(DailyReviewReminderPolicy.DELIVERY_GRACE_MINUTES + 1),
            ),
        )
        assertFalse(
            DailyReviewReminderPolicy.shouldDeliver(
                scheduled,
                scheduled.plusDays(1),
            ),
        )
    }

    @Test
    fun completedJournal_suppressesOnlyEveningPrompt() {
        assertFalse(
            DailyReviewReminderPolicy.shouldPost(
                DailyReviewKind.EVENING,
                scheduleIsFresh = true,
                journalCompleted = true,
            ),
        )
        assertTrue(
            DailyReviewReminderPolicy.shouldPost(
                DailyReviewKind.MORNING,
                scheduleIsFresh = true,
                journalCompleted = true,
            ),
        )
    }
}
