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
class DailyHrvMethodMigrationInstrumentedTest {
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
    fun migrate35To36PreservesHrvAndLeavesMethodUnknown() {
        migrationHelper.createDatabase(DATABASE_NAME, 35).use { database ->
            database.execSQL(
                "INSERT INTO `dailyMetric` (`deviceId`, `day`, `avgHrv`) VALUES (?, ?, ?)",
                arrayOf<Any?>("apple-health", "2026-08-25", 61.0),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            36,
            true,
            WhoopDatabase.MIGRATION_35_36,
        ).use { database ->
            assertEquals(36, database.version)
            database.query(
                "SELECT `deviceId`, `day`, `avgHrv`, `hrvMethod` FROM `dailyMetric`",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("apple-health", cursor.getString(0))
                assertEquals("2026-08-25", cursor.getString(1))
                assertEquals(61.0, cursor.getDouble(2), 0.0)
                assertTrue(cursor.isNull(3))
            }
        }
    }

    private companion object {
        const val DATABASE_NAME = "daily-hrv-method-migration-test"
    }
}
