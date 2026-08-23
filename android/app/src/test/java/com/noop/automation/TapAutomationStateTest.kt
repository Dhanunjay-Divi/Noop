package com.noop.automation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TapAutomationStateTest {
    private val now = 1_800_000_000_000L

    @Test fun alarmDisplacesHydrationAndHydrationCannotDisplaceAlarm() {
        val state = PendingTapAutomationState()
        val water = PendingTapAutomation.create(
            kind = TapAutomationKind.HYDRATION_CONFIRM,
            value = 250,
            nowMs = now,
            windowMinutes = 10,
            token = "water",
        )
        val alarm = PendingTapAutomation.create(
            kind = TapAutomationKind.ALARM_DISMISS,
            nowMs = now,
            windowMinutes = 15,
            token = "alarm",
        )

        assertTrue(state.arm(water, now))
        assertTrue(state.arm(alarm, now))
        assertFalse(state.arm(water, now))
        assertEquals("alarm", state.consume(now)?.token)
    }

    @Test fun consumedActionIsExactlyOnce() {
        val state = PendingTapAutomationState()
        state.arm(
            PendingTapAutomation.create(
                kind = TapAutomationKind.HYDRATION_CONFIRM,
                value = 300,
                nowMs = now,
                windowMinutes = 5,
                token = "one",
            ),
            now,
        )

        assertEquals(300, state.consume(now)?.value)
        assertNull(state.consume(now))
    }

    @Test fun expiredAndFutureTokensCannotBeConsumed() {
        val action = PendingTapAutomation.create(
            kind = TapAutomationKind.HYDRATION_CONFIRM,
            nowMs = now,
            windowMinutes = 5,
            token = "window",
        )
        assertNull(PendingTapAutomationState(action).consume(now + 5 * 60_000L))
        assertNull(PendingTapAutomationState(action).consume(now - 1L))
    }

    @Test fun actionWindowIsClamped() {
        val short = PendingTapAutomation.create(
            kind = TapAutomationKind.REMINDER_ACKNOWLEDGE,
            nowMs = now,
            windowMinutes = 0,
        )
        val long = PendingTapAutomation.create(
            kind = TapAutomationKind.REMINDER_ACKNOWLEDGE,
            nowMs = now,
            windowMinutes = 99,
        )
        assertEquals(60_000L, short.expiresAtMs - now)
        assertEquals(30 * 60_000L, long.expiresAtMs - now)
    }

    @Test fun occurrenceIdentityIsPreserved() {
        val state = PendingTapAutomationState()
        state.arm(
            PendingTapAutomation.create(
                kind = TapAutomationKind.HYDRATION_CONFIRM,
                value = 250,
                contextKey = "10:480",
                nowMs = now,
                windowMinutes = 10,
            ),
            now,
        )

        assertEquals("10:480", state.consume(now)?.contextKey)
    }

    @Test fun clearingHydrationDoesNotClearHigherPriorityAlarm() {
        val state = PendingTapAutomationState(
            PendingTapAutomation.create(
                kind = TapAutomationKind.ALARM_DISMISS,
                nowMs = now,
                windowMinutes = 15,
            ),
        )

        state.clear(TapAutomationKind.HYDRATION_CONFIRM)

        assertEquals(TapAutomationKind.ALARM_DISMISS, state.consume(now)?.kind)
    }

    @Test fun snoozeDismissesOnlyAfterReplacementIsScheduled() {
        val calls = mutableListOf<String>()

        val scheduled = TapAutomationRuntime.scheduleSnoozeBeforeDismiss(
            minutes = 10,
            schedule = {
                calls += "schedule:$it"
                true
            },
            dismiss = { calls += "dismiss" },
        )

        assertTrue(scheduled)
        assertEquals(listOf("schedule:10", "dismiss"), calls)
    }

    @Test fun failedSnoozeLeavesCurrentAlarmActive() {
        var dismissed = false

        val scheduled = TapAutomationRuntime.scheduleSnoozeBeforeDismiss(
            minutes = 10,
            schedule = { false },
            dismiss = { dismissed = true },
        )

        assertFalse(scheduled)
        assertFalse(dismissed)
    }

    @Test fun throwingSnoozeSchedulerLeavesCurrentAlarmActive() {
        var dismissed = false

        try {
            TapAutomationRuntime.scheduleSnoozeBeforeDismiss(
                minutes = 10,
                schedule = { error("scheduler failed") },
                dismiss = { dismissed = true },
            )
            throw AssertionError("Expected scheduler failure")
        } catch (_: IllegalStateException) {
            // Expected.
        }

        assertFalse(dismissed)
    }
}
