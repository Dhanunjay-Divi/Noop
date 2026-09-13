package com.noop.feedback

import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.test.runTest
import okhttp3.Authenticator
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
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
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FeedbackProtocolTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun reserveUploadAndCompleteUseExactAccountFreeIdentityProtocol() = runTest {
        val requests = mutableListOf<Request>()
        val reportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        val http = client { request ->
            requests += request
            when {
                request.url.host == "storage.googleapis.com" -> {
                    request.bodyText()
                    response(request, 200, "")
                }
                request.url.encodedPath.endsWith("/complete") ->
                    response(
                        request,
                        200,
                        statusJson(
                            status = "sent",
                            receipt = "NF-ABCDEFGHIJKLMNOP",
                        ),
                    )
                else ->
                    response(
                        request,
                        201,
                        reservationJson(reportId),
                    )
            }
        }
        val api = FeedbackApiClient(
            configuration = FeedbackConfiguration("https://api.example/base".toHttpUrl()),
            apiHttp = http,
            uploadHttp = http,
        )
        val idempotency = UUID.fromString("11111111-2222-4333-8444-555555555555")
        val reservation = api.reserve(
            authorization = authorization,
            idempotencyKey = idempotency,
            request = reservationRequest(appVersion = "9.2.1"),
        )
        val archive = File(temporary.newFolder("archive"), "report.zip").apply {
            writeBytes("zip".toByteArray())
        }
        var finalProgress = 0L
        api.upload(
            archive = archive,
            expectedBytes = 3,
            expectedSha256 = "a".repeat(64),
            capability = requireNotNull(reservation.upload),
        ) { uploaded, _ ->
            finalProgress = uploaded
        }
        val completed = api.complete(
            authorization = authorization,
            reportId = reservation.reportId,
            reportToken = reservation.reportToken,
        )

        val reserve = requests[0]
        assertEquals(
            "/base/v1/feedback/reports/reservations",
            reserve.url.encodedPath,
        )
        assertEquals("app-check-token", reserve.header("X-Firebase-AppCheck"))
        assertEquals("Bearer identity-token", reserve.header("Authorization"))
        assertEquals(idempotency.toString(), reserve.header("Idempotency-Key"))
        val reserveBody = JSONObject(reserve.bodyText())
        assertEquals(1, reserveBody.getInt("schema_version"))
        assertEquals("android", reserveBody.getString("platform"))
        assertEquals("9.2.1", reserveBody.getString("app_version"))
        assertEquals(3L, reserveBody.getLong("archive_bytes"))
        assertEquals("a".repeat(64), reserveBody.getString("archive_sha256"))
        assertTrue(reserveBody.getBoolean("includes_user_note"))
        assertFalse(reserveBody.getBoolean("includes_screenshot"))

        val upload = requests[1]
        assertEquals("storage.googleapis.com", upload.url.host)
        assertEquals("3", upload.header("content-length"))
        assertEquals("0", upload.header("x-goog-if-generation-match"))
        assertEquals("application/zip", upload.header("content-type"))
        assertNull(upload.header("Authorization"))
        assertNull(upload.header("X-Firebase-AppCheck"))
        assertNull(upload.header("X-NOOP-Feedback-Token"))
        assertEquals(3L, finalProgress)

        val complete = requests[2]
        assertEquals(
            "/base/v1/feedback/reports/$reportId/complete",
            complete.url.encodedPath,
        )
        assertEquals("app-check-token", complete.header("X-Firebase-AppCheck"))
        assertEquals("Bearer identity-token", complete.header("Authorization"))
        assertEquals(
            reportToken,
            complete.header("X-NOOP-Feedback-Token"),
        )
        assertEquals("{}", complete.bodyText())
        assertEquals("sent", completed.status)
        assertEquals("NF-ABCDEFGHIJKLMNOP", completed.receipt)
    }

    @Test
    fun reportTokenGrammarMatchesLegacyAndVersionedServerCapabilities() = runTest {
        for (valid in listOf(
            "a".repeat(43),
            "v2." + "_".repeat(43),
        )) {
            val reservation = apiReturning(
                reservationJson(reportToken = valid),
                responseCode = 201,
            ).reserve(
                authorization = authorization,
                idempotencyKey = UUID.randomUUID(),
                request = reservationRequest(),
            )
            assertEquals(valid, reservation.reportToken)
        }
        for (invalid in listOf(
            "a".repeat(42),
            "a".repeat(44),
            "v." + "a".repeat(43),
            "v12345." + "a".repeat(43),
            "v2." + "a".repeat(42),
        )) {
            assertInvalidResponse {
                apiReturning(
                    reservationJson(reportToken = invalid),
                    responseCode = 201,
                ).reserve(
                    authorization = authorization,
                    idempotencyKey = UUID.randomUUID(),
                    request = reservationRequest(),
                )
            }
        }
    }

    @Test
    fun getRecoversSentAndDelete204ConfirmsDeleted() = runTest {
        val requests = mutableListOf<Request>()
        val reportId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        val http = client { request ->
            requests += request
            if (request.method == "GET") {
                response(
                    request,
                    200,
                    statusJson("sent", "NF-234567ABCDEFGHIJ"),
                )
            } else {
                response(request, 204, "")
            }
        }
        val api = FeedbackApiClient(
            FeedbackConfiguration("https://api.example".toHttpUrl()),
            apiHttp = http,
            uploadHttp = http,
        )

        val status = api.status(
            authorization,
            reportId,
            reportToken,
        )
        val deletion = api.cancel(
            authorization,
            reportId,
            reportToken,
        )

        assertEquals("sent", status.status)
        assertEquals("deleted", deletion.status)
        assertNull(deletion.receipt)
        assertNull(deletion.retainedUntil)
        assertEquals(listOf("GET", "DELETE"), requests.map { it.method })
        requests.forEach { request ->
            assertEquals("app-check-token", request.header("X-Firebase-AppCheck"))
            assertEquals("Bearer identity-token", request.header("Authorization"))
            assertEquals(
                reportToken,
                request.header("X-NOOP-Feedback-Token"),
            )
        }
    }

    @Test
    fun statusNotFoundIsAuthoritativeDeletion() = runTest {
        listOf(404, 410).forEach { statusCode ->
            val status = apiReturning("", responseCode = statusCode).status(
                authorization,
                "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                reportToken,
            )

            assertEquals("deleted", status.status)
            assertNull(status.receipt)
            assertNull(status.retainedUntil)
        }
    }

    @Test
    fun statusParserAcceptsOnlyServerEnumAndExactReceipt() = runTest {
        listOf("reserved", "rejected", "deleting", "deleted").forEach { state ->
            assertEquals(state, apiReturning(statusJson(state)).status())
        }
        assertEquals(
            "sent",
            apiReturning(statusJson("sent", "NF-ABCDEFGHIJKLMNOP")).status(),
        )

        listOf("canceled", "failed").forEach { invalid ->
            assertInvalidResponse {
                apiReturning(statusJson(invalid)).status()
            }
        }
        assertInvalidResponse {
            apiReturning(statusJson("sent", "NF-TOO-SHORT")).status()
        }
        assertInvalidResponse {
            apiReturning(statusJson("reserved", "NF-ABCDEFGHIJKLMNOP")).status()
        }
        assertInvalidResponse {
            apiReturning("""{"status":"reserved"}""").status()
        }
    }

    @Test
    fun reservationRejectsArbitraryHttpsUploadOriginAndUnreviewedHeaders() = runTest {
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadUrl = "https://upload.example/object",
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadUrl =
                        "https://storage.googleapis.com/noop-feedback/report.zip" +
                            "?X-Goog-Signature=unsigned-fields-missing",
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadUrl = "https://storage.googleapis.com:444/object",
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadHeaders = """
                        {
                          "content-length":"3",
                          "content-type":"application/zip",
                          "Authorization":"Bearer should-not-forward"
                        }
                    """.trimIndent(),
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadHeaders = """
                        {
                          "content-length":3,
                          "content-type":"application/zip"
                        }
                    """.trimIndent(),
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadHeaders = signedHeaders(
                        metaSha256 = "b".repeat(64),
                    ),
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
        assertInvalidResponse {
            apiReturning(
                reservationJson(
                    uploadUrl = signedUploadUrl(
                        signedHeaders =
                            "content-length;content-type;host;" +
                                "x-goog-content-sha256;" +
                                "x-goog-if-generation-match",
                    ),
                ),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
    }

    @Test
    fun defaultSignedUploadClientCannotInheritApiCredentialsOrState() {
        val hostileCookies = object : CookieJar {
            override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) = Unit

            override fun loadForRequest(url: HttpUrl): List<Cookie> = listOf(
                Cookie.Builder()
                    .name("session")
                    .value("secret")
                    .hostOnlyDomain(url.host)
                    .build(),
            )
        }
        val hostileAuthenticator = Authenticator { _, response ->
            response.request.newBuilder()
                .header("Authorization", "Bearer authenticator-secret")
                .build()
        }
        val hostileApi = OkHttpClient.Builder()
            .addInterceptor { chain ->
                chain.proceed(
                    chain.request().newBuilder()
                        .header("Authorization", "Bearer interceptor-secret")
                        .header("X-Firebase-AppCheck", "app-check-secret")
                        .header("Cookie", "session=secret")
                        .build(),
                )
            }
            .cookieJar(hostileCookies)
            .authenticator(hostileAuthenticator)
            .proxyAuthenticator(hostileAuthenticator)
            .build()

        val api = FeedbackApiClient(
            configuration = FeedbackConfiguration("https://api.example".toHttpUrl()),
            apiHttp = hostileApi,
        )
        val upload = api.signedUploadHttp

        assertTrue(upload.interceptors.isEmpty())
        assertTrue(upload.networkInterceptors.isEmpty())
        assertSame(CookieJar.NO_COOKIES, upload.cookieJar)
        assertSame(Authenticator.NONE, upload.authenticator)
        assertSame(Authenticator.NONE, upload.proxyAuthenticator)
        assertFalse(upload.followRedirects)
        assertFalse(upload.followSslRedirects)
    }

    @Test
    fun defaultApiClientRejectsCrossOriginRedirectWithoutASecondRequest() {
        val secondOrigin = OneShotHttpServer(responseCode = 200)
        val firstOrigin = OneShotHttpServer(
            responseCode = 307,
            responseHeaders = mapOf("Location" to secondOrigin.url("/capture")),
        )
        secondOrigin.start()
        firstOrigin.start()

        try {
            val http = FeedbackApiClient.defaultHttp(timeoutSeconds = 2)
            assertFalse(http.followRedirects)
            assertFalse(http.followSslRedirects)
            val request = Request.Builder()
                .url(firstOrigin.url("/feedback"))
                .header("Authorization", "Bearer identity-secret")
                .header("X-Firebase-AppCheck", "app-check-secret")
                .header("X-NOOP-Feedback-Token", "report-capability-secret")
                .build()

            http.newCall(request).execute().use { response ->
                assertEquals(307, response.code)
            }

            assertEquals(1, firstOrigin.requestCount.get())
            assertEquals(0, secondOrigin.requestCount.get())
            assertEquals(
                listOf("Bearer identity-secret"),
                firstOrigin.receivedHeaders.get()["authorization"],
            )
            assertEquals(
                listOf("app-check-secret"),
                firstOrigin.receivedHeaders.get()["x-firebase-appcheck"],
            )
            assertEquals(
                listOf("report-capability-secret"),
                firstOrigin.receivedHeaders.get()["x-noop-feedback-token"],
            )
        } finally {
            firstOrigin.close()
            secondOrigin.close()
        }
    }

    @Test
    fun signedUploadRequestContainsOnlyCapabilityHeadersWithHostileApiClient() = runTest {
        val uploadRequests = mutableListOf<Request>()
        val hostileApi = OkHttpClient.Builder()
            .addInterceptor { chain ->
                val request = chain.request().newBuilder()
                    .header("Authorization", "Bearer interceptor-secret")
                    .header("X-Firebase-AppCheck", "app-check-secret")
                    .header("Cookie", "session=secret")
                    .build()
                response(request, 201, reservationJson())
            }
            .build()
        val isolatedUpload = client { request ->
            uploadRequests += request
            request.bodyText()
            response(request, 200, "")
        }
        val api = FeedbackApiClient(
            configuration = FeedbackConfiguration("https://api.example".toHttpUrl()),
            apiHttp = hostileApi,
            uploadHttp = isolatedUpload,
        )
        val reservation = api.reserve(
            authorization,
            UUID.randomUUID(),
            reservationRequest(),
        )
        val archive = File(temporary.newFolder("isolated-upload"), "report.zip").apply {
            writeBytes("zip".toByteArray())
        }

        api.upload(
            archive = archive,
            expectedBytes = 3,
            expectedSha256 = "a".repeat(64),
            capability = requireNotNull(reservation.upload),
        ) { _, _ -> }

        val request = uploadRequests.single()
        assertNull(request.header("Authorization"))
        assertNull(request.header("X-Firebase-AppCheck"))
        assertNull(request.header("X-NOOP-Feedback-Token"))
        assertNull(request.header("Cookie"))
        assertEquals(
            setOf(
                "content-length",
                "content-type",
                "x-goog-content-sha256",
                "x-goog-if-generation-match",
                "x-goog-meta-noop-sha256",
            ),
            request.headers.names().map(String::lowercase).toSet(),
        )
    }

    @Test
    fun reservationAcceptsServerReplayWithoutAnotherUploadCapability() = runTest {
        val response = reservationJson(
            status = "sent",
            includeUpload = false,
        )
        val reservation = apiReturning(response, responseCode = 201).reserve(
            authorization,
            UUID.randomUUID(),
            reservationRequest(),
        )

        assertEquals("sent", reservation.status)
        assertNull(reservation.upload)

        assertInvalidResponse {
            apiReturning(
                reservationJson(status = "sent", includeUpload = true),
                responseCode = 201,
            ).reserve(
                authorization,
                UUID.randomUUID(),
                reservationRequest(),
            )
        }
    }

    @Test
    fun reportCapabilityCredentialsMatchServerGrammar() = runTest {
        val api = apiReturning(statusJson("reserved"))
        api.status(
            authorization,
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken,
        )
        listOf(
            "report_12345678" to reportToken,
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" to "short-token",
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" to
                ("a".repeat(39) + "="),
        ).forEach { (reportId, token) ->
            assertInvalidResponse {
                api.status(authorization, reportId, token)
            }
        }
    }

    @Test
    fun reservationAppVersionMatchesServerMaximumAndGrammar() = runTest {
        val requestCount = intArrayOf(0)
        val api = FeedbackApiClient(
            FeedbackConfiguration("https://api.example".toHttpUrl()),
            apiHttp = client { request ->
                requestCount[0] += 1
                response(request, 201, reservationJson())
            },
        )
        val valid = "v" + "1".repeat(31)
        api.reserve(
            authorization,
            UUID.randomUUID(),
            reservationRequest(appVersion = valid),
        )
        assertEquals(1, requestCount[0])

        listOf("v" + "1".repeat(32), ".9.2.1", "9 2 1").forEach { invalid ->
            assertInvalidResponse {
                api.reserve(
                    authorization,
                    UUID.randomUUID(),
                    reservationRequest(appVersion = invalid),
                )
            }
        }
        assertEquals(1, requestCount[0])
    }

    @Test
    fun apiRequestsRequireBothBoundedAuthorizationTokens() = runTest {
        val api = apiReturning(statusJson("reserved"))
        listOf(
            FeedbackAuthorization("", "identity-token", "feedback-owner"),
            FeedbackAuthorization(
                "a".repeat(16 * 1024 + 1),
                "identity-token",
                "feedback-owner",
            ),
        ).forEach { invalid ->
            try {
                api.status(
                    invalid,
                    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    reportToken,
                )
                fail("Expected App Check rejection")
            } catch (_: FeedbackProtocolException.Attestation) {
                // Expected.
            }
        }
        listOf(
            FeedbackAuthorization("app-check-token", "", "feedback-owner"),
            FeedbackAuthorization(
                "app-check-token",
                "i".repeat(16 * 1024 + 1),
                "feedback-owner",
            ),
        ).forEach { invalid ->
            try {
                api.status(
                    invalid,
                    "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    reportToken,
                )
                fail("Expected identity rejection")
            } catch (_: FeedbackProtocolException.Identity) {
                // Expected.
            }
        }
    }

    @Test
    fun emptyHttpErrorRemainsRetryClassifiableHttpFailure() = runTest {
        val api = apiReturning("", responseCode = 503)
        try {
            api.status(
                authorization,
                "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                reportToken,
            )
            fail("Expected HTTP failure")
        } catch (error: FeedbackProtocolException.Http) {
            assertEquals(503, error.statusCode)
        }
    }

    private suspend fun FeedbackApiClient.status(): String =
        status(
            authorization,
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            reportToken,
        ).status

    private val authorization = FeedbackAuthorization(
        appCheckToken = "app-check-token",
        identityToken = "identity-token",
        identitySubject = "feedback-owner",
    )

    private fun apiReturning(
        body: String,
        responseCode: Int = 200,
    ): FeedbackApiClient {
        val http = client { request -> response(request, responseCode, body) }
        return FeedbackApiClient(
            FeedbackConfiguration("https://api.example".toHttpUrl()),
            apiHttp = http,
            uploadHttp = http,
        )
    }

    private fun reservationRequest(appVersion: String = "9.2.1") =
        FeedbackReservationRequest(
            appVersion = appVersion,
            archiveBytes = 3,
            archiveSha256 = "a".repeat(64),
            includesUserNote = true,
            includesScreenshot = false,
        )

    private fun reservationJson(
        reportId: String = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        reportToken: String = Companion.reportToken,
        status: String = "reserved",
        includeUpload: Boolean = true,
        uploadUrl: String = signedUploadUrl(),
        uploadHeaders: String = signedHeaders(),
    ): String =
        """
        {
          "report_id":"$reportId",
          "report_token":"$reportToken",
          "status":"$status",
          "upload":${if (includeUpload) """{
            "method":"PUT",
            "url":"$uploadUrl",
            "headers":$uploadHeaders,
            "expires_at":"2026-09-13T12:00:00Z"
          }""" else "null"},
          "retained_until":"2026-10-12T12:00:00Z"
        }
        """.trimIndent()

    private fun signedUploadUrl(
        signedHeaders: String =
            "content-length;content-type;host;x-goog-content-sha256;" +
                "x-goog-if-generation-match;x-goog-meta-noop-sha256",
    ): String =
        "https://storage.googleapis.com/noop-feedback/report.zip" +
            "?X-Goog-Algorithm=GOOG4-RSA-SHA256" +
            "&X-Goog-Credential=credential" +
            "&X-Goog-Date=20260912T180000Z" +
            "&X-Goog-Expires=300" +
            "&X-Goog-SignedHeaders=${signedHeaders.replace(";", "%3B")}" +
            "&X-Goog-Signature=abc123"

    private fun signedHeaders(
        contentSha256: String = "a".repeat(64),
        metaSha256: String = contentSha256,
    ): String =
        """
        {
          "content-length":"3",
          "content-type":"application/zip",
          "x-goog-content-sha256":"$contentSha256",
          "x-goog-if-generation-match":"0",
          "x-goog-meta-noop-sha256":"$metaSha256"
        }
        """.trimIndent()

    private fun statusJson(status: String, receipt: String? = null): String =
        JSONObject()
            .put("status", status)
            .put("receipt", receipt ?: JSONObject.NULL)
            .put("retained_until", "2026-10-12T12:00:00Z")
            .toString()

    private fun client(responder: (Request) -> Response): OkHttpClient =
        OkHttpClient.Builder()
            .addInterceptor(Interceptor { chain -> responder(chain.request()) })
            .build()

    private fun response(request: Request, code: Int, body: String): Response =
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message("synthetic")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()

    private fun Request.bodyText(): String =
        body?.let { requestBody ->
            Buffer().also(requestBody::writeTo).readUtf8()
        }.orEmpty()

    private class OneShotHttpServer(
        private val responseCode: Int,
        private val responseHeaders: Map<String, String> = emptyMap(),
    ) : AutoCloseable {
        private val server = ServerSocket(
            0,
            1,
            InetAddress.getByName("127.0.0.1"),
        )
        private var worker: Thread? = null
        val requestCount = AtomicInteger()
        val receivedHeaders = AtomicReference<Map<String, List<String>>>(emptyMap())

        fun url(path: String): String = "http://127.0.0.1:${server.localPort}$path"

        fun start() {
            worker = thread(
                name = "feedback-redirect-test-server",
                isDaemon = true,
            ) {
                runCatching {
                    server.accept().use { socket ->
                        val reader = socket.getInputStream()
                            .bufferedReader(Charsets.US_ASCII)
                        reader.readLine()
                        val headers = linkedMapOf<String, MutableList<String>>()
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                            val separator = line.indexOf(':')
                            if (separator <= 0) continue
                            val name = line.substring(0, separator)
                                .trim()
                                .lowercase(Locale.US)
                            val value = line.substring(separator + 1).trim()
                            headers.getOrPut(name, ::mutableListOf).add(value)
                        }
                        requestCount.incrementAndGet()
                        receivedHeaders.set(headers)
                        val reason = if (responseCode == 307) {
                            "Temporary Redirect"
                        } else {
                            "OK"
                        }
                        val response = buildString {
                            append("HTTP/1.1 $responseCode $reason\r\n")
                            responseHeaders.forEach { (name, value) ->
                                append("$name: $value\r\n")
                            }
                            append("Content-Length: 0\r\n")
                            append("Connection: close\r\n")
                            append("\r\n")
                        }
                        socket.getOutputStream().use { output ->
                            output.write(response.toByteArray(Charsets.US_ASCII))
                            output.flush()
                        }
                    }
                }
            }
        }

        override fun close() {
            runCatching { server.close() }
            worker?.join(2_000L)
        }
    }

    private suspend fun assertInvalidResponse(block: suspend () -> Unit) {
        try {
            block()
            fail("Expected invalid feedback protocol response")
        } catch (_: FeedbackProtocolException.InvalidResponse) {
            // Expected.
        }
    }

    private companion object {
        val reportToken = "v2." + "a".repeat(43)
    }
}
