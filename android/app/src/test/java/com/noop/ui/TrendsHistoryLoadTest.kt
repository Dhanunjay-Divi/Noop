package com.noop.ui

import com.noop.data.DailyMetric
import java.io.File
import kotlin.system.measureTimeMillis
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test
    fun timedPreparationCancelsCpuLoopFromWorkerContext() = runBlocking {
        var checks = 0
        val elapsedMillis = measureTimeMillis {
            try {
                runTimedTrendsPreparation(timeoutMillis = 25L) { cancellationCheck ->
                    while (true) {
                        cancellationCheck()
                        checks += 1
                    }
                }
                fail("Expected timed preparation cancellation")
            } catch (_: TimeoutCancellationException) {
                // Expected: the worker's own timed child became inactive.
            }
        }

        assertTrue(checks > 0)
        assertTrue(
            "Timed CPU preparation took ${elapsedMillis}ms instead of observing its child timeout",
            elapsedMillis < 1_000L,
        )
    }

    @Test
    fun snapshotVisitsEachSourceRowOnce() {
        var visits = 0
        val history = List(4_000) { index ->
            day.copy(
                avgHrv = (30 + index % 40).toDouble(),
                restingHr = 48 + index % 8,
                recovery = (index % 100).toDouble(),
                strain = (index % 80).toDouble(),
            )
        }

        val snapshot = buildTrendsSnapshot(
            days = history,
            selected = TrendsRange.All,
            sleepPerfByDay = mapOf(day.day to 82.0),
            today = java.time.LocalDate.parse(day.day),
            onSourceRow = { visits += 1 },
        )

        assertEquals(history.size, visits)
        assertEquals(history.size, snapshot.recovery.values.size)
        assertEquals(history.size, snapshot.hrv.values.size)
        assertEquals(history.size, snapshot.rhr.values.size)
        assertEquals(history.size, snapshot.strain.values.size)
        assertEquals(history.size, snapshot.rest.values.size)
    }

    @Test
    fun snapshotCacheIsBoundedAndUsesLruOrder() {
        val snapshot = buildTrendsSnapshot(
            days = listOf(day.copy(recovery = 55.0)),
            selected = TrendsRange.All,
            sleepPerfByDay = emptyMap(),
            today = java.time.LocalDate.parse(day.day),
        )
        val week = cacheKey(TrendsRange.Week)
        val month = cacheKey(TrendsRange.Month)
        val quarter = cacheKey(TrendsRange.Quarter)
        val cache = TrendsSnapshotCache(capacity = 2)

        cache.put(week, snapshot)
        cache.put(month, snapshot)
        assertTrue(cache[week] != null)
        cache.put(quarter, snapshot)

        assertEquals(2, cache.size)
        assertTrue(cache[week] != null)
        assertTrue(cache[month] == null)
        assertTrue(cache[quarter] != null)
    }

    @Test
    fun trendsSourceKeepsLongHistoryPreparationOffMainAndDiagnosticsBounded() {
        val source = trendsSource()

        assertTrue(source.contains("val result = withContext(Dispatchers.Default)"))
        assertTrue(source.contains("val workerContext = currentCoroutineContext()"))
        assertTrue(source.contains("prepare { workerContext.ensureActive() }"))
        assertEquals(
            2,
            source.split("runTimedTrendsPreparation { cancellationCheck ->").size - 1,
        )
        assertTrue(source.contains("buildTrendsSnapshot("))
        assertTrue(source.contains("buildWeeklyDigest("))
        assertFalse(source.contains("val loadContext = currentCoroutineContext()"))
        assertTrue(source.contains("TrendsSnapshotCache()"))
        assertTrue(source.contains("\"cache_status\""))
        assertTrue(source.contains("\"day_count_bucket\""))
        assertTrue(source.contains("TrendsLoadingSkeleton()"))
        assertFalse(source.contains("\"health_value\""))
        assertFalse(source.contains("\"device_id\""))
    }

    private fun cacheKey(range: TrendsRange) = TrendsSnapshotCacheKey(
        historyGeneration = 1,
        todayKey = day.day,
        range = range,
    )

    private fun trendsSource(): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(
            File(root, "src/main/java/com/noop/ui/TrendsScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/TrendsScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/TrendsScreen.kt"),
        )
        return requireNotNull(candidates.firstOrNull(File::isFile)) {
            "Missing TrendsScreen.kt"
        }.readText()
    }
}
