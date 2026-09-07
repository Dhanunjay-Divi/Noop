package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MetricSeriesValidityInstrumentedTest {
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
    fun repositoryDropsNonFiniteGenericSeriesValues() = runBlocking {
        val source = "compatible-band-noop"

        repository.upsertMetricSeries(
            listOf(
                MetricSeriesRow(source, "2026-09-06", "fitness_age", Double.NaN),
                MetricSeriesRow(source, "2026-09-07", "fitness_age", Double.POSITIVE_INFINITY),
            ),
        )

        assertTrue(dao.metricSeries(source, "fitness_age", "2026-09-06", "2026-09-07").isEmpty())
    }

    @Test
    fun latestReadSkipsInvalidLegacyUnitRowAndReturnsNewestValidValue() = runBlocking {
        val active = "compatible-band"
        val computed = "$active-noop"
        dao.upsertMetricSeries(
            listOf(
                MetricSeriesRow(computed, "2026-09-06", "sleep_efficiency", 0.91),
                MetricSeriesRow(computed, "2026-09-07", "sleep_efficiency", 200.0),
            ),
        )

        val latest = repository.latestMetricComputedUnion(active, "sleep_efficiency")

        assertEquals("2026-09-06", latest?.day)
        assertEquals(0.91, latest?.value ?: Double.NaN, 0.0)
    }
}
