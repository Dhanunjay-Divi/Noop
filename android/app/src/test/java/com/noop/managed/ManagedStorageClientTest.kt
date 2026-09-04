package com.noop.managed

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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
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
            )
            fail("Expected stale restore replay")
        } catch (_: ManagedStorageException.Conflict) {
            // Expected.
        }
        val body = JSONObject(
            okio.Buffer().also { captured!!.body!!.writeTo(it) }.readUtf8(),
        )
        assertEquals(true, body.getBoolean("include_documents"))
        assertEquals(0, body.getJSONArray("document_kinds").length())
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
        val payload = JSONObject()
            .put("schema_version", 1)
            .put("table", "journal")
            .put(
                "key",
                JSONObject()
                    .put("deviceId", "strap")
                    .put("day", "2026-09-04")
                    .put("question", "late_caffeine"),
            )
            .put(
                "record",
                JSONObject()
                    .put("deviceId", "strap")
                    .put("day", "2026-09-04")
                    .put("question", "late_caffeine")
                    .put("answeredYes", 1)
                    .put("notes", "after lunch")
                    .put("numericValue", 2.5),
            )
        val documentJson = JSONObject()
            .put("document_kind", "journal")
            .put("document_id", documentId.toString())
            .put("revision", 1)
            .put("origin_installation_id", authorization.installationId)
            .put("content_mode", "server_readable")
            .put("content_sha256", "a".repeat(64))
            .put("payload_json", payload)
            .put("updated_at", "2026-09-04T12:00:00Z")
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
                            .put("documents", org.json.JSONArray().put(documentJson))
                            .put(
                                "next_cursor",
                                JSONObject()
                                    .put("after_updated_at", "2026-09-04T12:00:00Z")
                                    .put("after_document_kind", "journal")
                                    .put("after_document_id", documentId.toString()),
                            )
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
            contentMode = "server_readable",
            payloadJson = payload,
            contentSha256 = "a".repeat(64),
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
        )

        assertEquals(1, page.documents.size)
        assertEquals(documentId, page.nextCursor?.afterDocumentId)
        assertEquals("PUT", captured[0].method)
        assertEquals(
            "/v1/managed/documents/journal/$documentId",
            captured[0].url.encodedPath,
        )
        val putBody = JSONObject(
            okio.Buffer().also { captured[0].body!!.writeTo(it) }.readUtf8(),
        )
        assertEquals(0L, putBody.getLong("base_revision"))
        assertEquals(payload.toString(), putBody.getJSONObject("payload_json").toString())
        assertEquals("GET", captured[1].method)
        assertEquals("1", captured[1].url.queryParameter("revision"))
        assertEquals("/v1/managed/documents", captured[2].url.encodedPath)
        assertEquals("false", captured[2].url.queryParameter("include_deleted"))
        assertEquals("25", captured[2].url.queryParameter("limit"))
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
