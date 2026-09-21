package com.noop.ble

internal object LiveHeartRateNotificationPolicy {
    const val UPDATE_INTERVAL_MS = 15_000L
    const val FRESHNESS_MS = 30_000L
    const val FAILED_POST_RETRY_MS = 5_000L
    const val MAX_FAILED_POST_RETRY_MS = 5 * 60_000L

    fun hasFreshSample(
        connected: Boolean,
        receivedAtMillis: Long?,
        nowMillis: Long,
    ): Boolean {
        if (!connected || receivedAtMillis == null) return false
        return nowMillis - receivedAtMillis in 0..FRESHNESS_MS
    }

    fun visibleBpm(
        enabled: Boolean,
        connected: Boolean,
        bpm: Int?,
        receivedAtMillis: Long?,
        nowMillis: Long,
    ): Int? {
        if (!enabled || bpm !in 30..220) return null
        return bpm.takeIf { hasFreshSample(connected, receivedAtMillis, nowMillis) }
    }

    fun shouldPost(
        baseChanged: Boolean,
        liveHeartRateEnabled: Boolean,
        visibleBpm: Int?,
        previousVisibleBpm: Int?,
        nowMillis: Long,
        lastPostedAtMillis: Long,
    ): Boolean {
        if (baseChanged) return true
        if (previousVisibleBpm != null && visibleBpm == null) return true
        if (!liveHeartRateEnabled || visibleBpm == previousVisibleBpm) {
            return false
        }
        return lastPostedAtMillis <= 0L ||
            nowMillis - lastPostedAtMillis >= UPDATE_INTERVAL_MS
    }

    fun expiryCheckDelayMillis(
        receivedAtMillis: Long?,
        nowMillis: Long,
    ): Long? {
        if (receivedAtMillis == null || receivedAtMillis > nowMillis) return null
        return (receivedAtMillis + FRESHNESS_MS + 1L - nowMillis).coerceAtLeast(0L)
    }

    fun mayRetryFailedPost(
        failurePending: Boolean,
        nowMillis: Long,
        lastAttemptAtMillis: Long,
        requiredDelayMillis: Long = FAILED_POST_RETRY_MS,
    ): Boolean =
        !failurePending ||
            lastAttemptAtMillis <= 0L ||
            nowMillis - lastAttemptAtMillis >= requiredDelayMillis

    fun failedPostRetryDelayMillis(consecutiveFailures: Int): Long {
        if (consecutiveFailures <= 1) return FAILED_POST_RETRY_MS
        val shift = (consecutiveFailures - 1).coerceAtMost(6)
        return (FAILED_POST_RETRY_MS shl shift).coerceAtMost(MAX_FAILED_POST_RETRY_MS)
    }
}
