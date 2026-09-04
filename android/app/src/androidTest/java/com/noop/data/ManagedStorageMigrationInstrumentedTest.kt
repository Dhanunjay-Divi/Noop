package com.noop.data

import android.content.Context
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ManagedStorageMigrationInstrumentedTest {
    @Test
    fun migrate40To41PreservesPpgRowsAsRealAndAddsBodyMeasurements() = withDatabase { database ->
        database.execSQL(
            """
                CREATE TABLE ppgHrSample (
                    deviceId TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    bpm INTEGER NOT NULL,
                    conf REAL NOT NULL,
                    synced INTEGER NOT NULL,
                    PRIMARY KEY(deviceId, ts)
                )
            """.trimIndent(),
        )
        database.execSQL(
            "INSERT INTO ppgHrSample (deviceId, ts, bpm, conf, synced) VALUES (?, ?, ?, ?, ?)",
            arrayOf<Any?>("strap", 100L, 67, 0.91, 1),
        )

        WhoopDatabase.MIGRATION_40_41.migrate(database)

        database.query("SELECT bpm, typeof(bpm), conf, synced FROM ppgHrSample").use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(67.0, cursor.getDouble(0), 0.0)
            assertEquals("real", cursor.getString(1))
            assertEquals(0.91, cursor.getDouble(2), 0.0)
            assertEquals(1, cursor.getInt(3))
        }
        assertEquals(
            listOf(
                "deviceId",
                "measuredAt",
                "receivedAt",
                "weightKg",
                "bmi",
                "heightCm",
                "userId",
                "unit",
                "source",
            ),
            columns(database, "bodyMeasurement"),
        )
    }

    @Test
    fun migrate41To42ResetsAccountlessCursorAndCreatesReceiptState() = withDatabase { database ->
        database.execSQL(
            """
                CREATE TABLE managedSyncCheckpoint (
                    sourceId TEXT NOT NULL,
                    dataClass TEXT NOT NULL,
                    nextWindowStartMs INTEGER,
                    repairWindowStartMs INTEGER,
                    updatedAtMs INTEGER NOT NULL,
                    PRIMARY KEY(sourceId, dataClass)
                )
            """.trimIndent(),
        )
        database.execSQL(
            """
                INSERT INTO managedSyncCheckpoint (
                    sourceId, dataClass, nextWindowStartMs, repairWindowStartMs, updatedAtMs
                ) VALUES ('source', 'essential_timeseries', 10, 20, 30)
            """.trimIndent(),
        )

        WhoopDatabase.MIGRATION_41_42.migrate(database)

        assertEquals(
            listOf(
                "accountScopeHash",
                "sourceId",
                "dataClass",
                "nextWindowStartMs",
                "repairWindowStartMs",
                "updatedAtMs",
            ),
            columns(database, "managedSyncCheckpoint"),
        )
        database.query("SELECT COUNT(*) FROM managedSyncCheckpoint").use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(0, cursor.getInt(0))
        }
        assertTrue(columns(database, "managedWindowUpload").containsAll(
            listOf(
                "accountScopeHash",
                "windowStartMs",
                "windowEndMs",
                "chunkId",
                "phase",
                "objectGeneration",
                "objectMetageneration",
                "objectCRC32C",
            ),
        ))
    }

    @Test
    fun migrate43To44AddsOnlyDurableSnapshotRestoreProgress() = withDatabase { database ->
        WhoopDatabase.MIGRATION_43_44.migrate(database)

        assertEquals(
            listOf(
                "accountScopeHash",
                "requestId",
                "dataClassesJSON",
                "restoreJobId",
                "snapshotAt",
                "changeSequence",
                "selectedObjects",
                "selectedBytes",
                "dataClassIndex",
                "afterEventStart",
                "afterChunkId",
                "deliveredObjects",
                "deliveredBytes",
                "updatedAtMs",
            ),
            columns(database, "managedSnapshotRestore"),
        )
    }

    @Test
    fun migrate44To45SeedsDocumentsAndInstallsEchoGuardedTriggers() = withDatabase { database ->
        database.execSQL(WhoopDatabase.MANAGED_SNAPSHOT_RESTORE_MIGRATION_SQL)
        createManagedDocumentSourceTables(database)
        database.execSQL(
            """
                INSERT INTO journal (deviceId, day, question)
                VALUES ('strap', '2026-09-04', 'late_caffeine')
            """.trimIndent(),
        )
        database.execSQL(
            """
                INSERT INTO strengthExercise (id, isCustom, createdAt, updatedAt)
                VALUES ('built_in', 0, 1, 1), ('custom', 1, 10, 10)
            """.trimIndent(),
        )

        WhoopDatabase.MIGRATION_44_45.migrate(database)

        assertTrue(columns(database, "managedDocumentDirty").containsAll(
            listOf(
                "tableName",
                "localKey",
                "documentKind",
                "generation",
                "operation",
                "updatedAtMs",
                "payloadJSON",
            ),
        ))
        assertTrue(columns(database, "managedDocumentState").containsAll(
            listOf(
                "accountScopeHash",
                "documentId",
                "acknowledgedGeneration",
                "remoteRevision",
                "remoteContentSHA256",
            ),
        ))
        assertTrue(columns(database, "managedSnapshotRestore").containsAll(
            listOf(
                "afterDocumentUpdatedAt",
                "afterDocumentKind",
                "afterDocumentId",
                "documentsComplete",
            ),
        ))
        assertEquals(2L, long(database, "SELECT COUNT(*) FROM managedDocumentDirty"))
        assertEquals(
            36L,
            long(
                database,
                "SELECT COUNT(*) FROM sqlite_master " +
                    "WHERE type = 'trigger' AND name LIKE 'managed_document_%'",
            ),
        )

        database.execSQL("DELETE FROM managedDocumentDirty")
        database.execSQL(
            "INSERT INTO managedDocumentApplyGuard (guardId) VALUES (1)",
        )
        database.execSQL("INSERT INTO labMarker (id) VALUES ('guarded')")
        assertEquals(0L, long(database, "SELECT COUNT(*) FROM managedDocumentDirty"))

        database.execSQL("DELETE FROM managedDocumentApplyGuard")
        database.execSQL("INSERT INTO labMarker (id) VALUES ('local')")
        assertEquals(1L, long(database, "SELECT COUNT(*) FROM managedDocumentDirty"))
    }

    private fun createManagedDocumentSourceTables(database: SupportSQLiteDatabase) {
        listOf(
            "CREATE TABLE journal (deviceId TEXT, day TEXT, question TEXT)",
            "CREATE TABLE labMarker (id TEXT)",
            "CREATE TABLE nutritionEntry (id TEXT)",
            "CREATE TABLE nutritionCatalogItem (id TEXT, isSaved INTEGER)",
            "CREATE TABLE strengthExercise (" +
                "id TEXT, isCustom INTEGER, createdAt INTEGER, updatedAt INTEGER)",
            "CREATE TABLE strengthRoutine (id TEXT)",
            "CREATE TABLE strengthRoutineExercise (id TEXT)",
            "CREATE TABLE strengthSession (id TEXT)",
            "CREATE TABLE strengthSet (id TEXT)",
            "CREATE TABLE coachMessage (id TEXT)",
            "CREATE TABLE coachMemory (id TEXT)",
            "CREATE TABLE dayOwnership (day TEXT)",
        ).forEach(database::execSQL)
    }

    private fun columns(database: SupportSQLiteDatabase, table: String): List<String> =
        database.query("PRAGMA table_info(`$table`)").use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.getString(1))
            }
        }

    private fun long(database: SupportSQLiteDatabase, sql: String): Long =
        database.query(sql).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getLong(0)
        }

    private fun withDatabase(block: (SupportSQLiteDatabase) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(null)
                .callback(
                    object : SupportSQLiteOpenHelper.Callback(1) {
                        override fun onCreate(db: SupportSQLiteDatabase) = Unit
                        override fun onUpgrade(
                            db: SupportSQLiteDatabase,
                            oldVersion: Int,
                            newVersion: Int,
                        ) = Unit
                    },
                )
                .build(),
        )
        helper.use { block(it.writableDatabase) }
    }
}
