package com.noop.managed

import com.noop.safety.SafetyLocation
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
                    deliveryCapableCount = 0,
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
                    deliveryCapableCount = 1,
                    minimumRequired = 1,
                    maximumAllowed = 5,
                ),
            ),
        )
        assertTrue(
            shouldDisableBandSosPreference(
                enabled = true,
                phase = ManagedCloudPhase.ENROLLED,
                contacts = ManagedSafetyContacts(
                    contacts = listOf(acceptedContact),
                    deliveryCapableCount = 0,
                    minimumRequired = 1,
                    maximumAllowed = 5,
                ),
            ),
        )
    }

    @Test
    fun locationSharingRequiresForegroundAuthorizationOnly() {
        assertTrue(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = false,
                foregroundGranted = false,
            ),
        )
        assertFalse(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = true,
                foregroundGranted = false,
            ),
        )
        assertTrue(
            ManagedSafetyLocationAuthorization.canStartIncident(
                shareLocation = true,
                foregroundGranted = true,
            ),
        )
    }

    @Test
    fun safetyLocationUploadRequiresReadyFreshValidFixWithBoundedAccuracy() {
        val nowUnix = 1_800_000_000L

        fun location(
            latitude: Double = 40.7128,
            longitude: Double = -74.0060,
            accuracy: Double? = 12.0,
            capturedAtUnix: Long = nowUnix,
        ) = SafetyLocation(
            latitude = latitude,
            longitude = longitude,
            horizontalAccuracyMeters = accuracy,
            capturedAtUnix = capturedAtUnix,
        )

        assertTrue(
            managedSafetyLocationCanUpload(
                location = location(),
                locationReady = true,
                nowUnix = nowUnix,
            ),
        )
        assertTrue(
            managedSafetyLocationCanUpload(
                location = location(
                    accuracy = SafetyLocation.MAXIMUM_HORIZONTAL_ACCURACY_METERS,
                ),
                locationReady = true,
                nowUnix = nowUnix,
            ),
        )
        assertFalse(
            managedSafetyLocationCanUpload(
                location = location(),
                locationReady = false,
                nowUnix = nowUnix,
            ),
        )
        assertFalse(
            managedSafetyLocationCanUpload(
                location = null,
                locationReady = true,
                nowUnix = nowUnix,
            ),
        )
        for (invalidAccuracy in listOf(null, Double.NaN, Double.POSITIVE_INFINITY, -0.1, 10_000.1)) {
            assertFalse(
                managedSafetyLocationCanUpload(
                    location = location(accuracy = invalidAccuracy),
                    locationReady = true,
                    nowUnix = nowUnix,
                ),
            )
        }
        assertFalse(
            managedSafetyLocationCanUpload(
                location = location(latitude = Double.NaN),
                locationReady = true,
                nowUnix = nowUnix,
            ),
        )
        assertFalse(
            managedSafetyLocationCanUpload(
                location = location(
                    capturedAtUnix = nowUnix - SafetyLocation.MAXIMUM_AGE_SECONDS - 1L,
                ),
                locationReady = true,
                nowUnix = nowUnix,
            ),
        )
        assertFalse(
            managedSafetyLocationCanUpload(
                location = location(
                    capturedAtUnix =
                        nowUnix + SafetyLocation.MAXIMUM_FUTURE_CLOCK_SKEW_SECONDS + 1L,
                ),
                locationReady = true,
                nowUnix = nowUnix,
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
    fun incidentRequestReplaysSameIntentAndRotatesAfterIntentOrAccountChanges() {
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
        val changedDuration = ManagedSafetyIncidentRequestPolicy.resolve(
            existing = created,
            accountScopeHash = firstScope,
            trigger = "manual_sos",
            durationHours = 12,
            shareLocation = true,
            createRequestId = { secondId },
        )
        assertEquals(secondId, changedDuration.requestId)
        assertEquals(12, changedDuration.durationHours)

        val changedTrigger = ManagedSafetyIncidentRequestPolicy.resolve(
            existing = created,
            accountScopeHash = firstScope,
            trigger = "band_sos",
            durationHours = 8,
            shareLocation = false,
            createRequestId = { secondId },
        )
        assertEquals(secondId, changedTrigger.requestId)
        assertEquals("band_sos", changedTrigger.trigger)
        assertFalse(changedTrigger.shareLocation)
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
