package com.noop.data

import android.content.Context
import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EfficiencyHealMigrationInstrumentedTest {
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
    fun migrate33To34RepairsLegacyImportValuesConservativelyAndIsIdempotent() {
        migrationHelper.createDatabase(DATABASE_NAME, 33).use { database ->
            insertMetric(database, "legacy-percent", "sleep_efficiency", 80.0)
            insertMetric(database, "upper-bound", "sleep_efficiency", 100.0)
            insertMetric(database, "fraction", "sleep_efficiency", 0.8)
            insertMetric(database, "lower-bound", "sleep_efficiency", 1.0)
            insertMetric(database, "out-of-range", "sleep_efficiency", 101.0)
            insertMetric(database, "different-key", "rest_quality", 75.0)
            insertMetric(database, "legacy-temp", "skin_temp", 95.0, deviceId = "my-whoop")
            insertMetric(database, "valid-temp", "skin_temp", 35.0, deviceId = "my-whoop")
            insertMetric(
                database,
                "legacy-disturbance",
                "awake_min",
                37.2,
                deviceId = "my-whoop",
            )
            insertMetric(
                database,
                "real-disturbance",
                "awake_min",
                37.2,
                deviceId = "my-whoop",
            )
            insertDaily(database, "legacy-temp", disturbances = null, skinTemp = 95.0)
            insertDaily(database, "valid-temp", disturbances = null, skinTemp = 35.0)
            insertDaily(database, "legacy-disturbance", disturbances = 37, skinTemp = null)
            insertDaily(database, "real-disturbance", disturbances = 5, skinTemp = null)
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            34,
            true,
            WhoopDatabase.MIGRATION_33_34,
        ).use { database ->
            assertEquals(34, database.version)
            val afterFirstMigration = readMetrics(database)
            assertExpectedValues(afterFirstMigration)
            assertExpectedDailyValues(database)

            WhoopDatabase.MIGRATION_33_34.migrate(database)
            assertEquals(afterFirstMigration, readMetrics(database))
            assertExpectedDailyValues(database)
        }
    }

    private fun insertMetric(
        database: SupportSQLiteDatabase,
        day: String,
        key: String,
        value: Double,
        deviceId: String = "test-device",
    ) {
        database.execSQL(
            "INSERT INTO `metricSeries` (`deviceId`, `day`, `key`, `value`) VALUES (?, ?, ?, ?)",
            arrayOf<Any>(deviceId, day, key, value),
        )
    }

    private fun readMetrics(database: SupportSQLiteDatabase): Map<String, Double> {
        val values = linkedMapOf<String, Double>()
        database.query(
            "SELECT `day`, `key`, `value` FROM `metricSeries` ORDER BY `day`, `key`",
        ).use { cursor ->
            val dayIndex = cursor.getColumnIndexOrThrow("day")
            val keyIndex = cursor.getColumnIndexOrThrow("key")
            val valueIndex = cursor.getColumnIndexOrThrow("value")
            while (cursor.moveToNext()) {
                values["${cursor.getString(dayIndex)}:${cursor.getString(keyIndex)}"] =
                    cursor.getDouble(valueIndex)
            }
        }
        return values
    }

    private fun insertDaily(
        database: SupportSQLiteDatabase,
        day: String,
        disturbances: Int?,
        skinTemp: Double?,
    ) {
        database.execSQL(
            "INSERT INTO `dailyMetric` " +
                "(`deviceId`, `day`, `disturbances`, `skinTempDevC`) VALUES (?, ?, ?, ?)",
            arrayOf<Any?>("my-whoop", day, disturbances, skinTemp),
        )
    }

    private fun assertExpectedValues(values: Map<String, Double>) {
        assertEquals(10, values.size)
        assertEquals(0.8, values.getValue("legacy-percent:sleep_efficiency"), 0.000_000_1)
        assertEquals(1.0, values.getValue("upper-bound:sleep_efficiency"), 0.000_000_1)
        assertEquals(0.8, values.getValue("fraction:sleep_efficiency"), 0.000_000_1)
        assertEquals(1.0, values.getValue("lower-bound:sleep_efficiency"), 0.000_000_1)
        assertEquals(101.0, values.getValue("out-of-range:sleep_efficiency"), 0.000_000_1)
        assertEquals(75.0, values.getValue("different-key:rest_quality"), 0.000_000_1)
        assertEquals(35.0, values.getValue("legacy-temp:skin_temp"), 0.000_000_1)
        assertEquals(35.0, values.getValue("valid-temp:skin_temp"), 0.000_000_1)
        assertEquals(37.2, values.getValue("legacy-disturbance:awake_min"), 0.000_000_1)
        assertEquals(37.2, values.getValue("real-disturbance:awake_min"), 0.000_000_1)
    }

    private fun assertExpectedDailyValues(database: SupportSQLiteDatabase) {
        database.query(
            "SELECT `day`, `disturbances`, `skinTempDevC` FROM `dailyMetric` ORDER BY `day`",
        ).use { cursor ->
            val values = linkedMapOf<String, Pair<Int?, Double?>>()
            val dayIndex = cursor.getColumnIndexOrThrow("day")
            val disturbancesIndex = cursor.getColumnIndexOrThrow("disturbances")
            val skinTempIndex = cursor.getColumnIndexOrThrow("skinTempDevC")
            while (cursor.moveToNext()) {
                values[cursor.getString(dayIndex)] =
                    (if (cursor.isNull(disturbancesIndex)) null
                    else cursor.getInt(disturbancesIndex)) to
                    (if (cursor.isNull(skinTempIndex)) null else cursor.getDouble(skinTempIndex))
            }
            assertEquals(null, values.getValue("legacy-disturbance").first)
            assertEquals(5, values.getValue("real-disturbance").first)
            assertEquals(35.0, values.getValue("legacy-temp").second!!, 0.000_000_1)
            assertEquals(35.0, values.getValue("valid-temp").second!!, 0.000_000_1)
        }
    }

    private companion object {
        const val DATABASE_NAME = "efficiency-heal-migration-test"
    }
}
