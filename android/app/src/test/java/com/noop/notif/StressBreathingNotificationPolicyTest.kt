package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StressBreathingNotificationPolicyTest {
    private val now = 1_800_000_000_000L

    @Test
    fun freshUniqueEvidence_deliversAndCommitsRestartSafeState() {
        val decision = evaluate(
            observedAtMillis = now - 30_000L,
            fingerprint = "window-1",
        )

        assertTrue(decision.shouldDeliver)
        assertEquals(StressBreathingNotificationReason.DELIVER, decision.reason)
        assertEquals(now, decision.nextState.lastDeliveryMillis)
        assertEquals("window-1", decision.nextState.fingerprint)
    }

    @Test
    fun staleOrTooFutureEvidence_isRejectedWithoutConsumingIt() {
        val prior = StressBreathingNotificationState(now - 10_000L, "prior")

        for (observedAt in listOf(
            now - StressBreathingNotificationPolicy.MAXIMUM_AGE_MILLIS - 1L,
            now + StressBreathingNotificationPolicy.FUTURE_TOLERANCE_MILLIS + 1L,
        )) {
            val decision = evaluate(observedAt, "new", prior)
            assertFalse(decision.shouldDeliver)
            assertEquals(StressBreathingNotificationReason.STALE, decision.reason)
            assertEquals(prior, decision.nextState)
        }
    }

    @Test
    fun duplicateAndCooldown_areRestartSafe() {
        val prior = StressBreathingNotificationState(
            lastDeliveryMillis = now - 60_000L,
            fingerprint = "window-1",
        )
        val duplicate = evaluate(now, "window-1", prior)
        assertEquals(StressBreathingNotificationReason.DUPLICATE, duplicate.reason)
        assertEquals(prior, duplicate.nextState)

        val cooldown = evaluate(now, "window-2", prior)
        assertEquals(StressBreathingNotificationReason.COOLDOWN, cooldown.reason)
        assertEquals(prior, cooldown.nextState)

        val elapsed = evaluate(
            observedAtMillis = now,
            fingerprint = "window-2",
            state = prior.copy(
                lastDeliveryMillis = now - StressBreathingNotificationPolicy.COOLDOWN_MILLIS,
            ),
        )
        assertTrue(elapsed.shouldDeliver)
    }

    @Test
    fun crossMidnightQuietHours_suppressOnlyInsideWindow() {
        val atNight = evaluate(now, "night", localMinuteOfDay = 23 * 60)
        assertEquals(StressBreathingNotificationReason.QUIET_HOURS, atNight.reason)

        val beforeEnd = evaluate(now, "morning", localMinuteOfDay = 6 * 60 + 59)
        assertEquals(StressBreathingNotificationReason.QUIET_HOURS, beforeEnd.reason)

        val atEnd = evaluate(now, "day", localMinuteOfDay = 7 * 60)
        assertTrue(atEnd.shouldDeliver)
    }

    private fun evaluate(
        observedAtMillis: Long,
        fingerprint: String,
        state: StressBreathingNotificationState = StressBreathingNotificationState(),
        localMinuteOfDay: Int = 12 * 60,
    ): StressBreathingNotificationDecision = StressBreathingNotificationPolicy.evaluate(
        observedAtMillis = observedAtMillis,
        fingerprint = fingerprint,
        state = state,
        nowMillis = now,
        localMinuteOfDay = localMinuteOfDay,
        quietHoursEnabled = true,
        quietStartMinutes = 22 * 60,
        quietEndMinutes = 7 * 60,
    )
}
