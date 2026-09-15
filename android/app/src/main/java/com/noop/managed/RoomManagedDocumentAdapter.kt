package com.noop.managed

import android.content.Context
import android.database.Cursor
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.data.AnalysisInvalidationSource
import com.noop.data.BackupSettingsBridge
import com.noop.data.BackupSettingsCodec
import com.noop.data.WhoopDatabase
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.util.Base64
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
    private data class DayOwnershipValue(
        val deviceId: String,
        val locked: Long,
    )

    private val appContext = context?.applicationContext
    private val candidateLock = Any()
    private val candidates = mutableMapOf<String, LocalCandidate>()
    @Volatile
    private var claimedLocalProfileId: String? = null

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
                val localProfileId = requireLocalProfile(db)
                discardConflictingDirtyProfiles(
                    db,
                    PREFERENCES_TABLE,
                    PREFERENCES_KEY,
                    localProfileId,
                )
                val existing = stringOrNull(
                    db,
                    """
                        SELECT payloadJSON FROM managedDocumentDirty
                        WHERE localProfileId = ? AND tableName = ? AND localKey = ?
                    """.trimIndent(),
                    localProfileId,
                    PREFERENCES_TABLE,
                    PREFERENCES_KEY,
                )
                if (existing == payload) return@runInTransaction
                db.execSQL(
                    """
                        INSERT INTO managedDocumentDirty (
                            localProfileId, tableName, localKey, documentKind, generation,
                            operation, updatedAtMs, payloadJSON
                        ) VALUES (?, ?, ?, ?, 1, 'upsert', ?, ?)
                        ON CONFLICT(localProfileId, tableName, localKey) DO UPDATE SET
                            documentKind = excluded.documentKind,
                            generation = managedDocumentDirty.generation + 1,
                            operation = 'upsert',
                            updatedAtMs = excluded.updatedAtMs,
                            payloadJSON = excluded.payloadJSON
                    """.trimIndent(),
                    arrayOf<Any?>(
                        localProfileId,
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
            val localProfileId = requireLocalProfile()
            val local = pendingCandidates(localProfileId, limit)
            local.map { candidate ->
                val kind = ManagedDocumentKind.fromWire(candidate.documentKind)
                if (!isServerReadableKind(kind)) {
                    throw ManagedStorageException.InvalidResponse()
                }
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
        withContext(Dispatchers.IO) { requireLocalProfile() }
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
        val localProfileId = withContext(Dispatchers.IO) { requireLocalProfile() }
        validateDocumentMetadata(document, change)
        if (document.contentMode == "client_encrypted") {
            validateIgnoredEncryptedDocument(document)
            // This client has no key recovery or durable ciphertext inbox yet.
            // Failing keeps the feed cursor anchored so a capable client can
            // replay the document instead of silently losing it.
            throw ManagedStorageException.InvalidResponse()
        }
        validateServerReadableDocument(document)
        val deleted = document.deletedAt != null
        val payloadText = if (deleted) {
            if (document.payloadJson != null || change.operation != "tombstone") {
                throw ManagedStorageException.InvalidResponse()
            }
            null
        } else {
            val payload = document.payloadJson ?: throw ManagedStorageException.InvalidResponse()
            if (change.operation != "upsert") throw ManagedStorageException.InvalidResponse()
            if (document.documentKind == ManagedDocumentKind.DAY_OWNERSHIP) {
                validateIncomingDayOwnershipPayload(payload)
            }
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
            applyPreferences(
                payloadText ?: throw ManagedStorageException.InvalidResponse(),
                localProfileId,
            )
        }
        applyVerifiedDocument(document, payloadText, deleted)
    }

    private fun pendingCandidates(localProfileId: String, limit: Int): List<LocalCandidate> {
        val db = database.openHelper.readableDatabase
        val storagePredicates = SERVER_READABLE_TABLE_SPECS.joinToString(" OR ") {
            "(dirty.tableName = ? AND dirty.documentKind = ?)"
        }
        val arguments = buildList<Any?> {
            add(accountScopeHash)
            add(localProfileId)
            SERVER_READABLE_TABLE_SPECS.forEach { spec ->
                add(spec.table)
                add(spec.kind.wireValue)
            }
            add(limit)
        }.toTypedArray()
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
                    WHERE dirty.localProfileId = ?
                      AND (
                        state.acknowledgedGeneration IS NULL
                        OR state.acknowledgedGeneration < dirty.generation
                    )
                      AND ($storagePredicates)
                      AND (
                        dirty.operation != 'delete'
                        OR COALESCE(state.remoteRevision, 0) > 0
                      )
                    ORDER BY dirty.updatedAtMs, dirty.tableName, dirty.localKey
                    LIMIT ?
                """.trimIndent(),
                arguments,
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
        if (spec !in SERVER_READABLE_TABLE_SPECS) {
            throw ManagedStorageException.InvalidResponse()
        }
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
            val canonicalKey = canonicalObject(key)
            if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
                validateDayOwnershipKey(JSONObject(canonicalKey))
            }
            return LocalCandidate(
                dirty.tableName,
                dirty.documentKind,
                dirty.localKey,
                canonicalKey,
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
        if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
            validateDayOwnership(key, current)
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

    private fun validateDocumentMetadata(document: ManagedDocument, change: ManagedChange) {
        val metadata = change.document
        if (document.revision <= 0L ||
            runCatching { Instant.parse(document.updatedAt) }.isFailure ||
            document.deletedAt?.let { runCatching { Instant.parse(it) }.isFailure } == true ||
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
            (document.deletedAt == null && change.operation != "upsert") ||
            (document.deletedAt != null && change.operation != "tombstone")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun validateServerReadableDocument(document: ManagedDocument) {
        if (!isServerReadableKind(document.documentKind) ||
            document.contentMode != "server_readable" ||
            document.clientKeyId != null ||
            document.payloadCiphertextBase64 != null ||
            (document.payloadJson == null && document.deletedAt == null)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun validateIgnoredEncryptedDocument(document: ManagedDocument) {
        if (isServerReadableKind(document.documentKind) || document.payloadJson != null) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (document.deletedAt != null) {
            if (document.clientKeyId != null ||
                document.payloadCiphertextBase64 != null ||
                deletionDigest(
                    document.documentKind,
                    document.documentId,
                    document.revision,
                ) != document.contentSha256
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            return
        }

        val encoded = document.payloadCiphertextBase64
            ?: throw ManagedStorageException.InvalidResponse()
        val ciphertext = runCatching { Base64.getDecoder().decode(encoded) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if (document.clientKeyId == null ||
            Base64.getEncoder().encodeToString(ciphertext) != encoded ||
            ciphertext.size !in MIN_ENCRYPTED_DOCUMENT_BYTES..MAX_ENCRYPTED_DOCUMENT_BYTES ||
            ManagedDigest.sha256(ciphertext) != document.contentSha256
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun applyPreferences(payload: String, localProfileId: String) {
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
                    WHERE localProfileId = ? AND tableName = ? AND localKey = ?
                """.trimIndent(),
                localProfileId,
                PREFERENCES_TABLE,
                PREFERENCES_KEY,
            )
            if (existing != payload) {
                it.execSQL(
                    """
                        INSERT INTO managedDocumentDirty (
                            localProfileId, tableName, localKey, documentKind, generation,
                            operation, updatedAtMs, payloadJSON
                        ) VALUES (?, ?, ?, ?, 1, 'upsert', ?, ?)
                        ON CONFLICT(localProfileId, tableName, localKey) DO UPDATE SET
                            documentKind = excluded.documentKind,
                            generation = managedDocumentDirty.generation + 1,
                            operation = 'upsert',
                            updatedAtMs = excluded.updatedAtMs,
                            payloadJSON = excluded.payloadJSON
                    """.trimIndent(),
                    arrayOf<Any?>(
                        localProfileId,
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
            requireLocalProfile(db)
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
                    SELECT tableName, localKey, keyJSON,
                           acknowledgedGeneration, remoteRevision,
                           remoteContentSHA256
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
            if (!cursor.moveToFirst()) null else ManagedStateIdentity(
                tableName = cursor.getString(0),
                localKey = cursor.getString(1),
                keyJson = cursor.getString(2),
                acknowledgedGeneration = cursor.getLong(3),
                remoteRevision = cursor.getLong(4),
                remoteContentSha256 = cursor.getString(5),
            )
        }
        if (identity == null) {
            rebaseUnknownTombstoneIfPending(db, document)
            return
        }
        val spec = TABLE_SPECS.firstOrNull {
            it.table == identity.tableName && it.kind == document.documentKind
        } ?: throw ManagedStorageException.InvalidResponse()
        if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
            validateDayOwnershipKey(
                runCatching { JSONObject(identity.keyJson) }
                    .getOrElse { throw ManagedStorageException.InvalidResponse() },
            )
        }
        discardConflictingDirtyProfiles(
            db,
            spec.table,
            identity.localKey,
            requiredLocalProfileId(),
        )
        if (hasUnacknowledgedLocalGeneration(db, spec.table, identity.localKey)) {
            if (advancePendingTombstoneBaseline(db, spec, identity, document)) {
                return
            }
            throw ManagedStorageException.Conflict()
        }
        val changed = db.compileStatement(
            "DELETE FROM `${spec.table}` WHERE ${spec.localKey(spec.table)} = ?",
        ).let { statement ->
            statement.bindString(1, identity.localKey)
            statement.executeUpdateDelete()
        }
        if (changed > 0 && spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
            invalidateOwnershipAnalysis(db, dayFromLocalKey(identity.localKey))
        }
        upsertStateFromCurrentGeneration(
            db,
            spec.table,
            identity.localKey,
            document.documentKind,
            document.documentId,
            identity.keyJson,
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
        if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
            validateDayOwnership(key, record)
        }
        val keyValues = spec.keyColumns.map { databaseValue(key.get(it)) }
        val localKey = localKey(db, spec, keyValues)
        val day = if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
            key.getString("day")
        } else {
            null
        }
        val priorDayOwnership = day?.let { storedDayOwnership(db, it) }
        val incomingDayOwnership = day?.let {
            DayOwnershipValue(
                deviceId = record.getString("deviceId"),
                locked = exactBinaryFlag(record.get("locked"))
                    ?: throw ManagedStorageException.InvalidResponse(),
            )
        }
        ensureNoUnacknowledgedLocalGeneration(db, spec.table, localKey)
        discardConflictingDirtyProfiles(
            db,
            spec.table,
            localKey,
            requiredLocalProfileId(),
        )
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
        if (day != null && priorDayOwnership != incomingDayOwnership) {
            invalidateOwnershipAnalysis(db, day)
        }
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

    private fun validateIncomingDayOwnershipPayload(payload: JSONObject) {
        if (payload.opt("table") != "dayOwnership") {
            throw ManagedStorageException.InvalidResponse()
        }
        val key = payload.optJSONObject("key")
            ?: throw ManagedStorageException.InvalidResponse()
        val record = payload.optJSONObject("record")
            ?: throw ManagedStorageException.InvalidResponse()
        validateDayOwnership(key, record)
    }

    private fun advancePendingTombstoneBaseline(
        db: SupportSQLiteDatabase,
        spec: TableSpec,
        identity: ManagedStateIdentity,
        document: ManagedDocument,
    ): Boolean {
        val priorTombstoneDigest = deletionDigest(
            document.documentKind,
            document.documentId,
            identity.remoteRevision,
        )
        if (identity.remoteContentSha256 != priorTombstoneDigest) return false
        if (document.revision < identity.remoteRevision) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (document.revision == identity.remoteRevision) return true
        upsertState(
            db,
            spec.table,
            identity.localKey,
            spec.kind.wireValue,
            document.documentId,
            identity.keyJson,
            identity.acknowledgedGeneration,
            document.revision,
            document.contentSha256,
            clock(),
        )
        return true
    }

    private fun rebaseUnknownTombstoneIfPending(
        db: SupportSQLiteDatabase,
        document: ManagedDocument,
    ) {
        val spec = SERVER_READABLE_TABLE_SPECS.singleOrNull {
            it.kind == document.documentKind
        } ?: throw ManagedStorageException.InvalidResponse()
        val pendingRows = db.query(
            SimpleSQLiteQuery(
                """
                    SELECT dirty.localKey,
                           dirty.generation,
                           dirty.operation,
                           COALESCE(state.acknowledgedGeneration, 0),
                           state.documentId,
                           state.keyJSON
                    FROM managedDocumentDirty AS dirty
                    LEFT JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE dirty.localProfileId = ?
                      AND dirty.tableName = ?
                      AND dirty.documentKind = ?
                      AND dirty.generation > COALESCE(state.acknowledgedGeneration, 0)
                    ORDER BY dirty.localKey
                """.trimIndent(),
                arrayOf<Any?>(
                    accountScopeHash,
                    requiredLocalProfileId(),
                    spec.table,
                    spec.kind.wireValue,
                ),
            ),
        ).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(
                        PendingDirtyIdentityRow(
                            localKey = cursor.getString(0),
                            generation = cursor.getLong(1),
                            operation = cursor.getString(2),
                            acknowledgedGeneration = cursor.getLong(3),
                            stateDocumentId = if (cursor.isNull(4)) {
                                null
                            } else {
                                cursor.getString(4)
                            },
                            stateKeyJson = if (cursor.isNull(5)) {
                                null
                            } else {
                                cursor.getString(5)
                            },
                        ),
                    )
                }
            }
        }

        var matching: PendingLocalIdentity? = null
        for (row in pendingRows) {
            val identity = pendingLocalIdentity(db, spec, row)
            if (identity.documentId != document.documentId) continue
            if (matching != null && matching.localKey != identity.localKey) {
                throw ManagedStorageException.InvalidResponse()
            }
            matching = identity
        }
        val identity = matching ?: return
        val acknowledgedGeneration =
            if (identity.operation == "delete" && !identity.hadState) {
                identity.generation
            } else {
                identity.acknowledgedGeneration
            }
        upsertState(
            db,
            spec.table,
            identity.localKey,
            spec.kind.wireValue,
            identity.documentId,
            identity.keyJson,
            acknowledgedGeneration,
            document.revision,
            document.contentSha256,
            clock(),
        )
    }

    private fun pendingLocalIdentity(
        db: SupportSQLiteDatabase,
        spec: TableSpec,
        dirty: PendingDirtyIdentityRow,
    ): PendingLocalIdentity {
        if (dirty.generation <= dirty.acknowledgedGeneration ||
            dirty.operation !in setOf("upsert", "delete")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
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
        val key = if (current != null) {
            JSONObject().also { keyObject ->
                spec.keyColumns.forEach { column ->
                    if (!current.has(column)) {
                        throw ManagedStorageException.InvalidResponse()
                    }
                    keyObject.put(column, current.get(column))
                }
                if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
                    validateDayOwnership(keyObject, current)
                }
            }
        } else {
            val keyObject = dirty.stateKeyJson?.let {
                runCatching { JSONObject(it) }
                    .getOrElse { throw ManagedStorageException.InvalidResponse() }
            } ?: when (spec.kind) {
                ManagedDocumentKind.DAY_OWNERSHIP -> JSONObject()
                    .put("day", dayFromLocalKey(dirty.localKey))
                else -> throw ManagedStorageException.InvalidResponse()
            }
            if (spec.kind == ManagedDocumentKind.DAY_OWNERSHIP) {
                validateDayOwnershipKey(keyObject)
            }
            keyObject
        }
        val keyJson = ManagedCanonicalJson.encode(key)
        val expectedDocumentId = documentId(spec.kind, spec.table, keyJson)
        if (dirty.stateDocumentId != null &&
            dirty.stateDocumentId != expectedDocumentId.toString().lowercase()
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return PendingLocalIdentity(
            localKey = dirty.localKey,
            keyJson = keyJson,
            generation = dirty.generation,
            operation = dirty.operation,
            hadState = dirty.stateDocumentId != null,
            acknowledgedGeneration = dirty.acknowledgedGeneration,
            documentId = expectedDocumentId,
        )
    }

    private fun validateDayOwnership(key: JSONObject, record: JSONObject) {
        validateDayOwnershipKey(key)
        val keyDay = key.opt("day") as? String
            ?: throw ManagedStorageException.InvalidResponse()
        val recordDay = record.opt("day") as? String
            ?: throw ManagedStorageException.InvalidResponse()
        val deviceId = record.opt("deviceId") as? String
            ?: throw ManagedStorageException.InvalidResponse()
        if (keyDay != recordDay ||
            deviceId != deviceId.trim() ||
            deviceId.isBlank() ||
            deviceId.toByteArray(StandardCharsets.UTF_8).size >
            MAX_DAY_OWNERSHIP_DEVICE_ID_BYTES ||
            deviceId.any { Character.isISOControl(it.code) } ||
            exactBinaryFlag(record.opt("locked")) == null
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun validateDayOwnershipKey(key: JSONObject) {
        val day = key.opt("day") as? String
            ?: throw ManagedStorageException.InvalidResponse()
        val parsed = if (VALID_CIVIL_DAY.matches(day)) {
            runCatching { LocalDate.parse(day) }.getOrNull()
        } else {
            null
        }
        if (key.keys().asSequence().toSet() != setOf("day") ||
            parsed == null ||
            parsed.year !in 2000..2099
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun exactBinaryFlag(value: Any?): Long? = when (value) {
        is Boolean -> if (value) 1L else 0L
        is Byte, is Short, is Int, is Long -> (value as Number).toLong()
            .takeIf { it == 0L || it == 1L }
        else -> null
    }

    private fun dayFromLocalKey(localKey: String): String {
        if (localKey.length % 2 != 0 || !HEX_BYTES.matches(localKey)) {
            throw ManagedStorageException.InvalidResponse()
        }
        val bytes = ByteArray(localKey.length / 2) { index ->
            localKey.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
        val day = String(bytes, StandardCharsets.UTF_8)
        if (!bytes.contentEquals(day.toByteArray(StandardCharsets.UTF_8))) {
            throw ManagedStorageException.InvalidResponse()
        }
        return day
    }

    private fun storedDayOwnership(
        db: SupportSQLiteDatabase,
        day: String,
    ): DayOwnershipValue? = db.query(
        SimpleSQLiteQuery(
            "SELECT deviceId, locked FROM dayOwnership WHERE day = ?",
            arrayOf<Any?>(day),
        ),
    ).use { cursor ->
        if (!cursor.moveToFirst()) {
            null
        } else {
            DayOwnershipValue(
                deviceId = cursor.getString(0),
                locked = cursor.getLong(1),
            )
        }
    }

    private fun invalidateOwnershipAnalysis(
        db: SupportSQLiteDatabase,
        day: String,
    ) {
        val timestamp = runCatching {
            LocalDate.parse(day)
                .atTime(LocalTime.NOON)
                .atZone(ZoneId.systemDefault())
                .toEpochSecond()
        }.getOrElse { throw ManagedStorageException.InvalidResponse() }
        db.execSQL(
            """
                INSERT INTO analysisDirtySource (
                    deviceId, generation, acknowledgedGeneration,
                    earliestAffectedTs, latestAffectedTs
                ) VALUES (?, 1, 0, ?, ?)
                ON CONFLICT(deviceId) DO UPDATE SET
                    generation = analysisDirtySource.generation + 1,
                    earliestAffectedTs = CASE
                        WHEN analysisDirtySource.earliestAffectedTs IS NULL
                            THEN excluded.earliestAffectedTs
                        ELSE MIN(
                            analysisDirtySource.earliestAffectedTs,
                            excluded.earliestAffectedTs
                        )
                    END,
                    latestAffectedTs = CASE
                        WHEN analysisDirtySource.latestAffectedTs IS NULL
                            THEN excluded.latestAffectedTs
                        ELSE MAX(
                            analysisDirtySource.latestAffectedTs,
                            excluded.latestAffectedTs
                        )
                    END
            """.trimIndent(),
            arrayOf<Any?>(
                AnalysisInvalidationSource.OWNERSHIP,
                timestamp,
                timestamp,
            ),
        )
    }

    private fun localKey(
        db: SupportSQLiteDatabase,
        spec: TableSpec,
        keyValues: List<Any?>,
    ): String {
        val projectedKey = spec.keyColumns.joinToString(", ") { "? AS `$it`" }
        return stringOrNull(
            db,
            """
                SELECT ${spec.localKey("candidate")}
                FROM (SELECT $projectedKey) AS candidate
            """.trimIndent(),
            *keyValues.toTypedArray(),
        ) ?: throw ManagedStorageException.InvalidResponse()
    }

    private fun ensureNoUnacknowledgedLocalGeneration(
        db: SupportSQLiteDatabase,
        tableName: String,
        localKey: String,
    ) {
        if (hasUnacknowledgedLocalGeneration(db, tableName, localKey)) {
            throw ManagedStorageException.Conflict()
        }
    }

    private fun hasUnacknowledgedLocalGeneration(
        db: SupportSQLiteDatabase,
        tableName: String,
        localKey: String,
    ): Boolean = longOrNull(
            db,
            """
                SELECT EXISTS (
                    SELECT 1
                    FROM managedDocumentDirty AS dirty
                    LEFT JOIN managedDocumentState AS state
                      ON state.accountScopeHash = ?
                     AND state.tableName = dirty.tableName
                     AND state.localKey = dirty.localKey
                    WHERE dirty.localProfileId = ?
                      AND dirty.tableName = ?
                      AND dirty.localKey = ?
                      AND dirty.generation > COALESCE(state.acknowledgedGeneration, 0)
                )
            """.trimIndent(),
            accountScopeHash,
            requiredLocalProfileId(),
            tableName,
            localKey,
        ) == 1L

    private fun discardConflictingDirtyProfiles(
        db: SupportSQLiteDatabase,
        tableName: String,
        localKey: String,
        localProfileId: String,
    ) {
        db.execSQL(
            """
                DELETE FROM managedDocumentDirty
                WHERE tableName = ? AND localKey = ? AND localProfileId != ?
            """.trimIndent(),
            arrayOf<Any?>(tableName, localKey, localProfileId),
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
                WHERE localProfileId = ? AND tableName = ? AND localKey = ?
            """.trimIndent(),
            requiredLocalProfileId(),
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

    private fun requireLocalProfile(): String {
        var required: String? = null
        database.runInTransaction {
            required = requireLocalProfile(database.openHelper.writableDatabase)
        }
        return required ?: throw ManagedStorageException.InvalidResponse()
    }

    private fun requireLocalProfile(db: SupportSQLiteDatabase): String {
        val binding = db.query(
            """
                SELECT localProfileId, accountScopeHash
                FROM managedLocalProfile
                WHERE bindingId = 1
            """.trimIndent(),
        ).use { cursor ->
            if (!cursor.moveToFirst() || cursor.isNull(0)) {
                throw ManagedStorageException.InvalidResponse()
            }
            LocalProfileBinding(
                localProfileId = cursor.getString(0),
                accountScopeHash = if (cursor.isNull(1)) null else cursor.getString(1),
            )
        }
        val localProfileId = binding.localProfileId
        if (localProfileId.isBlank() || localProfileId.length > 64) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (binding.accountScopeHash != accountScopeHash ||
            binding.localProfileId != accountScopeHash
        ) {
            throw ManagedStorageException.Conflict()
        }
        claimedLocalProfileId = accountScopeHash
        return accountScopeHash
    }

    private fun requiredLocalProfileId(): String =
        claimedLocalProfileId ?: throw ManagedStorageException.InvalidResponse()

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

    private data class PendingDirtyIdentityRow(
        val localKey: String,
        val generation: Long,
        val operation: String,
        val acknowledgedGeneration: Long,
        val stateDocumentId: String?,
        val stateKeyJson: String?,
    )

    private data class PendingLocalIdentity(
        val localKey: String,
        val keyJson: String,
        val generation: Long,
        val operation: String,
        val hadState: Boolean,
        val acknowledgedGeneration: Long,
        val documentId: UUID,
    )

    private data class ManagedStateIdentity(
        val tableName: String,
        val localKey: String,
        val keyJson: String,
        val acknowledgedGeneration: Long,
        val remoteRevision: Long,
        val remoteContentSha256: String,
    )

    private data class LocalProfileBinding(
        val localProfileId: String,
        val accountScopeHash: String?,
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
        private const val MIN_ENCRYPTED_DOCUMENT_BYTES = 17
        private const val MAX_ENCRYPTED_DOCUMENT_BYTES = 1_048_576
        private const val MAX_DAY_OWNERSHIP_DEVICE_ID_BYTES = 256
        private const val PREFERENCES_TABLE = "preferences"
        private const val PREFERENCES_KEY = "global"
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val HEX_BYTES = Regex("^(?:[0-9A-Fa-f]{2})+$")
        private val VALID_CIVIL_DAY = Regex("^(?:20[0-9]{2})-[0-9]{2}-[0-9]{2}$")
        private val SERVER_READABLE_KINDS = setOf(
            ManagedDocumentKind.DAY_OWNERSHIP,
        )
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
        private val SERVER_READABLE_TABLE_SPECS = TABLE_SPECS.filter {
            it.kind in SERVER_READABLE_KINDS
        }

        internal fun isServerReadableKind(kind: ManagedDocumentKind): Boolean =
            kind in SERVER_READABLE_KINDS

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
