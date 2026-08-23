package com.noop.data

import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Focused contract tests for the isolated, local period-start metric series. */
class CycleTrackingStoreTest {

    private data class Fixture(
        val repo: WhoopRepository,
        val rows: MutableMap<Triple<String, String, String>, MetricSeriesRow>,
    )

    private fun fixture(seed: List<MetricSeriesRow> = emptyList()): Fixture {
        val rows = seed.associateByTo(linkedMapOf()) { Triple(it.deviceId, it.day, it.key) }
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "metricSeries" -> {
                    val a = args!!
                    val source = a[0] as String
                    val key = a[1] as String
                    val from = a[2] as String
                    val to = a[3] as String
                    rows.values
                        .filter { it.deviceId == source && it.key == key && it.day >= from && it.day <= to }
                        .sortedBy { it.day }
                }
                "upsertMetricSeries" -> {
                    @Suppress("UNCHECKED_CAST")
                    val incoming = args!![0] as List<MetricSeriesRow>
                    incoming.forEach { rows[Triple(it.deviceId, it.day, it.key)] = it }
                    Unit
                }
                "deleteMetricSeriesPoint" -> {
                    val a = args!!
                    rows.remove(Triple(a[0] as String, a[1] as String, a[2] as String))
                    Unit
                }
                "deleteMetricSeries" -> {
                    val a = args!!
                    val source = a[0] as String
                    val key = a[1] as String
                    val doomed = rows.filterKeys { it.first == source && it.third == key }.keys
                    doomed.forEach(rows::remove)
                    doomed.size
                }
                else -> throw UnsupportedOperationException("cycle store must not call ${method.name}")
            }
        } as WhoopDao
        return Fixture(WhoopRepository(dao), rows)
    }

    private fun point(source: String, day: String, key: String, value: Double) =
        MetricSeriesRow(deviceId = source, day = day, key = key, value = value)

    @Test
    fun logListDeleteAndDeleteAllStayInsideTheCycleSeries() = runBlocking {
        val unrelatedCycleKey = point(CycleTrackingStore.SOURCE_ID, "2026-07-01", "note", 9.0)
        val unrelatedSource = point("my-whoop", "2026-07-01", CycleTrackingStore.PERIOD_START_KEY, 1.0)
        val f = fixture(listOf(unrelatedCycleKey, unrelatedSource))

        assertTrue(f.repo.logPeriodStart("2026-07-01"))
        assertTrue("re-logging is idempotent", f.repo.logPeriodStart("2026-07-01"))
        assertTrue(f.repo.logPeriodStart("2026-08-03"))
        assertEquals(listOf("2026-07-01", "2026-08-03"), f.repo.periodStarts())

        assertTrue(f.repo.deletePeriodStart("2026-07-01"))
        assertTrue("deleting an already-absent valid day is idempotent", f.repo.deletePeriodStart("2026-07-01"))
        assertEquals(listOf("2026-08-03"), f.repo.periodStarts())

        assertTrue(f.repo.deleteAllPeriodStarts())
        assertTrue(f.repo.periodStarts().isEmpty())
        assertEquals(unrelatedCycleKey, f.rows[Triple(unrelatedCycleKey.deviceId, unrelatedCycleKey.day, unrelatedCycleKey.key)])
        assertEquals(unrelatedSource, f.rows[Triple(unrelatedSource.deviceId, unrelatedSource.day, unrelatedSource.key)])
    }

    @Test
    fun listIncludesOnlyValidLoggedPeriodRowsWithinTheRequestedRange() = runBlocking {
        val f = fixture(
            listOf(
                point(CycleTrackingStore.SOURCE_ID, "2026-06-01", CycleTrackingStore.PERIOD_START_KEY, 1.0),
                point(CycleTrackingStore.SOURCE_ID, "2026-07-01", CycleTrackingStore.PERIOD_START_KEY, 0.0),
                point(CycleTrackingStore.SOURCE_ID, "2026-08-01", CycleTrackingStore.PERIOD_START_KEY, 2.0),
                point(CycleTrackingStore.SOURCE_ID, "not-a-day", CycleTrackingStore.PERIOD_START_KEY, 1.0),
            )
        )

        assertEquals(
            listOf("2026-08-01"),
            f.repo.periodStarts(from = "2026-07-01", to = "2026-09-01"),
        )
    }

    @Test
    fun malformedOrImpossibleDaysNeverReachTheDatabase() = runBlocking {
        val invalid = listOf(
            "", "2026-2-01", "2026-02-29", "2026-13-01", "2026-01-00", "../../secret", "2026-01-01Z",
        )
        invalid.forEach { assertFalse("accepted invalid day $it", CycleTrackingStore.isValidLocalDayKey(it)) }
        assertTrue(CycleTrackingStore.isValidLocalDayKey("2024-02-29"))

        val f = fixture()
        invalid.forEach {
            assertFalse(f.repo.logPeriodStart(it))
            assertFalse(f.repo.deletePeriodStart(it))
        }
        assertTrue(f.rows.isEmpty())
    }

    @Test
    fun dailyDetailsRoundTripAndKeepExplicitNoFlowDistinctFromMissing() = runBlocking {
        val f = fixture()
        val symptoms = setOf(
            CycleTrackingStore.Symptom.CRAMPS,
            CycleTrackingStore.Symptom.FATIGUE,
            CycleTrackingStore.Symptom.BACK_PAIN,
        )
        assertTrue(
            f.repo.saveCycleDailyLog(
                "2026-08-23",
                CycleTrackingStore.Flow.NONE,
                symptoms,
            )
        )
        assertEquals(
            listOf(
                CycleTrackingStore.DailyLog(
                    "2026-08-23",
                    CycleTrackingStore.Flow.NONE,
                    symptoms,
                )
            ),
            f.repo.cycleDailyLogs(),
        )
    }

    @Test
    fun clearingDailyDetailsPhysicallyDeletesOnlyTheDetailRow() = runBlocking {
        val f = fixture()
        assertTrue(f.repo.logPeriodStart("2026-08-23"))
        assertTrue(
            f.repo.saveCycleDailyLog(
                "2026-08-23",
                CycleTrackingStore.Flow.MEDIUM,
                setOf(CycleTrackingStore.Symptom.BLOATING),
            )
        )
        assertTrue(f.repo.saveCycleDailyLog("2026-08-23", null, emptySet()))

        assertTrue(f.repo.cycleDailyLogs().isEmpty())
        assertEquals(listOf("2026-08-23"), f.repo.periodStarts())
    }

    @Test
    fun dailyDetailDecoderRejectsMalformedAndUnknownBits() {
        assertEquals(null, CycleTrackingStore.decode("not-a-day", 1.0))
        assertEquals(null, CycleTrackingStore.decode("2026-08-23", Double.NaN))
        assertEquals(null, CycleTrackingStore.decode("2026-08-23", 1.5))
        assertEquals(
            null,
            CycleTrackingStore.decode("2026-08-23", ((1 shl 30) or 1).toDouble()),
        )
    }
}
