package com.noop.ownership

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.test.runTest
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class OwnershipAccountDeletionContractTest {
    private val configuration = OwnershipConfiguration(
        baseUrl = "https://ownership.noop.example".toHttpUrl(),
        termsHost = "terms.noop.example",
        projectId = "noop-test-project",
        apiKey = "test-api-key",
        googleAppId = "1:123456789:android:abcdef12",
        gcmSenderId = "123456789",
    )
    private val installation = OwnershipInstallationCredential(
        id = "android-installation",
        token = "noopo_" + "A".repeat(43),
    )
    private val authorization = OwnershipAuthorization(
        identityToken = "identity-token",
        appCheckToken = "app-check-token",
        installation = installation,
    )
    private val deletionRequestId =
        UUID.fromString("c54af6e3-917c-43db-a42d-1f5ed79d79a1")
    private val attemptId =
        UUID.fromString("7aa9e043-6851-49c7-9178-2740bdb736fb")

    @Test
    fun requestStatusAndCancelMatchTheServerRouteAndCredentialContract() = runTest {
        val requests = mutableListOf<Request>()
        val client = client { request ->
            requests += request
            response(
                request = request,
                body = deletionResponse(
                    canceled = request.url.encodedPath.endsWith("/cancel"),
                ).toString(),
            )
        }

        client.requestAccountDeletion(
            requestId = attemptId,
            confirmationSha256 = CONFIRMATION_SHA256,
            exportAcknowledged = true,
            retentionAcknowledged = true,
            policyVersion = "ownership-v1",
            policySha256 = "b".repeat(64),
            locale = "en",
            authorization = authorization,
        )
        client.accountDeletion(deletionRequestId, authorization)
        client.cancelAccountDeletion(deletionRequestId, authorization)

        assertEquals(3, requests.size)
        val request = requests[0]
        assertEquals("POST", request.method)
        assertEquals(
            "/v1/ownership/account/deletion-requests",
            request.url.encodedPath,
        )
        assertEquals(installation.id, request.header(INSTALLATION_ID_HEADER))
        assertEquals(installation.token, request.header(INSTALLATION_TOKEN_HEADER))

        val body = JSONObject(request.bodyText())
        assertEquals(
            setOf(
                "request_id",
                "confirmation_sha256",
                "export_acknowledged",
                "retention_acknowledged",
                "policy_version",
                "policy_sha256",
                "locale",
            ),
            body.keys().asSequence().toSet(),
        )
        assertEquals(attemptId.toString(), body.getString("request_id"))
        assertEquals(CONFIRMATION_SHA256, body.getString("confirmation_sha256"))
        assertTrue(body.getBoolean("export_acknowledged"))
        assertTrue(body.getBoolean("retention_acknowledged"))
        assertEquals("ownership-v1", body.getString("policy_version"))
        assertEquals("b".repeat(64), body.getString("policy_sha256"))
        assertEquals("en", body.getString("locale"))
        assertFalse(request.bodyText().contains(TYPED_CONFIRMATION))

        val status = requests[1]
        assertEquals("GET", status.method)
        assertEquals(
            "/v1/ownership/account/deletion-requests/$deletionRequestId",
            status.url.encodedPath,
        )
        assertNull(status.header(INSTALLATION_ID_HEADER))
        assertNull(status.header(INSTALLATION_TOKEN_HEADER))

        val cancel = requests[2]
        assertEquals("POST", cancel.method)
        assertEquals(
            "/v1/ownership/account/deletion-requests/$deletionRequestId/cancel",
            cancel.url.encodedPath,
        )
        assertEquals(installation.id, cancel.header(INSTALLATION_ID_HEADER))
        assertEquals(installation.token, cancel.header(INSTALLATION_TOKEN_HEADER))

        listOf(request, status, cancel).forEach {
            assertEquals("Bearer identity-token", it.header("Authorization"))
            assertEquals("app-check-token", it.header("X-Firebase-AppCheck"))
            assertEquals("no-store", it.header("Cache-Control"))
        }

        val server = source("server/app/ownership_api.py")
        assertTrue(server.contains("\"/account/deletion-requests\""))
        assertTrue(
            server.contains(
                "@router.get(\"/account/deletion-requests/{deletion_request_id}\")",
            ),
        )
        assertTrue(
            server.contains(
                "\"/account/deletion-requests/{deletion_request_id}/cancel\"",
            ),
        )
        val statusRoute = block(
            server,
            "    @router.get(\"/account/deletion-requests/",
            "    @router.post(\n        \"/account/deletion-requests/",
        )
        val cancelRoute = block(
            server,
            "    @router.post(\n        \"/account/deletion-requests/",
            "    @router.put(\"/plan-selection\")",
        )
        assertTrue(statusRoute.contains("Depends(require_account_deletion_principal)"))
        assertFalse(statusRoute.contains("installation_id_header"))
        assertFalse(statusRoute.contains("installation_token_hash_header"))
        assertTrue(cancelRoute.contains("Depends("))
        assertTrue(cancelRoute.contains("require_account_deletion_cancellation"))
        assertTrue(cancelRoute.contains("identity.installation_id"))
        assertTrue(cancelRoute.contains("identity.installation_token_hash"))
    }

    @Test
    fun typedConfirmationHashIsExactAcrossAndroidAndServer() {
        assertEquals(TYPED_CONFIRMATION, OwnershipService.ACCOUNT_DELETION_CONFIRMATION)
        assertEquals(CONFIRMATION_SHA256, sha256(TYPED_CONFIRMATION))

        val service = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
        )
        val serverModels = source("server/app/ownership_models.py")
        val serverApi = source("server/app/ownership_api.py")
        val request = block(
            service,
            "    suspend fun requestAccountDeletion(",
            "    suspend fun refreshAccountDeletion(",
        )
        val hash = block(
            service,
            "    private fun accountDeletionConfirmationSha256()",
            "    private fun deletionDiagnosticFields(",
        )

        assertTrue(request.contains("confirmation != ACCOUNT_DELETION_CONFIRMATION"))
        assertTrue(
            request.contains(
                "confirmationSha256 = accountDeletionConfirmationSha256()",
            ),
        )
        assertTrue(hash.contains("MessageDigest.getInstance(\"SHA-256\")"))
        assertTrue(hash.contains("StandardCharsets.UTF_8"))
        assertTrue(serverModels.contains("b\"$TYPED_CONFIRMATION\""))
        assertTrue(
            serverApi.contains(
                "body.confirmation_sha256,\n" +
                    "            OWNERSHIP_ACCOUNT_DELETION_CONFIRMATION_SHA256,",
            ),
        )
    }

    @Test
    fun parserRequiresNullableKeysAndConsistentBlockerStates() = runTest {
        val missingNullableKeys = listOf<Pair<String, JSONObject.() -> Unit>>(
            "canceled_at" to { remove("canceled_at") },
            "identity blocker" to {
                getJSONObject("identity_deletion").remove("blocker")
            },
            "band blocker" to {
                getJSONObject("band_retirement").remove("blocker")
            },
            "band policy version" to {
                getJSONObject("band_retirement").remove("policy_version")
            },
            "band hardware version" to {
                getJSONObject("band_retirement")
                    .remove("hardware_capability_version")
            },
            "control blocker" to {
                getJSONObject("control_plane_deletion").remove("blocker")
            },
        )
        for ((label, mutation) in missingNullableKeys) {
            assertInvalidDeletion(label, mutation)
        }

        assertInvalidDeletion("malformed blocker") {
            getJSONObject("identity_deletion").put("blocker", "Private Detail")
        }
        assertInvalidDeletion("blocked state without blocker") {
            getJSONObject("identity_deletion").put("blocker", JSONObject.NULL)
        }
        assertInvalidDeletion("non-blocked state with blocker") {
            getJSONObject("identity_deletion").put("state", "scheduled")
        }
        assertInvalidDeletion("canceled state without canceled timestamp") {
            put("state", "canceled")
            put("cancellation_allowed", false)
        }
        assertInvalidDeletion("cooling-off state without cancellation") {
            put("cancellation_allowed", false)
        }
        assertInvalidDeletion("scheduled state with cancellation") {
            put("state", "scheduled")
        }

        val scheduled = deletionObject(canceled = false).apply {
            put("state", "scheduled")
            put("cancellation_allowed", false)
            getJSONObject("identity_deletion")
                .put("state", "scheduled")
                .put("blocker", JSONObject.NULL)
        }
        parseDeletion(scheduled)

        // Canceled targets no longer expose their original blocker.
        parseDeletion(deletionObject(canceled = true))
    }

    @Test
    fun encryptedStoreKeepsAttemptAndServerReferencesDurablyDistinct() {
        val store = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipSecureStore.kt",
        )
        val service = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
        )
        val request = block(
            service,
            "    suspend fun requestAccountDeletion(",
            "    suspend fun refreshAccountDeletion(",
        )

        assertTrue(store.contains("EncryptedSharedPreferences.create("))
        assertTrue(store.contains("MasterKey.KeyScheme.AES256_GCM"))
        assertTrue(
            store.contains(
                "EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV",
            ),
        )
        assertTrue(
            store.contains(
                "EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM",
            ),
        )
        assertTrue(
            store.contains(
                "private const val DELETION_PREFIX = \"account_deletion.\"",
            ),
        )
        assertTrue(
            store.contains(
                "private const val DELETION_ATTEMPT_PREFIX = " +
                    "\"account_deletion_attempt.\"",
            ),
        )

        val readAttempt = request.indexOf("accountDeletionAttemptId(scope)")
        val persistAttempt =
            request.indexOf("writeAccountDeletionAttemptId(scope, created)")
        val remoteRequest = request.indexOf("client().requestAccountDeletion(")
        val persistServerReference =
            request.indexOf("writeAccountDeletionRequestId(")
        val clearAttempt = request.indexOf("clearAccountDeletionAttemptId(scope)")
        assertTrue(readAttempt >= 0)
        assertTrue(persistAttempt > readAttempt)
        assertTrue(remoteRequest > persistAttempt)
        assertTrue(persistServerReference > remoteRequest)
        assertTrue(clearAttempt > persistServerReference)
    }

    @Test
    fun canceledServerStateCleansReferencesBestEffortAndAlwaysSignsOut() {
        val store = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipSecureStore.kt",
        )
        val service = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
        )
        val apply = block(
            service,
            "    private fun applyAccountDeletion(",
            "    private fun checkpoint(",
        )
        val canceled = block(
            apply,
            "        if (deletion.state == \"canceled\") {",
            "        secureStore().writeAccountDeletionRequestId(",
        )

        val clearServerReference =
            canceled.indexOf("clearAccountDeletionRequestId(scope)")
        val clearAttempt =
            canceled.indexOf("clearAccountDeletionAttemptId(scope)")
        val signOut = canceled.indexOf("runtime().auth.signOut()")
        assertTrue(clearServerReference >= 0)
        assertTrue(clearAttempt > clearServerReference)
        assertTrue(signOut > clearAttempt)
        assertTrue(canceled.contains("return if (cleanupCompleted) \"completed\" else \"deferred\""))
        assertTrue(canceled.contains("ownership_deletion_canceled_cleanup_deferred_status"))

        val clearServer = block(
            store,
            "    fun clearAccountDeletionRequestId(",
            "    fun clearAccountDeletionAttemptId(",
        )
        val clearAttemptSource = block(
            store,
            "    fun clearAccountDeletionAttemptId(",
            "    private fun createCredential(",
        )
        assertTrue(clearServer.contains("bestEffortOwnershipCleanup"))
        assertTrue(clearAttemptSource.contains("bestEffortOwnershipCleanup"))
        assertFalse(
            "A failed server-reference cleanup must not skip attempt cleanup",
            canceled.contains(
                "clearAccountDeletionRequestId(scope) &&\n" +
                    "                    secureStore().clearAccountDeletionAttemptId(scope)",
            ),
        )
    }

    @Test
    fun deletionUiPreservesLocalDataAndNeverOffersBandRelease() {
        val screen = source(
            "android/app/src/main/java/com/noop/ui/OwnershipAccountScreen.kt",
        )
        val strings = source("android/app/src/main/res/values/strings.xml")
        val service = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
        )
        val lifecycle = block(
            service,
            "    suspend fun requestAccountDeletion(",
            "    fun signOut()",
        )

        assertTrue(
            strings.contains(
                "Local health data remains on this phone while the server " +
                    "coordinates account deletion.",
            ),
        )
        assertTrue(
            strings.contains(
                "A claimed band is not released, transferred or made resellable here.",
            ),
        )
        assertTrue(
            screen.contains(
                "stringResource(R.string.ownership_deletion_local_preserved)",
            ),
        )
        assertTrue(
            screen.contains(
                "stringResource(R.string.ownership_deletion_no_unpair)",
            ),
        )
        listOf(
            "unpairBand",
            "releaseBand",
            "transferBand",
            "client().unpair",
            "client().release",
            "client().transfer",
        ).forEach { forbidden ->
            assertFalse(forbidden, lifecycle.contains(forbidden))
        }
    }

    @Test
    fun deletionDiagnosticsAreCategoricalBoundedAndIdentifierFree() {
        val service = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipService.kt",
        )
        val client = source(
            "android/app/src/main/java/com/noop/ownership/OwnershipClient.kt",
        )
        val lifecycle = block(
            service,
            "    suspend fun requestAccountDeletion(",
            "    fun signOut()",
        )
        val deletionFields = block(
            service,
            "    private fun deletionDiagnosticFields(",
            "    private fun secureStore()",
        )
        val requestFields = block(
            client,
            "    private fun recordRequest(",
            "    companion object {",
        )

        listOf(
            "ownership.account_deletion.request",
            "ownership.account_deletion.refresh",
            "ownership.account_deletion.cancel",
        ).forEach { assertTrue(it, lifecycle.contains("\"$it\"")) }
        listOf(
            "deletion_state",
            "cloud_state",
            "identity_state",
            "band_eligibility",
            "band_state",
            "control_state",
        ).forEach { assertTrue(it, deletionFields.contains("\"$it\"")) }
        listOf(
            "target",
            "route_group",
            "method",
            "duration_ms",
            "outcome",
            "status_code",
        ).forEach { assertTrue(it, requestFields.contains("\"$it\"")) }

        val diagnosticSource = lifecycle + deletionFields + requestFields
        listOf(
            "\"account_id\"",
            "\"deletion_request_id\"",
            "\"request_id\"",
            "\"email\"",
            "\"installation_id\"",
            "\"password\"",
            "\"confirmation_sha256\"",
            "\"raw_error\"",
            "error.message",
            "error.stackTrace",
        ).forEach { forbidden ->
            assertFalse(forbidden, diagnosticSource.contains(forbidden))
        }
        assertFalse(
            Regex("""\bdeletion\.id\b""").containsMatchIn(deletionFields),
        )
        assertFalse(requestFields.contains("url.toString()"))
        assertFalse(requestFields.contains("url.encodedPath"))
    }

    private suspend fun assertInvalidDeletion(
        label: String,
        mutation: JSONObject.() -> Unit,
    ) {
        val deletion = deletionObject(canceled = false).apply(mutation)
        try {
            parseDeletion(deletion)
            fail("Expected invalid deletion response: $label")
        } catch (error: OwnershipException) {
            assertSame(label, OwnershipException.InvalidResponse, error)
        }
    }

    private suspend fun parseDeletion(deletion: JSONObject): OwnershipAccountDeletion {
        val client = client { request ->
            response(
                request = request,
                body = JSONObject().put("deletion", deletion).toString(),
            )
        }
        return client.accountDeletion(deletionRequestId, authorization)
    }

    private fun deletionResponse(canceled: Boolean): JSONObject =
        JSONObject().put("deletion", deletionObject(canceled))

    private fun deletionObject(canceled: Boolean): JSONObject {
        val targetState = if (canceled) "canceled" else "blocked"
        val identityBlocker = if (canceled) {
            JSONObject.NULL
        } else {
            "provider_credentials_unavailable"
        }
        val bandBlocker = if (canceled) {
            JSONObject.NULL
        } else {
            "policy_unapproved"
        }
        val controlBlocker = if (canceled) {
            JSONObject.NULL
        } else {
            "account_targets_pending"
        }
        return JSONObject()
            .put("deletion_request_id", deletionRequestId.toString())
            .put("state", if (canceled) "canceled" else "cooling_off")
            .put("account_state", if (canceled) "active" else "deletion_pending")
            .put("requested_at", "2026-09-18T12:00:00Z")
            .put("cancel_before", "2026-10-18T12:00:00Z")
            .put(
                "canceled_at",
                if (canceled) "2026-09-18T13:00:00Z" else JSONObject.NULL,
            )
            .put("cancellation_allowed", !canceled)
            .put("policy_version", "ownership-v1")
            .put("export_acknowledged", true)
            .put("retention_acknowledged", true)
            .put("sessions_revoked", true)
            .put("revoked_session_count", 1)
            .put("reauthorization_required", true)
            .put(
                "cloud_data_deletion",
                JSONObject()
                    .put("state", if (canceled) "canceled" else "scheduled")
                    .put("not_before", "2026-10-18T12:00:00Z"),
            )
            .put(
                "identity_deletion",
                JSONObject()
                    .put("state", targetState)
                    .put("blocker", identityBlocker),
            )
            .put(
                "band_retirement",
                JSONObject()
                    .put("required", true)
                    .put("eligibility", "blocked_policy")
                    .put("work_state", targetState)
                    .put("blocker", bandBlocker)
                    .put("policy_version", JSONObject.NULL)
                    .put("hardware_capability_version", JSONObject.NULL),
            )
            .put(
                "control_plane_deletion",
                JSONObject()
                    .put("state", targetState)
                    .put("blocker", controlBlocker),
            )
            .put("destructive_completion_claimed", false)
            .put("duplicate", false)
    }

    private fun client(responder: (Request) -> Response): OwnershipClient =
        OwnershipClient(
            configuration = configuration,
            client = OkHttpClient.Builder()
                .addInterceptor(Interceptor { chain ->
                    responder(chain.request())
                })
                .build(),
        )

    private fun response(request: Request, body: String): Response =
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()

    private fun Request.bodyText(): String {
        val buffer = Buffer()
        body?.writeTo(buffer)
        return buffer.readUtf8()
    }

    private fun sha256(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) }

    private fun source(relativePath: String): String {
        var root = File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(5) {
            val candidate = File(root, relativePath)
            if (candidate.isFile) return candidate.readText()
            root = root.parentFile ?: root
        }
        error("Missing audited source: $relativePath")
    }

    private fun block(source: String, start: String, end: String): String {
        val startIndex = source.indexOf(start)
        require(startIndex >= 0) { "Missing start marker: $start" }
        val endIndex = source.indexOf(end, startIndex + start.length)
        require(endIndex > startIndex) { "Missing end marker: $end" }
        return source.substring(startIndex, endIndex)
    }

    companion object {
        private const val TYPED_CONFIRMATION =
            "DELETE MY NOOP OWNERSHIP ACCOUNT"
        private const val CONFIRMATION_SHA256 =
            "906c9d4d0cae69e471be62f9a05278b0c02b5b3e7354265b633e12c37e7ae8e3"
        private const val INSTALLATION_ID_HEADER =
            "X-Noop-Ownership-Installation-ID"
        private const val INSTALLATION_TOKEN_HEADER =
            "X-Noop-Ownership-Installation-Token"
    }
}
