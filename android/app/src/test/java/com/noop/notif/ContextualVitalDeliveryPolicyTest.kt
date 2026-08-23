package com.noop.notif

import com.noop.analytics.ContextualVitalPolicy
import java.time.ZoneOffset
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContextualVitalDeliveryPolicyTest {
    private val now = ZonedDateTime.of(2026, 8, 22, 12, 0, 0, 0, ZoneOffset.UTC)

    private fun candidate(
        kind: ContextualVitalPolicy.Kind = ContextualVitalPolicy.Kind.OXYGEN_TREND,
        day: String = "2026-08-22",
        fingerprint: String = "first",
    ) = ContextualVitalPolicy.Candidate(kind, day, 3, fingerprint)

    @Test
    fun gateRejectsDuplicateTopicCooldownGlobalCooldownAndStaleData() {
        val delivered = ContextualVitalDeliveryPolicy.evaluate(
            candidate(),
            ContextualVitalDeliveryState(),
            now,
            quietHoursEnabled = false,
            quietStartMinutes = 22 * 60,
            quietEndMinutes = 7 * 60,
        )
        assertTrue(delivered.shouldDeliver)

        val duplicate = ContextualVitalDeliveryPolicy.evaluate(
            candidate(),
            delivered.nextState,
            now.plusMinutes(31),
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(ContextualVitalDecisionReason.DUPLICATE, duplicate.reason)

        val topicCooldown = ContextualVitalDeliveryPolicy.evaluate(
            candidate(fingerprint = "second"),
            delivered.nextState,
            now.plusMinutes(31),
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(ContextualVitalDecisionReason.TOPIC_COOLDOWN, topicCooldown.reason)

        val globalCooldown = ContextualVitalDeliveryPolicy.evaluate(
            candidate(
                kind = ContextualVitalPolicy.Kind.BODY_TEMPERATURE_REVIEW,
                fingerprint = "temperature",
            ),
            delivered.nextState,
            now.plusMinutes(10),
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(ContextualVitalDecisionReason.GLOBAL_COOLDOWN, globalCooldown.reason)

        val stale = ContextualVitalDeliveryPolicy.evaluate(
            candidate(day = "2026-08-18"),
            ContextualVitalDeliveryState(),
            now,
            false,
            22 * 60,
            7 * 60,
        )
        assertEquals(ContextualVitalDecisionReason.STALE, stale.reason)
    }

    @Test
    fun gateRespectsWraparoundQuietHours() {
        val atNight = now.withHour(23)
        val quiet = ContextualVitalDeliveryPolicy.evaluate(
            candidate(),
            ContextualVitalDeliveryState(),
            atNight,
            quietHoursEnabled = true,
            quietStartMinutes = 22 * 60,
            quietEndMinutes = 7 * 60,
        )
        assertFalse(quiet.shouldDeliver)
        assertEquals(ContextualVitalDecisionReason.QUIET_HOURS, quiet.reason)
        assertTrue(ContextualVitalDeliveryPolicy.windowContains(23 * 60, 22 * 60, 7 * 60))
        assertFalse(ContextualVitalDeliveryPolicy.windowContains(12 * 60, 22 * 60, 7 * 60))
    }
}
