package com.noop.managed

import java.time.Instant
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedSafetyModelsTest {
    @Test
    fun invitationUrlCarriesOnlyOneValidCapability() {
        val capability = "noopsafety_" + "a".repeat(43)
        val expected = "noop://managed-safety/invite?capability=$capability"

        assertEquals(capability, ManagedSafetyIdentifier.inviteCapability(expected))
        assertEquals(expected, ManagedSafetyIdentifier.inviteUrl(capability))
        assertEquals(
            capability,
            ManagedSafetyIdentifier.inviteCapability(
                "noop://managed-safety/invite?capability=noopsafety%5F${"a".repeat(43)}",
            ),
        )
        listOf(
            "$expected&extra=1",
            "$expected#fragment",
            "noop://user@managed-safety/invite?capability=$capability",
            "noop://managed-safety:443/invite?capability=$capability",
            "noop://other/invite?capability=$capability",
            "noop://managed-safety/invite?capability=short",
            "noop://managed-safety/invite?capability=%",
        ).forEach {
            assertNull(ManagedSafetyIdentifier.inviteCapability(it))
        }
    }

    @Test
    fun generatedCapabilitiesAreValidAndDistinct() {
        val values = (0 until 32)
            .map { ManagedSafetyIdentifier.makeInviteCapability() }
            .toSet()

        assertEquals(32, values.size)
        assertTrue(values.all(ManagedSafetyIdentifier.invitePattern::matches))
    }

    @Test
    fun pushPayloadRequiresTheFixedContract() {
        val incidentId = UUID.randomUUID()
        val now = Instant.parse("2026-09-08T08:00:00Z")
        val values = mapOf(
            "kind" to "managed_safety_incident",
            "schema" to "1",
            "route" to "safety",
            "expires_at" to Instant.parse("2026-09-08T18:30:00Z").toString(),
            "incident_id" to incidentId.toString(),
        )

        assertEquals(
            incidentId,
            ManagedSafetyPushPayload.incidentId(values, now),
        )
        values.keys.forEach { key ->
            assertNull(
                "accepted payload without $key",
                ManagedSafetyPushPayload.incidentId(values - key, now),
            )
        }
        mapOf(
            "kind" to "other",
            "schema" to "2",
            "route" to "friends",
            "expires_at" to "not-a-date",
            "incident_id" to "not-a-uuid",
        ).forEach { (key, value) ->
            assertNull(
                "accepted invalid $key",
                ManagedSafetyPushPayload.incidentId(
                    values + (key to value),
                    now,
                ),
            )
        }
        listOf(
            "2026-09-08T07:59:59Z",
            "2026-09-08T08:00:00Z",
        ).forEach { expiry ->
            assertNull(
                "accepted expired payload at $expiry",
                ManagedSafetyPushPayload.incidentId(
                    values + ("expires_at" to expiry),
                    now,
                ),
            )
        }
    }

    @Test
    fun disconnectRequiresOneCompletedPushInvalidation() {
        assertTrue(
            ManagedPushRevocationPolicy.canFinalizeDisconnect(
                requiresRevocation = false,
                serverRevoked = false,
                providerTokenDeleted = false,
            ),
        )
        assertTrue(
            ManagedPushRevocationPolicy.canFinalizeDisconnect(
                requiresRevocation = true,
                serverRevoked = true,
                providerTokenDeleted = false,
            ),
        )
        assertTrue(
            ManagedPushRevocationPolicy.canFinalizeDisconnect(
                requiresRevocation = true,
                serverRevoked = false,
                providerTokenDeleted = true,
            ),
        )
        assertFalse(
            ManagedPushRevocationPolicy.canFinalizeDisconnect(
                requiresRevocation = true,
                serverRevoked = false,
                providerTokenDeleted = false,
            ),
        )
    }
}
