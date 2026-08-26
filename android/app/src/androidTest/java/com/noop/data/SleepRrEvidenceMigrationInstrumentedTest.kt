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
class SleepRrEvidenceMigrationInstrumentedTest {
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
    fun migrate34To35PreservesSessionAndAddsNullEvidence() {
        migrationHelper.createDatabase(DATABASE_NAME, 34).use { database ->
            database.execSQL(
                "INSERT INTO `sleepSession` " +
                    "(`deviceId`, `startTs`, `endTs`, `efficiency`, `stagesJSON`, `userEdited`) " +
                    "VALUES (?, ?, ?, ?, ?, ?)",
                arrayOf(
                    "my-band-noop",
                    1_800_000_000L,
                    1_800_028_800L,
                    0.91,
                    """[{"start":1800000000,"end":1800028800,"stage":"light"}]""",
                    0,
                ),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            35,
            true,
            WhoopDatabase.MIGRATION_34_35,
        ).use { database ->
            assertEquals(35, database.version)
            database.query(
                "SELECT `deviceId`, `startTs`, `endTs`, `efficiency`, " +
                    "`rrEligibleWindowCount`, `rrValidWindowCount` FROM `sleepSession`",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("my-band-noop", cursor.getString(0))
                assertEquals(1_800_000_000L, cursor.getLong(1))
                assertEquals(1_800_028_800L, cursor.getLong(2))
                assertEquals(0.91, cursor.getDouble(3), 0.0)
                assertTrue(cursor.isNull(4))
                assertTrue(cursor.isNull(5))
            }
        }
    }

    private companion object {
        const val DATABASE_NAME = "sleep-rr-evidence-migration-test"
    }
}
