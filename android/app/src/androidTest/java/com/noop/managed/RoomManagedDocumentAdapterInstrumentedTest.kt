package com.noop.managed

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.noop.data.WhoopDatabase
import java.nio.charset.StandardCharsets
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.Base64
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
        WhoopDatabase.ensureManagedLocalProfile(
            database.openHelper.writableDatabase,
            NOW_MS,
        )
        WhoopDatabase.activateManagedLocalProfile(
            database.openHelper.writableDatabase,
            SCOPE,
            NOW_MS,
        )
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
    fun clientEncryptedJournalStaysDirtyAndPlaintextRestoreIsRejected() = runBlocking {
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

        assertTrue(adapter.pendingDocuments(10).isEmpty())
        assertEquals(
            1L,
            long(
                """
                    SELECT generation FROM managedDocumentDirty
                    WHERE tableName = 'journal'
                """.trimIndent(),
            ),
        )
        assertEquals(
            "upsert",
            text(
                """
                    SELECT operation FROM managedDocumentDirty
                    WHERE tableName = 'journal'
                """.trimIndent(),
            ),
        )

        val key = JSONObject()
            .put("deviceId", "strap")
            .put("day", "2026-09-04")
            .put("question", "late_caffeine")
        val record = JSONObject()
            .put("deviceId", "strap")
            .put("day", "2026-09-04")
            .put("question", "late_caffeine")
            .put("answeredYes", 0)
            .put("notes", "remote plaintext")
            .put("numericValue", JSONObject.NULL)
        val remote = serverReadableUpsert(
            kind = ManagedDocumentKind.JOURNAL,
            table = "journal",
            key = key,
            record = record,
        )

        assertInvalidResponse {
            adapter.apply(remote, remote.asChange())
        }

        assertEquals(
            "after lunch",
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
        assertEquals(
            1L,
            long(
                """
                    SELECT generation FROM managedDocumentDirty
                    WHERE tableName = 'journal'
                """.trimIndent(),
            ),
        )
        assertEquals(
            0L,
            long("SELECT COUNT(*) FROM managedDocumentState"),
        )
    }

    @Test
    fun serverReadableFilteringHappensBeforeLimit() = runBlocking {
        repeat(3) { index ->
            exec(
                """
                    INSERT INTO journal (
                        deviceId, day, question, answeredYes, notes, numericValue
                    ) VALUES (?, ?, ?, 1, NULL, NULL)
                """.trimIndent(),
                "strap",
                "2026-09-0${index + 1}",
                "journal-$index",
            )
        }
        insertDayOwnership("2026-09-08", "band-a")
        exec(
            """
                UPDATE managedDocumentDirty SET updatedAtMs = 1
                WHERE documentKind = 'journal'
            """.trimIndent(),
        )
        exec(
            """
                UPDATE managedDocumentDirty SET updatedAtMs = 2
                WHERE documentKind = 'day_ownership'
            """.trimIndent(),
        )

        val pending = adapter.pendingDocuments(1).single()
        assertEquals(ManagedDocumentKind.DAY_OWNERSHIP, pending.mutation.documentKind)
        assertEquals("server_readable", pending.mutation.contentMode)
        assertEquals("dayOwnership", pending.mutation.payloadJson?.getString("table"))
        assertEquals(
            3L,
            long(
                """
                    SELECT COUNT(*) FROM managedDocumentDirty
                    WHERE documentKind = 'journal'
                """.trimIndent(),
            ),
        )
        assertEquals(
            1L,
            long(
                """
                    SELECT COUNT(*) FROM managedDocumentDirty
                    WHERE documentKind = 'day_ownership'
                """.trimIndent(),
            ),
        )
    }

    @Test
    fun encryptedDocumentStopsRestoreBeforeLaterServerReadableDocument() = runBlocking {
        val encrypted = encryptedDocument(
            kind = ManagedDocumentKind.JOURNAL,
            documentId = UUID.fromString("11111111-1111-5111-8111-111111111111"),
            revision = 1,
        )
        assertInvalidResponse("encrypted document without local key recovery") {
            adapter.apply(
                encrypted,
                encrypted.asChange().copy(sequence = 1),
            )
        }
        assertEquals(
            0L,
            long("SELECT COUNT(*) FROM dayOwnership WHERE day = ?", "2026-09-11"),
        )

        val ownership = dayOwnershipUpsert(
            keyDay = "2026-09-11",
            deviceId = "remote-band",
            locked = true,
        )
        adapter.apply(
            ownership,
            ownership.asChange().copy(sequence = 2),
        )
        assertEquals(
            "remote-band",
            text(
                "SELECT deviceId FROM dayOwnership WHERE day = ?",
                "2026-09-11",
            ),
        )
        assertEquals(
            1L,
            long(
                "SELECT locked FROM dayOwnership WHERE day = ?",
                "2026-09-11",
            ),
        )
        assertEquals(1L, long("SELECT COUNT(*) FROM managedDocumentState"))
    }

    @Test
    fun encryptedRestoreFailsClosedOnMalformedMetadataAndSensitivePlaintext() = runBlocking {
        val encrypted = encryptedDocument(
            kind = ManagedDocumentKind.JOURNAL,
            documentId = UUID.fromString(
                "33333333-3333-5333-8333-333333333333",
            ),
            revision = 1,
        )
        val metadata = requireNotNull(encrypted.asChange().document)
        assertInvalidResponse("mismatched encrypted metadata") {
            adapter.apply(
                encrypted,
                encrypted.asChange().copy(
                    document = metadata.copy(contentMode = "server_readable"),
                ),
            )
        }

        val malformed = encrypted.copy(clientKeyId = null)
        assertInvalidResponse("encrypted document without a key") {
            adapter.apply(malformed, malformed.asChange())
        }

        val plaintextSensitive = serverReadableUpsert(
            kind = ManagedDocumentKind.JOURNAL,
            table = "journal",
            key = JSONObject()
                .put("deviceId", "strap")
                .put("day", "2026-09-04")
                .put("question", "late_caffeine"),
            record = JSONObject()
                .put("deviceId", "strap")
                .put("day", "2026-09-04")
                .put("question", "late_caffeine")
                .put("answeredYes", 1)
                .put("notes", "must remain encrypted")
                .put("numericValue", JSONObject.NULL),
        )
        assertInvalidResponse("plaintext sensitive document") {
            adapter.apply(plaintextSensitive, plaintextSensitive.asChange())
        }
    }

    @Test
    fun dayOwnershipRoundTripAcknowledgesAndCloudRestoreDoesNotEcho() = runBlocking {
        val firstRemote = acknowledgeDayOwnership("2026-09-05", "band-a")
        assertTrue(adapter.pendingDocuments(10).isEmpty())

        val restored = revisedDayOwnership(
            firstRemote,
            revision = 2,
            deviceId = "band-b",
            locked = true,
        )
        adapter.apply(restored, restored.asChange())

        assertEquals(
            "band-b",
            text(
                "SELECT deviceId FROM dayOwnership WHERE day = ?",
                "2026-09-05",
            ),
        )
        assertEquals(
            1L,
            long(
                "SELECT locked FROM dayOwnership WHERE day = ?",
                "2026-09-05",
            ),
        )
        assertTrue(adapter.pendingDocuments(10).isEmpty())
        assertEquals(0L, long("SELECT COUNT(*) FROM managedDocumentApplyGuard"))
        assertEquals(
            2L,
            long(
                """
                    SELECT remoteRevision FROM managedDocumentState
                    WHERE tableName = 'dayOwnership'
                """.trimIndent(),
            ),
        )
    }

    @Test
    fun remoteDayOwnershipInvalidatesExactDayOnlyWhenValueChanges() = runBlocking {
        val day = "2026-09-08"
        val expectedTimestamp = LocalDate.parse(day)
            .atTime(LocalTime.NOON)
            .atZone(ZoneId.systemDefault())
            .toEpochSecond()
        val initial = dayOwnershipUpsert(
            keyDay = day,
            deviceId = "band-a",
            locked = false,
        )

        adapter.apply(initial, initial.asChange())
        assertEquals(
            Triple(1L, expectedTimestamp, expectedTimestamp),
            ownershipInvalidation(),
        )

        val replay = initial.copy(
            revision = 2,
            updatedAt = "2026-09-04T12:02:00Z",
        )
        adapter.apply(replay, replay.asChange())
        assertEquals(
            Triple(1L, expectedTimestamp, expectedTimestamp),
            ownershipInvalidation(),
        )

        val changed = revisedDayOwnership(
            initial,
            revision = 3,
            deviceId = "band-a",
            locked = true,
        )
        adapter.apply(changed, changed.asChange())
        assertEquals(
            Triple(2L, expectedTimestamp, expectedTimestamp),
            ownershipInvalidation(),
        )

        val removed = tombstone(initial, revision = 4)
        adapter.apply(removed, removed.asChange())
        assertEquals(
            Triple(3L, expectedTimestamp, expectedTimestamp),
            ownershipInvalidation(),
        )

        val replayedRemoval = tombstone(initial, revision = 5)
        adapter.apply(replayedRemoval, replayedRemoval.asChange())
        assertEquals(
            Triple(3L, expectedTimestamp, expectedTimestamp),
            ownershipInvalidation(),
        )
    }

    @Test
    fun invalidRemoteDayOwnershipPayloadsAreRejectedWithoutMutation() = runBlocking {
        val invalid = listOf(
            "year below range" to dayOwnershipUpsert("1999-12-31"),
            "year above range" to dayOwnershipUpsert("2100-01-01"),
            "invalid calendar day" to dayOwnershipUpsert("2026-02-30"),
            "non-padded day" to dayOwnershipUpsert("2026-9-01"),
            "key-record mismatch" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                recordDay = "2026-09-09",
            ),
            "blank device" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                deviceId = "   ",
            ),
            "leading whitespace" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                deviceId = " band-a",
            ),
            "trailing whitespace" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                deviceId = "band-a ",
            ),
            "control character" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                deviceId = "band\u0000a",
            ),
            "device over UTF-8 limit" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                deviceId = "\u00e9".repeat(129),
            ),
            "locked integer outside binary range" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                locked = 2,
            ),
            "locked floating zero" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                locked = 0.0,
            ),
            "locked floating one" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                locked = 1.0,
            ),
            "locked string" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                locked = "1",
            ),
            "locked null" to dayOwnershipUpsert(
                keyDay = "2026-09-08",
                locked = JSONObject.NULL,
            ),
        )

        invalid.forEach { (label, document) ->
            assertInvalidResponse(label) {
                adapter.apply(document, document.asChange())
            }
            assertEquals(label, 0L, long("SELECT COUNT(*) FROM dayOwnership"))
            assertEquals(label, 0L, long("SELECT COUNT(*) FROM managedDocumentState"))
            assertEquals(label, 0L, long("SELECT COUNT(*) FROM managedDocumentDirty"))
        }
    }

    @Test
    fun dayOwnershipAcceptsExactBooleanLockedValue() = runBlocking {
        val document = dayOwnershipUpsert(
            keyDay = "2026-09-08",
            deviceId = "band-a",
            locked = true,
        )

        adapter.apply(document, document.asChange())

        assertEquals(
            1L,
            long("SELECT locked FROM dayOwnership WHERE day = ?", "2026-09-08"),
        )
        assertTrue(adapter.pendingDocuments(10).isEmpty())
    }

    @Test
    fun invalidLocalDayOwnershipRowsFailClosedAndRemainDirty() = runBlocking {
        val invalidRows = listOf(
            Triple("2026-02-30", "band-a", 0),
            Triple("2026-09-08", " band-a", 0),
            Triple("2026-09-09", "band-a", 2),
        )

        invalidRows.forEach { (day, deviceId, locked) ->
            insertDayOwnership(day, deviceId, locked)
            assertInvalidResponse("local row $day/$deviceId/$locked") {
                adapter.pendingDocuments(10)
            }
            assertEquals(1L, long("SELECT COUNT(*) FROM managedDocumentDirty"))
            assertEquals(1L, dirtyGeneration(day))
            assertEquals(0L, long("SELECT COUNT(*) FROM managedDocumentState"))

            exec("DELETE FROM dayOwnership")
            exec("DELETE FROM managedDocumentDirty")
        }
    }

    @Test
    fun remoteUpsertConflictsWithPendingExactKeyWithoutDataOrOutboxLoss() = runBlocking {
        val firstRemote = acknowledgeDayOwnership("2026-09-06", "band-a")
        exec(
            "UPDATE dayOwnership SET deviceId = 'local-band' WHERE day = ?",
            "2026-09-06",
        )
        val generation = dirtyGeneration("2026-09-06")
        val acknowledgedGeneration = stateAcknowledgedGeneration("2026-09-06")

        val competingRemote = revisedDayOwnership(
            firstRemote,
            revision = 2,
            deviceId = "remote-band",
            locked = true,
        )

        assertConflict {
            adapter.apply(competingRemote, competingRemote.asChange())
        }

        assertEquals(
            "local-band",
            text(
                "SELECT deviceId FROM dayOwnership WHERE day = ?",
                "2026-09-06",
            ),
        )
        assertEquals(generation, dirtyGeneration("2026-09-06"))
        assertEquals("upsert", dirtyOperation("2026-09-06"))
        assertEquals(acknowledgedGeneration, stateAcknowledgedGeneration("2026-09-06"))
        assertEquals(1L, stateRemoteRevision("2026-09-06"))
        assertEquals(
            "local-band",
            adapter.pendingDocuments(10).single()
                .mutation.payloadJson
                ?.getJSONObject("record")
                ?.getString("deviceId"),
        )
    }

    @Test
    fun unrelatedRemoteUpsertIsNotBlockedByAnotherKeysPendingMutation() = runBlocking {
        acknowledgeDayOwnership("2026-09-07", "band-a")
        exec(
            "UPDATE dayOwnership SET deviceId = 'local-band' WHERE day = ?",
            "2026-09-07",
        )
        val otherDay = "2026-09-08"
        val remote = serverReadableUpsert(
            kind = ManagedDocumentKind.DAY_OWNERSHIP,
            table = "dayOwnership",
            key = JSONObject().put("day", otherDay),
            record = JSONObject()
                .put("day", otherDay)
                .put("deviceId", "remote-band")
                .put("locked", 0),
        )

        adapter.apply(remote, remote.asChange())

        assertEquals(
            "remote-band",
            text("SELECT deviceId FROM dayOwnership WHERE day = ?", otherDay),
        )
        assertEquals(
            "local-band",
            adapter.pendingDocuments(10).single()
                .mutation.payloadJson
                ?.getJSONObject("record")
                ?.getString("deviceId"),
        )
    }

    @Test
    fun unknownExactTombstonesRebaseAndAdvancePendingUpsertWithoutAcknowledgingIt() =
        runBlocking {
        insertDayOwnership("2026-09-08", "local-band")
        val before = adapter.pendingDocuments(10).single()
        val tombstone = tombstone(
            kind = ManagedDocumentKind.DAY_OWNERSHIP,
            documentId = before.mutation.documentId,
            revision = 3,
        )

        adapter.apply(tombstone, tombstone.asChange())

        assertEquals(
            "local-band",
            text("SELECT deviceId FROM dayOwnership WHERE day = ?", "2026-09-08"),
        )
        assertEquals(1L, dirtyGeneration("2026-09-08"))
        assertEquals(0L, stateAcknowledgedGeneration("2026-09-08"))
        assertEquals(3L, stateRemoteRevision("2026-09-08"))
        val rebased = adapter.pendingDocuments(10).single()
        assertEquals(before.generation, rebased.generation)
        assertEquals(before.mutation.documentId, rebased.mutation.documentId)
        assertEquals(3L, rebased.mutation.baseRevision)
        assertFalse(rebased.mutation.deleted)

        val laterTombstone = tombstone(
            kind = ManagedDocumentKind.DAY_OWNERSHIP,
            documentId = before.mutation.documentId,
            revision = 5,
        )
        adapter.apply(laterTombstone, laterTombstone.asChange())

        assertEquals(before.generation, dirtyGeneration("2026-09-08"))
        assertEquals(0L, stateAcknowledgedGeneration("2026-09-08"))
        assertEquals(5L, stateRemoteRevision("2026-09-08"))
        val advanced = adapter.pendingDocuments(10).single()
        assertEquals(before.generation, advanced.generation)
        assertEquals(5L, advanced.mutation.baseRevision)
        assertFalse(advanced.mutation.deleted)
    }

    @Test
    fun unknownExactTombstoneAcknowledgesDeleteCreatedBeforeFirstAck() = runBlocking {
        insertDayOwnership("2026-09-08", "local-band")
        val documentId = adapter.pendingDocuments(10).single().mutation.documentId
        exec("DELETE FROM dayOwnership WHERE day = ?", "2026-09-08")
        assertTrue(adapter.pendingDocuments(10).isEmpty())
        val generation = dirtyGeneration("2026-09-08")
        val tombstone = tombstone(
            kind = ManagedDocumentKind.DAY_OWNERSHIP,
            documentId = documentId,
            revision = 4,
        )

        adapter.apply(tombstone, tombstone.asChange())

        assertEquals(generation, dirtyGeneration("2026-09-08"))
        assertEquals("delete", dirtyOperation("2026-09-08"))
        assertEquals(generation, stateAcknowledgedGeneration("2026-09-08"))
        assertEquals(4L, stateRemoteRevision("2026-09-08"))
        assertTrue(adapter.pendingDocuments(10).isEmpty())
    }

    @Test
    fun unrelatedUnknownTombstoneRemainsNoOp() = runBlocking {
        insertDayOwnership("2026-09-08", "local-band")
        val before = adapter.pendingDocuments(10).single()
        val otherKey = ManagedCanonicalJson.encode(
            JSONObject().put("day", "2026-09-09"),
        )
        val unrelatedId = RoomManagedDocumentAdapter.documentId(
            ManagedDocumentKind.DAY_OWNERSHIP,
            "dayOwnership",
            otherKey,
        )
        val tombstone = tombstone(
            kind = ManagedDocumentKind.DAY_OWNERSHIP,
            documentId = unrelatedId,
            revision = 2,
        )

        adapter.apply(tombstone, tombstone.asChange())

        assertEquals(0L, long("SELECT COUNT(*) FROM managedDocumentState"))
        assertEquals(1L, dirtyGeneration("2026-09-08"))
        val after = adapter.pendingDocuments(10).single()
        assertEquals(before.mutation.documentId, after.mutation.documentId)
        assertEquals(0L, after.mutation.baseRevision)
    }

    @Test
    fun remoteTombstoneConflictsWithPendingLocalDeleteWithoutOutboxLoss() = runBlocking {
        val firstRemote = acknowledgeDayOwnership("2026-09-07", "band-a")
        exec(
            "DELETE FROM dayOwnership WHERE day = ?",
            "2026-09-07",
        )
        val generation = dirtyGeneration("2026-09-07")
        val acknowledgedGeneration = stateAcknowledgedGeneration("2026-09-07")
        val tombstone = tombstone(firstRemote, revision = 2)

        assertConflict {
            adapter.apply(tombstone, tombstone.asChange())
        }

        assertEquals(
            0L,
            long(
                "SELECT COUNT(*) FROM dayOwnership WHERE day = ?",
                "2026-09-07",
            ),
        )
        assertEquals(generation, dirtyGeneration("2026-09-07"))
        assertEquals("delete", dirtyOperation("2026-09-07"))
        assertEquals(acknowledgedGeneration, stateAcknowledgedGeneration("2026-09-07"))
        assertEquals(1L, stateRemoteRevision("2026-09-07"))
        assertTrue(adapter.pendingDocuments(10).single().mutation.deleted)
    }

    private suspend fun acknowledgeDayOwnership(
        day: String,
        deviceId: String,
    ): ManagedDocument {
        insertDayOwnership(day, deviceId)
        val pending = adapter.pendingDocuments(10).single()
        assertEquals(1L, pending.generation)
        assertEquals(ManagedDocumentKind.DAY_OWNERSHIP, pending.mutation.documentKind)
        assertEquals(0L, pending.mutation.baseRevision)
        assertFalse(pending.mutation.deleted)
        val remote = remoteDocument(pending.mutation)
        adapter.acknowledge(pending, remote)
        return remote
    }

    private fun insertDayOwnership(
        day: String,
        deviceId: String,
        locked: Any = 0,
    ) {
        exec(
            "INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?, ?, ?)",
            day,
            deviceId,
            locked,
        )
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

    private fun encryptedDocument(
        kind: ManagedDocumentKind,
        documentId: UUID,
        revision: Long,
        deleted: Boolean = false,
    ): ManagedDocument {
        val updatedAt = "2026-09-11T15:00:00Z"
        if (deleted) {
            val digest = ManagedDigest.sha256(
                (
                    "deleted:${kind.wireValue}:" +
                        "${documentId.toString().lowercase()}:$revision"
                    ).toByteArray(StandardCharsets.UTF_8),
            )
            return ManagedDocument(
                documentKind = kind,
                documentId = documentId,
                revision = revision,
                originInstallationId = "android-installation",
                contentMode = "client_encrypted",
                clientKeyId = null,
                contentSha256 = digest,
                payloadJson = null,
                payloadCiphertextBase64 = null,
                updatedAt = updatedAt,
                deletedAt = updatedAt,
                duplicate = false,
            )
        }

        val ciphertext = "noop-encrypted-${kind.wireValue}-payload"
            .toByteArray(StandardCharsets.UTF_8)
        return ManagedDocument(
            documentKind = kind,
            documentId = documentId,
            revision = revision,
            originInstallationId = "android-installation",
            contentMode = "client_encrypted",
            clientKeyId = UUID.fromString(
                "44444444-4444-5444-8444-444444444444",
            ),
            contentSha256 = ManagedDigest.sha256(ciphertext),
            payloadJson = null,
            payloadCiphertextBase64 = Base64.getEncoder().encodeToString(ciphertext),
            updatedAt = updatedAt,
            deletedAt = null,
            duplicate = false,
        )
    }

    private fun serverReadableUpsert(
        kind: ManagedDocumentKind,
        table: String,
        key: JSONObject,
        record: JSONObject,
        revision: Long = 1,
    ): ManagedDocument {
        val canonicalKey = ManagedCanonicalJson.encode(key)
        val payload = JSONObject()
            .put("schema_version", 1)
            .put("table", table)
            .put("key", key)
            .put("record", record)
        val canonicalPayload = ManagedCanonicalJson.encode(payload)
        return ManagedDocument(
            documentKind = kind,
            documentId = RoomManagedDocumentAdapter.documentId(kind, table, canonicalKey),
            revision = revision,
            originInstallationId = "remote-installation",
            contentMode = "server_readable",
            clientKeyId = null,
            contentSha256 = ManagedDigest.sha256(
                canonicalPayload.toByteArray(StandardCharsets.UTF_8),
            ),
            payloadJson = payload,
            payloadCiphertextBase64 = null,
            updatedAt = "2026-09-04T12:01:00Z",
            deletedAt = null,
            duplicate = false,
        )
    }

    private fun dayOwnershipUpsert(
        keyDay: String,
        recordDay: String = keyDay,
        deviceId: String = "band-a",
        locked: Any = 0,
    ): ManagedDocument = serverReadableUpsert(
        kind = ManagedDocumentKind.DAY_OWNERSHIP,
        table = "dayOwnership",
        key = JSONObject().put("day", keyDay),
        record = JSONObject()
            .put("day", recordDay)
            .put("deviceId", deviceId)
            .put("locked", locked),
    )

    private fun revisedDayOwnership(
        source: ManagedDocument,
        revision: Long,
        deviceId: String,
        locked: Boolean,
    ): ManagedDocument {
        val payload = JSONObject(
            ManagedCanonicalJson.encode(
                requireNotNull(source.payloadJson),
            ),
        )
        payload.getJSONObject("record")
            .put("deviceId", deviceId)
            .put("locked", if (locked) 1 else 0)
        val canonical = ManagedCanonicalJson.encode(payload)
        return source.copy(
            revision = revision,
            contentSha256 = ManagedDigest.sha256(
                canonical.toByteArray(StandardCharsets.UTF_8),
            ),
            payloadJson = JSONObject(canonical),
            updatedAt = "2026-09-04T12:02:00Z",
            deletedAt = null,
            duplicate = false,
        )
    }

    private fun tombstone(source: ManagedDocument, revision: Long): ManagedDocument =
        tombstone(source.documentKind, source.documentId, revision)

    private fun tombstone(
        kind: ManagedDocumentKind,
        documentId: UUID,
        revision: Long,
    ): ManagedDocument {
        val digest = ManagedDigest.sha256(
            (
                "deleted:${kind.wireValue}:" +
                    "${documentId.toString().lowercase()}:$revision"
                ).toByteArray(StandardCharsets.UTF_8),
        )
        return ManagedDocument(
            documentKind = kind,
            documentId = documentId,
            revision = revision,
            originInstallationId = "remote-installation",
            contentMode = "server_readable",
            clientKeyId = null,
            contentSha256 = digest,
            payloadJson = null,
            payloadCiphertextBase64 = null,
            updatedAt = "2026-09-04T12:02:00Z",
            deletedAt = "2026-09-04T12:02:00Z",
            duplicate = false,
        )
    }

    private suspend fun assertConflict(block: suspend () -> Unit) {
        val failure = try {
            block()
            null
        } catch (error: Throwable) {
            error
        }
        assertTrue(
            "Expected ManagedStorageException.Conflict but was $failure",
            failure is ManagedStorageException.Conflict,
        )
    }

    private suspend fun assertInvalidResponse(
        label: String = "",
        block: suspend () -> Unit,
    ) {
        val failure = try {
            block()
            null
        } catch (error: Throwable) {
            error
        }
        assertTrue(
            "$label: expected ManagedStorageException.InvalidResponse but was $failure",
            failure is ManagedStorageException.InvalidResponse,
        )
    }

    private fun dirtyGeneration(day: String): Long = long(
        """
            SELECT generation
            FROM managedDocumentDirty
            WHERE tableName = 'dayOwnership'
              AND localKey = hex(CAST(? AS BLOB))
        """.trimIndent(),
        day,
    )

    private fun dirtyOperation(day: String): String = text(
        """
            SELECT operation
            FROM managedDocumentDirty
            WHERE tableName = 'dayOwnership'
              AND localKey = hex(CAST(? AS BLOB))
        """.trimIndent(),
        day,
    )

    private fun stateAcknowledgedGeneration(day: String): Long = long(
        """
            SELECT acknowledgedGeneration
            FROM managedDocumentState
            WHERE accountScopeHash = ?
              AND tableName = 'dayOwnership'
              AND localKey = hex(CAST(? AS BLOB))
        """.trimIndent(),
        SCOPE,
        day,
    )

    private fun stateRemoteRevision(day: String): Long = long(
        """
            SELECT remoteRevision
            FROM managedDocumentState
            WHERE accountScopeHash = ?
              AND tableName = 'dayOwnership'
              AND localKey = hex(CAST(? AS BLOB))
        """.trimIndent(),
        SCOPE,
        day,
    )

    private fun ownershipInvalidation(): Triple<Long, Long, Long> =
        database.openHelper.readableDatabase.query(
            SimpleSQLiteQuery(
                """
                    SELECT generation, earliestAffectedTs, latestAffectedTs
                    FROM analysisDirtySource
                    WHERE deviceId = ?
                """.trimIndent(),
                arrayOf<Any?>("noop.internal.analysis.ownership"),
            ),
        ).use { cursor ->
            check(cursor.moveToFirst())
            Triple(
                cursor.getLong(0),
                cursor.getLong(1),
                cursor.getLong(2),
            )
        }

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

    private fun long(sql: String, vararg arguments: Any): Long =
        database.openHelper.readableDatabase.query(
            SimpleSQLiteQuery(sql, arguments),
        ).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getLong(0)
        }

    companion object {
        private const val NOW_MS = 1_788_523_200_000L
        private val SCOPE = "b".repeat(64)
    }
}
