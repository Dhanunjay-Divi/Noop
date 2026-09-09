package com.noop.managed

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import java.util.UUID

data class ManagedStorageConfiguration(
    val baseUrl: String,
    val policyVersion: String,
    val policySha256: String,
    val timeoutSeconds: Long = 60,
    val allowLocalHttp: Boolean = false,
) {
    init {
        val url = requireNotNull(baseUrl.toHttpUrlOrNull())
        val localRelayHosts = setOf("127.0.0.1", "::1", "localhost", "10.0.2.2")
        val validTransport = (
            url.isHttps || (
                allowLocalHttp &&
                    url.scheme == "http" &&
                    url.host.lowercase() in localRelayHosts
                )
            )
        require(validTransport && url.username.isEmpty() && url.password.isEmpty())
        require(url.querySize == 0 && url.fragment == null)
        require(policyVersion.isNotBlank())
        require(policySha256.matches(Regex("^[0-9a-f]{64}$")))
        require(timeoutSeconds > 0)
    }
}

data class ManagedAuthorization(
    val identityToken: String,
    val appCheckToken: String,
    val installationId: String,
    val installationToken: String,
) {
    init {
        require(identityToken.isNotBlank() && appCheckToken.isNotBlank())
        require(installationId.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")))
        require(installationToken.matches(Regex("^noopm_[A-Za-z0-9_-]{43}$")))
    }
}

data class ManagedChunkReservation(
    val chunkId: UUID,
    val requestId: UUID,
    val sourceId: UUID,
    val dataClass: String,
    val eventStart: String,
    val eventEnd: String,
    val compression: String,
    val expectedSha256: String,
    val expectedCompressedBytes: Int,
    val expectedUncompressedBytes: Int,
    val streams: List<ManagedChunkStreamManifest>,
    val schemaVersion: Int = 1,
    val contentMode: String = "server_readable",
    val clientKeyId: UUID? = null,
    val contentType: String = "application/vnd.noop.chunk+json",
)

data class ManagedUploadCapability(
    val grantId: UUID,
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val expiresAt: String,
)

data class ManagedChunkReservationResult(
    val chunkId: UUID,
    val state: String,
    val duplicate: Boolean,
    val upload: ManagedUploadCapability?,
)

data class ManagedObjectUploadReceipt(
    val objectGeneration: Long,
    val objectMetageneration: Long,
    val objectCrc32c: String,
)

data class ManagedChange(
    val sequence: Long,
    val resourceKind: String,
    val resourceId: UUID,
    val operation: String,
    val contentSha256: String?,
    val dataClass: String?,
    val eventStart: String?,
    val eventEnd: String?,
    val chunk: ManagedChangedChunk?,
    val document: ManagedChangedDocument? = null,
)

data class ManagedChangedChunk(
    val chunkId: UUID,
    val sourceId: UUID?,
    val schemaVersion: Int?,
    val contentMode: String?,
    val state: String?,
    val compression: String?,
    val contentType: String?,
    val expectedCompressedBytes: Int?,
    val expectedUncompressedBytes: Int?,
    val objectGeneration: Long?,
    val expiresAt: String?,
)

enum class ManagedDocumentKind(val wireValue: String) {
    AUTOMATION("automation"),
    CAFFEINE("caffeine"),
    COACH_HISTORY("coach_history"),
    COACH_MEMORY("coach_memory"),
    CYCLE("cycle"),
    DAY_OWNERSHIP("day_ownership"),
    DEVICE_REGISTRY("device_registry"),
    DISMISSAL("dismissal"),
    HYDRATION("hydration"),
    JOURNAL("journal"),
    LAB_MARKER("lab_marker"),
    MEDICATION("medication"),
    MOOD("mood"),
    NOTIFICATION_SETTINGS("notification_settings"),
    NUTRITION("nutrition"),
    NUTRITION_CATALOG("nutrition_catalog"),
    PREFERENCES("preferences"),
    PROFILE("profile"),
    STRENGTH_LOG("strength_log"),
    STRENGTH_PLAN("strength_plan"),
    USER_MARKER("user_marker"),
    WORKOUT_PLAN("workout_plan"),
    OTHER("other");

    companion object {
        fun fromWire(value: String): ManagedDocumentKind =
            entries.firstOrNull { it.wireValue == value }
                ?: throw ManagedStorageException.InvalidResponse()
    }
}

data class ManagedChangedDocument(
    val documentKind: ManagedDocumentKind,
    val documentId: UUID,
    val revision: Long,
    val contentMode: String,
    val clientKeyId: UUID?,
    val updatedAt: String,
    val deletedAt: String?,
)

data class ManagedDocumentMutation(
    val requestId: UUID,
    val documentKind: ManagedDocumentKind,
    val documentId: UUID,
    val baseRevision: Long,
    val contentMode: String,
    val clientKeyId: UUID? = null,
    val payloadJson: JSONObject? = null,
    val payloadCiphertextBase64: String? = null,
    val contentSha256: String? = null,
    val updatedAt: String,
    val deleted: Boolean = false,
) {
    init {
        require(baseRevision >= 0)
        require(contentMode == "server_readable" || contentMode == "client_encrypted")
        require(runCatching { java.time.Instant.parse(updatedAt) }.isSuccess)
        if (deleted) {
            require(clientKeyId == null && payloadJson == null && payloadCiphertextBase64 == null)
        } else if (contentMode == "server_readable") {
            require(clientKeyId == null && payloadJson != null && payloadCiphertextBase64 == null)
        } else {
            require(clientKeyId != null && payloadJson == null && payloadCiphertextBase64 != null)
        }
        require(contentSha256 == null || contentSha256.matches(Regex("^[0-9a-f]{64}$")))
    }
}

data class ManagedDocument(
    val documentKind: ManagedDocumentKind,
    val documentId: UUID,
    val revision: Long,
    val originInstallationId: String,
    val contentMode: String,
    val clientKeyId: UUID?,
    val contentSha256: String,
    val payloadJson: JSONObject?,
    val payloadCiphertextBase64: String?,
    val updatedAt: String,
    val deletedAt: String?,
    val duplicate: Boolean,
) {
    fun asChange(): ManagedChange = ManagedChange(
        sequence = 0,
        resourceKind = "document",
        resourceId = documentId,
        operation = if (deletedAt == null) "upsert" else "tombstone",
        contentSha256 = contentSha256,
        dataClass = null,
        eventStart = null,
        eventEnd = null,
        chunk = null,
        document = ManagedChangedDocument(
            documentKind = documentKind,
            documentId = documentId,
            revision = revision,
            contentMode = contentMode,
            clientKeyId = clientKeyId,
            updatedAt = updatedAt,
            deletedAt = deletedAt,
        ),
    )

    fun pageCursor(): ManagedDocumentCursor = ManagedDocumentCursor(
        afterUpdatedAt = updatedAt,
        afterDocumentKind = documentKind,
        afterDocumentId = documentId,
    )
}

data class ManagedDocumentCursor(
    val afterUpdatedAt: String,
    val afterDocumentKind: ManagedDocumentKind,
    val afterDocumentId: UUID,
)

data class ManagedDocumentPage(
    val documents: List<ManagedDocument>,
    val nextCursor: ManagedDocumentCursor?,
)

data class ManagedChangeFeed(
    val changes: List<ManagedChange>,
    val minimumSequence: Long,
    val highWatermark: Long,
    val nextSequence: Long,
    val hasMore: Boolean,
)

data class ManagedRestoreJob(
    val restoreJobId: UUID,
    val status: String,
    val snapshotAt: String,
    val changeSequence: Long,
    val selectedObjects: Int,
    val selectedBytes: Long,
    val deliveredObjects: Int,
    val deliveredBytes: Long,
    val expiresAt: String,
    val duplicate: Boolean,
)

data class ManagedChunkCursor(
    val afterEventStart: String,
    val afterChunkId: UUID,
)

data class ManagedAvailableChunk(
    val chunkId: UUID,
    val sourceId: UUID,
    val dataClass: String,
    val schemaVersion: Int,
    val contentMode: String,
    val state: String,
    val eventStart: String,
    val eventEnd: String,
    val compression: String,
    val contentType: String,
    val expectedSha256: String,
    val expectedCompressedBytes: Int,
    val expectedUncompressedBytes: Int,
    val objectGeneration: Long,
    val expiresAt: String,
) {
    fun asChange(): ManagedChange = ManagedChange(
        sequence = 0,
        resourceKind = "chunk",
        resourceId = chunkId,
        operation = "available",
        contentSha256 = expectedSha256,
        dataClass = dataClass,
        eventStart = eventStart,
        eventEnd = eventEnd,
        chunk = ManagedChangedChunk(
            chunkId = chunkId,
            sourceId = sourceId,
            schemaVersion = schemaVersion,
            contentMode = contentMode,
            state = state,
            compression = compression,
            contentType = contentType,
            expectedCompressedBytes = expectedCompressedBytes,
            expectedUncompressedBytes = expectedUncompressedBytes,
            objectGeneration = objectGeneration,
            expiresAt = expiresAt,
        ),
    )
}

data class ManagedChunkPage(
    val chunks: List<ManagedAvailableChunk>,
    val nextCursor: ManagedChunkCursor?,
)

data class ManagedDownloadCapability(
    val grantId: UUID,
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val expiresAt: String,
    val chunkId: UUID,
    val expectedSha256: String,
    val compression: String,
    val contentType: String,
    val expectedUncompressedBytes: Int? = null,
)

data class ManagedStorageOverview(
    val accountStatus: String,
    val planCode: String,
    val planTier: String,
    val maximumBytes: Long?,
    val committedBytes: Long,
    val reservedBytes: Long,
    val installationCount: Int,
    val maximumInstallations: Int,
)

data class ManagedInstallation(
    val installationId: String,
    val platform: String,
    val status: String,
    val attestationState: String,
    val registeredAt: String,
    val lastSeenAt: String,
    val revokedAt: String?,
    val current: Boolean,
)

data class ManagedErasureJob(
    val jobId: UUID,
    val scope: String,
    val status: String,
    val requestedAt: String,
    val notBefore: String,
    val startedAt: String?,
    val completedAt: String?,
)

sealed class ManagedStorageException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class Network(cause: Throwable? = null) :
        ManagedStorageException("NOOP+ could not be reached.", cause)
    class InvalidResponse : ManagedStorageException("NOOP+ returned an invalid response.")
    class Authentication : ManagedStorageException("NOOP+ authentication expired. Sign in again.")
    class PolicyChanged :
        ManagedStorageException("The NOOP+ storage policy changed. Review it before syncing.")
    class CursorExpired(val minimumSequence: Long?) :
        ManagedStorageException("This device's cloud cursor expired. A full restore is required.")
    class Forbidden : ManagedStorageException("NOOP+ did not allow that action.")
    class NotFound : ManagedStorageException("The requested NOOP+ resource no longer exists.")
    class QuotaExceeded : ManagedStorageException("This NOOP+ storage allowance is full.")
    class Conflict : ManagedStorageException("NOOP+ rejected conflicting sync state.")
    class Server(val statusCode: Int) :
        ManagedStorageException("NOOP+ is temporarily unavailable.")
    class DigestMismatch : ManagedStorageException("A cloud object failed its integrity check.")
}
