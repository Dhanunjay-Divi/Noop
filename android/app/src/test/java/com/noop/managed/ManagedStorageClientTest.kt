package com.noop.managed

import com.noop.safety.SafetyLocation
import kotlinx.coroutines.test.runTest
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.util.UUID

class ManagedStorageClientTest {
    private val config = ManagedStorageConfiguration(
        "https://noop.example",
        "synthetic-v1",
        "a".repeat(64),
    )
    private val authorization = ManagedAuthorization(
        "identity-token",
        "app-check-token",
        "android-installation",
        "noopm_" + "a".repeat(43),
    )

    @Test
    fun localHttpRequiresExplicitEmulatorOrLoopbackHost() {
        listOf(
            "http://127.0.0.1:8765",
            "http://localhost:8765",
            "http://[::1]:8765",
            "http://10.0.2.2:8765",
        ).forEach { baseUrl ->
            ManagedStorageConfiguration(
                baseUrl,
                "synthetic-v1",
                "a".repeat(64),
                allowLocalHttp = true,
            )
        }
        listOf(
            "http://noop.example",
            "http://192.168.1.20:8765",
        ).forEach { baseUrl ->
            runCatching {
                ManagedStorageConfiguration(
                    baseUrl,
                    "synthetic-v1",
                    "a".repeat(64),
                    allowLocalHttp = true,
                )
            }.onSuccess {
                fail("public or LAN cleartext managed endpoint was accepted")
            }
        }
    }

    @Test
    fun enrollmentCarriesBothAssertionsAndExplicitPolicy() = runTest {
        var captured: Request? = null
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    201,
                    """
                    {
                      "created": true,
                      "product_boundary": {
                        "account_optional": true,
                        "local_metrics_available": true,
                        "storage_only_entitlement": true
                      }
                    }
                    """.trimIndent(),
                )
            },
        )

        assertTrue(
            client.enroll(
                authorization,
                UUID.fromString("397f4624-1c42-49ea-8af7-ced2ca439a36"),
                listOf("essential_timeseries", "derived_summaries"),
            ),
        )
        assertEquals("Bearer identity-token", captured!!.header("Authorization"))
        assertEquals("app-check-token", captured!!.header("X-Firebase-AppCheck"))
        assertNull(captured!!.header("X-Noop-Installation-ID"))
        assertNull(captured!!.header("X-Noop-Installation-Token"))
        val body = JSONObject(okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8())
        assertEquals("android-installation", body.getString("installation_id"))
        assertEquals("noopm_" + "a".repeat(43), body.getString("installation_token"))
        assertEquals("synthetic-v1", body.getString("policy_version"))
        assertEquals("a".repeat(64), body.getString("policy_sha256"))
    }

    @Test
    fun retryableServerResponsePreservesBoundedRetryAfter() = runTest {
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    429,
                    """{"detail":"rate limited"}""",
                    mapOf("Retry-After" to "300"),
                )
            },
        )

        try {
            client.overview(authorization)
            fail("Expected rate limiting")
        } catch (error: ManagedStorageException.Server) {
            assertEquals(429, error.statusCode)
            assertEquals(300_000L, error.retryAfterMillis)
        }
    }

    @Test
    fun accountErasureReceiptOmitsIdentityBearer() = runTest {
        var captured: Request? = null
        val jobId = UUID.fromString("8519298e-c785-45e8-963a-81834be94638")
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    """
                    {
                      "erasure": {
                        "erasure_job_id": "$jobId",
                        "scope": "account",
                        "status": "completed",
                        "objects_selected": 0,
                        "objects_deleted": 0,
                        "bytes_selected": 0,
                        "bytes_deleted": 0,
                        "database_rows_deleted": 0,
                        "requested_at": "2026-09-04T04:00:00Z",
                        "not_before": "2026-09-05T04:00:00Z",
                        "started_at": "2026-09-05T04:00:00Z",
                        "completed_at": "2026-09-05T04:01:00Z",
                        "verification_expires_at": "2027-10-09T04:00:00Z",
                        "duplicate": false
                      }
                    }
                    """.trimIndent(),
                )
            },
        )

        val job = client.erasureReceipt(authorization, jobId)

        assertEquals(jobId, job.jobId)
        assertEquals("completed", job.status)
        assertNull(captured!!.header("Authorization"))
        assertEquals("app-check-token", captured!!.header("X-Firebase-AppCheck"))
        assertEquals(
            "android-installation",
            captured!!.header("X-Noop-Installation-ID"),
        )
        assertEquals(
            "noopm_" + "a".repeat(43),
            captured!!.header("X-Noop-Installation-Token"),
        )
    }

    @Test
    fun signedUploadProducesGenerationBoundReceiptWithoutBearer() = runTest {
        var captured: Request? = null
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    "",
                    mapOf(
                        "x-goog-generation" to "42",
                        "x-goog-metageneration" to "1",
                        "x-goog-hash" to "crc32c=AAAAAA==,md5=BBBBBBBBBBBBBBBBBBBBBB==",
                    ),
                )
            },
        )
        val receipt = client.upload(
            "abc".toByteArray(),
            ManagedUploadCapability(
                UUID.randomUUID(),
                "PUT",
                "https://storage.googleapis.com/bucket/object",
                mapOf(
                    "content-type" to "application/vnd.noop.chunk+json",
                    "x-goog-if-generation-match" to "0",
                ),
                "2026-09-03T12:10:00Z",
            ),
        )

        assertNull(captured!!.header("Authorization"))
        assertEquals("0", captured!!.header("x-goog-if-generation-match"))
        assertEquals(42L, receipt.objectGeneration)
        assertEquals("AAAAAA==", receipt.objectCrc32c)
    }

    @Test
    fun signedUploadRejectsInvalidGenerationAndCrcReceipt() = runTest {
        val invalidHeaders = listOf(
            mapOf(
                "x-goog-generation" to "0",
                "x-goog-metageneration" to "1",
                "x-goog-hash" to "crc32c=AAAAAA==",
            ),
            mapOf(
                "x-goog-generation" to "42",
                "x-goog-metageneration" to "1",
                "x-goog-hash" to "crc32c=not-a-checksum",
            ),
        )
        invalidHeaders.forEach { headers ->
            val client = ManagedStorageClient(
                config,
                client { request -> response(request, 200, "", headers) },
            )
            try {
                client.upload(
                    "abc".toByteArray(),
                    ManagedUploadCapability(
                        UUID.randomUUID(),
                        "PUT",
                        "https://storage.googleapis.com/bucket/object",
                        emptyMap(),
                        "2026-09-03T12:10:00Z",
                    ),
                )
                fail("Expected invalid upload receipt")
            } catch (_: ManagedStorageException.InvalidResponse) {
                // Expected.
            }
        }
    }

    @Test
    fun signedTransfersRejectNonHttpsCapabilitiesBeforeNetwork() = runTest {
        var requestCount = 0
        val client = ManagedStorageClient(
            config,
            client { request ->
                requestCount += 1
                response(request, 500, "")
            },
        )

        try {
            client.upload(
                "abc".toByteArray(),
                ManagedUploadCapability(
                    UUID.randomUUID(),
                    "PUT",
                    "http://storage.googleapis.com/bucket/object",
                    emptyMap(),
                    "2026-09-03T12:10:00Z",
                ),
            )
            fail("Expected insecure upload capability rejection")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }

        try {
            client.download(
                ManagedDownloadCapability(
                    grantId = UUID.randomUUID(),
                    method = "GET",
                    url = "http://storage.googleapis.com/bucket/object",
                    headers = emptyMap(),
                    expiresAt = "2026-09-03T12:10:00Z",
                    chunkId = UUID.randomUUID(),
                    expectedSha256 = "a".repeat(64),
                    compression = "gzip",
                    contentType = "application/vnd.noop.chunk+json",
                    expectedUncompressedBytes = 3,
                ),
            )
            fail("Expected insecure download capability rejection")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }

        assertEquals(0, requestCount)
    }

    @Test
    fun expiredRestoreReplayIsRestartableAndIncludesDocuments() = runTest {
        var captured: Request? = null
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    201,
                    """
                    {
                      "restore": {
                        "restore_job_id": "${UUID.randomUUID()}",
                        "status": "expired",
                        "snapshot_at": "2026-09-01T00:00:00Z",
                        "change_sequence": 42,
                        "selected_objects": 2,
                        "selected_bytes": 200,
                        "delivered_objects": 0,
                        "delivered_bytes": 0,
                        "expires_at": "2026-09-02T00:00:00Z",
                        "duplicate": true
                      }
                    }
                    """.trimIndent(),
                )
            },
        )

        try {
            client.createRestore(
                authorization,
                UUID.randomUUID(),
                listOf("raw_ppg", "essential_timeseries"),
                includeDeletedDocuments = true,
            )
            fail("Expected stale restore replay")
        } catch (_: ManagedStorageException.Conflict) {
            // Expected.
        }
        val body = JSONObject(
            okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8(),
        )
        assertEquals(true, body.getBoolean("include_documents"))
        assertEquals(true, body.getBoolean("include_deleted_documents"))
        assertEquals(
            listOf("day_ownership"),
            List(body.getJSONArray("document_kinds").length()) {
                body.getJSONArray("document_kinds").getString(it)
            },
        )
        assertEquals(
            listOf("essential_timeseries", "raw_ppg"),
            List(body.getJSONArray("data_classes").length()) {
                body.getJSONArray("data_classes").getString(it)
            },
        )
    }

    @Test
    fun documentPutGetAndSnapshotListUseTheManagedRoutes() = runTest {
        val documentId = UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500")
        val clientKeyId = UUID.fromString("11111111-2222-4333-8444-555555555555")
        val ciphertext = "noop-encrypted-journal-payload".toByteArray()
        val digest = ManagedDigest.sha256(ciphertext)
        val payload = JSONObject()
            .put("schema_version", 1)
            .put("table", "dayOwnership")
            .put(
                "key",
                JSONObject()
                    .put("day", "2026-09-11"),
            )
            .put(
                "record",
                JSONObject()
                    .put("day", "2026-09-11")
                    .put("deviceId", "remote-band")
                    .put("locked", 1),
            )
        val documentJson = JSONObject()
            .put("document_kind", "journal")
            .put("document_id", documentId.toString())
            .put("revision", 1)
            .put("origin_installation_id", authorization.installationId)
            .put("content_mode", "client_encrypted")
            .put("client_key_id", clientKeyId.toString())
            .put("content_sha256", digest)
            .put("payload_json", JSONObject.NULL)
            .put(
                "payload_ciphertext_base64",
                java.util.Base64.getEncoder().encodeToString(ciphertext),
            )
            .put("updated_at", "2026-09-04T12:00:00Z")
            .put("deleted_at", JSONObject.NULL)
            .put("duplicate", false)
        val ownershipId = UUID.fromString("22222222-2222-5222-8222-222222222222")
        val ownershipJson = JSONObject()
            .put("document_kind", "day_ownership")
            .put("document_id", ownershipId.toString())
            .put("revision", 1)
            .put("origin_installation_id", authorization.installationId)
            .put("content_mode", "server_readable")
            .put("client_key_id", JSONObject.NULL)
            .put(
                "content_sha256",
                ManagedDigest.sha256(
                    ManagedCanonicalJson.encode(payload).toByteArray(),
                ),
            )
            .put("payload_json", payload)
            .put("payload_ciphertext_base64", JSONObject.NULL)
            .put("updated_at", "2026-09-04T12:01:00Z")
            .put("deleted_at", JSONObject.NULL)
            .put("duplicate", false)
        val captured = mutableListOf<Request>()
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured += request
                when (captured.size) {
                    1, 2 -> response(
                        request,
                        200,
                        JSONObject().put("document", documentJson).toString(),
                    )
                    else -> response(
                        request,
                        200,
                        JSONObject()
                            .put(
                                "documents",
                                org.json.JSONArray()
                                    .put(ownershipJson),
                            )
                            .put("next_cursor", JSONObject.NULL)
                            .toString(),
                    )
                }
            },
        )
        val mutation = ManagedDocumentMutation(
            requestId = UUID.fromString("11111111-1111-5111-8111-111111111111"),
            documentKind = ManagedDocumentKind.JOURNAL,
            documentId = documentId,
            baseRevision = 0,
            contentMode = "client_encrypted",
            clientKeyId = clientKeyId,
            payloadCiphertextBase64 = java.util.Base64.getEncoder()
                .encodeToString(ciphertext),
            contentSha256 = digest,
            updatedAt = "2026-09-04T12:00:00Z",
        )

        assertEquals(documentId, client.putDocument(authorization, mutation).documentId)
        assertEquals(
            documentId,
            client.document(
                authorization,
                ManagedDocumentKind.JOURNAL,
                documentId,
                revision = 1,
            ).documentId,
        )
        val page = client.documents(
            authorization,
            snapshotAt = "2026-09-04T13:00:00Z",
            after = null,
            limit = 25,
            includeDeleted = false,
        )

        assertEquals(
            listOf("server_readable"),
            page.documents.map(ManagedDocument::contentMode),
        )
        assertEquals(null, page.nextCursor)
        assertEquals("PUT", captured[0].method)
        assertEquals(
            "/v1/managed/documents/journal/$documentId",
            captured[0].url.encodedPath,
        )
        val putBody = JSONObject(
            okio.Buffer().also { captured[0].body!!.writeTo(it) }.readUtf8(),
        )
        assertEquals(0L, putBody.getLong("base_revision"))
        assertEquals("client_encrypted", putBody.getString("content_mode"))
        assertEquals(
            java.util.Base64.getEncoder().encodeToString(ciphertext),
            putBody.getString("payload_ciphertext_base64"),
        )
        assertEquals("GET", captured[1].method)
        assertEquals("1", captured[1].url.queryParameter("revision"))
        assertEquals("/v1/managed/documents", captured[2].url.encodedPath)
        assertEquals(
            "day_ownership",
            captured[2].url.queryParameter("document_kind"),
        )
        assertEquals("false", captured[2].url.queryParameter("include_deleted"))
        assertEquals("25", captured[2].url.queryParameter("limit"))
    }

    @Test
    fun managedDocumentKeyPutUsesAuthenticatedOpaqueContract() = runTest {
        var captured: Request? = null
        val keyId = UUID.fromString("11111111-1111-4111-8111-111111111111")
        val wrappedKey = ByteArray(40) { 0x6d }
        val confirmation = "f".repeat(64)
        val mutation = ManagedWrappedKeyMutation(
            keyKind = ManagedWrappedKeyKind.ACCOUNT_MASTER,
            wrappingKeyId = null,
            wrappingRevision = 1,
            wrappedKey = wrappedKey,
            masterKeyConfirmationHmacSha256 = confirmation,
            recoveryMethod = ManagedWrappedKeyRecoveryMethod.DEVICE_TRANSFER,
        )
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "key",
                            wrappedKeyRecordJson(
                                keyId = keyId,
                                keyKind = "account_master",
                                wrappingKeyId = null,
                                wrappingRevision = 1,
                                wrappedKey = wrappedKey,
                                confirmation = confirmation,
                                recoveryMethod = "device_transfer",
                            ),
                        )
                        .toString(),
                )
            },
        )

        val stored = client.putManagedDocumentKey(
            authorization = authorization,
            keyId = keyId,
            mutation = mutation,
        )

        assertEquals(ManagedWrappedKeyStatus.ACTIVE, stored.status)
        assertTrue(stored.wrappedKey.contentEquals(wrappedKey))
        assertEquals("Bearer identity-token", captured!!.header("Authorization"))
        assertEquals("app-check-token", captured!!.header("X-Firebase-AppCheck"))
        assertEquals(
            authorization.installationId,
            captured!!.header("X-Noop-Installation-ID"),
        )
        assertEquals(
            authorization.installationToken,
            captured!!.header("X-Noop-Installation-Token"),
        )
        assertEquals("PUT", captured!!.method)
        assertEquals(
            "/v1/managed/document-keys/${keyId.toString().lowercase()}",
            captured!!.url.encodedPath,
        )
        val body = captured!!.jsonBody()
        assertEquals("account_master", body.getString("key_kind"))
        assertFalse(body.has("wrapping_key_id"))
        assertEquals(1, body.getInt("wrapping_revision"))
        assertEquals("A256GCM", body.getString("algorithm"))
        assertEquals(
            java.util.Base64.getEncoder().encodeToString(wrappedKey),
            body.getString("wrapped_key_base64"),
        )
        assertEquals(
            ManagedDigest.sha256(wrappedKey),
            body.getString("wrapped_key_sha256"),
        )
        assertEquals(
            confirmation,
            body.getString("master_key_confirmation_hmac_sha256"),
        )
        assertEquals("device_transfer", body.getString("recovery_method"))
    }

    @Test
    fun managedDocumentKeyCurrentVersionRotateAndRevokeUseExactRoutes() = runTest {
        val keyId = UUID.fromString("22222222-2222-4222-8222-222222222222")
        val firstMasterId =
            UUID.fromString("33333333-3333-4333-8333-333333333333")
        val secondMasterId =
            UUID.fromString("44444444-4444-4444-8444-444444444444")
        val successorKeyId =
            UUID.fromString("55555555-5555-4555-8555-555555555555")
        val original = ByteArray(72) { 0x31 }
        val rotated = ByteArray(72) { 0x32 }
        val rotation = ManagedWrappedKeyRotation(
            mutation = ManagedWrappedKeyMutation(
                keyKind = ManagedWrappedKeyKind.DOCUMENT,
                wrappingKeyId = secondMasterId,
                wrappingRevision = 2,
                wrappedKey = rotated,
            ),
            expectedWrappingRevision = 1,
        )
        val captured = mutableListOf<Request>()
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured += request
                val body = when (captured.size) {
                    1 -> JSONObject().put(
                        "key",
                        wrappedKeyRecordJson(
                            keyId = keyId,
                            wrappingKeyId = firstMasterId,
                            wrappingRevision = 1,
                            wrappedKey = original,
                        ),
                    )
                    2 -> JSONObject().put(
                        "key_version",
                        wrappedKeyVersionJson(
                            keyId = keyId,
                            wrappingKeyId = firstMasterId,
                            wrappingRevision = 1,
                            wrappedKey = original,
                        ),
                    )
                    3 -> JSONObject().put(
                        "key",
                        wrappedKeyRecordJson(
                            keyId = keyId,
                            wrappingKeyId = secondMasterId,
                            wrappingRevision = 2,
                            wrappedKey = rotated,
                        ),
                    )
                    4 -> JSONObject().put(
                        "key",
                        wrappedKeyRecordJson(
                            keyId = keyId,
                            wrappingKeyId = secondMasterId,
                            wrappingRevision = 2,
                            wrappedKey = rotated,
                            status = "revoked",
                            successorKeyId = successorKeyId,
                            updatedAt = "2026-09-20T05:04:00Z",
                            revokedAt = "2026-09-20T05:04:00Z",
                        ),
                    )
                    else -> error("Unexpected managed document-key request")
                }
                response(request, 200, body.toString())
            },
        )

        val current = client.managedDocumentKey(authorization, keyId)
        val version = client.managedDocumentKeyVersion(
            authorization,
            keyId,
            wrappingRevision = 1,
        )
        val rotatedRecord = client.rotateManagedDocumentKey(
            authorization,
            keyId,
            rotation,
        )
        val revoked = client.revokeManagedDocumentKey(
            authorization,
            keyId,
            successorKeyId,
        )

        assertTrue(current.wrappedKey.contentEquals(original))
        assertTrue(version.wrappedKey.contentEquals(original))
        assertEquals(2, rotatedRecord.wrappingRevision)
        assertEquals(ManagedWrappedKeyStatus.REVOKED, revoked.status)
        assertEquals(successorKeyId, revoked.successorKeyId)
        assertEquals(
            listOf("GET", "GET", "POST", "POST"),
            captured.map { it.method },
        )
        assertEquals(
            listOf(
                "/v1/managed/document-keys/${keyId.toString().lowercase()}",
                "/v1/managed/document-keys/${keyId.toString().lowercase()}/versions/1",
                "/v1/managed/document-keys/${keyId.toString().lowercase()}/rotate",
                "/v1/managed/document-keys/${keyId.toString().lowercase()}/revoke",
            ),
            captured.map { it.url.encodedPath },
        )
        val rotateBody = captured[2].jsonBody()
        assertEquals("document", rotateBody.getString("key_kind"))
        assertEquals(secondMasterId.toString(), rotateBody.getString("wrapping_key_id"))
        assertEquals(2, rotateBody.getInt("wrapping_revision"))
        assertEquals(1, rotateBody.getInt("expected_wrapping_revision"))
        assertFalse(rotateBody.has("master_key_confirmation_hmac_sha256"))
        assertFalse(rotateBody.has("recovery_method"))
        assertEquals(
            successorKeyId.toString(),
            captured[3].jsonBody().getString("successor_key_id"),
        )
    }

    @Test
    fun managedDocumentKeyResponsesRejectMalformedContracts() = runTest {
        val keyId = UUID.fromString("66666666-6666-4666-8666-666666666666")
        val otherKeyId =
            UUID.fromString("77777777-7777-4777-8777-777777777777")
        val masterId = UUID.fromString("88888888-8888-4888-8888-888888888888")
        val wrappedKey = ByteArray(72) { 0x41 }
        val malformed = listOf<(JSONObject) -> Unit>(
            { it.put("key_id", otherKeyId.toString()) },
            { it.put("key_kind", "unsupported") },
            { it.put("algorithm", "A128GCM") },
            { it.put("wrapped_key_sha256", "0".repeat(64)) },
            {
                it.put(
                    "wrapped_key_base64",
                    java.util.Base64.getEncoder().encodeToString(wrappedKey) + "\n",
                )
            },
            {
                val shortEnvelope = ByteArray(40) { 0x42 }
                it.put(
                    "wrapped_key_base64",
                    java.util.Base64.getEncoder().encodeToString(shortEnvelope),
                )
                it.put("wrapped_key_sha256", ManagedDigest.sha256(shortEnvelope))
            },
            { it.put("wrapping_revision", 0) },
            { it.put("status", "unknown") },
            { it.put("wrapping_key_id", JSONObject.NULL) },
            {
                it.put("status", "revoked")
                it.put("revoked_at", JSONObject.NULL)
            },
        )

        malformed.forEach { mutate ->
            val key = wrappedKeyRecordJson(
                keyId = keyId,
                wrappingKeyId = masterId,
                wrappingRevision = 1,
                wrappedKey = wrappedKey,
            )
            mutate(key)
            val client = ManagedStorageClient(
                config,
                client { request ->
                    response(
                        request,
                        200,
                        JSONObject().put("key", key).toString(),
                    )
                },
            )

            try {
                client.managedDocumentKey(authorization, keyId)
                fail("Expected malformed managed document-key rejection")
            } catch (_: ManagedStorageException.InvalidResponse) {
                // Expected.
            }
        }
    }

    @Test
    fun managedDocumentKeyRouteAndVersionMismatchesFailClosed() = runTest {
        val keyId = UUID.fromString("99999999-9999-4999-8999-999999999999")
        val otherKeyId =
            UUID.fromString("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        val masterId = UUID.fromString("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        val wrappedKey = ByteArray(72) { 0x51 }
        var requests = 0
        val invalidRequestClient = ManagedStorageClient(
            config,
            client { request ->
                requests += 1
                response(request, 500, "")
            },
        )
        val selfWrapped = ManagedWrappedKeyMutation(
            keyKind = ManagedWrappedKeyKind.DOCUMENT,
            wrappingKeyId = keyId,
            wrappingRevision = 1,
            wrappedKey = wrappedKey,
        )

        runCatching {
            invalidRequestClient.putManagedDocumentKey(
                authorization,
                keyId,
                selfWrapped,
            )
        }.onSuccess { fail("Expected self-wrapping route rejection") }
        runCatching {
            invalidRequestClient.managedDocumentKeyVersion(
                authorization,
                keyId,
                wrappingRevision = 0,
            )
        }.onSuccess { fail("Expected invalid version route rejection") }
        runCatching {
            invalidRequestClient.revokeManagedDocumentKey(
                authorization,
                keyId,
                keyId,
            )
        }.onSuccess { fail("Expected self-successor route rejection") }
        assertEquals(0, requests)

        val mismatches = listOf(
            wrappedKeyVersionJson(
                keyId = otherKeyId,
                wrappingKeyId = masterId,
                wrappingRevision = 1,
                wrappedKey = wrappedKey,
            ),
            wrappedKeyVersionJson(
                keyId = keyId,
                wrappingKeyId = masterId,
                wrappingRevision = 2,
                wrappedKey = wrappedKey,
            ),
        )
        mismatches.forEach { keyVersion ->
            val client = ManagedStorageClient(
                config,
                client { request ->
                    response(
                        request,
                        200,
                        JSONObject().put("key_version", keyVersion).toString(),
                    )
                },
            )
            try {
                client.managedDocumentKeyVersion(
                    authorization,
                    keyId,
                    wrappingRevision = 1,
                )
                fail("Expected route/version mismatch rejection")
            } catch (_: ManagedStorageException.InvalidResponse) {
                // Expected.
            }
        }
    }

    @Test
    fun managedDocumentKeyDiagnosticsDoNotExposeKeyMaterial() = runTest {
        val diagnostics = mutableListOf<ManagedStorageRequestDiagnostic>()
        val keyId = UUID.fromString("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        val masterId = UUID.fromString("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
        val wrappedKey = ByteArray(72) { 0x61 }
        val client = ManagedStorageClient(
            configuration = config,
            http = client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "key",
                            wrappedKeyRecordJson(
                                keyId = keyId,
                                wrappingKeyId = masterId,
                                wrappingRevision = 1,
                                wrappedKey = wrappedKey,
                            ),
                        )
                        .toString(),
                    mapOf("X-Noop-Request-ID" to "e".repeat(32)),
                )
            },
            requestObserver = { diagnostics += it },
        )

        client.managedDocumentKey(authorization, keyId)

        val diagnostic = diagnostics.single()
        val rendered = diagnostic.toString()
        assertEquals("/v1/managed/document-keys", diagnostic.routeGroup)
        assertEquals("completed", diagnostic.outcome)
        assertFalse(rendered.contains(keyId.toString()))
        assertFalse(
            rendered.contains(java.util.Base64.getEncoder().encodeToString(wrappedKey)),
        )
        assertFalse(rendered.contains(ManagedDigest.sha256(wrappedKey)))
    }

    @Test
    fun snapshotListRejectsSensitiveServerReadableDocument() = runTest {
        val documentId = UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500")
        val payload = JSONObject().put("secret", "not-server-readable")
        val canonical = ManagedCanonicalJson.encode(payload).toByteArray()
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "documents",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("document_kind", "journal")
                                    .put("document_id", documentId.toString())
                                    .put("revision", 1)
                                    .put(
                                        "origin_installation_id",
                                        authorization.installationId,
                                    )
                                    .put("content_mode", "server_readable")
                                    .put("client_key_id", JSONObject.NULL)
                                    .put(
                                        "content_sha256",
                                        ManagedDigest.sha256(canonical),
                                    )
                                    .put("payload_json", payload)
                                    .put(
                                        "payload_ciphertext_base64",
                                        JSONObject.NULL,
                                    )
                                    .put("updated_at", "2026-09-04T12:00:00Z")
                                    .put("deleted_at", JSONObject.NULL)
                                    .put("duplicate", false),
                            ),
                        )
                        .put("next_cursor", JSONObject.NULL)
                        .toString(),
                )
            },
        )

        val failure = try {
            client.documents(
                authorization,
                snapshotAt = "2026-09-04T13:00:00Z",
                after = null,
                limit = 25,
                includeDeleted = false,
            )
            null
        } catch (error: Throwable) {
            error
        }

        assertTrue(failure is ManagedStorageException.InvalidResponse)
    }

    @Test
    fun snapshotListRejectsMalformedEncryptedMetadata() = runTest {
        val documentId = UUID.fromString("77777777-7777-5777-8777-777777777777")
        val clientKeyId = UUID.fromString("88888888-8888-5888-8888-888888888888")
        val ciphertext = "noop-encrypted-journal-payload".toByteArray()
        val encoded = java.util.Base64.getEncoder().encodeToString(ciphertext)
        val digest = ManagedDigest.sha256(ciphertext)
        val invalidDocuments = listOf(
            JSONObject()
                .put("document_kind", "journal")
                .put("document_id", documentId.toString())
                .put("revision", 1)
                .put("origin_installation_id", authorization.installationId)
                .put("content_mode", "client_encrypted")
                .put("client_key_id", JSONObject.NULL)
                .put("content_sha256", digest)
                .put("payload_json", JSONObject.NULL)
                .put("payload_ciphertext_base64", encoded)
                .put("updated_at", "2026-09-11T15:00:00Z")
                .put("deleted_at", JSONObject.NULL)
                .put("duplicate", false),
            JSONObject()
                .put("document_kind", "day_ownership")
                .put("document_id", documentId.toString())
                .put("revision", 1)
                .put("origin_installation_id", authorization.installationId)
                .put("content_mode", "client_encrypted")
                .put("client_key_id", clientKeyId.toString())
                .put("content_sha256", digest)
                .put("payload_json", JSONObject.NULL)
                .put("payload_ciphertext_base64", encoded)
                .put("updated_at", "2026-09-11T15:00:00Z")
                .put("deleted_at", JSONObject.NULL)
                .put("duplicate", false),
        )

        invalidDocuments.forEach { document ->
            val client = ManagedStorageClient(
                config,
                client { request ->
                    response(
                        request,
                        200,
                        JSONObject()
                            .put(
                                "documents",
                                org.json.JSONArray().put(document),
                            )
                            .put("next_cursor", JSONObject.NULL)
                            .toString(),
                    )
                },
            )
            val failure = try {
                client.documents(
                    authorization,
                    snapshotAt = "2026-09-11T16:00:00Z",
                    after = null,
                    limit = 25,
                    includeDeleted = false,
                )
                null
            } catch (error: Throwable) {
                error
            }

            assertTrue(failure is ManagedStorageException.InvalidResponse)
        }
    }

    @Test
    fun snapshotListRequestsAndAcceptsDeletionTombstones() = runTest {
        val documentId = UUID.fromString("33333333-3333-5333-8333-333333333333")
        val revision = 2L
        val digest = ManagedDigest.sha256(
            (
                "deleted:day_ownership:" +
                    "${documentId.toString().lowercase()}:$revision"
                ).toByteArray(),
        )
        val client = ManagedStorageClient(
            config,
            client { request ->
                assertEquals("true", request.url.queryParameter("include_deleted"))
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "documents",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("document_kind", "day_ownership")
                                    .put("document_id", documentId.toString())
                                    .put("revision", revision)
                                    .put(
                                        "origin_installation_id",
                                        authorization.installationId,
                                    )
                                    .put("content_mode", "server_readable")
                                    .put("client_key_id", JSONObject.NULL)
                                    .put("content_sha256", digest)
                                    .put("payload_json", JSONObject.NULL)
                                    .put(
                                        "payload_ciphertext_base64",
                                        JSONObject.NULL,
                                    )
                                    .put("updated_at", "2026-09-11T15:00:00Z")
                                    .put("deleted_at", "2026-09-11T15:00:00Z")
                                    .put("duplicate", false),
                            ),
                        )
                        .put("next_cursor", JSONObject.NULL)
                        .toString(),
                )
            },
        )

        val page = client.documents(
            authorization,
            snapshotAt = "2026-09-11T16:00:00Z",
            after = null,
            limit = 25,
            includeDeleted = true,
        )

        assertEquals(listOf(documentId), page.documents.map(ManagedDocument::documentId))
        assertEquals("2026-09-11T15:00:00Z", page.documents.single().deletedAt)
    }

    @Test
    fun changeFeedAcceptsExplicitNullDocumentFields() = runTest {
        val documentId = UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500")
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "changes",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("sequence", 1)
                                    .put("resource_kind", "document")
                                    .put("resource_id", documentId.toString())
                                    .put("operation", "upsert")
                                    .put("content_sha256", "a".repeat(64))
                                    .put("data_class", "user_documents")
                                    .put("event_start", JSONObject.NULL)
                                    .put("event_end", JSONObject.NULL)
                                    .put(
                                        "document",
                                        JSONObject()
                                            .put("document_kind", "day_ownership")
                                            .put("document_id", documentId.toString())
                                            .put("revision", 1)
                                            .put("content_mode", "server_readable")
                                            .put("client_key_id", JSONObject.NULL)
                                            .put("updated_at", "2026-09-04T12:00:00Z")
                                            .put("deleted_at", JSONObject.NULL),
                                    ),
                            ),
                        )
                        .put("minimum_sequence", 1)
                        .put("high_watermark", 1)
                        .put("next_sequence", 1)
                        .put("has_more", false)
                        .toString(),
                )
            },
        )

        val feed = client.changes(authorization, afterSequence = 0, limit = 200)

        assertEquals(1, feed.changes.size)
        assertNull(feed.changes.single().eventStart)
        assertNull(feed.changes.single().eventEnd)
        assertNull(feed.changes.single().document?.clientKeyId)
        assertNull(feed.changes.single().document?.deletedAt)
    }

    @Test
    fun changeFeedRejectsSensitiveServerReadableMetadata() = runTest {
        val documentId = UUID.fromString("a2810672-1c29-5e68-9ddd-45e8c3164500")
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "changes",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("sequence", 1)
                                    .put("resource_kind", "document")
                                    .put("resource_id", documentId.toString())
                                    .put("operation", "upsert")
                                    .put("content_sha256", "a".repeat(64))
                                    .put("data_class", "user_documents")
                                    .put("event_start", JSONObject.NULL)
                                    .put("event_end", JSONObject.NULL)
                                    .put(
                                        "document",
                                        JSONObject()
                                            .put("document_kind", "journal")
                                            .put("document_id", documentId.toString())
                                            .put("revision", 1)
                                            .put("content_mode", "server_readable")
                                            .put("client_key_id", JSONObject.NULL)
                                            .put("updated_at", "2026-09-04T12:00:00Z")
                                            .put("deleted_at", JSONObject.NULL),
                                    ),
                            ),
                        )
                        .put("minimum_sequence", 1)
                        .put("high_watermark", 1)
                        .put("next_sequence", 1)
                        .put("has_more", false)
                        .toString(),
                )
            },
        )

        val failure = try {
            client.changes(authorization, afterSequence = 0, limit = 200)
            null
        } catch (error: Throwable) {
            error
        }

        assertTrue(failure is ManagedStorageException.InvalidResponse)
    }

    @Test
    fun changeFeedRejectsMissingOrMisroutedDocumentMetadata() = runTest {
        val documentId = UUID.fromString("55555555-5555-5555-8555-555555555555")
        val clientKeyId = UUID.fromString("66666666-6666-5666-8666-666666666666")
        val digest = ManagedDigest.sha256(
            "noop-encrypted-journal-payload".toByteArray(),
        )
        val rows = listOf(
            JSONObject()
                .put("sequence", 1)
                .put("resource_kind", "document")
                .put("resource_id", documentId.toString())
                .put("operation", "upsert")
                .put("content_sha256", digest)
                .put("data_class", "user_documents")
                .put("event_start", JSONObject.NULL)
                .put("event_end", JSONObject.NULL),
            JSONObject()
                .put("sequence", 1)
                .put("resource_kind", "chunk")
                .put("resource_id", documentId.toString())
                .put("operation", "upsert")
                .put("content_sha256", digest)
                .put("data_class", "user_documents")
                .put("event_start", JSONObject.NULL)
                .put("event_end", JSONObject.NULL)
                .put(
                    "document",
                    JSONObject()
                        .put("document_kind", "journal")
                        .put("document_id", documentId.toString())
                        .put("revision", 1)
                        .put("content_mode", "client_encrypted")
                        .put("client_key_id", clientKeyId.toString())
                        .put("updated_at", "2026-09-11T15:00:00Z")
                        .put("deleted_at", JSONObject.NULL),
                ),
        )

        rows.forEach { row ->
            val client = ManagedStorageClient(
                config,
                client { request ->
                    response(
                        request,
                        200,
                        JSONObject()
                            .put("changes", org.json.JSONArray().put(row))
                            .put("minimum_sequence", 1)
                            .put("high_watermark", 1)
                            .put("next_sequence", 1)
                            .put("has_more", false)
                            .toString(),
                    )
                },
            )
            val failure = try {
                client.changes(
                    authorization,
                    afterSequence = 0,
                    limit = 200,
                )
                null
            } catch (error: Throwable) {
                error
            }

            assertTrue(failure is ManagedStorageException.InvalidResponse)
        }
    }

    @Test
    fun tombstoneResponseRejectsClientEncryptionMetadata() = runTest {
        val documentId = UUID.randomUUID()
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "document",
                            JSONObject()
                                .put("document_kind", "journal")
                                .put("document_id", documentId.toString())
                                .put("revision", 2)
                                .put(
                                    "origin_installation_id",
                                    authorization.installationId,
                                )
                                .put("content_mode", "client_encrypted")
                                .put("client_key_id", UUID.randomUUID().toString())
                                .put("content_sha256", "b".repeat(64))
                                .put("updated_at", "2026-09-04T12:00:00Z")
                                .put("deleted_at", "2026-09-04T12:00:00Z"),
                        )
                        .toString(),
                )
            },
        )

        try {
            client.document(
                authorization,
                ManagedDocumentKind.JOURNAL,
                documentId,
                revision = 2,
            )
            fail("Expected malformed tombstone rejection")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }
    }

    @Test
    fun requestDiagnosticCorrelatesWithoutDynamicPathOrQuery() = runTest {
        val diagnostics = mutableListOf<ManagedStorageRequestDiagnostic>()
        val requestId = "b".repeat(32)
        val client = ManagedStorageClient(
            configuration = config,
            http = client { request ->
                response(
                    request,
                    410,
                    """{"detail":{"minimum_sequence":55}}""",
                    mapOf("X-Noop-Request-ID" to requestId),
                )
            },
            requestObserver = { diagnostics += it },
        )

        try {
            client.changes(
                authorization = authorization,
                afterSequence = 123,
                limit = 200,
            )
            fail("Expected cursor expiry")
        } catch (error: ManagedStorageException.CursorExpired) {
            assertEquals(55L, error.minimumSequence)
        }

        val diagnostic = diagnostics.single()
        assertEquals("managed_api", diagnostic.target)
        assertEquals("/v1/managed/changes", diagnostic.routeGroup)
        assertEquals("GET", diagnostic.method)
        assertEquals(410, diagnostic.statusCode)
        assertEquals(requestId, diagnostic.requestId)
        assertEquals("rejected", diagnostic.outcome)
        assertTrue(!diagnostic.toString().contains("after_sequence"))
    }

    @Test
    fun managedSocialProfileUsesInstallationScopeAndStrictIdentity() = runTest {
        var captured: Request? = null
        val profileId = UUID.randomUUID()
        val requestId = UUID.randomUUID()
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    201,
                    JSONObject()
                        .put(
                            "profile",
                            JSONObject()
                                .put("profile_id", profileId.toString())
                                .put("display_name", "Private Friend")
                                .put("noop_id", "NOOP-ABCD-EFGH-JKLM-NPQR")
                                .put("poke_opt_in", false)
                                .put("quiet_start_minute", 1_320)
                                .put("quiet_end_minute", 420)
                                .put("time_zone", "America/New_York")
                                .put("created_at", "2026-09-05T12:00:00Z")
                                .put("updated_at", "2026-09-05T12:00:00Z")
                                .put("duplicate", false)
                                .put("badges", org.json.JSONArray()),
                        )
                        .toString(),
                )
            },
        )

        val profile = client.createSocialProfile(
            authorization = authorization,
            displayName = " Private Friend ",
            requestId = requestId,
        )

        assertEquals(profileId, profile.profileId)
        assertEquals("NOOP-ABCD-EFGH-JKLM-NPQR", profile.noopId)
        assertEquals(authorization.installationId, captured!!.header("X-Noop-Installation-ID"))
        assertEquals(authorization.installationToken, captured!!.header("X-Noop-Installation-Token"))
        assertEquals("/v1/managed/social/profile", captured!!.url.encodedPath)
        val body = JSONObject(okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8())
        assertEquals(requestId.toString(), body.getString("request_id"))
        assertEquals("Private Friend", body.getString("display_name"))
    }

    @Test
    fun managedSocialSummarySendsOnlyApprovedProjection() = runTest {
        var captured: Request? = null
        val requestId = UUID.randomUUID()
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    """{"summary":{"day":"2026-09-05"}}""",
                )
            },
        )

        client.putSocialSummary(
            authorization = authorization,
            day = "2026-09-05",
            summary = ManagedSocialSummary(
                charge = 74.0,
                sleepDuration = 442.0,
                hrv = 53.2,
            ),
            requestId = requestId,
        )

        assertEquals(
            "/v1/managed/social/summaries/2026-09-05",
            captured!!.url.encodedPath,
        )
        val body = JSONObject(okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8())
        assertEquals(requestId.toString(), body.getString("request_id"))
        val summary = body.getJSONObject("summary")
        assertEquals(setOf("charge", "sleep_duration", "hrv"), summary.keys().asSequence().toSet())
    }

    @Test
    fun managedSocialReturnsExpiredInviteReplayForRotation() = runTest {
        val capability = "noopinvite_" + "a".repeat(43)
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "invite",
                            JSONObject()
                                .put(
                                    "invite_id",
                                    "00000000-0000-0000-0000-000000000555",
                                )
                                .put("capability", capability)
                                .put("status", "expired")
                                .put("created_at", "2026-09-01T10:00:00Z")
                                .put("expires_at", "2026-09-04T10:00:00Z")
                                .put("duplicate", true),
                        )
                        .toString(),
                )
            },
        )

        val invite = client.createSocialInvite(
            authorization = authorization,
            capability = capability,
            requestId = UUID.randomUUID(),
        )

        assertEquals("expired", invite.status)
        assertTrue(invite.duplicate)
    }

    @Test
    fun managedSocialPokeAcknowledgementIsClaimBound() = runTest {
        var captured: Request? = null
        val pokeId = UUID.randomUUID()
        val claimId = UUID.randomUUID()
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "poke",
                            JSONObject()
                                .put("poke_id", pokeId.toString())
                                .put("status", "acknowledged")
                                .put("duplicate", false)
                                .put("notification_outcome", "scheduled")
                                .put("haptic_outcome", "band_unavailable"),
                        )
                        .toString(),
                )
            },
        )

        client.acknowledgeSocialPoke(
            authorization = authorization,
            pokeId = pokeId,
            acknowledgement = ManagedSocialPokeAcknowledgement(
                claimId = claimId,
                notificationOutcome = "scheduled",
                hapticOutcome = "band_unavailable",
            ),
        )

        assertEquals(
            "/v1/managed/social/pokes/${pokeId.toString().lowercase()}:ack",
            captured!!.url.encodedPath,
        )
        val body = JSONObject(okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8())
        assertEquals(claimId.toString(), body.getString("claim_id"))
        assertEquals("scheduled", body.getString("notification_outcome"))
        assertEquals("band_unavailable", body.getString("haptic_outcome"))
    }

    @Test
    fun managedSocialBlockedProfilesAreValidated() = runTest {
        var captured: Request? = null
        val profileId = UUID.randomUUID()
        val client = ManagedStorageClient(
            config,
            client { request ->
                captured = request
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "blocks",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("profile_id", profileId.toString())
                                    .put("display_name", "Blocked profile")
                                    .put(
                                        "blocked_at",
                                        "2026-09-05T12:00:00Z",
                                    ),
                            ),
                        )
                        .toString(),
                )
            },
        )

        val blocks = client.socialBlockedProfiles(authorization)

        assertEquals("/v1/managed/social/blocks", captured!!.url.encodedPath)
        assertEquals(profileId, blocks.single().profileId)
        assertEquals("Blocked profile", blocks.single().displayName)
    }

    @Test
    fun managedSocialFriendRejectsUnapprovedHealthField() = runTest {
        val profileId = UUID.randomUUID()
        val visibility = JSONObject()
            .put("charge", true)
            .put("effort", false)
            .put("rest", false)
            .put("sleep_duration", false)
            .put("hrv", false)
            .put("rhr", false)
            .put("poke_allowed", false)
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "friends",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("profile_id", profileId.toString())
                                    .put("display_name", "Friend")
                                    .put("friends_since", "2026-09-05T12:00:00Z")
                                    .put("sharing", visibility)
                                    .put("shared_with_me", visibility)
                                    .put("badges", org.json.JSONArray())
                                    .put(
                                        "latest",
                                        JSONObject()
                                            .put("day", "2026-09-05")
                                            .put(
                                                "summary",
                                                JSONObject()
                                                    .put("charge", 70)
                                                    .put("steps", 10_000),
                                            ),
                                    ),
                            ),
                        )
                        .toString(),
                )
            },
        )

        try {
            client.socialFriends(authorization)
            fail("Expected unapproved managed Friends field rejection")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }
    }

    @Test
    fun managedSafetyCreateAllowsMissingLocationForDuplicateReplay() = runTest {
        val incidentId = UUID.randomUUID()
        val ownerId = UUID.randomUUID()
        val firstId = UUID.randomUUID()
        val secondId = UUID.randomUUID()
        val initialLocation = SafetyLocation(
            latitude = 17.385,
            longitude = 78.4867,
            horizontalAccuracyMeters = 12.5,
            capturedAtUnix = Instant.parse("2026-09-08T10:00:00Z").epochSecond,
        )

        fun createClient(
            status: String,
            duplicate: Boolean = true,
        ): ManagedStorageClient =
            ManagedStorageClient(
                config,
                client { request ->
                    val incident = safetyIncident(
                        incidentId,
                        ownerId,
                        firstId,
                        secondId,
                    )
                        .put("status", status)
                        .put(
                            "ended_at",
                            if (status == "open") JSONObject.NULL
                            else "2026-09-08T18:00:00Z",
                        )
                        .put("duplicate", duplicate)
                        .put("location", JSONObject.NULL)
                    response(
                        request,
                        200,
                        JSONObject()
                            .put("incident", incident)
                            .put("push_outcome", "deferred")
                            .toString(),
                    )
                },
            )

        val replay = createClient("expired").createSafetyIncident(
            authorization = authorization,
            requestId = UUID.randomUUID(),
            durationHours = 8,
            shareLocation = true,
            initialLocation = initialLocation,
        )
        assertTrue(replay.incident.duplicate)
        assertEquals("expired", replay.incident.status)
        assertNull(replay.incident.location)

        val activeReplay = createClient("open").createSafetyIncident(
            authorization = authorization,
            requestId = UUID.randomUUID(),
            durationHours = 8,
            shareLocation = true,
            initialLocation = initialLocation,
        )
        assertTrue(activeReplay.incident.duplicate)
        assertEquals("open", activeReplay.incident.status)
        assertNull(activeReplay.incident.location)

        try {
            createClient(status = "open", duplicate = false).createSafetyIncident(
                authorization = authorization,
                requestId = UUID.randomUUID(),
                durationHours = 8,
                shareLocation = true,
                initialLocation = initialLocation,
            )
            fail("New incident without its accepted initial location was accepted")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }
    }

    @Test
    fun managedSafetyRejectsLocationWhenSharingIsOff() = runTest {
        val incident = safetyIncident(
            UUID.randomUUID(),
            UUID.randomUUID(),
            UUID.randomUUID(),
            UUID.randomUUID(),
        )
            .put("share_location", false)
            .put(
                "location",
                JSONObject()
                    .put("sequence", 1)
                    .put("latitude", 17.385)
                    .put("longitude", 78.4867)
                    .put("horizontal_accuracy_m", 12.5)
                    .put("captured_at", "2026-09-08T10:00:00Z")
                    .put("received_at", "2026-09-08T10:00:01Z"),
            )
        val client = ManagedStorageClient(
            config,
            client { request ->
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "incidents",
                            org.json.JSONArray().put(incident),
                        )
                        .toString(),
                )
            },
        )

        try {
            client.safetyIncidents(authorization)
            fail("Location was accepted while sharing was off")
        } catch (_: ManagedStorageException.InvalidResponse) {
            // Expected.
        }
    }

    @Test
    fun managedSafetyContractIsBoundedAndLocationIsLatestOnly() = runTest {
        val ownerId = UUID.fromString("00000000-0000-0000-0000-000000000101")
        val firstId = UUID.fromString("00000000-0000-0000-0000-000000000102")
        val secondId = UUID.fromString("00000000-0000-0000-0000-000000000103")
        val incidentId = UUID.fromString("00000000-0000-0000-0000-000000000104")
        val noLocationIncidentId =
            UUID.fromString("00000000-0000-0000-0000-000000000105")
        val token = "fcm-token:ABC_def-1234567890"
        val client = ManagedStorageClient(
            config,
            client { request ->
                val body = when (request.url.encodedPath) {
                    "/v1/managed/push/installations/current" -> {
                        val requestBody = request.jsonBody()
                        assertEquals("android", requestBody.getString("platform"))
                        assertEquals(
                            "development",
                            requestBody.getString("environment"),
                        )
                        assertEquals(
                            "token",
                            requestBody.getString("target_kind"),
                        )
                        assertEquals(token, requestBody.getString("token"))
                        JSONObject().put(
                            "registration",
                            JSONObject()
                                .put("installation_id", "android-installation")
                                .put("platform", "android")
                                .put("environment", "development")
                                .put("target_kind", "token")
                                .put("status", "active")
                                .put("updated_at", "2026-09-08T10:00:00Z")
                                .put("duplicate", false),
                        )
                    }
                    "/v1/managed/safety/contacts" -> JSONObject()
                        .put(
                            "contacts",
                            org.json.JSONArray()
                                .put(safetyContact(firstId, "First"))
                                .put(safetyContact(secondId, "Second")),
                        )
                        .put("delivery_capable_count", 2)
                        .put("minimum_required", 2)
                        .put("maximum_allowed", 5)
                    "/v1/managed/safety/incidents" -> {
                        val requestBody = request.jsonBody()
                        assertEquals(8, requestBody.getInt("duration_hours"))
                        if (requestBody.getBoolean("share_location")) {
                            assertEquals(
                                "band_sos",
                                requestBody.getString("trigger"),
                            )
                            val initialLocation =
                                requestBody.getJSONObject("initial_location")
                            assertEquals(1L, initialLocation.getLong("sequence"))
                            assertEquals(
                                "2026-09-08T10:00:00Z",
                                initialLocation.getString("captured_at"),
                            )
                            JSONObject()
                                .put(
                                    "incident",
                                    safetyIncident(
                                        incidentId,
                                        ownerId,
                                        firstId,
                                        secondId,
                                        trigger = "band_sos",
                                    ).put(
                                        "location",
                                        JSONObject()
                                            .put("sequence", 1)
                                            .put("latitude", 17.385)
                                            .put("longitude", 78.4867)
                                            .put("horizontal_accuracy_m", 12.5)
                                            .put(
                                                "captured_at",
                                                "2026-09-08T10:00:00Z",
                                            )
                                            .put(
                                                "received_at",
                                                "2026-09-08T10:00:01Z",
                                            ),
                                    ),
                                )
                                .put("push_outcome", "attempted")
                        } else {
                            assertEquals(
                                "manual_sos",
                                requestBody.getString("trigger"),
                            )
                            assertFalse(requestBody.has("initial_location"))
                            JSONObject()
                                .put(
                                    "incident",
                                    safetyIncident(
                                        noLocationIncidentId,
                                        ownerId,
                                        firstId,
                                        secondId,
                                        trigger = "manual_sos",
                                    ).put("share_location", false),
                                )
                                .put("push_outcome", "attempted")
                        }
                    }
                    "/v1/managed/safety/incidents/" +
                        "${incidentId.toString().lowercase()}/location" -> {
                        val requestBody = request.jsonBody()
                        assertEquals(99L, requestBody.getLong("sequence"))
                        JSONObject().put(
                            "location",
                            JSONObject()
                                .put("sequence", 3)
                                .put("latitude", 17.385)
                                .put("longitude", 78.4867)
                                .put("horizontal_accuracy_m", 12.5)
                                .put("captured_at", "2026-09-08T10:01:00Z")
                                .put("received_at", "2026-09-08T10:01:01Z")
                                .put("duplicate", false),
                        )
                    }
                    else -> error("Unexpected request ${request.url.encodedPath}")
                }
                response(request, 200, body.toString())
            },
        )

        val registration = client.registerPushInstallation(
            authorization,
            ManagedPushEnvironment.DEVELOPMENT,
            token,
        )
        assertEquals("android-installation", registration.installationId)
        assertEquals("token", registration.targetKind)
        val contacts = client.safetyContacts(authorization)
        assertEquals(2, contacts.contacts.size)
        assertEquals(2, contacts.deliveryCapableCount)
        val creation = client.createSafetyIncident(
            authorization = authorization,
            requestId = UUID.randomUUID(),
            trigger = "band_sos",
            durationHours = 8,
            shareLocation = true,
            initialLocation = SafetyLocation(
                latitude = 17.385,
                longitude = 78.4867,
                horizontalAccuracyMeters = 12.5,
                capturedAtUnix =
                    Instant.parse("2026-09-08T10:00:00Z").epochSecond,
            ),
        )
        assertEquals(incidentId, creation.incident.incidentId)
        assertEquals("attempted", creation.pushOutcome)
        val noLocationCreation = client.createSafetyIncident(
            authorization = authorization,
            requestId = UUID.randomUUID(),
            trigger = "manual_sos",
            durationHours = 8,
            shareLocation = false,
            initialLocation = null,
        )
        assertEquals(
            noLocationIncidentId,
            noLocationCreation.incident.incidentId,
        )
        assertFalse(noLocationCreation.incident.shareLocation)
        assertNull(noLocationCreation.incident.location)
        val location = client.updateSafetyLocation(
            authorization = authorization,
            incidentId = incidentId,
            sequence = 99,
            latitude = 17.385,
            longitude = 78.4867,
            horizontalAccuracyM = 12.5,
            capturedAt = "2026-09-08T10:01:00Z",
        )
        assertEquals(3L, location.sequence)
    }

    @Test
    fun managedSafetyContactsMissingDeliveryCapabilityFailsClosed() = runTest {
        val contactId =
            UUID.fromString("00000000-0000-0000-0000-000000000109")
        val client = ManagedStorageClient(
            config,
            client { request ->
                assertEquals(
                    "/v1/managed/safety/contacts",
                    request.url.encodedPath,
                )
                response(
                    request,
                    200,
                    JSONObject()
                        .put(
                            "contacts",
                            org.json.JSONArray().put(
                                JSONObject()
                                    .put("profile_id", contactId.toString())
                                    .put("display_name", "Contact")
                                    .put("role", "contact")
                                    .put(
                                        "accepted_at",
                                        "2026-09-08T09:00:00Z",
                                    ),
                            ),
                        )
                        .put("minimum_required", 2)
                        .put("maximum_allowed", 5)
                        .toString(),
                )
            },
        )

        val contacts = client.safetyContacts(authorization)
        assertEquals(1, contacts.contacts.size)
        assertEquals(0, contacts.deliveryCapableCount)
    }

    @Test
    fun retainedOwnerIncidentAllowsErasedParticipants() = runTest {
        val incidentId = UUID.fromString("00000000-0000-0000-0000-000000000204")
        val ownerId = UUID.fromString("00000000-0000-0000-0000-000000000205")
        val participantId =
            UUID.fromString("00000000-0000-0000-0000-000000000206")

        for (participantCount in 0..1) {
            val client = ManagedStorageClient(
                config,
                client { request ->
                    assertEquals(
                        "/v1/managed/safety/incidents",
                        request.url.encodedPath,
                    )
                    val participants = org.json.JSONArray()
                    if (participantCount == 1) {
                        participants.put(
                            JSONObject()
                                .put("profile_id", participantId.toString())
                                .put("display_name", "Former contact")
                                .put("status", "revoked")
                                .put("paged_at", "2026-09-08T10:00:00Z")
                                .put("responded_at", "2026-09-08T10:05:00Z")
                                .put(
                                    "push",
                                    JSONObject()
                                        .put("configured", false)
                                        .put("reached", false),
                                ),
                        )
                    }
                    val incident = JSONObject()
                        .put("incident_id", incidentId.toString())
                        .put("role", "owner")
                        .put("owner_profile_id", ownerId.toString())
                        .put("owner_display_name", "Owner")
                        .put("trigger", "manual_sos")
                        .put("status", "expired")
                        .put("duration_hours", 8)
                        .put("share_location", false)
                        .put("created_at", "2026-09-08T10:00:00Z")
                        .put("expires_at", "2026-09-08T18:00:00Z")
                        .put("acknowledged_at", JSONObject.NULL)
                        .put("ended_at", "2026-09-08T18:00:00Z")
                        .put("participants", participants)
                        .put("location", JSONObject.NULL)
                        .put(
                            "delivery",
                            JSONObject()
                                .put("contacts_targeted", 0)
                                .put("contacts_reached", 0)
                                .put("installations_targeted", 0)
                                .put("installations_reached", 0)
                                .put("installations_retryable", 0)
                                .put("installations_terminal", 0),
                        )
                        .put("duplicate", false)
                    response(
                        request,
                        200,
                        JSONObject()
                            .put(
                                "incidents",
                                org.json.JSONArray().put(incident),
                            )
                            .toString(),
                    )
                },
            )

            val incidents = client.safetyIncidents(authorization)

        assertEquals(1, incidents.size)
        assertEquals(participantCount, incidents.single().participants.size)
        }
    }

    private fun wrappedKeyRecordJson(
        keyId: UUID,
        keyKind: String = "document",
        wrappingKeyId: UUID?,
        wrappingRevision: Int,
        wrappedKey: ByteArray,
        confirmation: String? = null,
        recoveryMethod: String? = null,
        status: String = "active",
        successorKeyId: UUID? = null,
        createdAt: String = "2026-09-20T05:00:00Z",
        updatedAt: String = createdAt,
        revokedAt: String? = null,
    ): JSONObject = wrappedKeyVersionJson(
        keyId = keyId,
        keyKind = keyKind,
        wrappingKeyId = wrappingKeyId,
        wrappingRevision = wrappingRevision,
        wrappedKey = wrappedKey,
        confirmation = confirmation,
        recoveryMethod = recoveryMethod,
        createdAt = createdAt,
    )
        .put("status", status)
        .put(
            "successor_key_id",
            successorKeyId?.toString()?.lowercase() ?: JSONObject.NULL,
        )
        .put("updated_at", updatedAt)
        .put("revoked_at", revokedAt ?: JSONObject.NULL)

    private fun wrappedKeyVersionJson(
        keyId: UUID,
        keyKind: String = "document",
        wrappingKeyId: UUID?,
        wrappingRevision: Int,
        wrappedKey: ByteArray,
        confirmation: String? = null,
        recoveryMethod: String? = null,
        createdAt: String = "2026-09-20T05:00:00Z",
    ): JSONObject = JSONObject()
        .put("key_id", keyId.toString().lowercase())
        .put("key_kind", keyKind)
        .put(
            "wrapping_key_id",
            wrappingKeyId?.toString()?.lowercase() ?: JSONObject.NULL,
        )
        .put("wrapping_revision", wrappingRevision)
        .put("algorithm", "A256GCM")
        .put(
            "wrapped_key_base64",
            java.util.Base64.getEncoder().encodeToString(wrappedKey),
        )
        .put("wrapped_key_sha256", ManagedDigest.sha256(wrappedKey))
        .put(
            "master_key_confirmation_hmac_sha256",
            confirmation ?: JSONObject.NULL,
        )
        .put("recovery_method", recoveryMethod ?: JSONObject.NULL)
        .put("created_at", createdAt)

    private fun safetyContact(profileId: UUID, name: String): JSONObject =
        JSONObject()
            .put("profile_id", profileId.toString())
            .put("display_name", name)
            .put("role", "contact")
            .put("accepted_at", "2026-09-08T09:00:00Z")

    private fun safetyIncident(
        incidentId: UUID,
        ownerId: UUID,
        firstId: UUID,
        secondId: UUID,
        trigger: String = "manual_sos",
    ): JSONObject = JSONObject()
        .put("incident_id", incidentId.toString())
        .put("role", "owner")
        .put("owner_profile_id", ownerId.toString())
        .put("owner_display_name", "Owner")
        .put("trigger", trigger)
        .put("status", "open")
        .put("duration_hours", 8)
        .put("share_location", true)
        .put("created_at", "2026-09-08T10:00:00Z")
        .put("expires_at", "2026-09-08T18:00:00Z")
        .put("acknowledged_at", JSONObject.NULL)
        .put("ended_at", JSONObject.NULL)
        .put(
            "participants",
            org.json.JSONArray()
                .put(safetyParticipant(firstId, "First", true))
                .put(safetyParticipant(secondId, "Second", false)),
        )
        .put("location", JSONObject.NULL)
        .put(
            "delivery",
            JSONObject()
                .put("contacts_targeted", 2)
                .put("contacts_reached", 1)
                .put("installations_targeted", 2)
                .put("installations_reached", 1)
                .put("installations_retryable", 1)
                .put("installations_terminal", 0),
        )
        .put("duplicate", false)

    private fun safetyParticipant(
        profileId: UUID,
        name: String,
        reached: Boolean,
    ): JSONObject = JSONObject()
        .put("profile_id", profileId.toString())
        .put("display_name", name)
        .put("status", "pending")
        .put("paged_at", "2026-09-08T10:00:00Z")
        .put("responded_at", JSONObject.NULL)
        .put(
            "push",
            JSONObject()
                .put("configured", true)
                .put("reached", reached),
        )

    private fun Request.jsonBody(): JSONObject =
        JSONObject(okio.Buffer().also { body!!.writeTo(it) }.readUtf8())

    private fun client(block: (Request) -> Response): OkHttpClient =
        OkHttpClient.Builder().addInterceptor(Interceptor { chain -> block(chain.request()) }).build()

    private fun response(
        request: Request,
        code: Int,
        body: String,
        headers: Map<String, String> = emptyMap(),
    ): Response = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(code)
        .message(if (code in 200..299) "OK" else "Error")
        .apply { headers.forEach { (name, value) -> header(name, value) } }
        .body(body.toResponseBody("application/json".toMediaType()))
        .build()
}
