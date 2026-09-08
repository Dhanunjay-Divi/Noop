package com.noop.managed

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class ManagedSafetyRuntimePolicyTest {
    @Test
    fun notificationRegistrationRequiresPermissionOnAndroid13AndLater() {
        assertTrue(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 32,
                permissionGranted = false,
            ),
        )
        assertFalse(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 33,
                permissionGranted = false,
            ),
        )
        assertTrue(
            ManagedSafetyNotificationPermission.canRegister(
                sdkInt = 35,
                permissionGranted = true,
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
            durationHours = 8,
            shareLocation = true,
            createRequestId = { firstId },
        )

        assertEquals(
            created,
            ManagedSafetyIncidentRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                durationHours = 8,
                shareLocation = true,
                createRequestId = { secondId },
            ),
        )
        assertThrows(ManagedStorageException.Conflict::class.java) {
            ManagedSafetyIncidentRequestPolicy.resolve(
                existing = created,
                accountScopeHash = firstScope,
                durationHours = 12,
                shareLocation = true,
                createRequestId = { secondId },
            )
        }
        val otherAccount = ManagedSafetyIncidentRequestPolicy.resolve(
            existing = created,
            accountScopeHash = secondScope,
            durationHours = 8,
            shareLocation = true,
            createRequestId = { secondId },
        )
        assertNotEquals(created.requestId, otherAccount.requestId)
        assertEquals(secondScope, otherAccount.accountScopeHash)
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
