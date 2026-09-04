package com.noop.managed

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.data.WhoopDatabase
import java.nio.charset.StandardCharsets
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RoomManagedDocumentAdapterInstrumentedTest {
    private lateinit var database: WhoopDatabase
    private lateinit var adapter: RoomManagedDocumentAdapter

    @Before
    fun openDatabase() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, WhoopDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        WhoopDatabase.installManagedDocumentTriggers(
            database.openHelper.writableDatabase,
        )
        adapter = RoomManagedDocumentAdapter(
            database = database,
            accountScopeHash = SCOPE,
            context = context,
            clock = { NOW_MS },
        )
    }

    @After
    fun closeDatabase() {
        database.close()
    }

    @Test
    fun journalRoundTripAcknowledgesAndCloudRestoreDoesNotEcho() = runBlocking {
        exec(
            """
                INSERT INTO journal (
                    deviceId, day, question, answeredYes, notes, numericValue
                ) VALUES (?, ?, ?, 1, 'after lunch', 2.5)
            """.trimIndent(),
            "strap",
            "2026-09-04",
            "late_caffeine",
        )

        val pending = adapter.pendingDocuments(10).single()
        assertEquals(1L, pending.generation)
        assertEquals(ManagedDocumentKind.JOURNAL, pending.mutation.documentKind)
        assertEquals(
            UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500"),
            pending.mutation.documentId,
        )
        assertEquals(0L, pending.mutation.baseRevision)
        assertFalse(pending.mutation.deleted)

        val firstRemote = remoteDocument(pending.mutation)
        adapter.acknowledge(pending, firstRemote)
        assertTrue(adapter.pendingDocuments(10).isEmpty())

        val restoredPayload = JSONObject(
            ManagedCanonicalJson.encode(
                requireNotNull(firstRemote.payloadJson),
            ),
        )
        restoredPayload.getJSONObject("record").put("notes", "restored from cloud")
        val canonical = ManagedCanonicalJson.encode(restoredPayload)
        val restored = firstRemote.copy(
            revision = 2,
            contentSha256 = ManagedDigest.sha256(
                canonical.toByteArray(StandardCharsets.UTF_8),
            ),
            payloadJson = JSONObject(canonical),
            updatedAt = "2026-09-04T12:01:00Z",
            duplicate = false,
        )
        adapter.apply(restored, restored.asChange())

        assertEquals(
            "restored from cloud",
            text(
                """
                    SELECT notes FROM journal
                    WHERE deviceId = ? AND day = ? AND question = ?
                """.trimIndent(),
                "strap",
                "2026-09-04",
                "late_caffeine",
            ),
        )
        assertTrue(adapter.pendingDocuments(10).isEmpty())
        assertEquals(
            0L,
            long("SELECT COUNT(*) FROM managedDocumentApplyGuard"),
        )

        exec(
            """
                UPDATE journal SET notes = 'edited locally'
                WHERE deviceId = ? AND day = ? AND question = ?
            """.trimIndent(),
            "strap",
            "2026-09-04",
            "late_caffeine",
        )
        val edited = adapter.pendingDocuments(10).single()
        assertEquals(2L, edited.mutation.baseRevision)
        assertFalse(edited.mutation.deleted)

        exec(
            """
                DELETE FROM journal
                WHERE deviceId = ? AND day = ? AND question = ?
            """.trimIndent(),
            "strap",
            "2026-09-04",
            "late_caffeine",
        )
        val deleted = adapter.pendingDocuments(10).single()
        assertEquals(2L, deleted.mutation.baseRevision)
        assertTrue(deleted.mutation.deleted)
        assertEquals(null, deleted.mutation.clientKeyId)
        assertEquals(null, deleted.mutation.payloadJson)
    }

    private fun remoteDocument(mutation: ManagedDocumentMutation): ManagedDocument =
        ManagedDocument(
            documentKind = mutation.documentKind,
            documentId = mutation.documentId,
            revision = mutation.baseRevision + 1,
            originInstallationId = "android-installation",
            contentMode = mutation.contentMode,
            clientKeyId = mutation.clientKeyId,
            contentSha256 = requireNotNull(mutation.contentSha256),
            payloadJson = mutation.payloadJson,
            payloadCiphertextBase64 = mutation.payloadCiphertextBase64,
            updatedAt = mutation.updatedAt,
            deletedAt = null,
            duplicate = false,
        )

    private fun exec(sql: String, vararg arguments: Any) {
        database.openHelper.writableDatabase.execSQL(sql, arguments)
    }

    private fun text(sql: String, vararg arguments: Any): String =
        database.openHelper.readableDatabase.query(
            SimpleSQLiteQuery(sql, arguments),
        ).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getString(0)
        }

    private fun long(sql: String): Long =
        database.openHelper.readableDatabase.query(sql).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getLong(0)
        }

    companion object {
        private const val NOW_MS = 1_788_523_200_000L
        private val SCOPE = "b".repeat(64)
    }
}
