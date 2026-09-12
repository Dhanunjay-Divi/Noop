package com.noop.data

import android.content.Context
import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HydrationEntryMigrationInstrumentedTest {
    @get:Rule
    val migrationHelper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        WhoopDatabase::class.java,
    )

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @After
    fun deleteDatabase() {
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun migrationCreatesOnlyValidLocalLegacyEntriesAndPreservesEveryScalar() {
        val rows = listOf(
            arrayOf<Any?>("hydration", "2026-09-08", "hydration", 500.0),
            arrayOf<Any?>("hydration", "2026-09-09", "hydration", 0.0),
            arrayOf<Any?>("hydration", "2026-09-10", "hydration", 500.5),
            arrayOf<Any?>("hydration", "2026-09-11", "hydration", 10_001.0),
            arrayOf<Any?>("hydration", "not-a-day", "hydration", 237.0),
            arrayOf<Any?>("health-connect", "2026-09-08", "hydration", 700.0),
        )
        migrationHelper.createDatabase(DATABASE_NAME, 48).use { database ->
            rows.forEach { values ->
                database.execSQL(
                    "INSERT INTO `metricSeries` (`deviceId`,`day`,`key`,`value`) VALUES (?,?,?,?)",
                    values,
                )
            }
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            49,
            true,
            WhoopDatabase.MIGRATION_48_49,
        ).use { database ->
            assertEquals(49, database.version)
            database.query(
                "SELECT `id`,`deviceId`,`day`,`amountML`,`loggedAt` FROM `hydrationEntry`",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("hydration", cursor.getString(1))
                assertEquals("2026-09-08", cursor.getString(2))
                assertEquals(500, cursor.getInt(3))
                UUID.fromString(cursor.getString(0))
                val zoneId = ZoneId.systemDefault()
                val loggedAt = cursor.getLong(4)
                assertEquals(
                    requireNotNull(
                        WhoopDatabase.legacyHydrationLoggedAt("2026-09-08", zoneId),
                    ),
                    loggedAt,
                )
                val local = Instant.ofEpochSecond(loggedAt).atZone(zoneId)
                assertEquals("2026-09-08", local.toLocalDate().toString())
                assertEquals(LocalTime.NOON, local.toLocalTime())
                assertTrue(!cursor.moveToNext())
            }
            database.query("SELECT COUNT(*) FROM `metricSeries`").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(rows.size, cursor.getInt(0))
            }
            database.query(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' " +
                    "AND name LIKE '%hydrationEntry%'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
        }
    }

    private companion object {
        const val DATABASE_NAME = "hydration-entry-migration-test"
    }
}
