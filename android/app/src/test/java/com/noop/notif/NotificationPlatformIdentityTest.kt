package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPlatformIdentityTest {
    @Test
    fun notificationIdsAreCollisionFree() {
        val ids = NotificationPlatformIdentity.NotificationId.all

        assertEquals(27, ids.size)
        assertEquals(ids.size, ids.toSet().size)
        assertTrue(ids.all { it > 0 })
    }

    @Test
    fun activityPendingIntentIdentitiesAreCollisionFree() {
        val identities = NotificationPlatformIdentity.ActivityIntent.all

        assertEquals(29, identities.size)
        assertEquals(
            identities.size,
            identities.map { it.requestCode }.toSet().size,
        )
        assertEquals(
            identities.size,
            identities.map { it.action }.toSet().size,
        )
        assertTrue(
            identities.all {
                it.action.startsWith("com.noop.notification.action.open.")
            },
        )
    }

    @Test
    fun managedSafetyInstanceIdentitiesDoNotSharePendingIntentActions() {
        val base = NotificationPlatformIdentity.ActivityIntent.MANAGED_SAFETY
        val first = NotificationPlatformIdentity.instanceIdentity(
            base,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        )
        val second = NotificationPlatformIdentity.instanceIdentity(
            base,
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        )

        assertEquals(base.requestCode, first.requestCode)
        assertEquals(base.requestCode, second.requestCode)
        assertTrue(first.action.startsWith("${base.action}.instance."))
        assertTrue(second.action.startsWith("${base.action}.instance."))
        assertTrue(first.action != second.action)
    }

    @Test(expected = IllegalArgumentException::class)
    fun managedSafetyInstanceIdentityRejectsUnboundedDynamicKey() {
        NotificationPlatformIdentity.instanceIdentity(
            NotificationPlatformIdentity.ActivityIntent.MANAGED_SAFETY,
            "contains sensitive spaces",
        )
    }
}
