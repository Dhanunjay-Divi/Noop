package com.noop.managed

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ManagedDocumentAccountIsolationInstrumentedTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @After
    fun deleteDatabase() {
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun accountSwitchInvalidatesPriorUploadIntentOnlyForChangedKeys() = runBlocking {
        var database = openDatabase()
        val accountA = adapter(database, ACCOUNT_A, NOW_MS)
        assertTrue(accountA.pendingDocuments(10).isEmpty())
        insertOwnership(database, "2026-09-12", "band-a")
        val originalA = accountA.pendingDocuments(10).single()
        insertOwnership(database, "2026-09-13", "band-a")
        assertEquals(2, accountA.pendingDocuments(10).size)
        database.close()

        database = openDatabase()
        val accountB = adapter(database, ACCOUNT_B, NOW_MS + 1)
        assertTrue(accountB.pendingDocuments(10).isEmpty())
        updateOwnership(database, "2026-09-12", "band-b")
        val pendingB = accountB.pendingDocuments(10).single()
        assertEquals(originalA.mutation.documentId, pendingB.mutation.documentId)
        database.close()

        database = openDatabase()
        val restoredA = adapter(database, ACCOUNT_A, NOW_MS + 2)
        val remainingA = restoredA.pendingDocuments(10).single()
        assertEquals(
            "2026-09-13",
            remainingA.mutation.payloadJson
                ?.getJSONObject("key")
                ?.getString("day"),
        )
        val restoredB = adapter(database, ACCOUNT_B, NOW_MS + 3)
        assertEquals(
            pendingB.mutation.documentId,
            restoredB.pendingDocuments(10).single().mutation.documentId,
        )
        database.close()
    }

    @Test
    fun signedOutMutationClearsPriorAccountIntentAndIsNotAdoptedByNextAccount() = runBlocking {
        val database = openDatabase()
        val accountA = adapter(database, ACCOUNT_A, NOW_MS)
        assertTrue(accountA.pendingDocuments(10).isEmpty())
        insertOwnership(database, "2026-09-12", "band-a")
        assertEquals(1, accountA.pendingDocuments(10).size)

        database.runInTransaction {
            WhoopDatabase.releaseManagedLocalProfile(
                database.openHelper.writableDatabase,
                NOW_MS + 1,
            )
        }
        updateOwnership(database, "2026-09-12", "signed-out-band")
        assertEquals(0L, dirtyCount(database))
        try {
            accountA.pendingDocuments(10)
            throw AssertionError("A stale adapter must not reclaim a released profile")
        } catch (_: ManagedStorageException.Conflict) {
            // Expected: account activation belongs to the service lifecycle, not the adapter.
        }

        val accountB = adapter(database, ACCOUNT_B, NOW_MS + 2)
        assertTrue(accountB.pendingDocuments(10).isEmpty())
        updateOwnership(database, "2026-09-12", "band-b")
        assertEquals(1, accountB.pendingDocuments(10).size)
        database.close()
    }

    @Test
    fun quarantinedLegacyRowsDoNotBlockAccountScopedSync() = runBlocking {
        val database = openDatabase()
        insertOwnership(database, "2026-09-12", "legacy-band")
        database.openHelper.writableDatabase.execSQL(
            """
                INSERT INTO managedDocumentDirty (
                    localProfileId, tableName, localKey, documentKind, generation,
                    operation, updatedAtMs, payloadJSON
                ) VALUES (?, 'dayOwnership', ?, 'day_ownership', 3, 'upsert', ?, NULL)
            """.trimIndent(),
            arrayOf<Any?>(
                "legacy-quarantine",
                "323032362D30392D3132",
                NOW_MS,
            ),
        )

        val accountA = adapter(database, ACCOUNT_A, NOW_MS + 1)
        assertTrue(accountA.pendingDocuments(10).isEmpty())
        insertOwnership(database, "2026-09-13", "band-a")
        assertEquals(1, accountA.pendingDocuments(10).size)
        assertEquals(2L, dirtyCount(database))
        database.close()
    }

    private fun openDatabase(): WhoopDatabase =
        Room.databaseBuilder(context, WhoopDatabase::class.java, DATABASE_NAME)
            .allowMainThreadQueries()
            .build()
            .also { database ->
                val sql = database.openHelper.writableDatabase
                WhoopDatabase.ensureManagedLocalProfile(sql, NOW_MS)
                WhoopDatabase.installManagedDocumentTriggers(sql)
            }

    private fun adapter(
        database: WhoopDatabase,
        accountScopeHash: String,
        nowMs: Long,
    ): RoomManagedDocumentAdapter {
        database.runInTransaction {
            WhoopDatabase.activateManagedLocalProfile(
                database.openHelper.writableDatabase,
                accountScopeHash,
                nowMs,
            )
        }
        return RoomManagedDocumentAdapter(
            database = database,
            accountScopeHash = accountScopeHash,
            context = context,
            clock = { nowMs },
        )
    }

    private fun insertOwnership(database: WhoopDatabase, day: String, deviceId: String) {
        database.openHelper.writableDatabase.execSQL(
            "INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?, ?, 0)",
            arrayOf<Any?>(day, deviceId),
        )
    }

    private fun updateOwnership(database: WhoopDatabase, day: String, deviceId: String) {
        database.openHelper.writableDatabase.execSQL(
            "UPDATE dayOwnership SET deviceId = ? WHERE day = ?",
            arrayOf<Any?>(deviceId, day),
        )
    }

    private fun dirtyCount(database: WhoopDatabase): Long =
        database.openHelper.readableDatabase.query(
            "SELECT COUNT(*) FROM managedDocumentDirty",
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getLong(0)
        }

    private companion object {
        const val DATABASE_NAME = "managed-document-account-isolation"
        const val NOW_MS = 1_789_200_000_000L
        const val ACCOUNT_A =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val ACCOUNT_B =
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
}
