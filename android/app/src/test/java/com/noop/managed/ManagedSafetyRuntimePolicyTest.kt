package com.noop.managed

import com.noop.ui.shouldDisableBandSosPreference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ManagedSafetyRuntimePolicyTest {
    @Test
    fun bandSosPreferenceWaitsForAConfirmedContactSnapshotBeforeDisabling() {
        val acceptedContact = ManagedSafetyContact(
            profileId = UUID.fromString("00000000-0000-0000-0000-000000000111"),
            displayName = "Contact",
            role = "contact",
            acceptedAt = "2026-09-12T00:00:00Z",
        )

        assertFalse(
            shouldDisableBandSosPreference(
                enabled = true,
                phase = ManagedCloudPhase.SIGNED_OUT,
                contacts = null,
            ),
        )
        assertFalse(
            shouldDisableBandSosPreference(
                enabled = true,
                phase = ManagedCloudPhase.ENROLLED,
                contacts = null,
            ),
        )
        assertTrue(
            shouldDisableBandSosPreference(
                enabled = true,
                phase = ManagedCloudPhase.ENROLLED,
                contacts = ManagedSafetyContacts(
                    contacts = emptyList(),
                    minimumRequired = 1,
                    maximumAllowed = 5,
                ),
            ),
        )
        assertFalse(
            shouldDisableBandSosPreference(
                enabled = true,
                phase = ManagedCloudPhase.ENROLLED,
                contacts = ManagedSafetyContacts(
                    contacts = listOf(acceptedContact),
                    minimumRequired = 1,
                    maximumAllowed = 5,
                ),
            ),
        )
    }

    @Test
    fun locationSharingRequiresForegroundAndBackgroundAuthorization() {
        assertTrue(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = false,
                sdkInt = 35,
                foregroundGranted = false,
                backgroundGranted = false,
            ),
        )
        assertFalse(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = true,
                sdkInt = 35,
                foregroundGranted = false,
                backgroundGranted = true,
            ),
        )
        assertFalse(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = true,
                sdkInt = 35,
                foregroundGranted = true,
                backgroundGranted = false,
            ),
        )
        assertTrue(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = true,
                sdkInt = 35,
                foregroundGranted = true,
                backgroundGranted = true,
            ),
        )
        assertTrue(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = true,
                sdkInt = 28,
                foregroundGranted = true,
                backgroundGranted = false,
            ),
        )
    }

    @Test
    fun notificationRegistrationRequiresUsableAppAndChannelDelivery() {
        assertTrue(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 25,
                permissionGranted = false,
                appNotificationsEnabled = true,
                channelImportance = null,
            ),
        )
        assertFalse(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 33,
                permissionGranted = false,
                appNotificationsEnabled = true,
                channelImportance = 4,
            ),
        )
        assertFalse(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 32,
                permissionGranted = true,
                appNotificationsEnabled = false,
                channelImportance = 4,
            ),
        )
        assertFalse(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 32,
                permissionGranted = true,
                appNotificationsEnabled = true,
                channelImportance = 0,
            ),
        )
        assertFalse(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 32,
                permissionGranted = true,
                appNotificationsEnabled = true,
                channelImportance = null,
            ),
        )
        assertTrue(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 35,
                permissionGranted = true,
                appNotificationsEnabled = true,
                channelImportance = 4,
            ),
        )
    }

    @Test
    fun incidentRequestReplaysOnlyForTheSameAccountAndOptions() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000201")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000202")
        val firstScope = "a".repeat(64)
        val secondScope = "b".repeat(64)
        val created = ManagedSafetyIncidentRequestPolicy.resolve(
            existing = null,
            accountScopeHash = firstScope,
            trigger = "manual_sos",
            durationHours = 8,
            shareLocation = true,
            createRequestId = { firstId },
        )

        assertEquals(
            created,
            ManagedSafetyIncidentRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                trigger = "manual_sos",
                durationHours = 8,
                shareLocation = true,
                createRequestId = { secondId },
            ),
        )
        assertThrows(ManagedStorageException.Conflict::class.java) {
            ManagedSafetyIncidentRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                trigger = "manual_sos",
                durationHours = 12,
                shareLocation = true,
                createRequestId = { secondId },
            )
        }
        assertThrows(ManagedStorageException.Conflict::class.java) {
            ManagedSafetyIncidentRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                trigger = "band_sos",
                durationHours = 8,
                shareLocation = true,
                createRequestId = { secondId },
            )
        }
        val otherAccount = ManagedSafetyIncidentRequestPolicy.resolve(
            existing = created,
            accountScopeHash = secondScope,
            trigger = "band_sos",
            durationHours = 8,
            shareLocation = true,
            createRequestId = { secondId },
        )
        assertNotEquals(created.requestId, otherAccount.requestId)
        assertEquals(secondScope, otherAccount.accountScopeHash)
        assertEquals("band_sos", otherAccount.trigger)
    }

    @Test
    fun incidentRequestRetiresOnlyForTerminalFailures() {
        assertTrue(
            ManagedSafetyIncidentRequestPolicy.shouldRetire(
                ManagedStorageException.Forbidden(),
            ),
        )
        assertTrue(
            ManagedSafetyIncidentRequestPolicy.shouldRetire(
                ManagedStorageException.Server(422),
            ),
        )
        assertFalse(
            ManagedSafetyIncidentRequestPolicy.shouldRetire(
                ManagedStorageException.Server(408),
            ),
        )
        assertFalse(
            ManagedSafetyIncidentRequestPolicy.shouldRetire(
                ManagedStorageException.Server(429),
            ),
        )
        assertFalse(
            ManagedSafetyIncidentRequestPolicy.shouldRetire(
                ManagedStorageException.Server(503),
            ),
        )
        assertFalse(
            ManagedSafetyIncidentRequestPolicy.shouldRetire(
                ManagedStorageException.Network(),
            ),
        )
    }

    @Test
    fun contactRequestReplaysOnlyForTheSameAccountAndTarget() {
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000301")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000302")
        val firstScope = "a".repeat(64)
        val secondScope = "b".repeat(64)
        val firstTarget = "c".repeat(64)
        val secondTarget = "d".repeat(64)
        val created = ManagedSafetyContactRequestPolicy.resolve(
            existing = null,
            accountScopeHash = firstScope,
            targetScopeHash = firstTarget,
            createRequestId = { firstId },
        )

        assertEquals(
            created,
            ManagedSafetyContactRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                targetScopeHash = firstTarget,
                createRequestId = { secondId },
            ),
        )
        assertThrows(ManagedStorageException.Conflict::class.java) {
            ManagedSafetyContactRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                targetScopeHash = secondTarget,
                createRequestId = { secondId },
            )
        }
        val otherAccount = ManagedSafetyContactRequestPolicy.resolve(
            existing = created,
            accountScopeHash = secondScope,
            targetScopeHash = firstTarget,
            createRequestId = { secondId },
        )
        assertEquals(secondId, otherAccount.requestId)
        assertEquals(secondScope, otherAccount.accountScopeHash)
    }

    @Test
    fun contactRequestTargetHashMatchesTheCrossPlatformVector() {
        assertEquals(
            "19073644815f42ceb975fac653f25b8250dfdfcc998196ba0f13fd5cab38f8f6",
            ManagedSafetyContactRequestPolicy.targetScopeHash(
                " noop-2345-6789-abcd-efgh\n",
            ),
        )
        assertThrows(ManagedStorageException.InvalidResponse::class.java) {
            ManagedSafetyContactRequestPolicy.targetScopeHash("NOOP-INVALID")
        }
    }

    @Test
    fun contactRequestRetiresOnlyForTerminalFailures() {
        assertTrue(
            ManagedSafetyContactRequestPolicy.shouldRetire(
                ManagedStorageException.Forbidden(),
            ),
        )
        assertTrue(
            ManagedSafetyContactRequestPolicy.shouldRetire(
                ManagedStorageException.Server(422),
            ),
        )
        assertFalse(
            ManagedSafetyContactRequestPolicy.shouldRetire(
                ManagedStorageException.Server(408),
            ),
        )
        assertFalse(
            ManagedSafetyContactRequestPolicy.shouldRetire(
                ManagedStorageException.Server(429),
            ),
        )
        assertFalse(
            ManagedSafetyContactRequestPolicy.shouldRetire(
                ManagedStorageException.Server(503),
            ),
        )
        assertFalse(
            ManagedSafetyContactRequestPolicy.shouldRetire(
                ManagedStorageException.Network(),
            ),
        )
    }
}
