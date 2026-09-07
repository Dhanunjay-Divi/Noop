package com.noop.analytics

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WhoopReferenceCalibrationInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var repository: WhoopRepository

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java).build()
        repository = WhoopRepository(database)
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun loaderKeepsOfficialAndComputedNamespacesSeparateAndAudited() = runBlocking {
        val official = WhoopRepository.WHOOP_SOURCE
        val computed = repository.computedDeviceId(official)
        repository.upsertMetricSeries(
            listOf(
                MetricSeriesRow(official, "2026-09-05", "recovery", 70.0),
                MetricSeriesRow(official, "2026-09-06", "recovery", 71.0),
            ),
        )
        repository.upsertDailyMetrics(
            listOf(
                DailyMetric(computed, "2026-09-05", recovery = 60.0),
                DailyMetric(computed, "2026-09-06", recovery = 61.0),
            ),
        )

        val report = WhoopReferenceCalibration.report(
            repo = repository,
            metric = WhoopComparableMetric.RECOVERY_SCORE,
            importedDeviceId = official,
            computedDeviceId = computed,
            from = "2026-09-05",
            to = "2026-09-06",
            noopAlgorithmVersion = NoopScoreAlgorithmRevision.CHARGE,
            verifiedOfficialReferenceDays = setOf("2026-09-06"),
            verifiedCurrentNoopDays = setOf("2026-09-05", "2026-09-06"),
            whoopImportSchemaRevision = "whoop-csv-import-v5",
        )

        assertEquals(listOf("2026-09-06"), report.pairs.map { it.day })
        assertEquals(1, report.audit.unverifiedStoredOfficialDays)
        assertEquals(0, report.audit.unverifiedStoredNoopDays)
        assertEquals(-10.0, report.statistics?.bias ?: Double.NaN, 0.0)
        assertTrue(
            report.pairs.single().official.provenance is
                ReferenceMetricProvenance.OfficialExport,
        )
        assertTrue(
            report.pairs.single().noop.provenance is
                ReferenceMetricProvenance.NoopOnDevice,
        )
    }

    @Test
    fun loaderComparesSleepEfficiencyOnPercentScale() = runBlocking {
        val official = WhoopRepository.WHOOP_SOURCE
        val computed = repository.computedDeviceId(official)
        repository.upsertMetricSeries(
            listOf(MetricSeriesRow(official, "2026-09-06", "sleep_efficiency", 0.91)),
        )
        repository.upsertDailyMetrics(
            listOf(
                DailyMetric(
                    computed,
                    "2026-09-06",
                    totalSleepMin = 420.0,
                    efficiency = 0.91,
                    deepMin = 75.0,
                    remMin = 90.0,
                    lightMin = 255.0,
                ),
            ),
        )

        val report = WhoopReferenceCalibration.report(
            repo = repository,
            metric = WhoopComparableMetric.SLEEP_EFFICIENCY_PERCENT,
            importedDeviceId = official,
            computedDeviceId = computed,
            from = "2026-09-06",
            to = "2026-09-06",
            noopAlgorithmVersion = NoopScoreAlgorithmRevision.REST,
            verifiedOfficialReferenceDays = setOf("2026-09-06"),
            verifiedCurrentNoopDays = setOf("2026-09-06"),
        )

        assertEquals(91.0, report.pairs.single().official.value, 1e-12)
        assertEquals(91.0, report.pairs.single().noop.value, 1e-12)
        assertEquals(0.0, report.statistics?.bias ?: Double.NaN, 1e-12)
    }
}
