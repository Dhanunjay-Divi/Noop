package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.analytics.HydrationStore
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HydrationEntryPersistenceInstrumentedTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @After
    fun deleteDatabase() {
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun entriesPersistAcrossReopenAndExactHistoricalEditsLeaveTodayUntouched() = runBlocking {
        val historical = "2026-09-09"
        val today = "2026-09-11"
        var database = openDatabase()
        var repository = WhoopRepository(database)

        val historicalEntry = entry(historical, 237)
        repository.addHydrationEntry(historicalEntry)
        repository.addHydrationEntry(entry(today, 500))
        database.close()

        database = openDatabase()
        repository = WhoopRepository(database)
        assertEquals(listOf(historicalEntry), repository.hydrationEntries("hydration", historical))

        repository.updateHydrationEntry(historicalEntry.copy(amountML = 300))
        assertEquals(
            300.0,
            repository.metricSeries("hydration", "hydration", historical, historical).single().value,
            0.0,
        )
        assertEquals(
            500.0,
            repository.metricSeries("hydration", "hydration", today, today).single().value,
            0.0,
        )
        repository.deleteHydrationEntry(historicalEntry.id, "hydration", historical)
        assertTrue(repository.hydrationEntries("hydration", historical).isEmpty())
        assertEquals(
            500.0,
            repository.metricSeries("hydration", "hydration", today, today).single().value,
            0.0,
        )
        database.close()
    }

    @Test
    fun concurrentAddsRemainAtomicAndHealthConnectUsesMaxMerge() = runBlocking(Dispatchers.Default) {
        val database = openDatabase()
        val repository = WhoopRepository(database)
        val day = "2026-09-10"

        listOf(
            async { repository.addHydrationEntry(entry(day, 237)) },
            async { repository.addHydrationEntry(entry(day, 500)) },
        ).awaitAll()
        repository.upsertMetricSeries(
            listOf(MetricSeriesRow(WhoopRepository.HEALTH_CONNECT_SOURCE, day, "hydration", 900.0)),
        )

        assertEquals(2, repository.hydrationEntries("hydration", day).size)
        assertEquals(
            737.0,
            repository.metricSeries("hydration", "hydration", day, day).single().value,
            0.0,
        )
        val reading = requireNotNull(HydrationStore.readingForDay(repository, day))
        assertEquals(900.0, reading.valueMl, 0.0)
        assertEquals(HydrationStore.ReadingSource.BOTH, reading.source)

        repository.clearHydrationEntries("hydration", day)
        assertEquals(900.0, requireNotNull(HydrationStore.readingForDay(repository, day)).valueMl, 0.0)
        database.close()
    }

    @Test
    fun projectionFailureRollsBackEntryAndMalformedLegacyScalarFailsClosed() = runBlocking {
        val database = openDatabase()
        val repository = WhoopRepository(database)
        val day = "2026-09-10"
        database.openHelper.writableDatabase.execSQL(
            """
                CREATE TRIGGER `fail_hydration_projection`
                BEFORE INSERT ON `metricSeries`
                WHEN NEW.`deviceId` = 'hydration' AND NEW.`key` = 'hydration'
                BEGIN
                    SELECT RAISE(ABORT, 'synthetic hydration projection failure');
                END
            """.trimIndent(),
        )

        assertFails { repository.addHydrationEntry(entry(day, 500)) }
        assertTrue(repository.hydrationEntries("hydration", day).isEmpty())
        assertTrue(repository.metricSeries("hydration", "hydration", day, day).isEmpty())

        database.openHelper.writableDatabase.execSQL("DROP TRIGGER `fail_hydration_projection`")
        repository.upsertMetricSeries(
            listOf(MetricSeriesRow("hydration", day, "hydration", 500.5)),
        )
        assertFails { repository.addHydrationEntry(entry(day, 200)) }
        assertTrue(repository.hydrationEntries("hydration", day).isEmpty())
        assertEquals(
            500.5,
            repository.metricSeries("hydration", "hydration", day, day).single().value,
            0.0,
        )
        database.close()
    }

    private fun openDatabase(): WhoopDatabase =
        Room.databaseBuilder(context, WhoopDatabase::class.java, DATABASE_NAME).build()

    private fun entry(day: String, amountML: Int): HydrationEntryRow {
        val loggedAt = LocalDate.parse(day).atTime(12, 0).atZone(ZoneId.systemDefault()).toEpochSecond()
        return HydrationEntryRow(
            id = UUID.randomUUID().toString(),
            deviceId = "hydration",
            day = day,
            amountML = amountML,
            loggedAt = loggedAt,
        )
    }

    private suspend fun assertFails(block: suspend () -> Unit) {
        var failed = false
        try {
            block()
        } catch (_: Throwable) {
            failed = true
        }
        assertTrue("expected transactional hydration failure", failed)
    }

    private companion object {
        const val DATABASE_NAME = "hydration-entry-persistence-test"
    }
}
