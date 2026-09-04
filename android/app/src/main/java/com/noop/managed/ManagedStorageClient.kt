package com.noop.managed

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit

class ManagedStorageClient(
    private val configuration: ManagedStorageConfiguration,
    private val http: OkHttpClient = defaultHttp(configuration.timeoutSeconds),
) : ManagedStorageTransport {
    suspend fun overview(
        authorization: ManagedAuthorization,
    ): ManagedStorageOverview = withContext(Dispatchers.IO) {
        val response = executeJson(
            apiRequest("v1/managed/me", authorization).get().build(),
        )
        val account = response.optJSONObject("account")
            ?: throw ManagedStorageException.InvalidResponse()
        val storage = response.optJSONObject("storage")
            ?: throw ManagedStorageException.InvalidResponse()
        val rules = storage.optJSONArray("rules")
            ?: throw ManagedStorageException.InvalidResponse()
        var committedBytes = 0L
        var reservedBytes = 0L
        for (index in 0 until rules.length()) {
            val rule = rules.optJSONObject(index)
                ?: throw ManagedStorageException.InvalidResponse()
            committedBytes = addExactOrInvalid(
                committedBytes,
                rule.requiredNonnegativeLong("committed_bytes"),
            )
            reservedBytes = addExactOrInvalid(
                reservedBytes,
                rule.requiredNonnegativeLong("reserved_bytes"),
            )
        }
        ManagedStorageOverview(
            accountStatus = account.optString("status").requiredText(),
            planCode = account.optString("plan_code").requiredText(),
            planTier = account.optString("display_tier").requiredText(),
            maximumBytes = account.optionalNonnegativeLong("max_total_bytes"),
            committedBytes = committedBytes,
            reservedBytes = reservedBytes,
            installationCount = storage.requiredNonnegativeInt("installations"),
            maximumInstallations = account.requiredPositiveInt("max_installations"),
        )
    }

    suspend fun enroll(
        authorization: ManagedAuthorization,
        requestId: UUID,
        dataClasses: List<String>,
    ): Boolean = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("installation_id", authorization.installationId)
            .put("installation_token", authorization.installationToken)
            .put("platform", "android")
            .put("enrollment_request_id", requestId.toString())
            .put("policy_version", configuration.policyVersion)
            .put("policy_sha256", configuration.policySha256)
            .put("data_classes", JSONArray(dataClasses.distinct().sorted()))
        val response = executeJson(
            apiRequest("v1/managed/enroll", authorization, includeInstallation = false)
                .post(body.toString().toRequestBody(JSON))
                .build(),
        )
        val boundary = response.optJSONObject("product_boundary")
            ?: throw ManagedStorageException.InvalidResponse()
        if (!boundary.optBoolean("account_optional") ||
            !boundary.optBoolean("local_metrics_available") ||
            !boundary.optBoolean("storage_only_entitlement")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        response.optBoolean("created", false)
    }

    suspend fun installations(
        authorization: ManagedAuthorization,
    ): List<ManagedInstallation> = withContext(Dispatchers.IO) {
        val rows = executeJson(
            apiRequest("v1/managed/installations", authorization).get().build(),
        ).optJSONArray("installations")
            ?: throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index)
                    ?: throw ManagedStorageException.InvalidResponse()
                add(parseInstallation(row))
            }
        }
    }

    suspend fun revokeInstallation(
        authorization: ManagedAuthorization,
        installationId: String,
    ): ManagedInstallation = withContext(Dispatchers.IO) {
        if (!installationId.matches(INSTALLATION_ID) ||
            installationId == authorization.installationId
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val response = executeJson(
            apiRequest(
                "v1/managed/installations/$installationId",
                authorization,
            ).delete().build(),
        )
        parseInstallation(
            response.optJSONObject("installation")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
    }

    suspend fun requestErasure(
        authorization: ManagedAuthorization,
        requestId: UUID,
        scope: String = "account",
        confirmationSha256: String,
    ): ManagedErasureJob = withContext(Dispatchers.IO) {
        require(scope in setOf("all_managed_data", "raw_chunks", "derived_data", "account"))
        require(confirmationSha256.matches(SHA256))
        val body = JSONObject()
            .put("request_id", requestId.toString())
            .put("scope", scope)
            .put("confirmation_sha256", confirmationSha256)
        parseErasure(
            executeJson(
                apiRequest(
                    "v1/managed/erasure",
                    authorization,
                ).post(body.toString().toRequestBody(JSON)).build(),
            ).optJSONObject("erasure")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
    }

    suspend fun erasure(
        authorization: ManagedAuthorization,
        jobId: UUID,
    ): ManagedErasureJob = withContext(Dispatchers.IO) {
        parseErasure(
            executeJson(
                apiRequest("v1/managed/erasure/$jobId", authorization).get().build(),
            ).optJSONObject("erasure")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
    }

    suspend fun cancelErasure(
        authorization: ManagedAuthorization,
        jobId: UUID,
    ): ManagedErasureJob = withContext(Dispatchers.IO) {
        parseErasure(
            executeJson(
                apiRequest(
                    "v1/managed/erasure/$jobId/cancel",
                    authorization,
                ).post(ByteArray(0).toRequestBody(null)).build(),
            ).optJSONObject("erasure")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
    }

    override suspend fun registerSource(
        authorization: ManagedAuthorization,
        sourceId: UUID,
        sourceKind: String,
        logicalSourceHash: String,
    ) = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("source_id", sourceId.toString())
            .put("source_kind", sourceKind)
            .put("platform", "android")
            .put("logical_source_hash", logicalSourceHash)
        val response = executeJson(
            apiRequest("v1/managed/sources", authorization)
                .post(body.toString().toRequestBody(JSON))
                .build(),
        )
        val returned = response.optJSONObject("source")?.optString("source_id")
        if (!returned.equals(sourceId.toString(), ignoreCase = true)) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    override suspend fun reserveChunk(
        authorization: ManagedAuthorization,
        reservation: ManagedChunkReservation,
    ): ManagedChunkReservationResult = withContext(Dispatchers.IO) {
        val response = executeJson(
            apiRequest("v1/managed/chunks:reserve", authorization)
                .post(reservationJson(reservation).toString().toRequestBody(JSON))
                .build(),
        )
        val chunk = response.optJSONObject("chunk")
            ?: throw ManagedStorageException.InvalidResponse()
        val chunkId = uuidOrThrow(chunk.optString("chunk_id"))
        if (chunkId != reservation.chunkId) throw ManagedStorageException.InvalidResponse()
        ManagedChunkReservationResult(
            chunkId = chunkId,
            state = chunk.optString("state").ifBlank {
                throw ManagedStorageException.InvalidResponse()
            },
            duplicate = chunk.optBoolean("duplicate", false),
            upload = response.optJSONObject("upload")?.let(::parseUpload),
        )
    }

    override suspend fun upload(
        bytes: ByteArray,
        capability: ManagedUploadCapability,
    ): ManagedObjectUploadReceipt = withContext(Dispatchers.IO) {
        if (!capability.method.equals("PUT", ignoreCase = true)) {
            throw ManagedStorageException.InvalidResponse()
        }
        val signedUrl = validSignedUrl(capability.url)
        val contentType = capability.headers.entries
            .firstOrNull { it.key.equals("content-type", ignoreCase = true) }
            ?.value
            ?.toMediaType()
            ?: JSON
        val builder = Request.Builder()
            .url(signedUrl)
            .put(bytes.toRequestBody(contentType))
        capability.headers.forEach { (name, value) ->
            if (!name.equals("host", ignoreCase = true) &&
                !name.equals("content-length", ignoreCase = true) &&
                !name.equals("content-type", ignoreCase = true)
            ) {
                builder.header(name, value)
            }
        }
        val response = execute(builder.build())
        response.use {
            if (!it.isSuccessful) throw serverError(it.code, "")
            val generation = it.header("x-goog-generation")?.toLongOrNull()
            val metageneration = it.header("x-goog-metageneration")?.toLongOrNull()
            val crc32c = it.header("x-goog-hash")
                ?.split(',')
                ?.map(String::trim)
                ?.firstOrNull { hash -> hash.startsWith("crc32c=") }
                ?.removePrefix("crc32c=")
            if (generation == null ||
                generation <= 0L ||
                metageneration == null ||
                metageneration <= 0L ||
                crc32c?.matches(CRC32C) != true
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
            ManagedObjectUploadReceipt(generation, metageneration, crc32c)
        }
    }

    override suspend fun completeChunk(
        authorization: ManagedAuthorization,
        chunkId: UUID,
        receipt: ManagedObjectUploadReceipt,
    ): Unit = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("object_generation", receipt.objectGeneration)
            .put("object_metageneration", receipt.objectMetageneration)
            .put("object_crc32c", receipt.objectCrc32c)
        val response = executeJson(
            apiRequest("v1/managed/chunks/$chunkId/complete", authorization)
                .post(body.toString().toRequestBody(JSON))
                .build(),
        )
        val completed = response.optJSONObject("chunk")
            ?: throw ManagedStorageException.InvalidResponse()
        if (uuidOrThrow(completed.optString("chunk_id")) != chunkId ||
            completed.optString("state") !in setOf("uploaded", "validating", "available")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        Unit
    }

    override suspend fun changes(
        authorization: ManagedAuthorization,
        afterSequence: Long,
        limit: Int,
    ): ManagedChangeFeed = withContext(Dispatchers.IO) {
        require(afterSequence >= 0L && limit in 1..500)
        val response = executeJson(
            apiRequest(
                "v1/managed/changes?after_sequence=$afterSequence&limit=$limit",
                authorization,
            ).get().build(),
        )
        val rows = response.optJSONArray("changes")
            ?: throw ManagedStorageException.InvalidResponse()
        val changes = buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index)
                    ?: throw ManagedStorageException.InvalidResponse()
                add(parseChange(row))
            }
        }
        ManagedChangeFeed(
            changes = changes,
            minimumSequence = response.requiredLong("minimum_sequence"),
            highWatermark = response.requiredLong("high_watermark"),
            nextSequence = response.requiredLong("next_sequence"),
            hasMore = response.optBoolean("has_more", false),
        )
    }

    override suspend fun createRestore(
        authorization: ManagedAuthorization,
        requestId: UUID,
        dataClasses: List<String>,
    ): ManagedRestoreJob = withContext(Dispatchers.IO) {
        val classes = dataClasses.distinct().sorted()
        if (classes.isEmpty() ||
            classes.size != dataClasses.size ||
            classes.any { !it.matches(DATA_CLASS) }
        ) {
            throw IllegalArgumentException("Invalid managed restore data classes")
        }
        val body = JSONObject()
            .put("request_id", requestId.toString())
            .put("data_classes", JSONArray(classes))
            .put("document_kinds", JSONArray())
            .put("include_documents", true)
        parseRestore(
            executeJson(
                apiRequest("v1/managed/restores", authorization)
                    .post(body.toString().toRequestBody(JSON))
                    .build(),
            ).optJSONObject("restore")
                ?: throw ManagedStorageException.InvalidResponse(),
            expectedStatus = "running",
        )
    }

    override suspend fun availableChunks(
        authorization: ManagedAuthorization,
        dataClass: String,
        snapshotAt: String,
        after: ManagedChunkCursor?,
        limit: Int,
    ): ManagedChunkPage = withContext(Dispatchers.IO) {
        if (!dataClass.matches(DATA_CLASS) ||
            runCatching { Instant.parse(snapshotAt) }.isFailure ||
            limit !in 1..200
        ) {
            throw IllegalArgumentException("Invalid managed snapshot request")
        }
        val query = buildList {
            add("data_class=${queryValue(dataClass)}")
            add("snapshot_at=${queryValue(snapshotAt)}")
            add("limit=$limit")
            after?.let {
                if (runCatching { Instant.parse(it.afterEventStart) }.isFailure) {
                    throw IllegalArgumentException("Invalid managed snapshot cursor")
                }
                add("after_event_start=${queryValue(it.afterEventStart)}")
                add("after_chunk_id=${it.afterChunkId}")
            }
        }.joinToString("&")
        val response = executeJson(
            apiRequest("v1/managed/chunks?$query", authorization).get().build(),
        )
        val values = response.optJSONArray("chunks")
            ?: throw ManagedStorageException.InvalidResponse()
        val chunks = buildList {
            for (index in 0 until values.length()) {
                add(parseAvailableChunk(
                    values.optJSONObject(index)
                        ?: throw ManagedStorageException.InvalidResponse(),
                    expectedDataClass = dataClass,
                ))
            }
        }
        val cursor = response.optJSONObject("next_cursor")?.let {
            ManagedChunkCursor(
                afterEventStart = it.optString("after_event_start").requiredInstant(),
                afterChunkId = uuidOrThrow(it.optString("after_chunk_id")),
            )
        }
        if (cursor != null) {
            val last = chunks.lastOrNull() ?: throw ManagedStorageException.InvalidResponse()
            if (cursor.afterChunkId != last.chunkId ||
                cursor.afterEventStart != last.eventStart
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
        ManagedChunkPage(chunks, cursor)
    }

    override suspend fun completeRestore(
        authorization: ManagedAuthorization,
        restoreJobId: UUID,
        deliveredObjects: Int,
        deliveredBytes: Long,
    ): ManagedRestoreJob = withContext(Dispatchers.IO) {
        require(deliveredObjects >= 0 && deliveredBytes >= 0)
        val body = JSONObject()
            .put("delivered_objects", deliveredObjects)
            .put("delivered_bytes", deliveredBytes)
        val restore = parseRestore(
            executeJson(
                apiRequest(
                    "v1/managed/restores/$restoreJobId/complete",
                    authorization,
                ).post(body.toString().toRequestBody(JSON)).build(),
            ).optJSONObject("restore")
                ?: throw ManagedStorageException.InvalidResponse(),
            expectedStatus = "completed",
        )
        if (restore.restoreJobId != restoreJobId ||
            restore.deliveredObjects != deliveredObjects ||
            restore.deliveredBytes != deliveredBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        restore
    }

    override suspend fun putDocument(
        authorization: ManagedAuthorization,
        mutation: ManagedDocumentMutation,
    ): ManagedDocument = withContext(Dispatchers.IO) {
        val response = executeJson(
            apiRequest(
                "v1/managed/documents/${mutation.documentKind.wireValue}/" +
                    mutation.documentId,
                authorization,
            ).put(documentMutationJson(mutation).toString().toRequestBody(JSON)).build(),
        )
        parseDocument(
            response.optJSONObject("document")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
    }

    override suspend fun document(
        authorization: ManagedAuthorization,
        kind: ManagedDocumentKind,
        id: UUID,
        revision: Long?,
    ): ManagedDocument = withContext(Dispatchers.IO) {
        if (revision != null && revision <= 0L) {
            throw IllegalArgumentException("Invalid managed document revision")
        }
        val query = revision?.let { "?revision=$it" }.orEmpty()
        parseDocument(
            executeJson(
                apiRequest(
                    "v1/managed/documents/${kind.wireValue}/$id$query",
                    authorization,
                ).get().build(),
            ).optJSONObject("document")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
    }

    override suspend fun documents(
        authorization: ManagedAuthorization,
        snapshotAt: String,
        after: ManagedDocumentCursor?,
        limit: Int,
    ): ManagedDocumentPage = withContext(Dispatchers.IO) {
        if (runCatching { Instant.parse(snapshotAt) }.isFailure || limit !in 1..200) {
            throw IllegalArgumentException("Invalid managed document snapshot request")
        }
        val query = buildList {
            add("include_deleted=false")
            add("snapshot_at=${queryValue(snapshotAt)}")
            add("limit=$limit")
            after?.let { cursor ->
                if (runCatching { Instant.parse(cursor.afterUpdatedAt) }.isFailure) {
                    throw IllegalArgumentException("Invalid managed document cursor")
                }
                add("after_updated_at=${queryValue(cursor.afterUpdatedAt)}")
                add("after_document_kind=${cursor.afterDocumentKind.wireValue}")
                add("after_document_id=${cursor.afterDocumentId}")
            }
        }.joinToString("&")
        val response = executeJson(
            apiRequest("v1/managed/documents?$query", authorization).get().build(),
        )
        val rows = response.optJSONArray("documents")
            ?: throw ManagedStorageException.InvalidResponse()
        val documents = buildList {
            for (index in 0 until rows.length()) {
                val document = parseDocument(
                    rows.optJSONObject(index)
                        ?: throw ManagedStorageException.InvalidResponse(),
                )
                if (document.contentMode != "server_readable" ||
                    document.clientKeyId != null ||
                    document.payloadJson == null ||
                    document.payloadCiphertextBase64 != null ||
                    document.deletedAt != null
                ) {
                    throw ManagedStorageException.InvalidResponse()
                }
                add(document)
            }
        }
        val nextCursor = response.optJSONObject("next_cursor")?.let {
            ManagedDocumentCursor(
                afterUpdatedAt = it.optString("after_updated_at").requiredInstant(),
                afterDocumentKind = ManagedDocumentKind.fromWire(
                    it.optString("after_document_kind"),
                ),
                afterDocumentId = uuidOrThrow(it.optString("after_document_id")),
            )
        }
        if (nextCursor != null && documents.lastOrNull()?.pageCursor() != nextCursor) {
            throw ManagedStorageException.InvalidResponse()
        }
        ManagedDocumentPage(documents, nextCursor)
    }

    override suspend fun downloadCapability(
        authorization: ManagedAuthorization,
        chunkId: UUID,
        requestId: UUID,
    ): ManagedDownloadCapability = withContext(Dispatchers.IO) {
        val response = executeJson(
            apiRequest("v1/managed/chunks/$chunkId/download", authorization)
                .post(
                    JSONObject().put("request_id", requestId.toString()).toString()
                        .toRequestBody(JSON),
                )
                .build(),
        )
        val chunk = response.optJSONObject("chunk")
            ?: throw ManagedStorageException.InvalidResponse()
        val capability = ManagedDownloadCapability(
            grantId = uuidOrThrow(response.optString("grant_id")),
            method = response.optString("method"),
            url = validSignedUrl(response.optString("url")),
            headers = response.optJSONObject("headers")?.stringMap().orEmpty(),
            expiresAt = response.optString("expires_at"),
            chunkId = uuidOrThrow(chunk.optString("chunk_id")),
            expectedSha256 = chunk.optString("expected_sha256"),
            compression = chunk.optString("compression"),
            contentType = chunk.optString("content_type"),
            expectedUncompressedBytes = chunk.optInt("expected_uncompressed_bytes")
                .takeIf { it > 0 },
        )
        if (!capability.method.equals("GET", ignoreCase = true) ||
            capability.chunkId != chunkId ||
            !capability.expectedSha256.matches(SHA256) ||
            runCatching { ManagedChunkCompression.fromWire(capability.compression) }.isFailure ||
            capability.contentType != "application/vnd.noop.chunk+json"
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        capability
    }

    override suspend fun download(capability: ManagedDownloadCapability): ByteArray =
        withContext(Dispatchers.IO) {
            if (!capability.method.equals("GET", ignoreCase = true)) {
                throw ManagedStorageException.InvalidResponse()
            }
            val builder = Request.Builder().url(validSignedUrl(capability.url)).get()
            capability.headers.forEach { (name, value) ->
                if (!name.equals("host", ignoreCase = true)) builder.header(name, value)
            }
            val response = execute(builder.build())
            response.use {
                if (!it.isSuccessful) throw serverError(it.code, "")
                val bytes = it.body?.bytes() ?: throw ManagedStorageException.InvalidResponse()
                if (!ManagedDigest.sha256(bytes).equals(capability.expectedSha256, ignoreCase = true)) {
                    throw ManagedStorageException.DigestMismatch()
                }
                bytes
            }
        }

    private fun apiRequest(
        path: String,
        authorization: ManagedAuthorization,
        includeInstallation: Boolean = true,
    ): Request.Builder {
        val base = configuration.baseUrl.trimEnd('/')
        val builder = Request.Builder()
            .url("$base/$path")
            .header("Accept", "application/json")
            .header("Authorization", "Bearer ${authorization.identityToken}")
            .header("X-Firebase-AppCheck", authorization.appCheckToken)
            .header("User-Agent", "NOOP-Android/managed-storage-v1")
        if (includeInstallation) {
            builder.header("X-Noop-Installation-ID", authorization.installationId)
            builder.header("X-Noop-Installation-Token", authorization.installationToken)
        }
        return builder
    }

    private fun reservationJson(value: ManagedChunkReservation): JSONObject = JSONObject()
        .put("chunk_id", value.chunkId.toString())
        .put("request_id", value.requestId.toString())
        .put("source_id", value.sourceId.toString())
        .put("data_class", value.dataClass)
        .put("schema_version", value.schemaVersion)
        .put("content_mode", value.contentMode)
        .apply { value.clientKeyId?.let { put("client_key_id", it.toString()) } }
        .put("event_start", value.eventStart)
        .put("event_end", value.eventEnd)
        .put("compression", value.compression)
        .put("content_type", value.contentType)
        .put("expected_sha256", value.expectedSha256)
        .put("expected_compressed_bytes", value.expectedCompressedBytes)
        .put("expected_uncompressed_bytes", value.expectedUncompressedBytes)
        .put(
            "streams",
            JSONArray().apply {
                value.streams.forEach { stream ->
                    put(
                        JSONObject()
                            .put("stream_key", stream.streamKey)
                            .put("sample_count", stream.sampleCount)
                            .apply {
                                stream.firstEventAt?.let { put("first_event_at", it) }
                                stream.lastEventAt?.let { put("last_event_at", it) }
                            }
                            .put("encoded_bytes", stream.encodedBytes)
                            .put("schema_revision", stream.schemaRevision),
                    )
                }
            },
        )

    private fun documentMutationJson(value: ManagedDocumentMutation): JSONObject = JSONObject()
        .put("request_id", value.requestId.toString())
        .put("document_kind", value.documentKind.wireValue)
        .put("document_id", value.documentId.toString())
        .put("base_revision", value.baseRevision)
        .put("content_mode", value.contentMode)
        .apply {
            value.clientKeyId?.let { put("client_key_id", it.toString()) }
            value.payloadJson?.let { put("payload_json", it) }
            value.payloadCiphertextBase64?.let {
                put("payload_ciphertext_base64", it)
            }
            value.contentSha256?.let { put("content_sha256", it) }
        }
        .put("updated_at", value.updatedAt)
        .put("deleted", value.deleted)

    private fun parseUpload(value: JSONObject): ManagedUploadCapability =
        ManagedUploadCapability(
            grantId = uuidOrThrow(value.optString("grant_id")),
            method = value.optString("method").also {
                if (!it.equals("PUT", ignoreCase = true)) {
                    throw ManagedStorageException.InvalidResponse()
                }
            },
            url = validSignedUrl(value.optString("url")),
            headers = value.optJSONObject("headers")?.stringMap().orEmpty(),
            expiresAt = value.optString("expires_at"),
        )

    private fun parseChange(row: JSONObject): ManagedChange {
        val chunk = row.optJSONObject("chunk")?.let {
            ManagedChangedChunk(
                chunkId = uuidOrThrow(it.optString("chunk_id")),
                sourceId = it.optString("source_id").takeIf(String::isNotBlank)?.let(::uuidOrThrow),
                schemaVersion = it.optInt("schema_version").takeIf { value -> value > 0 },
                contentMode = it.optString("content_mode").takeIf(String::isNotBlank),
                state = it.optString("state").takeIf(String::isNotBlank),
                compression = it.optString("compression").takeIf(String::isNotBlank),
                contentType = it.optString("content_type").takeIf(String::isNotBlank),
                expectedCompressedBytes = it.optInt("expected_compressed_bytes")
                    .takeIf { value -> value > 0 },
                expectedUncompressedBytes = it.optInt("expected_uncompressed_bytes")
                    .takeIf { value -> value > 0 },
                objectGeneration = it.optLong("object_generation").takeIf { value -> value > 0 },
                expiresAt = it.optString("expires_at").takeIf(String::isNotBlank),
            )
        }
        val document = row.optJSONObject("document")?.let {
            ManagedChangedDocument(
                documentKind = ManagedDocumentKind.fromWire(it.optString("document_kind")),
                documentId = uuidOrThrow(it.optString("document_id")),
                revision = it.requiredLong("revision"),
                contentMode = it.optString("content_mode"),
                clientKeyId = it.optString("client_key_id")
                    .takeIf(String::isNotBlank)
                    ?.let(::uuidOrThrow),
                updatedAt = it.optString("updated_at").requiredInstant(),
                deletedAt = it.optString("deleted_at")
                    .takeIf(String::isNotBlank)
                    ?.requiredInstant(),
            ).also { parsed ->
                if (parsed.revision <= 0L ||
                    parsed.contentMode !in setOf("server_readable", "client_encrypted")
                ) {
                    throw ManagedStorageException.InvalidResponse()
                }
            }
        }
        return ManagedChange(
            sequence = row.requiredLong("sequence"),
            resourceKind = row.optString("resource_kind"),
            resourceId = uuidOrThrow(row.optString("resource_id")),
            operation = row.optString("operation"),
            contentSha256 = row.optString("content_sha256").takeIf(String::isNotBlank),
            dataClass = row.optString("data_class").takeIf(String::isNotBlank),
            eventStart = row.optString("event_start").takeIf(String::isNotBlank),
            eventEnd = row.optString("event_end").takeIf(String::isNotBlank),
            chunk = chunk,
            document = document,
        )
    }

    private fun parseDocument(value: JSONObject): ManagedDocument {
        val payload = when {
            !value.has("payload_json") || value.isNull("payload_json") -> null
            else -> value.optJSONObject("payload_json")
                ?: throw ManagedStorageException.InvalidResponse()
        }
        val deletedAt = value.optString("deleted_at")
            .takeIf(String::isNotBlank)
            ?.requiredInstant()
        val document = ManagedDocument(
            documentKind = ManagedDocumentKind.fromWire(value.optString("document_kind")),
            documentId = uuidOrThrow(value.optString("document_id")),
            revision = value.requiredLong("revision"),
            originInstallationId = value.optString("origin_installation_id"),
            contentMode = value.optString("content_mode"),
            clientKeyId = value.optString("client_key_id")
                .takeIf(String::isNotBlank)
                ?.let(::uuidOrThrow),
            contentSha256 = value.optString("content_sha256"),
            payloadJson = payload,
            payloadCiphertextBase64 = value.optString("payload_ciphertext_base64")
                .takeIf(String::isNotBlank),
            updatedAt = value.optString("updated_at").requiredInstant(),
            deletedAt = deletedAt,
            duplicate = value.optBoolean("duplicate", false),
        )
        val validPayload = if (deletedAt != null) {
            document.clientKeyId == null &&
                document.payloadJson == null &&
                document.payloadCiphertextBase64 == null
        } else if (document.contentMode == "server_readable") {
            document.clientKeyId == null &&
                document.payloadJson != null &&
                document.payloadCiphertextBase64 == null
        } else {
            document.clientKeyId != null &&
                document.payloadJson == null &&
                document.payloadCiphertextBase64 != null
        }
        if (document.revision <= 0L ||
            !document.originInstallationId.matches(INSTALLATION_ID) ||
            document.contentMode !in setOf("server_readable", "client_encrypted") ||
            !document.contentSha256.matches(SHA256) ||
            !validPayload
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return document
    }

    private fun parseRestore(
        value: JSONObject,
        expectedStatus: String,
    ): ManagedRestoreJob {
        val restore = ManagedRestoreJob(
            restoreJobId = uuidOrThrow(value.optString("restore_job_id")),
            status = value.optString("status"),
            snapshotAt = value.optString("snapshot_at").requiredInstant(),
            changeSequence = value.requiredNonnegativeLong("change_sequence"),
            selectedObjects = value.requiredNonnegativeInt("selected_objects"),
            selectedBytes = value.requiredNonnegativeLong("selected_bytes"),
            deliveredObjects = value.requiredNonnegativeInt("delivered_objects"),
            deliveredBytes = value.requiredNonnegativeLong("delivered_bytes"),
            expiresAt = value.optString("expires_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (expectedStatus == "running" &&
            restore.status in setOf("expired", "completed")
        ) {
            throw ManagedStorageException.Conflict()
        }
        if (restore.status != expectedStatus ||
            restore.deliveredObjects > restore.selectedObjects ||
            restore.deliveredBytes > restore.selectedBytes
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return restore
    }

    private fun parseAvailableChunk(
        value: JSONObject,
        expectedDataClass: String,
    ): ManagedAvailableChunk {
        val chunk = ManagedAvailableChunk(
            chunkId = uuidOrThrow(value.optString("chunk_id")),
            sourceId = uuidOrThrow(value.optString("source_id")),
            dataClass = value.optString("data_class"),
            schemaVersion = value.requiredPositiveInt("schema_version"),
            contentMode = value.optString("content_mode"),
            state = value.optString("state"),
            eventStart = value.optString("event_start").requiredInstant(),
            eventEnd = value.optString("event_end").requiredInstant(),
            compression = value.optString("compression"),
            contentType = value.optString("content_type"),
            expectedSha256 = value.optString("expected_sha256"),
            expectedCompressedBytes = value.requiredPositiveInt("expected_compressed_bytes"),
            expectedUncompressedBytes = value.requiredPositiveInt(
                "expected_uncompressed_bytes",
            ),
            objectGeneration = value.requiredLong("object_generation"),
            expiresAt = value.optString("expires_at").requiredInstant(),
        )
        if (chunk.dataClass != expectedDataClass ||
            chunk.contentMode != "server_readable" ||
            chunk.state != "available" ||
            !chunk.expectedSha256.matches(SHA256) ||
            chunk.objectGeneration <= 0 ||
            runCatching { ManagedChunkCompression.fromWire(chunk.compression) }.isFailure ||
            chunk.contentType != "application/vnd.noop.chunk+json"
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return chunk
    }

    private fun parseErasure(value: JSONObject): ManagedErasureJob {
        val scope = value.optString("scope")
        val status = value.optString("status")
        if (scope !in setOf("all_managed_data", "raw_chunks", "derived_data", "account") ||
            status !in setOf(
                "cooling_off",
                "queued",
                "running",
                "completed",
                "failed",
                "canceled",
            )
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return ManagedErasureJob(
            jobId = uuidOrThrow(value.optString("erasure_job_id")),
            scope = scope,
            status = status,
            requestedAt = value.optString("requested_at").requiredText(),
            notBefore = value.optString("not_before").requiredText(),
            startedAt = value.optString("started_at").takeIf(String::isNotBlank),
            completedAt = value.optString("completed_at").takeIf(String::isNotBlank),
        )
    }

    private fun parseInstallation(value: JSONObject): ManagedInstallation {
        val installationId = value.optString("installation_id")
        val platform = value.optString("platform")
        val status = value.optString("status")
        val attestation = value.optString("attestation_state")
        if (!installationId.matches(INSTALLATION_ID) ||
            platform !in setOf("ios", "android", "macos", "other") ||
            status !in setOf("active", "limited", "revoked") ||
            attestation !in setOf(
                "not_evaluated",
                "accepted",
                "rejected",
                "unavailable",
            )
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return ManagedInstallation(
            installationId = installationId,
            platform = platform,
            status = status,
            attestationState = attestation,
            registeredAt = value.optString("registered_at").requiredText(),
            lastSeenAt = value.optString("last_seen_at").requiredText(),
            revokedAt = value.optString("revoked_at").takeIf(String::isNotBlank),
            current = value.optBoolean("current", false),
        )
    }

    private fun executeJson(request: Request): JSONObject {
        val response = execute(request)
        response.use {
            val body = runCatching { it.body?.string().orEmpty() }.getOrDefault("")
            if (!it.isSuccessful) throw serverError(it.code, body)
            return runCatching { JSONObject(body) }
                .getOrElse { throw ManagedStorageException.InvalidResponse() }
        }
    }

    private fun execute(request: Request) = try {
        http.newCall(request).execute()
    } catch (error: IOException) {
        throw ManagedStorageException.Network(error)
    }

    private fun serverError(statusCode: Int, body: String): ManagedStorageException = when (statusCode) {
        401, 403 -> ManagedStorageException.Authentication()
        404 -> ManagedStorageException.NotFound()
        409 -> when {
            body.contains("policy", ignoreCase = true) -> ManagedStorageException.PolicyChanged()
            body.contains("quota", ignoreCase = true) ||
                body.contains("maximum_bytes", ignoreCase = true) ->
                ManagedStorageException.QuotaExceeded()
            else -> ManagedStorageException.Conflict()
        }
        410 -> {
            val minimum = runCatching {
                JSONObject(body).optJSONObject("detail")?.optLong("minimum_sequence")
            }.getOrNull()?.takeIf { it > 0 }
            ManagedStorageException.CursorExpired(minimum)
        }
        else -> ManagedStorageException.Server(statusCode)
    }

    private fun JSONObject.requiredLong(name: String): Long {
        if (!has(name) || isNull(name)) throw ManagedStorageException.InvalidResponse()
        return runCatching { getLong(name) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
    }

    private fun JSONObject.requiredNonnegativeLong(name: String): Long =
        requiredLong(name).takeIf { it >= 0L }
            ?: throw ManagedStorageException.InvalidResponse()

    private fun JSONObject.optionalNonnegativeLong(name: String): Long? {
        if (!has(name) || isNull(name)) return null
        return requiredNonnegativeLong(name)
    }

    private fun JSONObject.requiredNonnegativeInt(name: String): Int {
        val value = requiredNonnegativeLong(name)
        return value.takeIf { it <= Int.MAX_VALUE }?.toInt()
            ?: throw ManagedStorageException.InvalidResponse()
    }

    private fun JSONObject.requiredPositiveInt(name: String): Int {
        val value = requiredNonnegativeInt(name)
        return value.takeIf { it > 0 } ?: throw ManagedStorageException.InvalidResponse()
    }

    private fun String.requiredText(): String =
        trim().takeIf(String::isNotEmpty) ?: throw ManagedStorageException.InvalidResponse()

    private fun String.requiredInstant(): String =
        requiredText().also {
            if (runCatching { Instant.parse(it) }.isFailure) {
                throw ManagedStorageException.InvalidResponse()
            }
        }

    private fun queryValue(value: String): String =
        @Suppress("DEPRECATION")
        URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")

    private fun addExactOrInvalid(left: Long, right: Long): Long =
        runCatching { Math.addExact(left, right) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }

    private fun JSONObject.stringMap(): Map<String, String> = buildMap {
        val iterator = keys()
        while (iterator.hasNext()) {
            val name = iterator.next()
            val value = optString(name)
            if (value.isNotBlank()) put(name, value)
        }
    }

    private fun uuidOrThrow(value: String): UUID =
        runCatching { UUID.fromString(value) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }

    private fun validSignedUrl(value: String): String {
        val url = value.toHttpUrlOrNull()
        if (url == null || !url.isHttps || url.username.isNotEmpty() || url.password.isNotEmpty()) {
            throw ManagedStorageException.InvalidResponse()
        }
        return value
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val CRC32C = Regex("^[A-Za-z0-9+/]{6}==$")
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val DATA_CLASS = Regex("^[a-z][a-z0-9_]{1,63}$")
        private val INSTALLATION_ID =
            Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")

        internal fun defaultHttp(timeoutSeconds: Long): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(minOf(timeoutSeconds, 20), TimeUnit.SECONDS)
            .readTimeout(maxOf(timeoutSeconds, 120), TimeUnit.SECONDS)
            .writeTimeout(maxOf(timeoutSeconds, 120), TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(true)
            .build()
    }
}
