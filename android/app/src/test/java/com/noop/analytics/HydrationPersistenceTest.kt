package com.noop.analytics

import com.noop.data.HydrationEntryContract
import com.noop.data.HydrationEntryMutationResult
import com.noop.data.HydrationEntryRow
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
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
        val entries: ConcurrentHashMap<String, HydrationEntryRow>,
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
        val entries = ConcurrentHashMap(
            seed.mapNotNull { row ->
                row.takeIf {
                    it.deviceId == HydrationStore.SOURCE_ID &&
                        it.key == HydrationStore.KEY &&
                        it.value.isFinite() &&
                        it.value > 0.0 &&
                        it.value <= HydrationEntryContract.MAX_DAY_ML &&
                        it.value % 1.0 == 0.0
                }?.let {
                    val id = java.util.UUID.nameUUIDFromBytes(
                        "${it.deviceId}:${it.day}:${it.value}".toByteArray(),
                    ).toString()
                    id to HydrationEntryRow(
                        id = id,
                        deviceId = it.deviceId,
                        day = it.day,
                        amountML = it.value.toInt(),
                        loggedAt = LocalDate.parse(it.day)
                            .atTime(12, 0)
                            .atZone(ZoneId.systemDefault())
                            .toEpochSecond(),
                    )
                }
            }.toMap(),
        )
        val lock = Any()

        fun entriesFor(day: String): List<HydrationEntryRow> =
            entries.values.filter { it.deviceId == HydrationStore.SOURCE_ID && it.day == day }
                .sortedWith(compareBy(HydrationEntryRow::loggedAt, HydrationEntryRow::id))

        fun replaceDay(
            day: String,
            replacement: List<HydrationEntryRow>,
            changed: Boolean,
        ): HydrationEntryMutationResult = synchronized(lock) {
            if (failWrites) error("synthetic write failure")
            val scalarKey = Triple(HydrationStore.SOURCE_ID, day, HydrationStore.KEY)
            HydrationEntryContract.requireEditableProjection(rows[scalarKey]?.value, entriesFor(day))
            HydrationEntryContract.total(replacement)
            entries.values
                .filter { it.deviceId == HydrationStore.SOURCE_ID && it.day == day }
                .map(HydrationEntryRow::id)
                .forEach(entries::remove)
            replacement.forEach { entries[it.id] = it }
            val total = HydrationEntryContract.total(replacement)
            rows[scalarKey] = MetricSeriesRow(
                HydrationStore.SOURCE_ID,
                day,
                HydrationStore.KEY,
                total.toDouble(),
            )
            HydrationEntryMutationResult(changed, total.takeIf { it > 0 }?.toDouble())
        }

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
                "hydrationEntries" -> {
                    if (failReads) error("synthetic read failure")
                    if (readDelayMs > 0) Thread.sleep(readDelayMs)
                    entriesFor(args!![1] as String)
                }
                "addHydrationEntry" -> synchronized(lock) {
                    val row = HydrationEntryContract.validated(args!![0] as HydrationEntryRow)
                    replaceDay(row.day, entriesFor(row.day) + row, changed = true)
                }
                "updateHydrationEntry" -> synchronized(lock) {
                    val row = HydrationEntryContract.validated(args!![0] as HydrationEntryRow)
                    val current = entries[row.id]
                    if (current == null) {
                        HydrationEntryMutationResult(false, null)
                    } else {
                        require(current.deviceId == row.deviceId && current.day == row.day)
                        replaceDay(
                            row.day,
                            entriesFor(row.day).map { if (it.id == row.id) row else it },
                            changed = current != row,
                        )
                    }
                }
                "deleteHydrationEntry" -> synchronized(lock) {
                    val id = args!![0] as String
                    val day = args[2] as String
                    val current = entries[id]
                    if (current == null) {
                        HydrationEntryMutationResult(false, null)
                    } else {
                        require(current.day == day)
                        replaceDay(day, entriesFor(day).filterNot { it.id == id }, changed = true)
                    }
                }
                "clearHydrationEntries" -> synchronized(lock) {
                    val day = args!![1] as String
                    val current = entriesFor(day)
                    replaceDay(day, emptyList(), changed = current.isNotEmpty())
                }
                "replaceHydrationEntries" -> synchronized(lock) {
                    val day = args!![1] as String
                    @Suppress("UNCHECKED_CAST")
                    val replacement = args[2] as List<HydrationEntryRow>
                    replaceDay(day, replacement, changed = entriesFor(day) != replacement)
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
        return Fixture(WhoopRepository(dao), rows, entries)
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
    fun noOpMutationsStayUnchangedAndUseTheUnchangedDiagnosticOutcome() = runBlocking {
        val day = "2026-09-10"
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

        assertEquals(
            237.0,
            HydrationStore.updateEntryForDay(
                repo = fixture.repo,
                id = "missing-entry",
                amountMl = 500,
                day = day,
            )!!,
            0.0,
        )
        assertNull(
            HydrationStore.deleteEntryForDay(
                repo = fixture.repo,
                id = "missing-entry",
                day = day,
            ),
        )
        assertEquals(revisionBefore, HydrationStore.mutationSeq.value)
        assertEquals("unchanged", HydrationStore.persistenceOutcome(changed = false))
        assertEquals("saved", HydrationStore.persistenceOutcome(changed = true))
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

    @Test
    fun singleSourceProvenanceNamesTheSourceWithoutAnOverlapWarning() {
        val presentation = HydrationStore.run {
            HydrationStore.Reading(
                valueMl = 500.0,
                source = HydrationStore.ReadingSource.HEALTH_CONNECT,
                noopMl = 0.0,
                healthConnectMl = 500.0,
            ).provenance(
                HydrationStore.ProvenanceStrings(
                    noopOnlyLabel = "NOOP",
                    externalOnlyLabel = "Health Connect",
                    bothLabel = "NOOP and Health Connect",
                    bothExplanation = "merge explanation",
                ),
            )
        }

        assertEquals("Health Connect", presentation.sourceLabel)
        assertNull(presentation.explanation)
        assertTrue(presentation.sourceTotals.isEmpty())
    }

    @Test
    fun bothSourceProvenanceKeepsTotalsSeparateAndExplainsTheConservativeMerge() {
        val explanation = "The displayed total uses the larger source total."
        val presentation = HydrationStore.run {
            HydrationStore.Reading(
                valueMl = 700.0,
                source = HydrationStore.ReadingSource.BOTH,
                noopMl = 500.0,
                healthConnectMl = 700.0,
            ).provenance(
                HydrationStore.ProvenanceStrings(
                    noopOnlyLabel = "NOOP",
                    externalOnlyLabel = "Health Connect",
                    bothLabel = "NOOP and Health Connect",
                    bothExplanation = explanation,
                ),
            )
        }

        assertEquals("NOOP and Health Connect", presentation.sourceLabel)
        assertEquals(explanation, presentation.explanation)
        assertEquals(
            listOf(
                HydrationStore.SourceTotal(HydrationStore.ReadingSource.NOOP, 500.0),
                HydrationStore.SourceTotal(HydrationStore.ReadingSource.HEALTH_CONNECT, 700.0),
            ),
            presentation.sourceTotals,
        )
    }

    @Test
    fun sourceAwareReadUsesTheLargerTotalInsteadOfAddingOverlappingSources() = runBlocking {
        val day = "2026-09-10"
        val fixture = fixture(
            seed = listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, day, HydrationStore.KEY, 500.0),
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    day,
                    HydrationStore.KEY,
                    700.0,
                ),
            ),
        )

        val reading = requireNotNull(HydrationStore.readingForDay(fixture.repo, day))

        assertEquals(700.0, reading.valueMl, 0.0)
        assertEquals(HydrationStore.ReadingSource.BOTH, reading.source)
        assertEquals(500.0, reading.noopMl, 0.0)
        assertEquals(700.0, reading.healthConnectMl, 0.0)
        assertTrue(reading.valueMl != reading.noopMl + reading.healthConnectMl)
    }

    @Test
    fun explicitDayReadUsesTheDisplayedDayInsteadOfTheCurrentClock() = runBlocking {
        val fixture = fixture(
            seed = listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-09", HydrationStore.KEY, 237.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-10", HydrationStore.KEY, 500.0),
            ),
        )

        assertEquals(
            237.0,
            requireNotNull(HydrationStore.totalForDay(fixture.repo, "2026-09-09")),
            0.0,
        )
        assertEquals(
            500.0,
            requireNotNull(HydrationStore.totalForDay(fixture.repo, "2026-09-10")),
            0.0,
        )
        assertNull(HydrationStore.totalForDay(fixture.repo, "2026-09-11"))
    }

    @Test
    fun explicitDayMutationsNeverChangeAnotherDay() = runBlocking {
        val fixture = fixture(
            seed = listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-09", HydrationStore.KEY, 237.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-10", HydrationStore.KEY, 500.0),
            ),
        )

        assertEquals(437.0, HydrationStore.logForDay(fixture.repo, 200, "2026-09-09")!!, 0.0)
        assertEquals(337.0, HydrationStore.removeForDay(fixture.repo, 100, "2026-09-09")!!, 0.0)
        assertEquals(750.0, HydrationStore.setForDay(fixture.repo, 750.0, "2026-09-09")!!, 0.0)

        assertEquals(750.0, HydrationStore.totalForDay(fixture.repo, "2026-09-09")!!, 0.0)
        assertEquals(500.0, HydrationStore.totalForDay(fixture.repo, "2026-09-10")!!, 0.0)
    }

    @Test
    fun historyIsAnchoredToTheSelectedDayAndExcludesLaterData() = runBlocking {
        val fixture = fixture(
            seed = listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-08", HydrationStore.KEY, 100.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-09", HydrationStore.KEY, 200.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-10", HydrationStore.KEY, 300.0),
                MetricSeriesRow(HydrationStore.SOURCE_ID, "2026-09-11", HydrationStore.KEY, 400.0),
            ),
        )

        assertEquals(
            listOf(
                "2026-09-08" to 100.0,
                "2026-09-09" to 200.0,
                "2026-09-10" to 300.0,
            ),
            HydrationStore.historyThroughDay(
                repo = fixture.repo,
                days = 3,
                throughDay = "2026-09-10",
            ),
        )
    }

    @Test
    fun historicalTimestampStaysInsideSelectedDayAcrossDstGap() {
        val zone = ZoneId.of("America/New_York")
        val now = Instant.parse("2026-09-11T06:30:00Z").epochSecond

        val loggedAt = HydrationStore.loggedAtForDay(
            day = "2026-03-08",
            nowSec = now,
            zoneId = zone,
        )

        assertEquals("2026-03-08", Instant.ofEpochSecond(loggedAt).atZone(zone).toLocalDate().toString())
    }

    @Test
    fun malformedLegacyScalarRemainsVisibleButCannotBeMutated() = runBlocking {
        val day = "2026-09-10"
        val fixture = fixture(
            seed = listOf(
                MetricSeriesRow(HydrationStore.SOURCE_ID, day, HydrationStore.KEY, 500.5),
            ),
        )

        assertEquals(500.5, HydrationStore.totalForDay(fixture.repo, day)!!, 0.0)
        assertFails { HydrationStore.logForDay(fixture.repo, 200, day) }
        assertEquals(500.5, HydrationStore.totalForDay(fixture.repo, day)!!, 0.0)
        assertTrue(fixture.entries.isEmpty())
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
