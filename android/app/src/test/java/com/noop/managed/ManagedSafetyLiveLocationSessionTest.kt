package com.noop.managed

import java.time.Instant
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedSafetyLiveLocationSessionTest {
    @Test
    fun activeOwnerIncidentRequiresOwnerSharingActiveStatusAndFutureExpiry() {
        val now = Instant.parse("2026-09-08T12:00:00Z")
        val active = incident(
            role = "owner",
            shareLocation = true,
            status = "acknowledged",
            expiresAt = "2026-09-08T20:00:00Z",
        )
        val values = listOf(
            incident(
                role = "contact",
                shareLocation = true,
                status = "open",
                expiresAt = "2026-09-08T20:00:00Z",
            ),
            incident(
                role = "owner",
                shareLocation = false,
                status = "open",
                expiresAt = "2026-09-08T20:00:00Z",
            ),
            incident(
                role = "owner",
                shareLocation = true,
                status = "resolved",
                expiresAt = "2026-09-08T20:00:00Z",
            ),
            incident(
                role = "owner",
                shareLocation = true,
                status = "open",
                expiresAt = "2026-09-08T11:59:59Z",
            ),
            active,
        )

        assertEquals(
            active.incidentId,
            ManagedSafetyLiveLocationSession.activeOwnerIncident(
                values,
                now,
            )?.incidentId,
        )
        assertNull(
            ManagedSafetyLiveLocationSession.activeOwnerIncident(
                values.dropLast(1),
                now,
            ),
        )
    }

    @Test
    fun remainingSessionIsBoundedAndNeverNegative() {
        assertEquals(
            ManagedSafetyLiveLocationSession.MAXIMUM_SESSION_SECONDS,
            ManagedSafetyLiveLocationSession.remainingSessionSeconds(
                expiresAtUnix = 100_000,
                nowUnix = 0,
            ),
        )
        assertEquals(
            30L,
            ManagedSafetyLiveLocationSession.remainingSessionSeconds(
                expiresAtUnix = 130,
                nowUnix = 100,
            ),
        )
        assertEquals(
            0L,
            ManagedSafetyLiveLocationSession.remainingSessionSeconds(
                expiresAtUnix = 90,
                nowUnix = 100,
            ),
        )
    }

    @Test
    fun locationRetryStopsAfterTwoBoundedRetries() {
        assertEquals(
            2_000L,
            ManagedSafetyLocationRetryPolicy.delayMillis(1),
        )
        assertEquals(
            5_000L,
            ManagedSafetyLocationRetryPolicy.delayMillis(2),
        )
        assertNull(ManagedSafetyLocationRetryPolicy.delayMillis(3))
    }

    @Test
    fun permissionRevocationStopsAndExplicitRegrantRestartsOnlyActiveIncident() {
        assertEquals(
            ManagedSafetyLocationRuntimeAction.STOP,
            ManagedSafetyLocationRuntimePolicy.decide(
                locationAuthorized = false,
                enrolled = true,
                activeCloudIncident = true,
                activeLocalSession = true,
            ),
        )
        assertEquals(
            ManagedSafetyLocationRuntimeAction.NONE,
            ManagedSafetyLocationRuntimePolicy.decide(
                locationAuthorized = false,
                enrolled = true,
                activeCloudIncident = true,
                activeLocalSession = false,
            ),
        )
        assertEquals(
            ManagedSafetyLocationRuntimeAction.START,
            ManagedSafetyLocationRuntimePolicy.decide(
                locationAuthorized = true,
                enrolled = true,
                activeCloudIncident = true,
                activeLocalSession = false,
            ),
        )
        assertEquals(
            ManagedSafetyLocationRuntimeAction.NONE,
            ManagedSafetyLocationRuntimePolicy.decide(
                locationAuthorized = true,
                enrolled = false,
                activeCloudIncident = true,
                activeLocalSession = false,
            ),
        )
        assertEquals(
            ManagedSafetyLocationRuntimeAction.NONE,
            ManagedSafetyLocationRuntimePolicy.decide(
                locationAuthorized = true,
                enrolled = true,
                activeCloudIncident = false,
                activeLocalSession = false,
            ),
        )
    }

    @Test
    fun authorizationWatchdogStopsOnlyAnActiveUnauthorizedSession() {
        assertEquals(5_000L, ManagedSafetyLocationAuthorizationWatchdog.INTERVAL_MILLIS)
        assertTrue(
            ManagedSafetyLocationAuthorizationWatchdog.shouldStop(
                locationAuthorized = false,
                activeLocalSession = true,
            ),
        )
        assertFalse(
            ManagedSafetyLocationAuthorizationWatchdog.shouldStop(
                locationAuthorized = true,
                activeLocalSession = true,
            ),
        )
        assertFalse(
            ManagedSafetyLocationAuthorizationWatchdog.shouldStop(
                locationAuthorized = false,
                activeLocalSession = false,
            ),
        )
    }

    private fun incident(
        role: String,
        shareLocation: Boolean,
        status: String,
        expiresAt: String,
    ) = ManagedSafetyIncident(
        incidentId = UUID.randomUUID(),
        role = role,
        ownerProfileId = UUID.randomUUID(),
        ownerDisplayName = "Test owner",
        trigger = "manual",
        status = status,
        durationHours = 8,
        shareLocation = shareLocation,
        createdAt = "2026-09-08T10:00:00Z",
        expiresAt = expiresAt,
        acknowledgedAt = null,
        endedAt = null,
        participants = emptyList(),
        location = null,
        delivery = null,
    )
}
