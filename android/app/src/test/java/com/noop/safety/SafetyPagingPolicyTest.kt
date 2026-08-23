package com.noop.safety

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

class SafetyPagingPolicyTest {
    @Test
    fun e164NormalizationAcceptsInternationalInputAndRejectsUnsafeValues() {
        assertEquals(
            "+14155550123",
            SafetyPagingController.normalizedE164("+1 (415) 555-0123"),
        )
        assertEquals(
            "+442079460958",
            SafetyPagingController.normalizedE164("0044 20 7946 0958"),
        )
        assertNull(SafetyPagingController.normalizedE164("4155550123"))
        assertNull(SafetyPagingController.normalizedE164("+0123456789"))
        assertNull(SafetyPagingController.normalizedE164("+1234567"))
        assertNull(SafetyPagingController.normalizedE164("+1234567890123456"))
    }

    @Test
    fun setupReminderRemainsRequiredUntilTwoAcceptances() {
        assertFalse(SafetyContactSetupReminderScheduler.needsReminder(false, 0))
        assertTrue(SafetyContactSetupReminderScheduler.needsReminder(true, 0))
        assertTrue(SafetyContactSetupReminderScheduler.needsReminder(true, 1))
        assertFalse(SafetyContactSetupReminderScheduler.needsReminder(true, 2))
        assertFalse(SafetyContactSetupReminderScheduler.needsReminder(true, 5))
    }

    @Test
    fun pageIdempotencyKeySurvivesAmbiguousOutcomes() {
        assertTrue(SafetyPagingController.shouldRetainPageIdempotencyKey(null))
        assertTrue(SafetyPagingController.shouldRetainPageIdempotencyKey(500))
        assertTrue(SafetyPagingController.shouldRetainPageIdempotencyKey(503))
        assertFalse(SafetyPagingController.shouldRetainPageIdempotencyKey(401))
        assertFalse(SafetyPagingController.shouldRetainPageIdempotencyKey(412))
    }

    @Test
    fun acknowledgedIncidentDecodesResponderAndRetryState() {
        val incident = decodeDispatch(
            JSONObject(
                """
                {
                  "dispatch_id": "11111111-1111-4111-8111-111111111111",
                  "status": "acknowledged",
                  "idempotent_replay": false,
                  "acknowledged_contact_display_name": "Alex",
                  "deliveries": [{
                    "delivery_id": "22222222-2222-4222-8222-222222222222",
                    "contact_display_name": "Alex",
                    "channel": "sms",
                    "status": "retry_wait",
                    "attempt_count": 2,
                    "max_attempts": 3
                  }],
                  "responses": [{
                    "contact_id": "33333333-3333-4333-8333-333333333333",
                    "contact_display_name": "Alex",
                    "decision": "responding",
                    "source": "voice_dtmf"
                  }],
                  "latest_location": {
                    "sequence": 3,
                    "latitude": 40.7131,
                    "longitude": -74.0057,
                    "horizontal_accuracy_meters": 12.0,
                    "captured_at": "2026-08-22T12:00:45Z",
                    "received_at": "2026-08-22T12:00:46Z"
                  }
                }
                """.trimIndent(),
            ),
        )

        assertEquals(SafetyIncidentStatus.ACKNOWLEDGED, incident.status)
        assertEquals("Alex", incident.acknowledgedContactDisplayName)
        assertEquals(SafetyDeliveryStatus.RETRY_WAIT, incident.deliveries.single().status)
        assertEquals(2, incident.deliveries.single().attemptCount)
        assertEquals(SafetyResponseDecision.RESPONDING, incident.responses.single().decision)
        assertEquals(3L, incident.latestLocation?.sequence)
        assertEquals(12.0, incident.latestLocation?.horizontalAccuracyMeters)
    }
}
