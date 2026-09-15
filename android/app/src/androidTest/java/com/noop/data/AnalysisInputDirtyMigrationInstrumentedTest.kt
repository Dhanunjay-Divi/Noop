package com.noop.data

import android.content.Context
import androidx.room.testing.MigrationTestHelper
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AnalysisInputDirtyMigrationInstrumentedTest {
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
    fun migrationSeedsEverySourceAndInstallsConflictSafeGenerationTriggers() {
        migrationHelper.createDatabase(DATABASE_NAME, 47).use { database ->
            SCORE_TABLES.forEachIndexed { index, table ->
                insertScoreBearingRow(
                    database = database,
                    table = table,
                    source = "seed-$table",
                    ts = 100L + index,
                )
            }
            database.execSQL(
                "INSERT INTO `battery` (`deviceId`,`ts`,`soc`,`mv`,`charging`,`synced`) " +
                    "VALUES ('battery-only',200,80,NULL,NULL,0)",
            )
            listOf("", "   ", "\t", "\n\r").forEachIndexed { index, source ->
                database.execSQL(
                    "INSERT INTO `hrSample` (`deviceId`,`ts`,`bpm`,`synced`) VALUES (?,?,?,?)",
                    arrayOf<Any?>(source, 300L + index, 60, 0),
                )
            }
        }

        migrationHelper.runMigrationsAndValidate(
            DATABASE_NAME,
            48,
            true,
            WhoopDatabase.MIGRATION_47_48,
        ).use { database ->
            assertEquals(48, database.version)
            assertEquals(
                SCORE_TABLES.map { "seed-$it" }.sorted(),
                ledger(database).keys.sorted(),
            )
            ledger(database).values.forEach { row ->
                assertEquals(1L, row.generation)
                assertEquals(0L, row.acknowledgedGeneration)
            }
            SCORE_TABLES.forEachIndexed { index, table ->
                val row = requireNotNull(ledger(database)["seed-$table"])
                assertEquals(100L + index, row.earliestAffectedTs)
                assertEquals(100L + index, row.latestAffectedTs)
            }
            assertEquals(30, analysisTriggerCount(database))

            val source = "seed-hrSample"
            database.execSQL(
                """
                    INSERT INTO `hrSample` (`deviceId`,`ts`,`bpm`,`synced`)
                    VALUES (?,100,65,0)
                    ON CONFLICT(`deviceId`,`ts`) DO UPDATE SET `bpm` = excluded.`bpm`
                """.trimIndent(),
                arrayOf(source),
            )
            val afterUpsert = requireNotNull(ledger(database)[source]).generation
            assertTrue(afterUpsert > 1L)
            assertEquals(100L, ledger(database)[source]?.earliestAffectedTs)
            assertEquals(100L, ledger(database)[source]?.latestAffectedTs)

            database.execSQL(
                "INSERT OR REPLACE INTO `hrSample` (`deviceId`,`ts`,`bpm`,`synced`) " +
                    "VALUES (?,100,66,0)",
                arrayOf(source),
            )
            val afterReplace = requireNotNull(ledger(database)[source]).generation
            assertTrue(afterReplace > afterUpsert)

            database.execSQL(
                "UPDATE `analysisDirtySource` SET `acknowledgedGeneration` = `generation` " +
                    ", `earliestAffectedTs` = NULL, `latestAffectedTs` = NULL " +
                    "WHERE `deviceId` = ?",
                arrayOf(source),
            )
            database.execSQL(
                "UPDATE `hrSample` SET `synced` = 1 WHERE `deviceId` = ?",
                arrayOf(source),
            )
            assertFalse(isDirty(database, source))

            database.execSQL(
                "DELETE FROM `hrSample` WHERE `deviceId` = ?",
                arrayOf(source),
            )
            assertTrue(isDirty(database, source))
            assertEquals(100L, ledger(database)[source]?.earliestAffectedTs)
            assertEquals(100L, ledger(database)[source]?.latestAffectedTs)
        }
    }

    private data class LedgerRow(
        val generation: Long,
        val acknowledgedGeneration: Long,
        val earliestAffectedTs: Long?,
        val latestAffectedTs: Long?,
    )

    private fun ledger(database: SupportSQLiteDatabase): Map<String, LedgerRow> =
        database.query(
            "SELECT `deviceId`,`generation`,`acknowledgedGeneration`, " +
                "`earliestAffectedTs`,`latestAffectedTs` " +
                "FROM `analysisDirtySource` ORDER BY `deviceId`",
        ).use { cursor ->
            buildMap {
                while (cursor.moveToNext()) {
                    put(
                        cursor.getString(0),
                        LedgerRow(
                            generation = cursor.getLong(1),
                            acknowledgedGeneration = cursor.getLong(2),
                            earliestAffectedTs =
                                if (cursor.isNull(3)) null else cursor.getLong(3),
                            latestAffectedTs =
                                if (cursor.isNull(4)) null else cursor.getLong(4),
                        ),
                    )
                }
            }
        }

    private fun isDirty(database: SupportSQLiteDatabase, source: String): Boolean =
        database.query(
            "SELECT EXISTS(SELECT 1 FROM `analysisDirtySource` " +
                "WHERE `deviceId` = ? AND `generation` > `acknowledgedGeneration`)",
            arrayOf(source),
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getInt(0) != 0
        }

    private fun analysisTriggerCount(database: SupportSQLiteDatabase): Int =
        database.query(
            "SELECT COUNT(*) FROM sqlite_master " +
                "WHERE type = 'trigger' AND name LIKE 'analysis_dirty_%'",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getInt(0)
        }

    private fun insertScoreBearingRow(
        database: SupportSQLiteDatabase,
        table: String,
        source: String,
        ts: Long,
    ) {
        val (sql, values) = when (table) {
            "hrSample" ->
                "INSERT INTO `hrSample` (`deviceId`,`ts`,`bpm`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 61, 0)
            "ppgHrSample" ->
                "INSERT INTO `ppgHrSample` (`deviceId`,`ts`,`bpm`,`conf`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 61.0, 0.9, 0)
            "rrInterval" ->
                "INSERT INTO `rrInterval` " +
                    "(`deviceId`,`ts`,`rrMs`,`seq`,`synced`,`tsSuspect`,`ord`,`srcChannel`) " +
                    "VALUES (?,?,?,?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 980, 0, 0, null, null, null)
            "gravitySample" ->
                "INSERT INTO `gravitySample` (`deviceId`,`ts`,`x`,`y`,`z`,`synced`) VALUES (?,?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 0.1, 0.2, 0.3, 0)
            "respSample" ->
                "INSERT INTO `respSample` (`deviceId`,`ts`,`raw`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 10, 0)
            "skinTempSample" ->
                "INSERT INTO `skinTempSample` (`deviceId`,`ts`,`raw`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 10, 0)
            "spo2Sample" ->
                "INSERT INTO `spo2Sample` (`deviceId`,`ts`,`red`,`ir`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 100, 200, 0)
            "stepSample" ->
                "INSERT INTO `stepSample` " +
                    "(`deviceId`,`ts`,`counter`,`activityClass`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 10, 1, 0)
            "sleepStateSample" ->
                "INSERT INTO `sleepStateSample` (`deviceId`,`ts`,`state`,`synced`) VALUES (?,?,?,?)" to
                    arrayOf<Any?>(source, ts, 2, 0)
            "event" ->
                "INSERT INTO `event` (`deviceId`,`ts`,`kind`,`payloadJSON`,`synced`) VALUES (?,?,?,?,?)" to
                    arrayOf<Any?>(source, ts, "test", "{}", 0)
            else -> error("unknown score-bearing table $table")
        }
        database.execSQL(sql, values)
    }

    private companion object {
        const val DATABASE_NAME = "analysis-input-generation-migration-test"
        val SCORE_TABLES = listOf(
            "hrSample",
            "ppgHrSample",
            "rrInterval",
            "gravitySample",
            "respSample",
            "skinTempSample",
            "spo2Sample",
            "stepSample",
            "sleepStateSample",
            "event",
        )
    }
}
