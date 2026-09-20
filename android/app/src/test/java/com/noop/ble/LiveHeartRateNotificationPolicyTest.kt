package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveHeartRateNotificationPolicyTest {
    @Test fun visibleBpmRequiresOptInConnectionRangeAndFreshness() {
        val now = 100_000L
        assertEquals(
            72,
            LiveHeartRateNotificationPolicy.visibleBpm(true, true, 72, now - 1_000L, now),
        )
        assertNull(LiveHeartRateNotificationPolicy.visibleBpm(false, true, 72, now, now))
        assertNull(LiveHeartRateNotificationPolicy.visibleBpm(true, false, 72, now, now))
        assertEquals(30, LiveHeartRateNotificationPolicy.visibleBpm(true, true, 30, now, now))
        assertEquals(220, LiveHeartRateNotificationPolicy.visibleBpm(true, true, 220, now, now))
        assertNull(LiveHeartRateNotificationPolicy.visibleBpm(true, true, 29, now, now))
        assertNull(LiveHeartRateNotificationPolicy.visibleBpm(true, true, 221, now, now))
        assertNull(LiveHeartRateNotificationPolicy.visibleBpm(true, true, 72, now - 31_000L, now))
    }

    @Test fun freshnessCanDriveTruthfulConnectionCopyWithoutExposingTheValue() {
        val now = 100_000L
        assertTrue(LiveHeartRateNotificationPolicy.hasFreshSample(true, now - 1_000L, now))
        assertFalse(LiveHeartRateNotificationPolicy.hasFreshSample(false, now, now))
        assertFalse(LiveHeartRateNotificationPolicy.hasFreshSample(true, now - 30_001L, now))
    }

    @Test fun baseChangesAreImmediateAndHeartRateChangesAreBounded() {
        assertTrue(
            LiveHeartRateNotificationPolicy.shouldPost(
                baseChanged = true,
                liveHeartRateEnabled = false,
                visibleBpm = null,
                previousVisibleBpm = null,
                nowMillis = 1_000L,
                lastPostedAtMillis = 900L,
            ),
        )
        assertFalse(
            LiveHeartRateNotificationPolicy.shouldPost(
                baseChanged = false,
                liveHeartRateEnabled = true,
                visibleBpm = 73,
                previousVisibleBpm = 72,
                nowMillis = 14_999L,
                lastPostedAtMillis = 1L,
            ),
        )
        assertTrue(
            LiveHeartRateNotificationPolicy.shouldPost(
                baseChanged = false,
                liveHeartRateEnabled = true,
                visibleBpm = 73,
                previousVisibleBpm = 72,
                nowMillis = 15_001L,
                lastPostedAtMillis = 1L,
            ),
        )
    }

    @Test fun staleDisplayedHeartRateClearsAtTheSameBoundedCadence() {
        assertTrue(
            LiveHeartRateNotificationPolicy.shouldPost(
                baseChanged = false,
                liveHeartRateEnabled = true,
                visibleBpm = null,
                previousVisibleBpm = 72,
                nowMillis = 30_000L,
                lastPostedAtMillis = 10_000L,
            ),
        )
        assertTrue(
            LiveHeartRateNotificationPolicy.shouldPost(
                baseChanged = false,
                liveHeartRateEnabled = true,
                visibleBpm = null,
                previousVisibleBpm = 72,
                nowMillis = 30_001L,
                lastPostedAtMillis = 30_000L,
            ),
        )
    }

    @Test fun expiryCheckIsAnchoredToTheActualObservation() {
        assertEquals(
            20_001L,
            LiveHeartRateNotificationPolicy.expiryCheckDelayMillis(
                receivedAtMillis = 10_000L,
                nowMillis = 20_000L,
            ),
        )
        assertEquals(
            0L,
            LiveHeartRateNotificationPolicy.expiryCheckDelayMillis(
                receivedAtMillis = 10_000L,
                nowMillis = 40_001L,
            ),
        )
        assertNull(
            LiveHeartRateNotificationPolicy.expiryCheckDelayMillis(
                receivedAtMillis = 20_001L,
                nowMillis = 20_000L,
            ),
        )
    }

    @Test fun failedPlatformPostsRetryWithoutBecomingAOneHertzLoop() {
        assertFalse(
            LiveHeartRateNotificationPolicy.mayRetryFailedPost(
                failurePending = true,
                nowMillis = 5_999L,
                lastAttemptAtMillis = 1_000L,
            ),
        )
        assertTrue(
            LiveHeartRateNotificationPolicy.mayRetryFailedPost(
                failurePending = true,
                nowMillis = 6_000L,
                lastAttemptAtMillis = 1_000L,
            ),
        )
        assertTrue(
            LiveHeartRateNotificationPolicy.mayRetryFailedPost(
                failurePending = false,
                nowMillis = 1_001L,
                lastAttemptAtMillis = 1_000L,
            ),
        )
        assertEquals(
            5_000L,
            LiveHeartRateNotificationPolicy.failedPostRetryDelayMillis(1),
        )
        assertEquals(
            10_000L,
            LiveHeartRateNotificationPolicy.failedPostRetryDelayMillis(2),
        )
        assertEquals(
            LiveHeartRateNotificationPolicy.MAX_FAILED_POST_RETRY_MS,
            LiveHeartRateNotificationPolicy.failedPostRetryDelayMillis(99),
        )
    }
}
