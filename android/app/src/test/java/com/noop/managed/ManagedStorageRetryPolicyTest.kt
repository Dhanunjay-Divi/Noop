package com.noop.managed

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedStorageRetryPolicyTest {
    @Test
    fun backoffIsJitteredExponentialAndBounded() {
        assertEquals(
            ManagedStorageRetryPlan(
                failureCount = 1,
                delayMillis = 22_500L,
                retryAfterApplied = false,
                delayBucket = "under_1m",
            ),
            ManagedStorageRetryPolicy.plan(
                afterFailure = 1,
                retryAfterMillis = null,
                jitterUnit = 0.0,
            ),
        )
        assertEquals(
            60_000L,
            ManagedStorageRetryPolicy.plan(
                afterFailure = 2,
                retryAfterMillis = null,
                jitterUnit = 0.5,
            ).delayMillis,
        )
        assertEquals(
            ManagedStorageRetryPlan(
                failureCount = 7,
                delayMillis = 1_800_000L,
                retryAfterApplied = false,
                delayBucket = "30m_to_2h",
            ),
            ManagedStorageRetryPolicy.plan(
                afterFailure = 99,
                retryAfterMillis = null,
                jitterUnit = 1.0,
            ),
        )
    }

    @Test
    fun retryAfterIsALowerBoundAndClamped() {
        assertEquals(
            ManagedStorageRetryPlan(
                failureCount = 1,
                delayMillis = 300_000L,
                retryAfterApplied = true,
                delayBucket = "5_to_30m",
            ),
            ManagedStorageRetryPolicy.plan(
                afterFailure = 1,
                retryAfterMillis = 300_000L,
                jitterUnit = 0.5,
            ),
        )
        assertEquals(
            ManagedStorageRetryPolicy.MAXIMUM_RETRY_AFTER_MILLIS,
            ManagedStorageRetryPolicy.plan(
                afterFailure = 1,
                retryAfterMillis = 999_999_000L,
                jitterUnit = 0.5,
            ).delayMillis,
        )
    }

    @Test
    fun retryAfterAcceptsSecondsAndHttpDate() {
        val now = Instant.EPOCH
        assertEquals(
            300_000L,
            ManagedStorageRetryPolicy.retryAfterMillis("300", now),
        )
        assertEquals(
            300_000L,
            ManagedStorageRetryPolicy.retryAfterMillis(
                "Thu, 01 Jan 1970 00:05:00 GMT",
                now,
            ),
        )
        assertNull(ManagedStorageRetryPolicy.retryAfterMillis("0", now))
        assertNull(ManagedStorageRetryPolicy.retryAfterMillis("invalid", now))
    }

    @Test
    fun retryStateSaturatesAndGatesEarlyAttempts() {
        val (next, plan) = ManagedCloudRetryState(
            failureCount = 99,
            notBeforeMs = 0L,
        ).afterFailure(
            nowMs = 1_000L,
            retryAfterMillis = 300_000L,
            jitterUnit = 0.5,
        )

        assertEquals(ManagedStorageRetryPolicy.MAXIMUM_FAILURE_COUNT, next.failureCount)
        assertEquals(1_801_000L, next.notBeforeMs)
        assertEquals(1_800_000L, plan.delayMillis)
        assertFalse(next.shouldAttempt(1_800_999L))
        assertTrue(next.shouldAttempt(1_801_000L))
    }

    @Test
    fun onlyTransientManagedStorageFailuresAreAutomaticRetryable() {
        assertTrue(ManagedStorageException.Network().isManagedAutomaticRetryable)
        assertTrue(ManagedStorageException.Server(408).isManagedAutomaticRetryable)
        assertTrue(ManagedStorageException.Server(429).isManagedAutomaticRetryable)
        assertTrue(ManagedStorageException.Server(503).isManagedAutomaticRetryable)
        assertFalse(ManagedStorageException.Server(422).isManagedAutomaticRetryable)
        assertFalse(ManagedStorageException.Authentication().isManagedAutomaticRetryable)
    }
}
