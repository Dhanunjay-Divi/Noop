package com.noop.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class TodayRestLoadPolicyTest {
    @Test
    fun retriesTransientFailuresThenReturnsTheLoadedMap() = runBlocking {
        var calls = 0
        val result = loadTodayRestWithRetry(
            pause = {},
        ) {
            calls += 1
            if (calls < 3) error("transient")
            mapOf("2026-09-09" to 91.0)
        }

        assertEquals(3, calls)
        assertEquals(91.0, result["2026-09-09"])
    }

    @Test
    fun cancellationIsNeverRetriedOrConvertedToFailure() = runBlocking {
        var calls = 0
        try {
            loadTodayRestWithRetry(pause = {}) {
                calls += 1
                throw CancellationException("test")
            }
            fail("Expected cancellation")
        } catch (_: CancellationException) {
            assertEquals(1, calls)
        }
    }

    @Test
    fun bestEffortReadPreservesStructuredCancellation() = runBlocking {
        try {
            loadTodayBestEffort<String> {
                throw CancellationException("test")
            }
            fail("Expected cancellation")
        } catch (_: CancellationException) {
            // Expected.
        }
    }

    @Test
    fun bestEffortReadMapsOrdinaryFailureToNull() = runBlocking {
        assertEquals(null, loadTodayBestEffort<String> { error("transient") })
    }

    @Test
    fun bestEffortResultDistinguishesARealNullFromReadFailure() = runBlocking {
        val realNull = loadTodayBestEffortResult<String?> { null }
        val failed = loadTodayBestEffortResult<String> { error("transient") }

        assertEquals(true, realNull.succeeded)
        assertEquals(null, realNull.value)
        assertEquals(false, failed.succeeded)
        assertEquals(null, failed.value)
    }

    @Test
    fun bestEffortStateRetainsThePreviousValueOnlyOnReadFailure() = runBlocking {
        val failed = loadTodayBestEffortResult<Double?> { error("transient") }
        val confirmedMissing = loadTodayBestEffortResult<Double?> { null }
        val refreshed = loadTodayBestEffortResult<Double?> { 500.0 }

        assertEquals(237.0, failed.retainingPreviousOnFailure(237.0))
        assertEquals(null, confirmedMissing.retainingPreviousOnFailure(237.0))
        assertEquals(500.0, refreshed.retainingPreviousOnFailure(237.0))
    }

    @Test
    fun permanentFailureStopsAtTheBoundedAttemptLimit() = runBlocking {
        var calls = 0
        try {
            loadTodayRestWithRetry(pause = {}) {
                calls += 1
                error("still unavailable")
            }
            fail("Expected failure")
        } catch (_: IllegalStateException) {
            assertEquals(3, calls)
        }
    }

    @Test
    fun resultCountsUseBoundedCategories() {
        assertEquals("empty", todayRestResultBucket(0))
        assertEquals("up_to_30", todayRestResultBucket(30))
        assertEquals("31_to_365", todayRestResultBucket(31))
        assertEquals("over_365", todayRestResultBucket(366))
    }
}
