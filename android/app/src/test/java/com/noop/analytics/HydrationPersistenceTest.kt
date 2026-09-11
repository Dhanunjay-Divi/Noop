package com.noop.analytics

import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HydrationPersistenceTest {
    private data class Fixture(
        val repo: WhoopRepository,
        val rows: ConcurrentHashMap<Triple<String, String, String>, MetricSeriesRow>,
    )

    private fun fixture(
        seed: List<MetricSeriesRow> = emptyList(),
        failReads: Boolean = false,
        failWrites: Boolean = false,
        readDelayMs: Long = 0,
    ): Fixture {
        val rows = ConcurrentHashMap(
            seed.associateBy { Triple(it.deviceId, it.day, it.key) },
        )
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "metricSeries" -> {
                    if (failReads) error("synthetic read failure")
                    if (readDelayMs > 0) Thread.sleep(readDelayMs)
                    val values = args!!
                    val source = values[0] as String
                    val key = values[1] as String
                    val from = values[2] as String
                    val to = values[3] as String
                    rows.values
                        .filter {
                            it.deviceId == source &&
                                it.key == key &&
                                it.day >= from &&
                                it.day <= to
                        }
                        .sortedBy { it.day }
                }
                "upsertMetricSeries" -> {
                    if (failWrites) error("synthetic write failure")
                    @Suppress("UNCHECKED_CAST")
                    val incoming = args!![0] as List<MetricSeriesRow>
                    incoming.forEach {
                        rows[Triple(it.deviceId, it.day, it.key)] = it
                    }
                    Unit
                }
                else -> throw UnsupportedOperationException(
                    "hydration store must not call ${method.name}",
                )
            }
        } as WhoopDao
        return Fixture(WhoopRepository(dao), rows)
    }

    @Test
    fun concurrentAddsPreserveEveryIncrement() = runBlocking(Dispatchers.Default) {
        val timestamp = 1_800_000_000L
        val day = HydrationStore.dayKey(timestamp)
        val fixture = fixture(readDelayMs = 20)
        val revisionBefore = HydrationStore.mutationSeq.value

        val results = listOf(
            async { HydrationStore.log(fixture.repo, 237, timestamp) },
            async { HydrationStore.log(fixture.repo, 500, timestamp) },
        ).awaitAll()

        assertEquals(2, results.filterNotNull().size)
        assertEquals(737.0, results.filterNotNull().maxOrNull() ?: 0.0, 0.0)
        assertEquals(
            737.0,
            requireNotNull(
                fixture.rows[Triple(HydrationStore.SOURCE_ID, day, HydrationStore.KEY)]?.value,
            ),
            0.0,
        )
        assertEquals(revisionBefore + 2, HydrationStore.mutationSeq.value)
    }

    @Test
    fun failedWritesPreserveStoredTotalAndRevision() {
        val timestamp = 1_800_086_400L
        val day = HydrationStore.dayKey(timestamp)
        val existing = MetricSeriesRow(
            deviceId = HydrationStore.SOURCE_ID,
            day = day,
            key = HydrationStore.KEY,
            value = 237.0,
        )
        val fixture = fixture(seed = listOf(existing), failWrites = true)
        val revisionBefore = HydrationStore.mutationSeq.value

        assertFails { HydrationStore.log(fixture.repo, 500, timestamp) }
        assertFails { HydrationStore.set(fixture.repo, 0.0, timestamp) }
        assertFails { HydrationStore.remove(fixture.repo, 237, timestamp) }

        assertEquals(
            237.0,
            requireNotNull(
                fixture.rows[Triple(HydrationStore.SOURCE_ID, day, HydrationStore.KEY)]?.value,
            ),
            0.0,
        )
        assertEquals(revisionBefore, HydrationStore.mutationSeq.value)
    }

    @Test
    fun successfulClearReturnsMissingAndBanksCanonicalZero() = runBlocking {
        val timestamp = 1_800_172_800L
        val day = HydrationStore.dayKey(timestamp)
        val fixture = fixture(
            seed = listOf(
                MetricSeriesRow(
                    deviceId = HydrationStore.SOURCE_ID,
                    day = day,
                    key = HydrationStore.KEY,
                    value = 237.0,
                ),
            ),
        )
        val revisionBefore = HydrationStore.mutationSeq.value

        val result = HydrationStore.set(fixture.repo, 0.0, timestamp)

        assertNull(result)
        assertEquals(
            0.0,
            requireNotNull(
                fixture.rows[Triple(HydrationStore.SOURCE_ID, day, HydrationStore.KEY)]?.value,
            ),
            0.0,
        )
        assertEquals(revisionBefore + 1, HydrationStore.mutationSeq.value)
    }

    @Test
    fun readFailureDoesNotMasqueradeAsMissingIntake() {
        assertFails {
            HydrationStore.total(
                fixture(failReads = true).repo,
                1_800_259_200L,
            )
        }
    }

    private fun assertFails(block: suspend () -> Unit) {
        var failed = false
        try {
            runBlocking { block() }
        } catch (_: Throwable) {
            failed = true
        }
        assertTrue("expected synthetic persistence failure", failed)
    }
}
