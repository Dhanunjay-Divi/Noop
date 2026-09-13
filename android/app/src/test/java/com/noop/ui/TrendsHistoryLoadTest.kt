package com.noop.ui

import com.noop.data.DailyMetric
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TrendsHistoryLoadTest {
    private val day = DailyMetric(deviceId = "test-device", day = "2026-09-12")

    @Test
    fun fullHistoryAndBothSleepSeriesProduceCompleteContent() = runBlocking {
        var recentRead = false
        val result = loadTrendsHistory(
            loadFullHistory = { listOf(day) },
            loadRecentHistory = {
                recentRead = true
                emptyList()
            },
            loadResolvedSleep = { mapOf(day.day to 81.0) },
            loadImportedSleep = { mapOf(day.day to 92.0) },
        ) as TrendsHistoryLoadResult.Content

        assertEquals(TrendsHistoryMode.FULL, result.payload.mode)
        assertEquals(listOf(day), result.payload.days)
        assertEquals(emptySet<TrendsHistoryIssue>(), result.payload.issues)
        assertTrue(!recentRead)
    }

    @Test
    fun fullHistoryFailureUsesBoundedRecentFallback() = runBlocking {
        val result = loadTrendsHistory(
            loadFullHistory = { error("local read failed") },
            loadRecentHistory = { listOf(day) },
            loadResolvedSleep = { emptyMap() },
            loadImportedSleep = { emptyMap() },
        ) as TrendsHistoryLoadResult.Content

        assertEquals(TrendsHistoryMode.RECENT_FALLBACK, result.payload.mode)
        assertEquals(listOf(day), result.payload.days)
        assertEquals(setOf(TrendsHistoryIssue.FULL_HISTORY), result.payload.issues)
    }

    @Test
    fun bothHistoryReadsFailWithTerminalState() = runBlocking {
        val result = loadTrendsHistory(
            loadFullHistory = { error("full failed") },
            loadRecentHistory = { error("recent failed") },
            loadResolvedSleep = { error("must not run") },
            loadImportedSleep = { error("must not run") },
        )

        assertSame(TrendsHistoryLoadResult.Failed, result)
    }

    @Test
    fun sleepFailuresAreIndependentAndKeepUsableHistory() = runBlocking {
        val result = loadTrendsHistory(
            loadFullHistory = { listOf(day) },
            loadRecentHistory = { emptyList() },
            loadResolvedSleep = { error("resolved failed") },
            loadImportedSleep = { error("imported failed") },
        ) as TrendsHistoryLoadResult.Content

        assertEquals(
            setOf(
                TrendsHistoryIssue.RESOLVED_SLEEP,
                TrendsHistoryIssue.IMPORTED_SLEEP,
            ),
            result.payload.issues,
        )
        assertTrue(result.payload.resolvedSleep.isEmpty())
        assertTrue(result.payload.importedSleep.isEmpty())
    }

    @Test(expected = CancellationException::class)
    fun fullHistoryCancellationIsNeverConvertedToFallback(): Unit = runBlocking {
        loadTrendsHistory(
            loadFullHistory = { throw CancellationException("cancel") },
            loadRecentHistory = { error("must not run") },
            loadResolvedSleep = { emptyMap() },
            loadImportedSleep = { emptyMap() },
        )
    }

    @Test(expected = CancellationException::class)
    fun sleepCancellationIsNeverConvertedToPartialContent(): Unit = runBlocking {
        loadTrendsHistory(
            loadFullHistory = { listOf(day) },
            loadRecentHistory = { emptyList() },
            loadResolvedSleep = { throw CancellationException("cancel") },
            loadImportedSleep = { error("must not run") },
        )
    }

    @Test
    fun stalledHistoryReadTimesOutWithTerminalRetryableState() = runBlocking {
        val result = loadTrendsHistory(
            loadFullHistory = {
                delay(100)
                listOf(day)
            },
            loadRecentHistory = { emptyList() },
            loadResolvedSleep = { emptyMap() },
            loadImportedSleep = { emptyMap() },
            timeoutMillis = 10,
        )

        assertSame(TrendsHistoryLoadResult.TimedOut, result)
    }

    @Test
    fun aggregateCancellationCheckStopsCpuWork() {
        var checks = 0
        val history = List(2_000) { day.copy(recovery = 50.0) }

        try {
            buildTrendsSnapshot(
                days = history,
                selected = TrendsRange.All,
                sleepPerfByDay = emptyMap(),
                today = java.time.LocalDate.parse(day.day),
                cancellationCheck = {
                    checks += 1
                    if (checks >= 4) throw CancellationException("cancel")
                },
            )
            fail("Expected aggregate cancellation")
        } catch (_: CancellationException) {
            assertEquals(4, checks)
        }
    }
}
