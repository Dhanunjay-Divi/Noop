package com.noop.managed

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.UUID
import org.json.JSONObject

internal data class ManagedDocumentCiphertextInboxPolicy(
    val maximumRecordCount: Int = 512,
    val maximumTotalBytes: Long = 64L * 1_024L * 1_024L,
    val maximumAgeMilliseconds: Long = 30L * 24L * 60L * 60L * 1_000L,
) {
    init {
        require(maximumRecordCount > 0)
        require(maximumTotalBytes > 0)
        require(maximumAgeMilliseconds > 0)
    }
}

internal enum class ManagedDocumentCiphertextInboxLegacyDisposition(
    val diagnosticValue: String,
) {
    NONE("none"),
    MIGRATED("migrated"),
    PURGED_UNATTRIBUTABLE("purged_unattributable"),
}

internal enum class ManagedDocumentCiphertextInboxSweepDisposition(
    val diagnosticValue: String,
) {
    CLEAN("clean"),
    INVALID_PURGED("invalid_purged"),
    STALE_PURGED("stale_purged"),
    QUOTA_TRIMMED("quota_trimmed"),
    QUOTA_BLOCKED("quota_blocked"),
    MULTIPLE("multiple"),
}

internal data class ManagedDocumentCiphertextInboxMaintenanceResult(
    val legacyDisposition: ManagedDocumentCiphertextInboxLegacyDisposition,
    val sweepDisposition: ManagedDocumentCiphertextInboxSweepDisposition,
)

internal data class ManagedDocumentCiphertextInboxOutgoingReference(
    val localIdentifier: String,
    val generation: Long,
    val revision: Long,
)

internal enum class ManagedDocumentCiphertextInboxPurgeDisposition(
    val diagnosticValue: String,
) {
    NOT_PRESENT("not_present"),
    REMOVED("removed"),
}

internal class ManagedDocumentCiphertextInbox(
    private val root: File,
    private val configuredAccountScopeHash: String? = null,
    private val policy: ManagedDocumentCiphertextInboxPolicy =
        ManagedDocumentCiphertextInboxPolicy(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private data class StoredRecord(
        val direction: String,
        val accountScopeHash: String,
        val identity: String,
        val documentKind: ManagedDocumentKind,
        val documentId: UUID,
        val revision: Long,
        val keyId: UUID,
        val plaintextSha256: String?,
        val contentSha256: String,
        val ciphertextBase64: String,
        val stagedAtMilliseconds: Long,
    )

    private data class StoredEntry(
        val file: File,
        val bytes: ByteArray,
        val record: StoredRecord,
    ) {
        val byteCount: Long
            get() = bytes.size.toLong()
    }

    private sealed interface LegacyInspection {
        data object Empty : LegacyInspection
        data class Safe(val entries: List<StoredEntry>) : LegacyInspection
        data object Unsafe : LegacyInspection
    }

    private var boundAccountScopeHash: String? = null
    private var prepared = false

    constructor(context: Context) : this(
        File(
            context.applicationContext.noBackupFilesDir,
            "managed-document-ciphertext-v1",
        ),
    )

    @Synchronized
    fun startupMaintenance(
        accountScopeHash: String? = null,
    ): ManagedDocumentCiphertextInboxMaintenanceResult {
        val scope = bind(accountScopeHash)
        val result = performMaintenance(scope)
        prepared = true
        return result
    }

    @Synchronized
    fun purgeAccount(
        accountScopeHash: String,
    ): ManagedDocumentCiphertextInboxPurgeDisposition {
        requireValidScope(accountScopeHash)
        val legacyMatches = mutableListOf<File>()
        DIRECTIONS.forEach { direction ->
            val directory = legacyDirectory(direction)
            if (!directory.exists()) return@forEach
            val files = directory.listFiles()
                ?: throw ManagedStorageException.InvalidResponse()
            files.forEach { file ->
                val entry = validatedEntry(
                    file = file,
                    direction = direction,
                    expectedAccountScopeHash = null,
                    maximumBytes = DEFAULT_MAXIMUM_TOTAL_BYTES,
                ) ?: throw ManagedStorageException.InvalidResponse()
                if (entry.record.accountScopeHash == accountScopeHash) {
                    legacyMatches += file
                }
            }
        }

        var removed = false
        val accountRoot = accountRoot(accountScopeHash)
        if (accountRoot.exists()) {
            if (!accountRoot.deleteRecursively()) {
                throw ManagedStorageException.InvalidResponse()
            }
            removed = true
        }
        legacyMatches.forEach { file ->
            if (!file.delete()) {
                throw ManagedStorageException.InvalidResponse()
            }
            removed = true
        }
        removeEmptyLegacyDirectories()
        removeDirectoryIfEmpty(File(root, ACCOUNTS_DIRECTORY))
        return if (removed) {
            ManagedDocumentCiphertextInboxPurgeDisposition.REMOVED
        } else {
            ManagedDocumentCiphertextInboxPurgeDisposition.NOT_PRESENT
        }
    }

    @Synchronized
    fun reconcileOutgoing(
        accountScopeHash: String,
        retaining: List<ManagedDocumentCiphertextInboxOutgoingReference>,
    ): Int {
        val scope = prepareIfNeeded(accountScopeHash)
        val identities = retaining.mapTo(mutableSetOf()) { reference ->
            if (!reference.localIdentifier.matches(SHA256_PATTERN) ||
                reference.generation <= 0L ||
                reference.revision <= 0L
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            outgoingIdentity(
                scope,
                reference.localIdentifier,
                reference.generation,
                reference.revision,
            )
        }
        var removed = 0
        scopedEntries(scope)
            .filter {
                it.record.direction == OUTGOING &&
                    it.record.identity !in identities
            }
            .forEach {
                removeFileOrDirectory(it.file)
                removed += 1
            }
        cleanupEmptyScopedDirectories(scope)
        return removed
    }

    @Synchronized
    fun stageIncoming(accountScopeHash: String, document: ManagedDocument) {
        val scope = prepareIfNeeded(accountScopeHash)
        val keyId = document.clientKeyId
            ?: throw ManagedStorageException.InvalidResponse()
        val encoded = document.payloadCiphertextBase64
            ?: throw ManagedStorageException.InvalidResponse()
        val ciphertext = runCatching { Base64.getDecoder().decode(encoded) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        if (
            document.contentMode != "client_encrypted" ||
            document.deletedAt != null ||
            Base64.getEncoder().encodeToString(ciphertext) != encoded ||
            sha256(ciphertext) != document.contentSha256
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val identity = incomingIdentity(scope, document)
        write(
            direction = INCOMING,
            identity = identity,
            accountScopeHash = scope,
            documentKind = document.documentKind,
            documentId = document.documentId,
            revision = document.revision,
            keyId = keyId,
            plaintextSha256 = null,
            ciphertext = ciphertext,
        )
    }

    @Synchronized
    fun removeIncoming(accountScopeHash: String, document: ManagedDocument) {
        val scope = prepareIfNeeded(accountScopeHash)
        remove(
            file(
                scope,
                INCOMING,
                incomingIdentity(scope, document),
            ),
            scope,
        )
    }

    @Synchronized
    fun outgoingEnvelope(
        accountScopeHash: String,
        localIdentifier: String,
        generation: Long,
        documentKind: ManagedDocumentKind,
        documentId: UUID,
        revision: Long,
        key: ManagedDocumentKey,
        plaintext: ByteArray,
    ): ByteArray {
        val scope = prepareIfNeeded(accountScopeHash)
        val identity = outgoingIdentity(
            scope,
            localIdentifier,
            generation,
            revision,
        )
        val destination = file(scope, OUTGOING, identity)
        if (destination.exists()) {
            val record = read(destination, OUTGOING, scope)
            val ciphertext = runCatching {
                Base64.getDecoder().decode(record.ciphertextBase64)
            }.getOrElse { throw ManagedStorageException.InvalidResponse() }
            if (
                record.direction != OUTGOING ||
                record.accountScopeHash != scope ||
                record.identity != identity ||
                record.documentKind != documentKind ||
                record.documentId != documentId ||
                record.revision != revision ||
                record.keyId != key.keyId ||
                record.plaintextSha256 != sha256(plaintext) ||
                Base64.getEncoder().encodeToString(ciphertext) !=
                    record.ciphertextBase64 ||
                sha256(ciphertext) != record.contentSha256
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            return ciphertext
        }
        val ciphertext = ManagedDocumentEnvelope.seal(
            plaintext,
            key.keyData,
            ManagedDocumentEnvelopeMetadata(
                scope,
                documentKind,
                documentId,
                revision,
            ),
        )
        write(
            direction = OUTGOING,
            identity = identity,
            accountScopeHash = scope,
            documentKind = documentKind,
            documentId = documentId,
            revision = revision,
            keyId = key.keyId,
            plaintextSha256 = sha256(plaintext),
            ciphertext = ciphertext,
        )
        return ciphertext
    }

    @Synchronized
    fun removeOutgoing(
        accountScopeHash: String,
        localIdentifier: String,
        generation: Long,
        revision: Long,
    ) {
        val scope = prepareIfNeeded(accountScopeHash)
        remove(
            file(
                scope,
                OUTGOING,
                outgoingIdentity(
                    scope,
                    localIdentifier,
                    generation,
                    revision,
                ),
            ),
            scope,
        )
    }

    @Synchronized
    fun pendingIncomingCount(): Int = pendingCount(INCOMING)

    @Synchronized
    fun pendingOutgoingCount(): Int = pendingCount(OUTGOING)

    private fun bind(accountScopeHash: String?): String {
        val selected = requireValidScope(
            accountScopeHash ?: configuredAccountScopeHash ?: boundAccountScopeHash
        )
        if (
            configuredAccountScopeHash != null &&
            configuredAccountScopeHash != selected
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (
            boundAccountScopeHash != null &&
            boundAccountScopeHash != selected
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        boundAccountScopeHash = selected
        return selected
    }

    private fun requireValidScope(value: String?): String {
        if (value == null || !value.matches(SHA256_PATTERN)) {
            throw ManagedStorageException.InvalidResponse()
        }
        return value
    }

    private fun prepareIfNeeded(accountScopeHash: String): String {
        val scope = bind(accountScopeHash)
        if (!prepared) {
            performMaintenance(scope)
            prepared = true
        }
        return scope
    }

    private fun performMaintenance(
        accountScopeHash: String,
    ): ManagedDocumentCiphertextInboxMaintenanceResult =
        ManagedDocumentCiphertextInboxMaintenanceResult(
            legacyDisposition = migrateLegacySharedStorage(accountScopeHash),
            sweepDisposition = sweepScopedStorage(accountScopeHash),
        )

    private fun migrateLegacySharedStorage(
        accountScopeHash: String,
    ): ManagedDocumentCiphertextInboxLegacyDisposition =
        when (val inspection = inspectLegacySharedStorage(accountScopeHash)) {
            LegacyInspection.Empty -> {
                removeEmptyLegacyDirectories()
                ManagedDocumentCiphertextInboxLegacyDisposition.NONE
            }
            LegacyInspection.Unsafe -> {
                purgeLegacySharedStorage()
                ManagedDocumentCiphertextInboxLegacyDisposition.PURGED_UNATTRIBUTABLE
            }
            is LegacyInspection.Safe -> {
                inspection.entries.forEach { entry ->
                    val destination = file(
                        accountScopeHash,
                        entry.record.direction,
                        entry.record.identity,
                    )
                    if (
                        destination.exists() &&
                        !destination.readBytes().contentEquals(entry.bytes)
                    ) {
                        purgeLegacySharedStorage()
                        return ManagedDocumentCiphertextInboxLegacyDisposition
                            .PURGED_UNATTRIBUTABLE
                    }
                }
                inspection.entries.forEach { entry ->
                    val destination = file(
                        accountScopeHash,
                        entry.record.direction,
                        entry.record.identity,
                    )
                    ensureDirectory(destination.parentFile)
                    if (destination.exists()) {
                        if (!entry.file.delete()) {
                            throw ManagedStorageException.InvalidResponse()
                        }
                    } else {
                        moveAtomically(entry.file, destination)
                    }
                }
                removeEmptyLegacyDirectories()
                ManagedDocumentCiphertextInboxLegacyDisposition.MIGRATED
            }
        }

    private fun inspectLegacySharedStorage(
        accountScopeHash: String,
    ): LegacyInspection {
        val entries = mutableListOf<StoredEntry>()
        DIRECTIONS.forEach { direction ->
            val directory = legacyDirectory(direction)
            if (!directory.exists()) return@forEach
            val files = directory.listFiles()
                ?: throw ManagedStorageException.InvalidResponse()
            files.forEach { file ->
                val entry = validatedEntry(
                    file = file,
                    direction = direction,
                    expectedAccountScopeHash = null,
                    maximumBytes = policy.maximumTotalBytes,
                ) ?: return LegacyInspection.Unsafe
                if (entry.record.accountScopeHash != accountScopeHash) {
                    return LegacyInspection.Unsafe
                }
                entries += entry
            }
        }
        return if (entries.isEmpty()) {
            LegacyInspection.Empty
        } else {
            LegacyInspection.Safe(entries)
        }
    }

    private fun purgeLegacySharedStorage() {
        DIRECTIONS.forEach { direction ->
            val directory = legacyDirectory(direction)
            if (directory.exists() && !directory.deleteRecursively()) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
    }

    private fun sweepScopedStorage(
        accountScopeHash: String,
    ): ManagedDocumentCiphertextInboxSweepDisposition {
        val now = clock().coerceAtLeast(0L)
        val valid = mutableListOf<StoredEntry>()
        var removedInvalid = false
        var removedStale = false
        var trimmedQuota = false

        DIRECTIONS.forEach { direction ->
            val directory = scopedDirectory(accountScopeHash, direction)
            if (!directory.exists()) return@forEach
            val files = directory.listFiles()
                ?: throw ManagedStorageException.InvalidResponse()
            files.forEach { file ->
                val entry = validatedEntry(
                    file = file,
                    direction = direction,
                    expectedAccountScopeHash = accountScopeHash,
                    maximumBytes = policy.maximumTotalBytes,
                )
                if (entry == null) {
                    removeFileOrDirectory(file)
                    removedInvalid = true
                    return@forEach
                }
                if (direction == INCOMING &&
                    entry.record.stagedAtMilliseconds > now
                ) {
                    removeFileOrDirectory(file)
                    removedInvalid = true
                    return@forEach
                }
                if (direction == INCOMING &&
                    now - entry.record.stagedAtMilliseconds >=
                    policy.maximumAgeMilliseconds
                ) {
                    removeFileOrDirectory(file)
                    removedStale = true
                    return@forEach
                }
                valid += entry
            }
        }

        valid.sortWith(OLDEST_FIRST)
        var totalBytes = valid.sumOf(StoredEntry::byteCount)
        while (
            valid.size > policy.maximumRecordCount ||
            totalBytes > policy.maximumTotalBytes
        ) {
            val removableIndex = valid.indexOfFirst { it.record.direction == INCOMING }
            if (removableIndex < 0) break
            val removed = valid.removeAt(removableIndex)
            removeFileOrDirectory(removed.file)
            totalBytes -= removed.byteCount
            trimmedQuota = true
        }
        val quotaBlocked =
            valid.size > policy.maximumRecordCount ||
                totalBytes > policy.maximumTotalBytes
        cleanupEmptyScopedDirectories(accountScopeHash)

        val flags = listOf(
            removedInvalid,
            removedStale,
            trimmedQuota,
            quotaBlocked,
        ).count { it }
        return when {
            flags > 1 ->
                ManagedDocumentCiphertextInboxSweepDisposition.MULTIPLE
            removedInvalid ->
                ManagedDocumentCiphertextInboxSweepDisposition.INVALID_PURGED
            removedStale ->
                ManagedDocumentCiphertextInboxSweepDisposition.STALE_PURGED
            trimmedQuota ->
                ManagedDocumentCiphertextInboxSweepDisposition.QUOTA_TRIMMED
            quotaBlocked ->
                ManagedDocumentCiphertextInboxSweepDisposition.QUOTA_BLOCKED
            else -> ManagedDocumentCiphertextInboxSweepDisposition.CLEAN
        }
    }

    private fun write(
        direction: String,
        identity: String,
        accountScopeHash: String,
        documentKind: ManagedDocumentKind,
        documentId: UUID,
        revision: Long,
        keyId: UUID,
        plaintextSha256: String?,
        ciphertext: ByteArray,
    ) {
        val value = JSONObject()
            .put("version", 1)
            .put("direction", direction)
            .put("account_scope_hash", accountScopeHash)
            .put("identity", identity)
            .put("document_kind", documentKind.wireValue)
            .put("document_id", documentId.toString().lowercase())
            .put("revision", revision)
            .put("key_id", keyId.toString().lowercase())
            .put("plaintext_sha256", plaintextSha256 ?: JSONObject.NULL)
            .put("content_sha256", sha256(ciphertext))
            .put(
                "ciphertext_base64",
                Base64.getEncoder().encodeToString(ciphertext),
            )
            .put("staged_at_milliseconds", clock().coerceAtLeast(0L))
        val bytes = ManagedCanonicalJson.encode(value)
            .toByteArray(StandardCharsets.UTF_8)
        val destination = file(accountScopeHash, direction, identity)
        makeRoom(
            newByteCount = bytes.size.toLong(),
            replacing = destination,
            accountScopeHash = accountScopeHash,
        )
        ensureDirectory(destination.parentFile)
        val partial = File.createTempFile(
            ".${destination.name}.",
            ".partial",
            destination.parentFile,
        )
        try {
            FileOutputStream(partial).use {
                it.write(bytes)
                it.fd.sync()
            }
            moveAtomically(partial, destination)
        } catch (error: ManagedStorageException) {
            throw error
        } catch (_: Exception) {
            throw ManagedStorageException.InvalidResponse()
        } finally {
            partial.delete()
        }
    }

    private fun makeRoom(
        newByteCount: Long,
        replacing: File,
        accountScopeHash: String,
    ) {
        if (newByteCount > policy.maximumTotalBytes) {
            throw ManagedStorageException.QuotaExceeded()
        }
        sweepScopedStorage(accountScopeHash)
        val entries = scopedEntries(accountScopeHash)
            .filter { it.file.absoluteFile != replacing.absoluteFile }
            .sortedWith(OLDEST_FIRST)
            .toMutableList()
        var projectedCount = entries.size + 1
        var projectedBytes =
            entries.sumOf(StoredEntry::byteCount) + newByteCount
        while (
            projectedCount > policy.maximumRecordCount ||
            projectedBytes > policy.maximumTotalBytes
        ) {
            val removableIndex = entries.indexOfFirst {
                it.record.direction == INCOMING
            }
            if (removableIndex < 0) {
                throw ManagedStorageException.QuotaExceeded()
            }
            val removed = entries.removeAt(removableIndex)
            removeFileOrDirectory(removed.file)
            projectedCount -= 1
            projectedBytes -= removed.byteCount
        }
    }

    private fun read(
        source: File,
        direction: String,
        accountScopeHash: String,
    ): StoredRecord =
        validatedEntry(
            file = source,
            direction = direction,
            expectedAccountScopeHash = accountScopeHash,
            maximumBytes = policy.maximumTotalBytes,
        )?.record ?: throw ManagedStorageException.InvalidResponse()

    private fun remove(
        source: File,
        accountScopeHash: String,
    ) {
        if (source.exists() && !source.delete()) {
            throw ManagedStorageException.InvalidResponse()
        }
        cleanupEmptyScopedDirectories(accountScopeHash)
    }

    private fun pendingCount(direction: String): Int {
        val scope = bind(null)
        if (!prepared) {
            performMaintenance(scope)
            prepared = true
        } else {
            sweepScopedStorage(scope)
        }
        return scopedDirectory(scope, direction)
            .listFiles { file -> file.isFile && file.extension == "json" }
            ?.size
            ?: 0
    }

    private fun scopedEntries(
        accountScopeHash: String,
    ): List<StoredEntry> = buildList {
        DIRECTIONS.forEach { direction ->
            val directory = scopedDirectory(accountScopeHash, direction)
            if (!directory.exists()) return@forEach
            val files = directory.listFiles()
                ?: throw ManagedStorageException.InvalidResponse()
            files.forEach { file ->
                add(
                    validatedEntry(
                        file = file,
                        direction = direction,
                        expectedAccountScopeHash = accountScopeHash,
                        maximumBytes = policy.maximumTotalBytes,
                    ) ?: throw ManagedStorageException.InvalidResponse(),
                )
            }
        }
    }

    private fun validatedEntry(
        file: File,
        direction: String,
        expectedAccountScopeHash: String?,
        maximumBytes: Long,
    ): StoredEntry? = runCatching {
        if (
            file.extension != "json" ||
            !file.isFile ||
            Files.isSymbolicLink(file.toPath()) ||
            file.length() < 0L ||
            file.length() > maximumBytes
        ) {
            return@runCatching null
        }
        val bytes = file.readBytes()
        if (bytes.size.toLong() != file.length()) return@runCatching null
        val value = JSONObject(bytes.toString(StandardCharsets.UTF_8))
        val record = StoredRecord(
            direction = value.getString("direction"),
            accountScopeHash = value.getString("account_scope_hash"),
            identity = value.getString("identity"),
            documentKind = ManagedDocumentKind.fromWire(
                value.getString("document_kind"),
            ),
            documentId = UUID.fromString(value.getString("document_id")),
            revision = value.getLong("revision"),
            keyId = UUID.fromString(value.getString("key_id")),
            plaintextSha256 = if (value.isNull("plaintext_sha256")) {
                null
            } else {
                value.getString("plaintext_sha256")
            },
            contentSha256 = value.getString("content_sha256"),
            ciphertextBase64 = value.getString("ciphertext_base64"),
            stagedAtMilliseconds = value.getLong("staged_at_milliseconds"),
        )
        if (
            value.getInt("version") != 1 ||
            record.direction != direction ||
            direction !in DIRECTIONS ||
            !record.accountScopeHash.matches(SHA256_PATTERN) ||
            (
                expectedAccountScopeHash != null &&
                    record.accountScopeHash != expectedAccountScopeHash
                ) ||
            !record.identity.matches(SHA256_PATTERN) ||
            file.nameWithoutExtension != record.identity ||
            record.revision < 0L ||
            record.stagedAtMilliseconds < 0L ||
            !record.contentSha256.matches(SHA256_PATTERN)
        ) {
            return@runCatching null
        }
        val ciphertext = Base64.getDecoder().decode(record.ciphertextBase64)
        if (
            Base64.getEncoder().encodeToString(ciphertext) !=
            record.ciphertextBase64 ||
            sha256(ciphertext) != record.contentSha256
        ) {
            return@runCatching null
        }
        if (direction == INCOMING) {
            if (
                record.plaintextSha256 != null ||
                incomingIdentity(
                    record.accountScopeHash,
                    record.documentKind,
                    record.documentId,
                    record.revision,
                ) != record.identity
            ) {
                return@runCatching null
            }
        } else if (record.plaintextSha256?.matches(SHA256_PATTERN) != true) {
            return@runCatching null
        }
        StoredEntry(file, bytes, record)
    }.getOrNull()

    private fun removeFileOrDirectory(file: File) {
        val removed = if (file.isDirectory) {
            file.deleteRecursively()
        } else {
            file.delete()
        }
        if (!removed) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun cleanupEmptyScopedDirectories(accountScopeHash: String) {
        DIRECTIONS.forEach { direction ->
            removeDirectoryIfEmpty(scopedDirectory(accountScopeHash, direction))
        }
        removeDirectoryIfEmpty(accountRoot(accountScopeHash))
        removeDirectoryIfEmpty(File(root, ACCOUNTS_DIRECTORY))
    }

    private fun removeEmptyLegacyDirectories() {
        DIRECTIONS.forEach { direction ->
            removeDirectoryIfEmpty(legacyDirectory(direction))
        }
    }

    private fun removeDirectoryIfEmpty(directory: File) {
        if (!directory.exists()) return
        val entries = directory.listFiles()
            ?: throw ManagedStorageException.InvalidResponse()
        if (entries.isEmpty() && !directory.delete()) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun ensureDirectory(directory: File?) {
        if (directory == null) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (!directory.exists() && !directory.mkdirs()) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (!directory.isDirectory) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun moveAtomically(source: File, destination: File) {
        try {
            Files.move(
                source.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: Exception) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun incomingIdentity(
        accountScopeHash: String,
        document: ManagedDocument,
    ): String = incomingIdentity(
        accountScopeHash,
        document.documentKind,
        document.documentId,
        document.revision,
    )

    private fun incomingIdentity(
        accountScopeHash: String,
        documentKind: ManagedDocumentKind,
        documentId: UUID,
        revision: Long,
    ): String = sha256(
        (
            "$accountScopeHash\u0000${documentKind.wireValue}\u0000" +
                "${documentId.toString().lowercase()}\u0000$revision"
            ).toByteArray(StandardCharsets.UTF_8),
    )

    private fun outgoingIdentity(
        accountScopeHash: String,
        localIdentifier: String,
        generation: Long,
        revision: Long,
    ): String = sha256(
        "$accountScopeHash\u0000$localIdentifier\u0000$generation\u0000$revision"
            .toByteArray(StandardCharsets.UTF_8),
    )

    private fun accountRoot(accountScopeHash: String): File =
        File(
            File(root, ACCOUNTS_DIRECTORY),
            sha256(
                "$ACCOUNT_DIRECTORY_DOMAIN\u0000$accountScopeHash"
                    .toByteArray(StandardCharsets.UTF_8),
            ),
        )

    private fun scopedDirectory(
        accountScopeHash: String,
        direction: String,
    ): File = File(accountRoot(accountScopeHash), direction)

    private fun legacyDirectory(direction: String): File =
        File(root, direction)

    private fun file(
        accountScopeHash: String,
        direction: String,
        identity: String,
    ): File = File(
        scopedDirectory(accountScopeHash, direction),
        "$identity.json",
    )

    private companion object {
        private const val ACCOUNTS_DIRECTORY = "accounts"
        private const val ACCOUNT_DIRECTORY_DOMAIN =
            "noop-managed-document-ciphertext-account-v1"
        private const val INCOMING = "incoming"
        private const val OUTGOING = "outgoing"
        private const val DEFAULT_MAXIMUM_TOTAL_BYTES =
            64L * 1_024L * 1_024L
        private val DIRECTIONS = listOf(INCOMING, OUTGOING)
        private val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")
        private val OLDEST_FIRST =
            compareBy<StoredEntry>(
                { it.record.stagedAtMilliseconds },
                { it.file.name },
            )
    }
}
