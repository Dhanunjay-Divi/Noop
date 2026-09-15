package com.noop.ui

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test
import java.util.Locale

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
    fun hydrationRetentionRequiresTheExactDisplayedDay() = runBlocking {
        val failed = loadTodayBestEffortResult<Double?> { error("transient") }
        val confirmedMissing = loadTodayBestEffortResult<Double?> { null }
        val refreshed = loadTodayBestEffortResult<Double?> { 500.0 }
        val previous = TodayHydrationReadState(
            dayKey = "2026-09-10",
            totalMl = 237.0,
            status = TodayHydrationReadStatus.CONFIRMED,
        )

        assertEquals(
            TodayHydrationReadState(
                "2026-09-10",
                237.0,
                TodayHydrationReadStatus.CONFIRMED,
            ),
            failed.retainingHydrationForDay("2026-09-10", previous),
        )
        assertEquals(
            TodayHydrationReadState(
                "2026-09-11",
                null,
                TodayHydrationReadStatus.UNAVAILABLE,
            ),
            failed.retainingHydrationForDay("2026-09-11", previous),
        )
        assertEquals(
            TodayHydrationReadState(
                "2026-09-10",
                null,
                TodayHydrationReadStatus.MISSING,
            ),
            confirmedMissing.retainingHydrationForDay("2026-09-10", previous),
        )
        assertEquals(
            TodayHydrationReadState(
                "2026-09-10",
                500.0,
                TodayHydrationReadStatus.CONFIRMED,
            ),
            refreshed.retainingHydrationForDay("2026-09-10", previous),
        )
    }

    @Test
    fun hydrationFirstFailureIsUnavailableAndConfirmedMissingIsNotLogged() = runBlocking {
        val failed = loadTodayBestEffortResult<Double?> { error("storage unavailable") }
        val missing = loadTodayBestEffortResult<Double?> { null }

        val unavailable = failed.retainingHydrationForDay("2026-09-11", previous = null)
        val unlogged = missing.retainingHydrationForDay("2026-09-11", previous = unavailable)

        assertEquals(TodayHydrationReadStatus.UNAVAILABLE, unavailable.status)
        assertEquals("Unavailable", hydrationDashboardCardValue(unavailable, 2_500, "Not logged", "Unavailable"))
        assertEquals(TodayHydrationReadStatus.MISSING, unlogged.status)
        assertEquals("Not logged", hydrationDashboardCardValue(unlogged, 2_500, "Not logged", "Unavailable"))
    }

    @Test
    fun hydrationConfirmedIntakeStillShowsWithoutAnEligibleTarget() {
        val confirmed = TodayHydrationReadState(
            "2026-09-11",
            1_250.0,
            TodayHydrationReadStatus.CONFIRMED,
        )

        assertEquals(
            "1.3 L",
            hydrationDashboardCardValue(confirmed, null, "Not logged", "Unavailable"),
        )
    }

    @Test
    fun hydrationDashboardUsesTheActiveLocaleAndLocalizedUnitTemplate() {
        val confirmed = TodayHydrationReadState(
            "2026-09-11",
            1_250.0,
            TodayHydrationReadStatus.CONFIRMED,
        )

        assertEquals(
            "1,3 l / 3,2 l",
            hydrationDashboardCardValue(
                state = confirmed,
                goalMl = 3_200,
                notLoggedText = "Nicht protokolliert",
                unavailableText = "Nicht verfügbar",
                locale = Locale.GERMANY,
                litresFormat = "%1\$s l",
            ),
        )
    }

    @Test
    fun hydrationTransientFailureRetainsOnlyAConfirmedSameDayState() = runBlocking {
        val failed = loadTodayBestEffortResult<Double?> { error("transient") }
        val confirmed = TodayHydrationReadState(
            "2026-09-11",
            500.0,
            TodayHydrationReadStatus.CONFIRMED,
        )
        val unavailable = TodayHydrationReadState(
            "2026-09-11",
            null,
            TodayHydrationReadStatus.UNAVAILABLE,
        )
        val previouslyMissing = TodayHydrationReadState(
            "2026-09-11",
            null,
            TodayHydrationReadStatus.MISSING,
        )

        assertEquals(confirmed, failed.retainingHydrationForDay("2026-09-11", confirmed))
        assertEquals(
            TodayHydrationReadStatus.UNAVAILABLE,
            failed.retainingHydrationForDay("2026-09-11", unavailable).status,
        )
        val failedAfterMissing = failed.retainingHydrationForDay("2026-09-11", previouslyMissing)
        assertEquals(TodayHydrationReadStatus.UNAVAILABLE, failedAfterMissing.status)
        assertEquals(
            "Unavailable",
            hydrationDashboardCardValue(
                failedAfterMissing,
                2_500,
                "Not logged",
                "Unavailable",
            ),
        )
    }

    @Test
    fun bestEffortReadRechecksCancellationBeforePublishingSuccessfulLoad() = runTest {
        val loadStarted = CompletableDeferred<Unit>()
        val allowLoadToReturn = CompletableDeferred<Unit>()
        var published = false
        val job = launch {
            loadTodayBestEffortResult {
                withContext(NonCancellable) {
                    loadStarted.complete(Unit)
                    allowLoadToReturn.await()
                    500.0
                }
            }
            published = true
        }

        loadStarted.await()
        job.cancel()
        allowLoadToReturn.complete(Unit)
        job.join()

        assertFalse("a cancelled read must not publish its late result", published)
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
