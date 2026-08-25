package com.noop.safety

import androidx.work.BackoffPolicy
import com.noop.R
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
        assertTrue(SafetyPagingController.isStrictE164("+14155550123"))
        assertFalse(SafetyPagingController.isStrictE164("+1 (415) 555-0123"))
        assertFalse(SafetyPagingController.isStrictE164("+١٤١٥٥٥٥٠١٢٣"))
        assertFalse(SafetyPagingController.isStrictE164("+１２３４５６７８９"))
        assertNull(SafetyPagingController.normalizedE164("+١٤١٥٥٥٥٠١٢٣"))
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
                  },
                  "contact_summary": {
                    "targeted": 3,
                    "reached": 1,
                    "pending": 1,
                    "failed": 1,
                    "last_reached_at": "2026-08-22T12:01:00Z",
                    "all_contacts_failed": false
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
        assertEquals(3, incident.contactSummary?.targeted)
        assertEquals(1, incident.contactSummary?.reached)
        assertEquals(1, incident.contactSummary?.pending)
        assertEquals(1, incident.contactSummary?.failed)
        assertEquals("2026-08-22T12:01:00Z", incident.contactSummary?.lastReachedAt)
        assertFalse(requireNotNull(incident.contactSummary).allContactsFailed)
    }

    @Test
    fun contactSummaryIsOptionalAndFailedRemainsTerminalServerState() {
        val legacy = decodeDispatch(
            JSONObject(
                """
                {
                  "dispatch_id": "11111111-1111-4111-8111-111111111111",
                  "status": "open"
                }
                """.trimIndent(),
            ),
        )
        assertNull(legacy.contactSummary)

        val failed = decodeDispatch(
            JSONObject(
                """
                {
                  "dispatch_id": "22222222-2222-4222-8222-222222222222",
                  "status": "failed",
                  "contact_summary": {
                    "targeted": 2,
                    "reached": 0,
                    "pending": 0,
                    "failed": 2,
                    "last_reached_at": null,
                    "all_contacts_failed": true
                  }
                }
                """.trimIndent(),
            ),
        )
        assertEquals(SafetyIncidentStatus.FAILED, failed.status)
        assertTrue(requireNotNull(failed.contactSummary).allContactsFailed)
        assertNull(failed.contactSummary?.lastReachedAt)
        assertTrue(shouldShowAllContactsFailed(failed.status, failed.contactSummary))
        assertTrue(shouldShowAllContactsFailed(SafetyIncidentStatus.FAILED, null))
        assertFalse(shouldShowAllContactsFailed(SafetyIncidentStatus.OPEN, null))
    }

    @Test
    fun pagingEnabledDecodesAsBackwardCompatibleTriState() {
        val missing = decodeSafetyPagingSnapshot(
            JSONObject("""{"contacts":[],"paging_configured":true}"""),
        )
        val enabled = decodeSafetyPagingSnapshot(
            JSONObject(
                """{"contacts":[],"paging_configured":true,"paging_enabled":true}""",
            ),
        )
        val disabled = decodeSafetyPagingSnapshot(
            JSONObject(
                """{"contacts":[],"paging_configured":true,"paging_enabled":false}""",
            ),
        )

        assertNull(missing.pagingEnabled)
        assertTrue(enabled.pagingEnabled == true)
        assertTrue(disabled.pagingEnabled == false)
        assertTrue(missing.pagingConfigured)
    }

    @Test
    fun malformedContactSummaryFallsBackToLegacyDeliveryRows() {
        val missingFields = decodeDispatch(
            JSONObject(
                """
                {
                  "dispatch_id": "11111111-1111-4111-8111-111111111111",
                  "status": "open",
                  "contact_summary": {"targeted": 2, "reached": 1}
                }
                """.trimIndent(),
            ),
        )
        val inconsistent = decodeDispatch(
            JSONObject(
                """
                {
                  "dispatch_id": "22222222-2222-4222-8222-222222222222",
                  "status": "open",
                  "contact_summary": {
                    "targeted": 2,
                    "reached": 1,
                    "pending": 1,
                    "failed": 1,
                    "all_contacts_failed": false
                  }
                }
                """.trimIndent(),
            ),
        )
        val wrongTypes = decodeDispatch(
            JSONObject(
                """
                {
                  "dispatch_id": "33333333-3333-4333-8333-333333333333",
                  "status": "open",
                  "contact_summary": {
                    "targeted": "2",
                    "reached": 0,
                    "pending": 0,
                    "failed": 2,
                    "last_reached_at": 123,
                    "all_contacts_failed": "true"
                  }
                }
                """.trimIndent(),
            ),
        )

        assertNull(missingFields.contactSummary)
        assertNull(inconsistent.contactSummary)
        assertNull(wrongTypes.contactSummary)
    }

    @Test
    fun readinessRequiresContactsProviderAndEnabledPaging() {
        fun snapshot(
            accepted: Int = 2,
            configured: Boolean = true,
            enabled: Boolean? = true,
        ) = SafetyPagingSnapshot(
            contacts = emptyList(),
            acceptedCount = accepted,
            maximumContacts = 5,
            pagingConfigured = configured,
            pagingEnabled = enabled,
        )

        assertTrue(SafetyPagingController.isReadySnapshot(snapshot()))
        assertTrue(SafetyPagingController.isReadySnapshot(snapshot(enabled = null)))
        assertFalse(SafetyPagingController.isReadySnapshot(snapshot(accepted = 1)))
        assertFalse(SafetyPagingController.isReadySnapshot(snapshot(configured = false)))
        assertFalse(SafetyPagingController.isReadySnapshot(snapshot(enabled = false)))
        assertEquals(
            "Safety paging is ready.",
            SafetyPagingController.readinessStatusMessage(snapshot(enabled = true)),
        )
        assertEquals(
            "",
            SafetyPagingController.readinessStatusMessage(snapshot(enabled = false)),
        )
    }

    @Test
    fun backgroundMonitorContinuesOnlyForLivePagesAndNotifiesMaterialOutcomes() {
        assertTrue(SafetyIncidentStatusMonitor.isActive(SafetyIncidentStatus.OPEN))
        assertTrue(SafetyIncidentStatusMonitor.isActive(SafetyIncidentStatus.PENDING))
        assertTrue(SafetyIncidentStatusMonitor.isActive(SafetyIncidentStatus.ACKNOWLEDGED))
        assertFalse(SafetyIncidentStatusMonitor.isActive(SafetyIncidentStatus.FAILED))
        assertFalse(SafetyIncidentStatusMonitor.isActive(SafetyIncidentStatus.EXPIRED))
        assertEquals(
            SafetyIncidentStatus.ACKNOWLEDGED,
            SafetyIncidentStatusMonitor.notificationStatus(
                SafetyIncidentStatus.ACKNOWLEDGED,
            ),
        )
        assertEquals(
            SafetyIncidentStatus.FAILED,
            SafetyIncidentStatusMonitor.notificationStatus(SafetyIncidentStatus.FAILED),
        )
        assertNull(
            SafetyIncidentStatusMonitor.notificationStatus(SafetyIncidentStatus.OPEN),
        )
        assertEquals(
            SafetyIncidentPollResult.RETRY,
            SafetyIncidentStatusMonitor.pollResultAfterObservation(
                status = SafetyIncidentStatus.FAILED,
                locallyExpired = false,
                notificationReconciled = false,
            ),
        )
        assertEquals(
            SafetyIncidentPollResult.TERMINAL,
            SafetyIncidentStatusMonitor.pollResultAfterObservation(
                status = SafetyIncidentStatus.FAILED,
                locallyExpired = false,
                notificationReconciled = true,
            ),
        )
        assertEquals(
            SafetyIncidentPollResult.TERMINAL,
            SafetyIncidentStatusMonitor.pollResultAfterObservation(
                status = SafetyIncidentStatus.OPEN,
                locallyExpired = true,
                notificationReconciled = true,
            ),
        )
        assertEquals(
            SafetyIncidentPollResult.RETRY,
            SafetyIncidentStatusMonitor.pollResultAfterObservation(
                status = SafetyIncidentStatus.FAILED,
                locallyExpired = true,
                notificationReconciled = false,
            ),
        )
    }

    @Test
    fun terminalNotificationMarkerAdvancesOnlyAfterSuccessfulPost() {
        val previous = SafetyIncidentNotificationMarker("old", "ACKNOWLEDGED")
        val candidate = SafetyIncidentNotificationMarker("new", "FAILED")

        assertEquals(
            previous,
            safetyNotificationMarkerAfterAttempt(
                previous = previous,
                candidate = candidate,
                postedSuccessfully = false,
            ),
        )
        assertEquals(
            candidate,
            safetyNotificationMarkerAfterAttempt(
                previous = previous,
                candidate = candidate,
                postedSuccessfully = true,
            ),
        )
    }

    @Test
    fun incidentMonitorIsPrivacyBoundedAndUsesLinearBestEffortRetry() {
        val now = 1_700_000_000L
        assertEquals(
            now + SafetyIncidentStatusMonitor.MAXIMUM_MONITOR_SECONDS,
            SafetyIncidentStatusMonitor.boundedExpiryUnix(null, now),
        )
        assertEquals(
            now + SafetyIncidentStatusMonitor.MAXIMUM_MONITOR_SECONDS,
            SafetyIncidentStatusMonitor.boundedExpiryUnix(now + 7_200L, now),
        )
        assertEquals(
            now + 300L,
            SafetyIncidentStatusMonitor.boundedExpiryUnix(now + 300L, now),
        )
        assertEquals(
            now,
            SafetyIncidentStatusMonitor.boundedExpiryUnix(now - 1L, now),
        )
        assertEquals(
            SafetyIncidentStatusMonitor.ACTIVE_POLL_DELAY_MILLIS,
            SafetyIncidentStatusMonitor.nextPollDelayMillis(
                SafetyIncidentPollResult.ACTIVE,
            ),
        )
        assertEquals(
            SafetyIncidentStatusMonitor.RETRY_POLL_DELAY_MILLIS,
            SafetyIncidentStatusMonitor.nextPollDelayMillis(
                SafetyIncidentPollResult.RETRY,
            ),
        )
        assertNull(
            SafetyIncidentStatusMonitor.nextPollDelayMillis(
                SafetyIncidentPollResult.TERMINAL,
            ),
        )
        assertEquals(BackoffPolicy.LINEAR, SafetyIncidentStatusMonitor.workBackoffPolicy)
    }

    @Test
    fun gestureOutcomeNotificationsUseLocalizedHonestResources() {
        assertEquals(
            R.string.safety_page_status_submitted to
                R.string.safety_page_detail_submitted,
            SafetyStatusNotifications.outcomeResources(
                SafetySosDispatcher.Outcome.Opened,
            ),
        )
        assertEquals(
            R.string.safety_page_status_open to
                R.string.safety_page_detail_waiting,
            SafetyStatusNotifications.outcomeResources(
                SafetySosDispatcher.Outcome.AlreadyActive,
            ),
        )
        assertEquals(
            R.string.safety_page_status_failed to
                R.string.safety_delivery_unavailable,
            SafetyStatusNotifications.outcomeResources(
                SafetySosDispatcher.Outcome.Unavailable("offline"),
            ),
        )
    }
}
