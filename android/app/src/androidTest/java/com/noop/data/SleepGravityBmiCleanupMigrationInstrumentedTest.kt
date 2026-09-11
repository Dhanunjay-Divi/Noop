package com.noop.data

import android.content.Context
import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SleepGravityBmiCleanupMigrationInstrumentedTest {
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
    fun migrate45To46AddsUnknownGravityEvidenceAndRemovesOnlyHealthConnectBmi() {
        migrationHelper.createDatabase(DATABASE_NAME, 45).use { database ->
            database.execSQL(
                "INSERT INTO `sleepSession` " +
                    "(`deviceId`, `startTs`, `endTs`, `efficiency`, `stagesJSON`, `userEdited`) " +
                    "VALUES (?, ?, ?, ?, ?, ?)",
                arrayOf<Any?>(
                    "noop-band",
                    1_800_000_000L,
                    1_800_028_800L,
                    0.91,
                    """[{"start":1800000000,"end":1800028800,"stage":"light"}]""",
                    0,
                ),
            )
            database.execSQL(
                "INSERT INTO `metricSeries` (`deviceId`, `day`, `key`, `value`) VALUES (?, ?, ?, ?)",
                arrayOf<Any?>("health-connect", "2026-09-10", "bmi", 24.2),
            )
            database.execSQL(
                "INSERT INTO `metricSeries` (`deviceId`, `day`, `key`, `value`) VALUES (?, ?, ?, ?)",
                arrayOf<Any?>("health-connect", "2026-09-10", "weight_kg", 76.8),
            )
            database.execSQL(
                "INSERT INTO `metricSeries` (`deviceId`, `day`, `key`, `value`) VALUES (?, ?, ?, ?)",
                arrayOf<Any?>("manual", "2026-09-10", "bmi", 23.4),
            )
            database.execSQL(
                "INSERT INTO `healthConnectSyncState` (`recordType`, `changesToken`, `updatedAt`) " +
                    "VALUES (?, ?, ?)",
                arrayOf<Any?>(
                    "androidx.health.connect.client.records.WeightRecord",
                    "weight-token",
                    1_800_000_000_000L,
                ),
            )
            database.execSQL(
                "INSERT INTO `healthConnectSyncState` (`recordType`, `changesToken`, `updatedAt`) " +
                    "VALUES (?, ?, ?)",
                arrayOf<Any?>(
                    "androidx.health.connect.client.records.StepsRecord",
                    "steps-token",
                    1_800_000_000_000L,
                ),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            47,
            true,
            WhoopDatabase.MIGRATION_45_46,
            WhoopDatabase.MIGRATION_46_47,
        ).use { database ->
            assertEquals(47, database.version)
            database.query("SELECT `gravitySparse` FROM `sleepSession`").use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.isNull(0))
            }
            database.query(
                "SELECT COUNT(*) FROM `metricSeries` " +
                    "WHERE `deviceId` = 'health-connect' AND `key` = 'bmi'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
            database.query(
                "SELECT COUNT(*) FROM `metricSeries` " +
                    "WHERE (`deviceId` = 'health-connect' AND `key` = 'weight_kg') " +
                    "OR (`deviceId` = 'manual' AND `key` = 'bmi')",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(2, cursor.getInt(0))
            }
            database.query(
                "SELECT COUNT(*) FROM `healthConnectSyncState` " +
                    "WHERE `recordType` = 'androidx.health.connect.client.records.WeightRecord'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(0, cursor.getInt(0))
            }
            database.query(
                "SELECT `changesToken` FROM `healthConnectSyncState` " +
                    "WHERE `recordType` = 'androidx.health.connect.client.records.StepsRecord'",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("steps-token", cursor.getString(0))
            }
        }
    }

    private companion object {
        const val DATABASE_NAME = "sleep-gravity-bmi-cleanup-migration-test"
    }
}
