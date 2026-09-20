package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionNotificationDetailTest {
    @Test
    fun serviceKeepsOptedInHeartRatePrivateAndRateBounded() {
        val source = serviceSource()
        val policy = policySource()
        assertTrue(source.contains(".protectPrivateContent(this, CHANNEL_ID)"))
        assertTrue(source.contains(".setSilent(true)"))
        assertTrue(source.contains("LiveHeartRateNotificationPolicy.shouldPost"))
        assertTrue(source.contains("reconcileSampleFreshnessExpiry("))
        assertTrue(source.contains("LiveHeartRateNotificationPolicy.expiryCheckDelayMillis"))
        assertTrue(source.contains("delay(waitMillis)"))
        assertTrue(source.contains("receivingRecentData = receivingRecentData"))
        assertTrue(source.contains("receivingRecentData,"))
        assertTrue(policy.contains("UPDATE_INTERVAL_MS = 15_000L"))
        assertTrue(policy.contains("previousVisibleBpm != null && visibleBpm == null"))
        assertFalse(source.contains("fields = mapOf(\"bpm\""))
        assertFalse(source.contains("fields = mapOf(\"heart_rate\""))
    }

    @Test
    fun truthfulFreshnessExpiresEvenWhenLiveHeartRatePresentationIsDisabled() {
        val source = serviceSource()
        val postBody = source
            .substringAfter("private fun postNotification(")
            .substringBefore("private fun scheduleNotificationRetry(")

        assertTrue(postBody.contains("LiveHeartRateNotificationPolicy.hasFreshSample("))
        assertTrue(postBody.contains("reconcileSampleFreshnessExpiry("))
        assertTrue(postBody.contains("receivingRecentData,"))
        assertFalse(
            postBody
                .substringBefore("reconcileSampleFreshnessExpiry(")
                .substringAfter("val liveHeartRateEnabled")
                .contains("if (liveHeartRateEnabled)"),
        )
    }

    @Test
    fun connectedDetailIncludesEveryAvailableMetric() {
        assertEquals(
            "Receiving recent band data  ·  Recovery 78%  ·  Effort 42  ·  Noop Band 65%",
            connectionNotificationDetail(
                connected = true,
                backfilling = false,
                receivingRecentData = true,
                recoveryPct = 77.6,
                effort = 41.5,
                batteryPct = 64.7,
            ),
        )
    }

    @Test
    fun unavailableMetricsAreOmittedWithoutEmptySeparators() {
        assertEquals(
            "Keeping the connection ready",
            connectionNotificationDetail(
                connected = false,
                backfilling = false,
                receivingRecentData = false,
                recoveryPct = null,
                effort = null,
                batteryPct = null,
            ),
        )
    }

    @Test
    fun optedInLiveHeartRateUsesAPlainPrivateDetail() {
        assertEquals(
            "Receiving recent band data  ·  Heart rate 72 bpm",
            connectionNotificationDetail(
                connected = true,
                backfilling = false,
                receivingRecentData = true,
                recoveryPct = null,
                effort = null,
                batteryPct = null,
                heartRateText = "Heart rate 72 bpm",
            ),
        )
    }

    @Test
    fun connectionCopyDoesNotClaimStreamingWithoutEvidence() {
        assertEquals(
            "Connected; waiting for new band data",
            connectionNotificationDetail(
                connected = true,
                backfilling = false,
                receivingRecentData = false,
                recoveryPct = null,
                effort = null,
                batteryPct = null,
            ),
        )
        assertEquals(
            "Syncing saved history",
            connectionNotificationDetail(
                connected = true,
                backfilling = true,
                receivingRecentData = false,
                recoveryPct = null,
                effort = null,
                batteryPct = null,
            ),
        )
    }

    private fun serviceSource(): String {
        val root = java.io.File(checkNotNull(System.getProperty("user.dir")))
        val sourceRoot = listOf(
            java.io.File(root, "src/main/java/com/noop"),
            java.io.File(root, "app/src/main/java/com/noop"),
            java.io.File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(java.io.File::isDirectory)
            ?: error("Could not locate source root from $root")
        return java.io.File(sourceRoot, "ble/WhoopConnectionService.kt").readText()
    }

    private fun policySource(): String {
        val root = java.io.File(checkNotNull(System.getProperty("user.dir")))
        val sourceRoot = listOf(
            java.io.File(root, "src/main/java/com/noop"),
            java.io.File(root, "app/src/main/java/com/noop"),
            java.io.File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(java.io.File::isDirectory)
            ?: error("Could not locate source root from $root")
        return java.io.File(sourceRoot, "ble/LiveHeartRateNotificationPolicy.kt").readText()
    }
}
