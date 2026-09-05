package com.noop.managed

import java.time.LocalDate
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedSocialRuntimeTest {
    @Test
    fun profileLinkCarriesOnlyAValidShareableNoopId() {
        val noopId = "NOOP-ABCD-EFGH-JKLM-NPQR"
        val expected = "noop://managed-friends/profile?noopId=$noopId"

        assertEquals(noopId, ManagedSocialRuntime.profileNoopId(expected))
        assertEquals(expected, ManagedSocialRuntime.profileUrl(noopId))
        assertNull(
            ManagedSocialRuntime.profileNoopId(
                "$expected&redirect=https%3A%2F%2Fevil.example",
            ),
        )
        assertNull(
            ManagedSocialRuntime.profileNoopId(
                "noop://other/profile?noopId=$noopId",
            ),
        )
        assertNull(
            ManagedSocialRuntime.profileNoopId(
                "noop://managed-friends/profile?noopId=short",
            ),
        )
    }

    @Test
    fun inviteLinkCarriesOnlyAValidCapability() {
        val capability = "noopinvite_" + "a".repeat(43)
        val expected =
            "noop://managed-friends/invite?capability=$capability"

        assertEquals(capability, ManagedSocialRuntime.inviteCapability(expected))
        assertEquals(expected, ManagedSocialRuntime.inviteUrl(capability))
        assertNull(
            ManagedSocialRuntime.inviteCapability(
                "$expected&redirect=https%3A%2F%2Fevil.example",
            ),
        )
        assertNull(
            ManagedSocialRuntime.inviteCapability(
                "noop://other/invite?capability=$capability",
            ),
        )
        assertNull(
            ManagedSocialRuntime.inviteCapability(
                "noop://managed-friends/invite?capability=short",
            ),
        )
    }

    @Test
    fun summaryWindowContainsTodayAndThirtyPriorDays() {
        val days = ManagedSocialRuntime.summaryDays(LocalDate.of(2026, 9, 5))

        assertEquals(31, days.size)
        assertEquals("2026-08-06", days.first())
        assertEquals("2026-09-05", days.last())
    }

    @Test
    fun visibilityUnionAndDigestTrackOnlyApprovedFields() {
        val friend = socialFriend(
            ManagedSocialVisibility(
                charge = true,
                hrv = true,
                pokeAllowed = true,
            ),
        )
        val visibility = ManagedSocialRuntime.visibilityUnion(listOf(friend))
        val summary = ManagedSocialSummary(charge = 72.5, hrv = 54.0)
        val first = ManagedSocialRuntime.digest("2026-09-05", summary, visibility)
        val repeated = ManagedSocialRuntime.digest("2026-09-05", summary, visibility)
        val changed = ManagedSocialRuntime.digest(
            "2026-09-05",
            summary.copy(charge = 73.0),
            visibility,
        )

        assertTrue(visibility.charge)
        assertTrue(visibility.hrv)
        assertTrue(visibility.pokeAllowed)
        assertFalse(visibility.effort)
        assertEquals(first, repeated)
        assertNotEquals(first, changed)
        assertEquals(
            "1ae7221f2694469e23c6fecd9beb8053439ba79f7eedd7c4f244b6d9cf0dc9ca",
            first,
        )
    }

    @Test
    fun summaryRequestIdentityIsStableWithoutExposingValues() {
        val scope = "a".repeat(64)
        val digest = "b".repeat(64)

        assertEquals(
            ManagedSocialRuntime.summaryRequestId(scope, "2026-09-05", digest),
            ManagedSocialRuntime.summaryRequestId(scope, "2026-09-05", digest),
        )
        assertNotEquals(
            ManagedSocialRuntime.summaryRequestId(scope, "2026-09-05", digest),
            ManagedSocialRuntime.summaryRequestId(scope, "2026-09-04", digest),
        )
    }

    @Test
    fun automaticCatchUpUsesBoundedFiveMinuteCadence() {
        assertTrue(ManagedSocialRuntime.isCatchUpDue(0L, 1L))
        assertFalse(
            ManagedSocialRuntime.isCatchUpDue(
                1_000L,
                1_000L + ManagedSocialRuntime.AUTOMATIC_INTERVAL_MS - 1L,
            ),
        )
        assertTrue(
            ManagedSocialRuntime.isCatchUpDue(
                1_000L,
                1_000L + ManagedSocialRuntime.AUTOMATIC_INTERVAL_MS,
            ),
        )
    }

    private fun socialFriend(sharing: ManagedSocialVisibility) =
        ManagedSocialFriend(
            profileId = UUID.randomUUID(),
            displayName = "Friend",
            friendsSince = "2026-09-01T00:00:00Z",
            sharing = sharing,
            sharedWithMe = ManagedSocialVisibility(),
            latest = null,
            badges = emptyList(),
        )
}
