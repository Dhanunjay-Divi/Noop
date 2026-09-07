package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.time.LocalDate
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComputedScoreReconciliationInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var dao: WhoopDao
    private lateinit var repository: WhoopRepository

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java).build()
        dao = database.whoopDao()
        repository = WhoopRepository(database)
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun exactWindowReconciliationPublishesFreshRowsAndPreservesOtherOwners() = runBlocking {
        val computed = "compatible-band-noop"
        val imported = "compatible-band"
        val managed = setOf("sleep_performance", "rest_confidence", "rest_evidence_flags")
        dao.upsertDailyMetrics(
            listOf(
                DailyMetric(computed, "2026-05-01", recovery = 51.0),
                DailyMetric(computed, "2026-05-02", recovery = 52.0),
                DailyMetric(computed, "2026-05-03", recovery = 53.0),
                DailyMetric(computed, "2026-05-04", recovery = 54.0),
                DailyMetric(imported, "2026-05-02", recovery = 92.0),
            ),
        )
        dao.upsertMetricSeries(
            listOf(
                MetricSeriesRow(computed, "2026-05-01", "sleep_performance", 71.0),
                MetricSeriesRow(computed, "2026-05-02", "sleep_performance", 72.0),
                MetricSeriesRow(computed, "2026-05-02", "rest_confidence", 1.0),
                MetricSeriesRow(computed, "2026-05-02", "sleep_debt_min", 20.0),
                MetricSeriesRow(computed, "2026-05-03", "rest_evidence_flags", 3.0),
                MetricSeriesRow(computed, "2026-05-04", "sleep_performance", 74.0),
                MetricSeriesRow(imported, "2026-05-02", "sleep_performance", 95.0),
            ),
        )

        val receipt = repository.reconcileComputedScoreRange(
            deviceId = computed,
            fromDay = "2026-05-02",
            toDay = "2026-05-03",
            dailyRows = listOf(DailyMetric(computed, "2026-05-03", recovery = 83.0)),
            managedRestKeys = managed,
            restRows = listOf(
                MetricSeriesRow(computed, "2026-05-03", "sleep_performance", 84.0),
                MetricSeriesRow(computed, "2026-05-03", "rest_confidence", 2.0),
                MetricSeriesRow(computed, "2026-05-03", "rest_evidence_flags", 7.0),
            ),
        )

        assertEquals(setOf("2026-05-03"), receipt)
        assertEquals(
            listOf("2026-05-01", "2026-05-03", "2026-05-04"),
            dao.dailyMetricsRange(computed, "2026-05-01", "2026-05-04").map { it.day },
        )
        assertEquals(
            83.0,
            dao.dailyMetricsRange(computed, "2026-05-03", "2026-05-03").single().recovery!!,
            0.0,
        )
        assertEquals(
            listOf(92.0),
            dao.dailyMetricsRange(imported, "2026-05-02", "2026-05-02").map { it.recovery },
        )
        assertTrue(
            dao.metricSeries(computed, "sleep_performance", "2026-05-02", "2026-05-02")
                .isEmpty(),
        )
        assertEquals(
            84.0,
            dao.metricSeries(computed, "sleep_performance", "2026-05-03", "2026-05-03")
                .single().value,
            0.0,
        )
        assertEquals(
            1,
            dao.metricSeries(computed, "sleep_debt_min", "2026-05-02", "2026-05-02").size,
        )
        assertEquals(
            1,
            dao.metricSeries(computed, "sleep_performance", "2026-05-04", "2026-05-04").size,
        )
        assertEquals(
            1,
            dao.metricSeries(imported, "sleep_performance", "2026-05-02", "2026-05-02").size,
        )
    }

    @Test
    fun invalidOwnershipFailsBeforeAnyMutation() = runBlocking {
        val computed = "compatible-band-noop"
        dao.upsertDailyMetrics(listOf(DailyMetric(computed, "2026-05-02", recovery = 52.0)))

        val failure = runCatching {
            repository.reconcileComputedScoreRange(
                deviceId = computed,
                fromDay = "2026-05-02",
                toDay = "2026-05-03",
                dailyRows = listOf(DailyMetric("other-noop", "2026-05-03", recovery = 83.0)),
                managedRestKeys = setOf("sleep_performance"),
                restRows = emptyList(),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertEquals(
            52.0,
            dao.dailyMetricsRange(computed, "2026-05-02", "2026-05-02").single().recovery!!,
            0.0,
        )
    }

    @Test
    fun orphanRestEvidenceFailsBeforeAnyMutation() = runBlocking {
        val computed = "compatible-band-noop"
        dao.upsertDailyMetrics(listOf(DailyMetric(computed, "2026-05-02", recovery = 52.0)))
        dao.upsertMetricSeries(
            listOf(MetricSeriesRow(computed, "2026-05-02", "sleep_performance", 72.0)),
        )

        val failure = runCatching {
            repository.reconcileComputedScoreRange(
                deviceId = computed,
                fromDay = "2026-05-02",
                toDay = "2026-05-03",
                dailyRows = listOf(DailyMetric(computed, "2026-05-03", recovery = 83.0)),
                managedRestKeys = setOf("sleep_performance"),
                restRows = listOf(
                    MetricSeriesRow(computed, "2026-05-02", "sleep_performance", 84.0),
                ),
            )
        }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertEquals(
            52.0,
            dao.dailyMetricsRange(computed, "2026-05-02", "2026-05-02").single().recovery!!,
            0.0,
        )
        assertEquals(
            72.0,
            dao.metricSeries(computed, "sleep_performance", "2026-05-02", "2026-05-02")
                .single().value,
            0.0,
        )
    }

    @Test
    fun malformedDaysAndManagedKeysFailBeforeAnyMutation() = runBlocking {
        val computed = "compatible-band-noop"
        dao.upsertDailyMetrics(listOf(DailyMetric(computed, "2026-05-02", recovery = 52.0)))
        dao.upsertMetricSeries(
            listOf(MetricSeriesRow(computed, "2026-05-02", "sleep_performance", 72.0)),
        )

        val malformedDayFailure = runCatching {
            repository.reconcileComputedScoreRange(
                deviceId = computed,
                fromDay = "2026-02-30",
                toDay = "2026-05-03",
                dailyRows = listOf(DailyMetric(computed, "2026-05-03", recovery = 83.0)),
                managedRestKeys = setOf("sleep_performance"),
                restRows = emptyList(),
            )
        }.exceptionOrNull()
        val malformedKeyFailure = runCatching {
            repository.reconcileComputedScoreRange(
                deviceId = computed,
                fromDay = "2026-05-02",
                toDay = "2026-05-03",
                dailyRows = listOf(DailyMetric(computed, "2026-05-03", recovery = 83.0)),
                managedRestKeys = setOf("sleep-performance"),
                restRows = emptyList(),
            )
        }.exceptionOrNull()

        assertTrue(malformedDayFailure is IllegalArgumentException)
        assertTrue(malformedKeyFailure is IllegalArgumentException)
        assertEquals(
            52.0,
            dao.dailyMetricsRange(computed, "2026-05-02", "2026-05-02").single().recovery!!,
            0.0,
        )
        assertEquals(
            72.0,
            dao.metricSeries(computed, "sleep_performance", "2026-05-02", "2026-05-02")
                .single().value,
            0.0,
        )
    }

    @Test
    fun lateWriteFailureRollsBackDailyAndRestWindowTogether() = runBlocking {
        val computed = "compatible-band-noop"
        val managed = setOf("sleep_performance", "rest_confidence", "rest_evidence_flags")
        dao.upsertDailyMetrics(
            listOf(
                DailyMetric(computed, "2026-05-02", recovery = 52.0),
                DailyMetric(computed, "2026-05-03", recovery = 53.0),
            ),
        )
        dao.upsertMetricSeries(
            listOf(
                MetricSeriesRow(computed, "2026-05-02", "sleep_performance", 72.0),
                MetricSeriesRow(computed, "2026-05-03", "rest_confidence", 1.0),
            ),
        )
        database.openHelper.writableDatabase.execSQL(
            """
            CREATE TRIGGER fail_computed_rest_insert
            BEFORE INSERT ON metricSeries
            WHEN NEW.`key` = 'rest_confidence'
            BEGIN
                SELECT RAISE(ABORT, 'forced reconciliation failure');
            END
            """.trimIndent(),
        )

        val failure = runCatching {
            repository.reconcileComputedScoreRange(
                deviceId = computed,
                fromDay = "2026-05-02",
                toDay = "2026-05-03",
                dailyRows = listOf(DailyMetric(computed, "2026-05-03", recovery = 83.0)),
                managedRestKeys = managed,
                restRows = listOf(
                    MetricSeriesRow(computed, "2026-05-03", "sleep_performance", 84.0),
                    MetricSeriesRow(computed, "2026-05-03", "rest_confidence", 2.0),
                ),
            )
        }.exceptionOrNull()

        assertTrue(failure != null)
        val daily = dao.dailyMetricsRange(computed, "2026-05-02", "2026-05-03")
        assertEquals(listOf("2026-05-02", "2026-05-03"), daily.map { it.day })
        assertEquals(listOf(52.0, 53.0), daily.map { it.recovery })
        assertEquals(
            72.0,
            dao.metricSeries(computed, "sleep_performance", "2026-05-02", "2026-05-02")
                .single().value,
            0.0,
        )
        assertEquals(
            1.0,
            dao.metricSeries(computed, "rest_confidence", "2026-05-03", "2026-05-03")
                .single().value,
            0.0,
        )
    }

    @Test
    fun fullHistoryWindowDoesNotDependOnSqlVariableLimit() = runBlocking {
        val computed = "compatible-band-noop"
        val first = LocalDate.of(2023, 1, 1)
        val rows = (0 until 1_200).map { offset ->
            DailyMetric(
                deviceId = computed,
                day = first.plusDays(offset.toLong()).toString(),
                recovery = (offset % 100).toDouble(),
            )
        }
        val from = rows.first().day
        val to = rows.last().day

        val receipt = repository.reconcileComputedScoreRange(
            deviceId = computed,
            fromDay = from,
            toDay = to,
            dailyRows = rows,
            managedRestKeys = setOf("sleep_performance"),
            restRows = emptyList(),
        )

        assertEquals(1_200, receipt.size)
        assertEquals(
            1_200,
            dao.dailyMetricsRange(computed, from, to).size,
        )
    }
}
