package com.noop.data

import android.content.Context
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.testing.MigrationTestHelper
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
class CurrentSchemaMigrationInstrumentedTest {
    @get:Rule
    val migrationHelper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        WhoopDatabase::class.java,
    )

    private val context: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    @After
    fun deleteDatabases() {
        context.deleteDatabase(MIGRATION_DATABASE)
        context.deleteDatabase(FULL_MIGRATION_DATABASE)
        context.deleteDatabase(CAPABILITY_MIGRATION_DATABASE)
        context.deleteDatabase(FRESH_DATABASE)
    }

    @Test
    fun complete47To51UpgradeKeepsLegacyDirtyRowsUnclaimedAndInstallsCurrentTriggers() {
        migrationHelper.createDatabase(MIGRATION_DATABASE, 47).use { database ->
            database.execSQL(
                """
                    INSERT INTO managedDocumentDirty (
                        tableName, localKey, documentKind, generation,
                        operation, updatedAtMs, payloadJSON
                    ) VALUES (
                        'dayOwnership', '323032362D30392D3132', 'day_ownership',
                        3, 'upsert', 1789200000000, NULL
                    )
                """.trimIndent(),
            )
            database.execSQL(
                "INSERT INTO hrSample (deviceId, ts, bpm, synced) VALUES ('band-a', 1, 60, 0)",
            )
            database.execSQL(
                """
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    VALUES ('hydration', '2026-09-12', 'hydration', 500)
                """.trimIndent(),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            MIGRATION_DATABASE,
            51,
            true,
            WhoopDatabase.MIGRATION_47_48,
            WhoopDatabase.MIGRATION_48_49,
            WhoopDatabase.MIGRATION_49_50,
            WhoopDatabase.MIGRATION_50_51,
        ).use { database ->
            assertEquals(51, database.version)
            database.query(
                """
                    SELECT localProfileId, accountScopeHash
                    FROM managedLocalProfile
                    WHERE bindingId = 1
                """.trimIndent(),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.getString(0).isNotBlank())
                assertTrue(cursor.isNull(1))
            }
            database.query(
                "SELECT localProfileId, generation FROM managedDocumentDirty",
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.getString(0).isNotBlank())
                assertEquals(3L, cursor.getLong(1))
                assertFalse(cursor.moveToNext())
            }
            assertEquals(30, triggerCount(database, "analysis_dirty_%"))
            assertEquals(36, triggerCount(database, "managed_document_%"))
            assertEquals(1L, tableCount(database, "hydrationEntry"))
        }
    }

    @Test
    fun migration50To51PreservesCursorAndInterruptedSnapshotAtLegacyCapability() {
        migrationHelper.createDatabase(CAPABILITY_MIGRATION_DATABASE, 50).use { database ->
            database.execSQL(
                """
                    INSERT INTO managedChangeCursor (
                        accountScopeHash, sequence, updatedAtMs
                    ) VALUES (
                        'scope-a', 77, 1789200000000
                    )
                """.trimIndent(),
            )
            database.execSQL(
                """
                    INSERT INTO managedSnapshotRestore (
                        accountScopeHash, requestId, dataClassesJSON,
                        restoreJobId, snapshotAt, changeSequence,
                        selectedObjects, selectedBytes, dataClassIndex,
                        afterEventStart, afterChunkId,
                        deliveredObjects, deliveredBytes, updatedAtMs,
                        afterDocumentUpdatedAt, afterDocumentKind, afterDocumentId,
                        documentsComplete
                    ) VALUES (
                        'scope-a', 'request-a', '["essential_timeseries"]',
                        'restore-a', '2026-09-12T00:00:00Z', 77,
                        3, 1024, 1,
                        '2026-09-11T23:00:00Z', '11111111-1111-5111-8111-111111111111',
                        2, 768, 1789200000000,
                        '2026-09-12T00:30:00Z', 'journal',
                        '22222222-2222-5222-8222-222222222222',
                        0
                    )
                """.trimIndent(),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            CAPABILITY_MIGRATION_DATABASE,
            51,
            true,
            WhoopDatabase.MIGRATION_50_51,
        ).use { database ->
            database.query(
                """
                    SELECT sequence, updatedAtMs, changeFeedCapabilityVersion
                    FROM managedChangeCursor
                    WHERE accountScopeHash = 'scope-a'
                """.trimIndent(),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(77L, cursor.getLong(0))
                assertEquals(1_789_200_000_000L, cursor.getLong(1))
                assertEquals(0, cursor.getInt(2))
                assertFalse(cursor.moveToNext())
            }
            database.query(
                """
                    SELECT requestId, changeSequence, dataClassIndex,
                           deliveredObjects, deliveredBytes, documentsComplete,
                           changeFeedCapabilityVersion
                    FROM managedSnapshotRestore
                    WHERE accountScopeHash = 'scope-a'
                """.trimIndent(),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("request-a", cursor.getString(0))
                assertEquals(77L, cursor.getLong(1))
                assertEquals(1, cursor.getInt(2))
                assertEquals(2L, cursor.getLong(3))
                assertEquals(768L, cursor.getLong(4))
                assertEquals(0, cursor.getInt(5))
                assertEquals(0, cursor.getInt(6))
                assertFalse(cursor.moveToNext())
            }
        }
    }

    @Test
    fun fresh51InitializationCreatesBindingAndBothTriggerFamilies() {
        val database = Room.databaseBuilder(
            context,
            WhoopDatabase::class.java,
            FRESH_DATABASE,
        ).addCallback(
            object : RoomDatabase.Callback() {
                override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                    WhoopDatabase.ensureManagedLocalProfile(db, 1_789_200_000_000L)
                    WhoopDatabase.installManagedDocumentTriggers(db)
                    WhoopDatabase.installAnalysisDirtySourceTriggers(db)
                }
            },
        ).build()
        val sql = database.openHelper.writableDatabase

        assertEquals(51, sql.version)
        assertEquals(1L, tableCount(sql, "managedLocalProfile"))
        sql.query(
            "SELECT localProfileId, accountScopeHash FROM managedLocalProfile WHERE bindingId = 1",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertTrue(cursor.getString(0).isNotBlank())
            assertTrue(cursor.isNull(1))
        }
        assertEquals(30, triggerCount(sql, "analysis_dirty_%"))
        assertEquals(36, triggerCount(sql, "managed_document_%"))
        database.close()
    }

    @Test
    fun complete44To51UpgradeUsesLegacyTriggersUntilAccountPartitionExists() {
        migrationHelper.createDatabase(FULL_MIGRATION_DATABASE, 44).use { database ->
            database.execSQL(
                """
                    INSERT INTO dayOwnership (day, deviceId, locked)
                    VALUES ('2026-09-12', 'band-a', 0)
                """.trimIndent(),
            )
        }

        migrationHelper.runMigrationsAndValidate(
            FULL_MIGRATION_DATABASE,
            51,
            true,
            WhoopDatabase.MIGRATION_44_45,
            WhoopDatabase.MIGRATION_45_46,
            WhoopDatabase.MIGRATION_46_47,
            WhoopDatabase.MIGRATION_47_48,
            WhoopDatabase.MIGRATION_48_49,
            WhoopDatabase.MIGRATION_49_50,
            WhoopDatabase.MIGRATION_50_51,
        ).use { database ->
            assertEquals(51, database.version)
            assertEquals(36, triggerCount(database, "managed_document_%"))
            assertEquals(
                1L,
                database.query(
                    """
                        SELECT COUNT(*)
                        FROM managedDocumentDirty
                        WHERE documentKind = 'day_ownership'
                    """.trimIndent(),
                ).use { cursor ->
                    assertTrue(cursor.moveToFirst())
                    cursor.getLong(0)
                },
            )
            database.query(
                """
                    SELECT active.accountScopeHash,
                           dirty.localProfileId = active.localProfileId
                    FROM managedLocalProfile AS active
                    JOIN managedDocumentDirty AS dirty ON 1 = 1
                    WHERE active.bindingId = 1
                """.trimIndent(),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertTrue(cursor.isNull(0))
                assertEquals(1, cursor.getInt(1))
            }
        }
    }

    private fun triggerCount(
        database: androidx.sqlite.db.SupportSQLiteDatabase,
        pattern: String,
    ): Int = database.query(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE ?",
        arrayOf(pattern),
    ).use { cursor ->
        assertTrue(cursor.moveToFirst())
        cursor.getInt(0)
    }

    private fun tableCount(
        database: androidx.sqlite.db.SupportSQLiteDatabase,
        table: String,
    ): Long = database.query(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        arrayOf(table),
    ).use { cursor ->
        assertTrue(cursor.moveToFirst())
        cursor.getLong(0)
    }

    private companion object {
        const val MIGRATION_DATABASE = "current-schema-migration"
        const val FULL_MIGRATION_DATABASE = "current-schema-full-migration"
        const val CAPABILITY_MIGRATION_DATABASE = "current-schema-capability-migration"
        const val FRESH_DATABASE = "current-schema-fresh"
    }
}
