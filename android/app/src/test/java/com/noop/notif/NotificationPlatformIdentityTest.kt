package com.noop.notif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPlatformIdentityTest {
    @Test
    fun notificationIdsAreCollisionFree() {
        val ids = NotificationPlatformIdentity.NotificationId.all

        assertEquals(21, ids.size)
        assertEquals(ids.size, ids.toSet().size)
        assertTrue(ids.all { it > 0 })
    }

    @Test
    fun activityPendingIntentIdentitiesAreCollisionFree() {
        val identities = NotificationPlatformIdentity.ActivityIntent.all

        assertEquals(23, identities.size)
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
}
