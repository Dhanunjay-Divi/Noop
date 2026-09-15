package com.noop.data

import android.content.Context
import android.content.ContextWrapper
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PendingDatabaseRestoreInstrumentedTest {
    private val sqliteMagic = byteArrayOf(
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
    )
    private lateinit var root: File
    private lateinit var isolatedContext: Context

    @Before
    fun createIsolatedDatabaseDirectory() {
        val base = ApplicationProvider.getApplicationContext<Context>()
        root = File(base.cacheDir, "pending-restore-${UUID.randomUUID()}").apply {
            check(mkdirs())
        }
        isolatedContext = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this

            override fun getDatabasePath(name: String): File = File(root, name)
        }
    }

    @After
    fun removeIsolatedDatabaseDirectory() {
        root.deleteRecursively()
    }

    @Test
    fun existingLiveDatabaseIsCheckpointedAndPreservedBeforeCandidateSwap() {
        val live = isolatedContext.getDatabasePath(WhoopDatabase.DB_NAME)
        val candidate = File(root, "candidate.sqlite")
        val liveDatabase = createWalBackedDatabase(live, "previous")
        createDatabase(candidate, "replacement")
        try {
            val liveWal = File(live.path + "-wal")
            assertTrue("test requires committed WAL frames", liveWal.exists() && liveWal.length() > 32L)

            PendingDatabaseRestore.stage(isolatedContext, candidate, settings = null)
            val preparation = PendingDatabaseRestore.prepareAtColdOpen(isolatedContext)
            val files = PendingDatabaseRestore.Fileset(isolatedContext)

            assertTrue(preparation.applied)
            assertTrue(preparation.hadPreviousDatabase)
            assertEquals("replacement", readProbe(files.db))
            assertEquals("previous", readProbe(files.rollback))
            assertNull(DataBackup.sqliteQuickCheckFailure(files.db))
            assertNull(DataBackup.sqliteQuickCheckFailure(files.rollback))
            assertFalse(files.candidate.exists())

            val marker = PendingDatabaseRestore.readMarker(files.marker)
            assertEquals(2, marker?.formatVersion)
            assertEquals(PendingDatabaseRestore.Phase.APPLIED, marker?.phase)
            assertEquals(true, marker?.hadPreviousDatabase)
            assertEquals(sha256(files.rollback), marker?.rollbackSha256)
        } finally {
            runCatching { liveDatabase.close() }
        }
    }

    @Test
    fun productionValidatorRejectsCorruptRollbackAndKeepsLiveDatabase() {
        val files = PendingDatabaseRestore.Fileset(isolatedContext)
        val candidate = File(root, "candidate-invalid-rollback.sqlite")
        createDatabase(files.db, "previous")
        createDatabase(candidate, "replacement")
        PendingDatabaseRestore.stage(isolatedContext, candidate, settings = null)
        corruptSqlite(files.rollback)
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                sha256 = sha256(files.candidate),
                hasSettings = false,
                hadPreviousDatabase = true,
                rollbackSha256 = sha256(files.rollback),
            ),
            files.syncParentDirectory,
        )

        val failure = assertThrows(PendingDatabaseRestore.RollbackValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpen(isolatedContext)
        }

        assertEquals(
            PendingDatabaseRestore.RollbackFailureKind.ROLLBACK_INVALID,
            failure.failureKind,
        )
        assertEquals("previous", readProbe(files.db))
        assertTrue(files.candidate.exists())
        assertTrue(files.marker.exists())
    }

    @Test
    fun finalizingRejectsAReplacementLiveDatabaseBeforePreferenceRetry() {
        val files = PendingDatabaseRestore.Fileset(isolatedContext)
        createDatabase(files.db, "replacement")
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.FINALIZING,
                sha256 = sha256(files.db),
                hasSettings = false,
                hadPreviousDatabase = false,
                acceptedLiveFileIdentity = "0:0",
            ),
            files.syncParentDirectory,
        )

        val failure = assertThrows(PendingDatabaseRestore.AcceptedLiveValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpen(isolatedContext)
        }

        assertEquals("live_identity", failure.failureKind)
        assertEquals("replacement", readProbe(files.db))
        assertTrue(files.marker.exists())
    }

    @Test
    fun originalLegacyCommittedMarkerUsesRealValidatorAndCompletesCleanup() {
        val files = PendingDatabaseRestore.Fileset(isolatedContext)
        createDatabase(files.db, "accepted")
        createDatabase(files.rollback, "previous")
        createDatabase(files.candidate, "staged")
        files.marker.writeText(
            "version=1\n" +
                "phase=COMMITTED\n" +
                "sha256=${sha256(files.db)}\n" +
                "settings=0\n",
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpen(isolatedContext)

        assertFalse(preparation.applied)
        assertEquals("accepted", readProbe(files.db))
        assertFalse(files.rollback.exists())
        assertFalse(files.candidate.exists())
        assertFalse(files.marker.exists())
    }

    private fun createDatabase(file: File, value: String) {
        file.parentFile?.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(file, null).use { database ->
            database.execSQL("CREATE TABLE restore_probe (value TEXT NOT NULL)")
            database.execSQL("INSERT INTO restore_probe (value) VALUES (?)", arrayOf(value))
        }
    }

    private fun createWalBackedDatabase(file: File, value: String): SQLiteDatabase {
        file.parentFile?.mkdirs()
        return SQLiteDatabase.openOrCreateDatabase(file, null).also { database ->
            check(database.enableWriteAheadLogging())
            database.execSQL("CREATE TABLE restore_probe (value TEXT NOT NULL)")
            database.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { cursor ->
                check(cursor.moveToFirst())
                check(cursor.getInt(0) == 0)
            }
            database.execSQL("INSERT INTO restore_probe (value) VALUES (?)", arrayOf(value))
        }
    }

    private fun corruptSqlite(file: File) {
        file.outputStream().use { output ->
            output.write(sqliteMagic)
            output.write(ByteArray(4_080) { 0x7f })
            output.fd.sync()
        }
    }

    private fun readProbe(file: File): String =
        SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { database ->
            database.rawQuery("SELECT value FROM restore_probe", null).use { cursor ->
                check(cursor.moveToFirst())
                cursor.getString(0)
            }
        }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
