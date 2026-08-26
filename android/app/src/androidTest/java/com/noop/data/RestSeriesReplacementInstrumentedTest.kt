package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.ScoreConfidence
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@RunWith(AndroidJUnit4::class)
class RestSeriesReplacementInstrumentedTest {
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
    fun emptyRestReplacementClearsExactRangeAndPreservesEverythingElse() = runBlocking {
        val deviceId = "my-whoop-noop"
        val managed = setOf("sleep_performance", "rest_confidence", "rest_evidence_flags")
        dao.upsertMetricSeries(
            listOf(
                MetricSeriesRow(deviceId, "2026-05-01", "sleep_performance", 80.0),
                MetricSeriesRow(deviceId, "2026-05-02", "sleep_performance", 81.0),
                MetricSeriesRow(deviceId, "2026-05-02", "rest_confidence", 2.0),
                MetricSeriesRow(deviceId, "2026-05-02", "rest_evidence_flags", 55.0),
                MetricSeriesRow(deviceId, "2026-05-02", "sleep_debt_min", 30.0),
                MetricSeriesRow(deviceId, "2026-05-03", "rest_confidence", 1.0),
                MetricSeriesRow("other-device", "2026-05-02", "rest_confidence", 2.0),
            )
        )

        repository.replaceMetricSeriesRange(
            deviceId = deviceId,
            fromDay = "2026-05-02",
            toDay = "2026-05-02",
            managedKeys = managed,
            rows = emptyList(),
        )

        for (key in managed) {
            assertTrue(dao.metricSeries(deviceId, key, "2026-05-02", "2026-05-02").isEmpty())
        }
        assertEquals(
            1,
            dao.metricSeries(deviceId, "sleep_performance", "2026-05-01", "2026-05-01").size,
        )
        assertEquals(
            1,
            dao.metricSeries(deviceId, "rest_confidence", "2026-05-03", "2026-05-03").size,
        )
        assertEquals(
            1,
            dao.metricSeries(deviceId, "sleep_debt_min", "2026-05-02", "2026-05-02").size,
        )
        assertEquals(
            1,
            dao.metricSeries("other-device", "rest_confidence", "2026-05-02", "2026-05-02").size,
        )
    }

    @Test
    fun transientEmptyAnalyticsPassPreservesLastKnownRestSeries() = runBlocking {
        val nowSeconds = System.currentTimeMillis() / 1_000L
        val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(nowSeconds * 1_000L))
        val deviceId = "my-whoop-noop"
        dao.upsertMetricSeries(
            listOf(
                MetricSeriesRow(
                    deviceId,
                    day,
                    ScoreConfidence.sleepPerformanceSeriesKey,
                    82.0,
                ),
                MetricSeriesRow(
                    deviceId,
                    day,
                    ScoreConfidence.restConfidenceSeriesKey,
                    ScoreConfidence.SOLID.persistedValue,
                ),
                MetricSeriesRow(
                    deviceId,
                    day,
                    ScoreConfidence.restEvidenceSeriesKey,
                    55.0,
                ),
            )
        )

        IntelligenceEngine.analyzeRecent(
            repo = repository,
            maxDays = 1,
            nowSeconds = nowSeconds,
        )

        assertEquals(
            listOf(82.0),
            dao.metricSeries(
                deviceId,
                ScoreConfidence.sleepPerformanceSeriesKey,
                day,
                day,
            ).map { it.value },
        )
        assertEquals(
            listOf(ScoreConfidence.SOLID.persistedValue),
            dao.metricSeries(
                deviceId,
                ScoreConfidence.restConfidenceSeriesKey,
                day,
                day,
            ).map { it.value },
        )
        assertEquals(
            listOf(55.0),
            dao.metricSeries(
                deviceId,
                ScoreConfidence.restEvidenceSeriesKey,
                day,
                day,
            ).map { it.value },
        )
    }
}
