package com.noop.managed

import android.content.Context
import android.database.Cursor
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.data.BackupSettingsBridge
import com.noop.data.BackupSettingsCodec
import com.noop.data.WhoopDatabase
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

interface ManagedDocumentRestoring {
    suspend fun apply(document: ManagedDocument, change: ManagedChange)
}

class RoomManagedDocumentAdapter(
    private val database: WhoopDatabase,
    private val accountScopeHash: String,
    context: Context? = null,
    private val clock: () -> Long = System::currentTimeMillis,
) : ManagedDocumentOutbox, ManagedDocumentRestoring {
    private val appContext = context?.applicationContext
    private val candidateLock = Any()
    private val candidates = mutableMapOf<String, LocalCandidate>()

    init {
        require(accountScopeHash.matches(SHA256))
    }

    suspend fun stagePreferences(json: String?, updatedAtMs: Long = clock()) {
        if (json == null) return
        val normalized = BackupSettingsCodec.encode(BackupSettingsCodec.decode(json)) ?: return
        val payload = canonicalObject(normalized)
        if (payload.toByteArray(StandardCharsets.UTF_8).size > MAX_DOCUMENT_BYTES ||
            updatedAtMs < 0L
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        withContext(Dispatchers.IO) {
            database.runInTransaction {
                val db = database.openHelper.writableDatabase
                val existing = stringOrNull(
                    db,
                    """
                        SELECT payloadJSON FROM managedDocumentDirty
                        WHERE tableName = ? AND localKey = ?
                    """.trimIndent(),
                    PREFERENCES_TABLE,
                    PREFERENCES_KEY,
                )
                if (existing == payload) return@runInTransaction
                db.execSQL(
                    """
                        INSERT INTO managedDocumentDirty (
                            tableName, localKey, documentKind, generation,
                            operation, updatedAtMs, payloadJSON
                        ) VALUES (?, ?, ?, 1, 'upsert', ?, ?)
                        ON CONFLICT(tableName, localKey) DO UPDATE SET
                            documentKind = excluded.documentKind,
                            generation = managedDocumentDirty.generation + 1,
                            operation = 'upsert',
                            updatedAtMs = excluded.updatedAtMs,
                            payloadJSON = excluded.payloadJSON
                    """.trimIndent(),
                    arrayOf<Any?>(
                        PREFERENCES_TABLE,
                        PREFERENCES_KEY,
                        ManagedDocumentKind.PREFERENCES.wireValue,
                        updatedAtMs,
                        payload,
                    ),
                )
            }
        }
    }

    override suspend fun pendingDocuments(limit: Int): List<ManagedPendingDocument> {
        // The coordinator reads one look-ahead record to report a truthful bounded backlog.
        require(limit in 1..101)
        return withContext(Dispatchers.IO) {
            val local = pendingCandidates(limit)
            local.map { candidate ->
                val kind = ManagedDocumentKind.fromWire(candidate.documentKind)
                val documentId = documentId(kind, candidate.tableName, candidate.keyJson)
                val payload = candidate.payloadJson?.let(::JSONObject)
                val digest = payload?.let {
                    ManagedDigest.sha256(
                        ManagedCanonicalJson.encode(it).toByteArray(StandardCharsets.UTF_8),
                    )
                }
                val requestId = requestId(
                    documentId,
                    candidate.generation,
                    candidate.baseRevision,
                    digest,
                )
                val mutation = ManagedDocumentMutation(
                    requestId = requestId,
                    documentKind = kind,
                    documentId = documentId,
                    baseRevision = candidate.baseRevision,
                    contentMode = "server_readable",
                    payloadJson = payload,
                    contentSha256 = digest,
                    updatedAt = Instant.ofEpochMilli(candidate.updatedAtMs).toString(),
                    deleted = candidate.payloadJson == null,
                )
                val localIdentifier = ManagedDigest.sha256(
                    "${candidate.tableName}\u0000${candidate.localKey}"
                        .toByteArray(StandardCharsets.UTF_8),
                )
                synchronized(candidateLock) {
                    candidates[localIdentifier] = candidate
                }
                ManagedPendingDocument(
                    localIdentifier = localIdentifier,
                    generation = candidate.generation,
                    mutation = mutation,
                )
            }
        }
    }

    override suspend fun acknowledge(
        pending: ManagedPendingDocument,
        remote: ManagedDocument,
    ) {
        val candidate = synchronized(candidateLock) {
            candidates[pending.localIdentifier]
        } ?: throw ManagedStorageException.InvalidResponse()
        if (candidate.generation != pending.generation ||
            remote.documentKind != pending.mutation.documentKind ||
            remote.documentId != pending.mutation.documentId ||
            remote.revision != pending.mutation.baseRevision + 1
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val expectedDigest = if (pending.mutation.deleted) {
            deletionDigest(remote.documentKind, remote.documentId, remote.revision)
        } else {
            pending.mutation.contentSha256 ?: throw ManagedStorageException.InvalidResponse()
        }
        if (remote.contentSha256 != expectedDigest) {
            throw ManagedStorageException.InvalidResponse()
        }
        withContext(Dispatchers.IO) {
            database.runInTransaction {
                upsertState(
                    database.openHelper.writableDatabase,
                    candidate.tableName,
                    candidate.localKey,
                    candidate.documentKind,
                    remote.documentId,
                    candidate.keyJson,
                    candidate.generation,
                    remote.revision,
                    remote.contentSha256,
                    clock(),
                )
            }
        }
        synchronized(candidateLock) {
            if (candidates[pending.localIdentifier] == candidate) {
                candidates.remove(pending.localIdentifier)
            }
        }
    }

    override suspend fun apply(document: ManagedDocument, change: ManagedChange) {
        validateDocumentChange(document, change)
        val deleted = document.deletedAt != null
        val payloadText = if (deleted) {
            if (document.payloadJson != null || change.operation != "tombstone") {
                throw ManagedStorageException.InvalidResponse()
            }
            null
        } else {
            val payload = document.payloadJson ?: throw ManagedStorageException.InvalidResponse()
            if (change.operation != "upsert") throw ManagedStorageException.InvalidResponse()
            val canonical = ManagedCanonicalJson.encode(payload)
            if (ManagedDigest.sha256(canonical.toByteArray(StandardCharsets.UTF_8)) !=
                document.contentSha256 ||
                documentId(document.documentKind, payload) != document.documentId
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            canonical
        }
        if (deleted &&
            deletionDigest(document.documentKind, document.documentId, document.revision) !=
            document.contentSha256
        ) {
            throw ManagedStorageException.InvalidResponse()
        }

        if (document.documentKind == ManagedDocumentKind.PREFERENCES && !deleted) {
            applyPreferences(payloadText ?: throw ManagedStorageException.InvalidResponse())
        }
        applyVerifiedDocument(document, payloadText, deleted)
    }

    private fun pendingCandidates(limit: Int): List<LocalCandidate> {
        val db = database.openHelper.readableDatabase
        val dirty = db.query(
            SimpleSQLiteQuery(
                """
                    SELECT dirty.tableName, dirty.localKey, dirty.documentKind,
                           dirty.generation, dirty.operation, dirty.updatedAtMs,
                           dirty.payloadJSON, COALESCE(state.remoteRevision, 0)
                    FROM managedDocumentDirty AS dirty
                    LEFT JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE (
                        state.acknowledgedGeneration IS NULL
                        OR state.acknowledgedGeneration < dirty.generation
                    )
                      AND (
                        dirty.operation != 'delete'
                        OR COALESCE(state.remoteRevision, 0) > 0
                      )
                    ORDER BY dirty.updatedAtMs, dirty.tableName, dirty.localKey
                    LIMIT ?
                """.trimIndent(),
                arrayOf<Any?>(accountScopeHash, limit),
            ),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(
                        DirtyRow(
                            tableName = cursor.getString(0),
                            localKey = cursor.getString(1),
                            documentKind = cursor.getString(2),
                            generation = cursor.getLong(3),
                            operation = cursor.getString(4),
                            updatedAtMs = cursor.getLong(5),
                            payloadJson = if (cursor.isNull(6)) null else cursor.getString(6),
                            baseRevision = cursor.getLong(7),
                        ),
                    )
                }
            }
        }
        return dirty.map { row -> candidate(db, row) }
    }

    private fun candidate(db: SupportSQLiteDatabase, dirty: DirtyRow): LocalCandidate {
        if (dirty.generation <= 0L || dirty.baseRevision < 0L || dirty.updatedAtMs < 0L) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (dirty.tableName == PREFERENCES_TABLE) {
            if (dirty.documentKind != ManagedDocumentKind.PREFERENCES.wireValue ||
                dirty.localKey != PREFERENCES_KEY ||
                dirty.operation != "upsert" ||
                dirty.payloadJson == null
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            return LocalCandidate(
                dirty.tableName,
                dirty.documentKind,
                dirty.localKey,
                canonicalObject("""{"scope":"$PREFERENCES_KEY"}"""),
                dirty.generation,
                dirty.baseRevision,
                dirty.updatedAtMs,
                canonicalObject(dirty.payloadJson),
            )
        }
        val spec = TABLE_SPECS.firstOrNull {
            it.table == dirty.tableName && it.kind.wireValue == dirty.documentKind
        } ?: throw ManagedStorageException.InvalidResponse()
        val current = db.query(
            SimpleSQLiteQuery(
                """
                    SELECT * FROM `${spec.table}` AS candidate
                    WHERE ${spec.localKey("candidate")} = ?
                      AND ${spec.eligibility("candidate")}
                """.trimIndent(),
                arrayOf<Any?>(dirty.localKey),
            ),
        ).use { cursor -> if (cursor.moveToFirst()) cursorObject(cursor) else null }
        if (dirty.operation != "upsert" || current == null) {
            val key = stringOrNull(
                db,
                """
                    SELECT keyJSON FROM managedDocumentState
                    WHERE accountScopeHash = ? AND tableName = ? AND localKey = ?
                """.trimIndent(),
                accountScopeHash,
                dirty.tableName,
                dirty.localKey,
            ) ?: throw ManagedStorageException.InvalidResponse()
            return LocalCandidate(
                dirty.tableName,
                dirty.documentKind,
                dirty.localKey,
                canonicalObject(key),
                dirty.generation,
                dirty.baseRevision,
                dirty.updatedAtMs,
                null,
            )
        }
        val key = JSONObject()
        spec.keyColumns.forEach { column ->
            if (!current.has(column)) throw ManagedStorageException.InvalidResponse()
            key.put(column, current.get(column))
        }
        val envelope = JSONObject()
            .put("schema_version", 1)
            .put("table", spec.table)
            .put("key", key)
            .put("record", current)
        val payload = ManagedCanonicalJson.encode(envelope)
        if (payload.toByteArray(StandardCharsets.UTF_8).size > MAX_DOCUMENT_BYTES) {
            throw ManagedStorageException.QuotaExceeded()
        }
        return LocalCandidate(
            dirty.tableName,
            dirty.documentKind,
            dirty.localKey,
            ManagedCanonicalJson.encode(key),
            dirty.generation,
            dirty.baseRevision,
            dirty.updatedAtMs,
            payload,
        )
    }

    private fun validateDocumentChange(document: ManagedDocument, change: ManagedChange) {
        val metadata = change.document
        if (document.contentMode != "server_readable" ||
            document.clientKeyId != null ||
            document.payloadCiphertextBase64 != null ||
            document.revision <= 0L ||
            change.resourceKind != "document" ||
            change.resourceId != document.documentId ||
            change.contentSha256 != document.contentSha256 ||
            !document.contentSha256.matches(SHA256) ||
            metadata == null ||
            metadata.documentKind != document.documentKind ||
            metadata.documentId != document.documentId ||
            metadata.revision != document.revision ||
            metadata.contentMode != document.contentMode ||
            metadata.clientKeyId != document.clientKeyId ||
            metadata.updatedAt != document.updatedAt ||
            metadata.deletedAt != document.deletedAt ||
            change.operation !in setOf("upsert", "tombstone")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun applyPreferences(payload: String) {
        val context = appContext ?: throw ManagedStorageException.InvalidResponse()
        val values = BackupSettingsCodec.decode(payload)
        val normalized = BackupSettingsCodec.encode(values)
            ?: throw ManagedStorageException.InvalidResponse()
        if (canonicalObject(normalized) != payload) {
            throw ManagedStorageException.InvalidResponse()
        }
        BackupSettingsBridge.apply(context, normalized)
        BackupSettingsBridge.reconcileAfterRestore(context)
        database.openHelper.writableDatabase.let {
            val existing = stringOrNull(
                it,
                """
                    SELECT payloadJSON FROM managedDocumentDirty
                    WHERE tableName = ? AND localKey = ?
                """.trimIndent(),
                PREFERENCES_TABLE,
                PREFERENCES_KEY,
            )
            if (existing != payload) {
                it.execSQL(
                    """
                        INSERT INTO managedDocumentDirty (
                            tableName, localKey, documentKind, generation,
                            operation, updatedAtMs, payloadJSON
                        ) VALUES (?, ?, ?, 1, 'upsert', ?, ?)
                        ON CONFLICT(tableName, localKey) DO UPDATE SET
                            documentKind = excluded.documentKind,
                            generation = managedDocumentDirty.generation + 1,
                            operation = 'upsert',
                            updatedAtMs = excluded.updatedAtMs,
                            payloadJSON = excluded.payloadJSON
                    """.trimIndent(),
                    arrayOf<Any?>(
                        PREFERENCES_TABLE,
                        PREFERENCES_KEY,
                        ManagedDocumentKind.PREFERENCES.wireValue,
                        clock(),
                        payload,
                    ),
                )
            }
        }
    }

    private suspend fun applyVerifiedDocument(
        document: ManagedDocument,
        payload: String?,
        deleted: Boolean,
    ) = withContext(Dispatchers.IO) {
        database.runInTransaction {
            val db = database.openHelper.writableDatabase
            db.execSQL(
                "INSERT OR IGNORE INTO managedDocumentApplyGuard (guardId) VALUES (1)",
            )
            try {
                if (document.documentKind == ManagedDocumentKind.PREFERENCES) {
                    if (deleted || payload == null) throw ManagedStorageException.InvalidResponse()
                    upsertStateFromCurrentGeneration(
                        db,
                        PREFERENCES_TABLE,
                        PREFERENCES_KEY,
                        document.documentKind,
                        document.documentId,
                        """{"scope":"$PREFERENCES_KEY"}""",
                        document.revision,
                        document.contentSha256,
                    )
                    return@runInTransaction
                }
                if (deleted) {
                    applyDelete(db, document)
                } else {
                    applyUpsert(
                        db,
                        document,
                        payload ?: throw ManagedStorageException.InvalidResponse(),
                    )
                }
            } finally {
                db.execSQL("DELETE FROM managedDocumentApplyGuard WHERE guardId = 1")
            }
        }
    }

    private fun applyDelete(db: SupportSQLiteDatabase, document: ManagedDocument) {
        val identity = db.query(
            SimpleSQLiteQuery(
                """
                    SELECT tableName, localKey, keyJSON
                    FROM managedDocumentState
                    WHERE accountScopeHash = ? AND documentKind = ? AND documentId = ?
                """.trimIndent(),
                arrayOf<Any?>(
                    accountScopeHash,
                    document.documentKind.wireValue,
                    document.documentId.toString().lowercase(),
                ),
            ),
        ).use { cursor ->
            if (!cursor.moveToFirst()) null else Triple(
                cursor.getString(0),
                cursor.getString(1),
                cursor.getString(2),
            )
        } ?: return
        val spec = TABLE_SPECS.firstOrNull {
            it.table == identity.first && it.kind == document.documentKind
        } ?: throw ManagedStorageException.InvalidResponse()
        db.execSQL(
            "DELETE FROM `${spec.table}` WHERE ${spec.localKey(spec.table)} = ?",
            arrayOf<Any?>(identity.second),
        )
        upsertStateFromCurrentGeneration(
            db,
            spec.table,
            identity.second,
            document.documentKind,
            document.documentId,
            identity.third,
            document.revision,
            document.contentSha256,
        )
    }

    private fun applyUpsert(
        db: SupportSQLiteDatabase,
        document: ManagedDocument,
        payload: String,
    ) {
        if (payload.toByteArray(StandardCharsets.UTF_8).size > MAX_DOCUMENT_BYTES) {
            throw ManagedStorageException.InvalidResponse()
        }
        val envelope = runCatching { JSONObject(payload) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if (envelope.optInt("schema_version", -1) != 1) {
            throw ManagedStorageException.InvalidResponse()
        }
        val table = envelope.optString("table")
        val key = envelope.optJSONObject("key")
            ?: throw ManagedStorageException.InvalidResponse()
        val record = envelope.optJSONObject("record")
            ?: throw ManagedStorageException.InvalidResponse()
        val spec = TABLE_SPECS.firstOrNull {
            it.table == table && it.kind == document.documentKind
        } ?: throw ManagedStorageException.InvalidResponse()
        if (key.keys().asSequence().toSet() != spec.keyColumns.toSet()) {
            throw ManagedStorageException.InvalidResponse()
        }
        val columns = db.query("PRAGMA table_info(`${spec.table}`)").use { cursor ->
            buildList {
                while (cursor.moveToNext()) add(cursor.getString(1))
            }
        }
        if (columns.isEmpty() ||
            record.keys().asSequence().toSet() != columns.toSet() ||
            spec.keyColumns.any {
                !jsonValuesEqual(key.opt(it), record.opt(it))
            }
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val values = columns.map { databaseValue(record.get(it)) }
        val quotedColumns = columns.joinToString(", ") { "`$it`" }
        val placeholders = columns.joinToString(", ") { "?" }
        val updates = columns.filterNot(spec.keyColumns::contains)
            .joinToString(", ") { "`$it` = excluded.`$it`" }
        db.execSQL(
            """
                INSERT INTO `${spec.table}` ($quotedColumns)
                VALUES ($placeholders)
                ON CONFLICT(${spec.keyColumns.joinToString(", ") { "`$it`" }})
                DO UPDATE SET $updates
            """.trimIndent(),
            values.toTypedArray(),
        )
        val predicates = spec.keyColumns.joinToString(" AND ") { "`$it` IS ?" }
        val keyValues = spec.keyColumns.map { databaseValue(key.get(it)) }
        val localKey = stringOrNull(
            db,
            """
                SELECT ${spec.localKey("candidate")}
                FROM `${spec.table}` AS candidate
                WHERE $predicates
            """.trimIndent(),
            *keyValues.toTypedArray(),
        ) ?: throw ManagedStorageException.InvalidResponse()
        upsertStateFromCurrentGeneration(
            db,
            spec.table,
            localKey,
            document.documentKind,
            document.documentId,
            ManagedCanonicalJson.encode(key),
            document.revision,
            document.contentSha256,
        )
    }

    private fun upsertStateFromCurrentGeneration(
        db: SupportSQLiteDatabase,
        tableName: String,
        localKey: String,
        kind: ManagedDocumentKind,
        documentId: UUID,
        keyJson: String,
        revision: Long,
        contentSha256: String,
    ) {
        val generation = longOrNull(
            db,
            """
                SELECT generation FROM managedDocumentDirty
                WHERE tableName = ? AND localKey = ?
            """.trimIndent(),
            tableName,
            localKey,
        ) ?: 0L
        upsertState(
            db,
            tableName,
            localKey,
            kind.wireValue,
            documentId,
            canonicalObject(keyJson),
            generation,
            revision,
            contentSha256,
            clock(),
        )
    }

    private fun upsertState(
        db: SupportSQLiteDatabase,
        tableName: String,
        localKey: String,
        documentKind: String,
        documentId: UUID,
        keyJson: String,
        acknowledgedGeneration: Long,
        remoteRevision: Long,
        remoteContentSha256: String,
        updatedAtMs: Long,
    ) {
        if (acknowledgedGeneration < 0L ||
            remoteRevision <= 0L ||
            !remoteContentSha256.matches(SHA256)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        db.execSQL(
            """
                INSERT INTO managedDocumentState (
                    accountScopeHash, tableName, localKey, documentKind,
                    documentId, keyJSON, acknowledgedGeneration, remoteRevision,
                    remoteContentSHA256, updatedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(accountScopeHash, tableName, localKey) DO UPDATE SET
                    documentKind = excluded.documentKind,
                    documentId = excluded.documentId,
                    keyJSON = excluded.keyJSON,
                    acknowledgedGeneration = MAX(
                        managedDocumentState.acknowledgedGeneration,
                        excluded.acknowledgedGeneration
                    ),
                    remoteRevision = excluded.remoteRevision,
                    remoteContentSHA256 = excluded.remoteContentSHA256,
                    updatedAtMs = excluded.updatedAtMs
            """.trimIndent(),
            arrayOf<Any?>(
                accountScopeHash,
                tableName,
                localKey,
                documentKind,
                documentId.toString().lowercase(),
                canonicalObject(keyJson),
                acknowledgedGeneration,
                remoteRevision,
                remoteContentSha256,
                updatedAtMs,
            ),
        )
    }

    private fun cursorObject(cursor: Cursor): JSONObject {
        val objectValue = JSONObject()
        for (index in 0 until cursor.columnCount) {
            val value: Any = when (cursor.getType(index)) {
                Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
                Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(index)
                Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(index).also {
                    if (!it.isFinite()) throw ManagedStorageException.InvalidResponse()
                }
                Cursor.FIELD_TYPE_STRING -> cursor.getString(index)
                else -> throw ManagedStorageException.InvalidResponse()
            }
            objectValue.put(cursor.getColumnName(index), value)
        }
        return objectValue
    }

    private fun databaseValue(value: Any): Any? = when (value) {
        JSONObject.NULL -> null
        is String -> value
        is Boolean -> if (value) 1L else 0L
        is Byte, is Short, is Int, is Long -> (value as Number).toLong()
        is Float, is Double -> (value as Number).toDouble().also {
            if (!it.isFinite()) throw ManagedStorageException.InvalidResponse()
        }
        else -> throw ManagedStorageException.InvalidResponse()
    }

    private fun jsonValuesEqual(left: Any?, right: Any?): Boolean {
        if (left === JSONObject.NULL && right === JSONObject.NULL) return true
        if (left is Number && right is Number) {
            return left.toDouble().isFinite() &&
                right.toDouble().isFinite() &&
                left.toDouble() == right.toDouble()
        }
        return left == right
    }

    private fun canonicalObject(json: String): String = runCatching {
        ManagedCanonicalJson.encode(JSONObject(json))
    }.getOrElse { throw ManagedStorageException.InvalidResponse() }

    private fun stringOrNull(
        db: SupportSQLiteDatabase,
        sql: String,
        vararg arguments: Any?,
    ): String? = db.query(SimpleSQLiteQuery(sql, arguments)).use { cursor ->
        if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
    }

    private fun longOrNull(
        db: SupportSQLiteDatabase,
        sql: String,
        vararg arguments: Any?,
    ): Long? = db.query(SimpleSQLiteQuery(sql, arguments)).use { cursor ->
        if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
    }

    private data class DirtyRow(
        val tableName: String,
        val localKey: String,
        val documentKind: String,
        val generation: Long,
        val operation: String,
        val updatedAtMs: Long,
        val payloadJson: String?,
        val baseRevision: Long,
    )

    private data class LocalCandidate(
        val tableName: String,
        val documentKind: String,
        val localKey: String,
        val keyJson: String,
        val generation: Long,
        val baseRevision: Long,
        val updatedAtMs: Long,
        val payloadJson: String?,
    )

    private data class TableSpec(
        val table: String,
        val kind: ManagedDocumentKind,
        val keyColumns: List<String>,
        val eligibility: (String) -> String = { "1" },
    ) {
        fun localKey(row: String): String = keyColumns.joinToString(" || ':' || ") {
            "hex(CAST($row.`$it` AS BLOB))"
        }
    }

    companion object {
        private const val MAX_DOCUMENT_BYTES = 1_000_000
        private const val PREFERENCES_TABLE = "preferences"
        private const val PREFERENCES_KEY = "global"
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val TABLE_SPECS = listOf(
            TableSpec(
                "journal",
                ManagedDocumentKind.JOURNAL,
                listOf("deviceId", "day", "question"),
            ),
            TableSpec("labMarker", ManagedDocumentKind.LAB_MARKER, listOf("id")),
            TableSpec("nutritionEntry", ManagedDocumentKind.NUTRITION, listOf("id")),
            TableSpec(
                "nutritionCatalogItem",
                ManagedDocumentKind.NUTRITION_CATALOG,
                listOf("id"),
                eligibility = { "$it.`isSaved` != 0" },
            ),
            TableSpec(
                "strengthExercise",
                ManagedDocumentKind.STRENGTH_PLAN,
                listOf("id"),
                eligibility = {
                    "($it.`isCustom` != 0 OR $it.`createdAt` != 1 OR $it.`updatedAt` != 1)"
                },
            ),
            TableSpec("strengthRoutine", ManagedDocumentKind.STRENGTH_PLAN, listOf("id")),
            TableSpec(
                "strengthRoutineExercise",
                ManagedDocumentKind.STRENGTH_PLAN,
                listOf("id"),
            ),
            TableSpec("strengthSession", ManagedDocumentKind.STRENGTH_LOG, listOf("id")),
            TableSpec("strengthSet", ManagedDocumentKind.STRENGTH_LOG, listOf("id")),
            TableSpec("coachMessage", ManagedDocumentKind.COACH_HISTORY, listOf("id")),
            TableSpec("coachMemory", ManagedDocumentKind.COACH_MEMORY, listOf("id")),
            TableSpec("dayOwnership", ManagedDocumentKind.DAY_OWNERSHIP, listOf("day")),
        )

        internal fun documentId(
            kind: ManagedDocumentKind,
            tableName: String,
            canonicalKeyJson: String,
        ): UUID = ManagedStableIdentifier.uuid(
            (
                "noop-managed-document-v1\u0000${kind.wireValue}\u0000" +
                    "$tableName\u0000$canonicalKeyJson"
                ).toByteArray(StandardCharsets.UTF_8),
        )

        private fun documentId(
            kind: ManagedDocumentKind,
            payload: JSONObject,
        ): UUID {
            if (kind == ManagedDocumentKind.PREFERENCES) {
                return documentId(
                    kind,
                    PREFERENCES_TABLE,
                    """{"scope":"$PREFERENCES_KEY"}""",
                )
            }
            val table = payload.optString("table")
            val key = payload.optJSONObject("key")
                ?: throw ManagedStorageException.InvalidResponse()
            val spec = TABLE_SPECS.firstOrNull {
                it.table == table && it.kind == kind
            } ?: throw ManagedStorageException.InvalidResponse()
            if (key.keys().asSequence().toSet() != spec.keyColumns.toSet()) {
                throw ManagedStorageException.InvalidResponse()
            }
            return documentId(kind, table, ManagedCanonicalJson.encode(key))
        }

        private fun requestId(
            documentId: UUID,
            generation: Long,
            baseRevision: Long,
            contentSha256: String?,
        ): UUID = ManagedStableIdentifier.uuid(
            (
                "noop-managed-document-request-v1\u0000" +
                    "${documentId.toString().lowercase()}\u0000" +
                    "$generation\u0000$baseRevision\u0000" +
                    (contentSha256 ?: "deleted")
                ).toByteArray(StandardCharsets.UTF_8),
        )

        private fun deletionDigest(
            kind: ManagedDocumentKind,
            documentId: UUID,
            revision: Long,
        ): String = ManagedDigest.sha256(
            (
                "deleted:${kind.wireValue}:${documentId.toString().lowercase()}:$revision"
                ).toByteArray(StandardCharsets.UTF_8),
        )
    }
}
