package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

    @Test
    fun migration52To53MaterializesOversizedScalarWithoutDuplicatingEditableRows() {
        migrationHelper.createDatabase(DATABASE_NAME, 52).use { database ->
            database.execSQL(
                """
                    INSERT INTO `metricSeries` (`deviceId`,`day`,`key`,`value`)
                    VALUES
                        ('hydration','2026-09-08','hydration',12000),
                        ('hydration','2026-09-09','hydration',500),
                        ('hydration','2026-09-10','hydration',650)
                """.trimIndent(),
            )
            database.execSQL(
                """
                    INSERT INTO `hydrationEntry` (`id`,`deviceId`,`day`,`amountML`,`loggedAt`)
                    VALUES (
                        '719c47b0-7ed1-44a2-94b5-aa6b926e4d5b',
                        'hydration',
                        '2026-09-10',
                        650,
                        1789000000
                    )
                """.trimIndent(),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            53,
            true,
            WhoopDatabase.MIGRATION_52_53,
        ).use { database ->
            assertEquals(53, database.version)
            database.query(
                """
                    SELECT `id`,`day`,`amountML`
                    FROM `hydrationEntry`
                    ORDER BY `day`
                """.trimIndent(),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(
                    cursor.getString(0).startsWith(
                        HydrationEntryContract.LEGACY_OVERSIZED_ID_PREFIX,
                    ),
                )
                assertEquals("2026-09-08", cursor.getString(1))
                assertEquals(12_000, cursor.getInt(2))

                assertTrue(cursor.moveToNext())
                assertEquals("719c47b0-7ed1-44a2-94b5-aa6b926e4d5b", cursor.getString(0))
                assertEquals("2026-09-10", cursor.getString(1))
                assertEquals(650, cursor.getInt(2))
                assertTrue(!cursor.moveToNext())
            }
            database.query("SELECT COUNT(*) FROM `metricSeries`").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(3, cursor.getInt(0))
            }
        }
    }

    @Test
    fun migratedOversizedEntryCanBeCorrectedAndClearedThroughRoomTransactions() = runBlocking {
        migrationHelper.createDatabase(DATABASE_NAME, 52).use { database ->
            database.execSQL(
                """
                    INSERT INTO `metricSeries` (`deviceId`,`day`,`key`,`value`)
                    VALUES ('hydration','2026-09-08','hydration',12000)
                """.trimIndent(),
            )
        }
        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            53,
            true,
            WhoopDatabase.MIGRATION_52_53,
        ).close()
        val database = Room.databaseBuilder(
            context,
            WhoopDatabase::class.java,
            DATABASE_NAME,
        ).build()
        try {
            val dao = database.whoopDao()
            val legacy = dao.hydrationEntries("hydration", "2026-09-08").single()
            assertTrue(HydrationEntryContract.isLegacyOversized(legacy))

            val rejected = runCatching {
                dao.updateHydrationEntry(legacy.copy(amountML = 11_000))
            }
            assertTrue(rejected.isFailure)
            assertEquals(
                12_000.0,
                dao.hydrationProjectionValue(
                    "hydration",
                    "2026-09-08",
                    HydrationEntryContract.METRIC_KEY,
                ),
            )

            installProjectionFailureTrigger(database)
            val failedCorrection = runCatching {
                dao.updateHydrationEntry(legacy.copy(amountML = 9_000))
            }
            assertTrue(failedCorrection.isFailure)
            assertEquals(
                legacy,
                dao.hydrationEntries("hydration", "2026-09-08").single(),
            )
            assertEquals(
                12_000.0,
                dao.hydrationProjectionValue(
                    "hydration",
                    "2026-09-08",
                    HydrationEntryContract.METRIC_KEY,
                ),
            )
            removeProjectionFailureTrigger(database)

            val corrected = dao.updateHydrationEntry(legacy.copy(amountML = 9_000))
            assertTrue(corrected.changed)
            assertEquals(9_000.0, corrected.totalML)
            assertEquals(
                9_000.0,
                dao.hydrationProjectionValue(
                    "hydration",
                    "2026-09-08",
                    HydrationEntryContract.METRIC_KEY,
                ),
            )

            installProjectionFailureTrigger(database)
            val failedDelete = runCatching {
                dao.deleteHydrationEntry(
                    legacy.id,
                    "hydration",
                    "2026-09-08",
                )
            }
            assertTrue(failedDelete.isFailure)
            assertEquals(
                9_000,
                dao.hydrationEntries("hydration", "2026-09-08").single().amountML,
            )
            assertEquals(
                9_000.0,
                dao.hydrationProjectionValue(
                    "hydration",
                    "2026-09-08",
                    HydrationEntryContract.METRIC_KEY,
                ),
            )
            removeProjectionFailureTrigger(database)

            val cleared = dao.deleteHydrationEntry(
                legacy.id,
                "hydration",
                "2026-09-08",
            )
            assertTrue(cleared.changed)
            assertNull(cleared.totalML)
            assertTrue(
                dao.hydrationEntries("hydration", "2026-09-08").isEmpty(),
            )
            assertEquals(
                0.0,
                dao.hydrationProjectionValue(
                    "hydration",
                    "2026-09-08",
                    HydrationEntryContract.METRIC_KEY,
                ),
            )
        } finally {
            database.close()
        }
    }

    private fun installProjectionFailureTrigger(database: WhoopDatabase) {
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
    }

    private fun removeProjectionFailureTrigger(database: WhoopDatabase) {
        database.openHelper.writableDatabase.execSQL(
            "DROP TRIGGER `fail_hydration_projection`",
        )
    }

    private companion object {
        const val DATABASE_NAME = "hydration-entry-migration-test"
    }
}
