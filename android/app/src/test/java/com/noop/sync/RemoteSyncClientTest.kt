package com.noop.sync

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
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class RemoteSyncClientTest {
    @Test
    fun authenticatedStatusUsesBearerAndV1Status() = runTest {
        var captured: Request? = null
        val http = client { request ->
            captured = request
            response(request, 200, """{"status":"ok"}""")
        }
        val remote = RemoteSyncClient(
            RemoteSyncConfiguration("https://noop.example", "top-secret"),
            http,
        )

        assertEquals("ok", remote.authenticatedStatus().status)
        assertEquals("https://noop.example/v1/status", captured!!.url.toString())
        assertEquals("Bearer top-secret", captured!!.header("Authorization"))
        assertEquals("GET", captured!!.method)
    }

    @Test
    fun uploadIsSnakeCaseAndCarriesIdempotencyKey() = runTest {
        var captured: Request? = null
        val batchId = "40b67e76-1298-4d66-a2a7-dca6905c5158"
        val http = client { request ->
            captured = request
            response(
                request,
                200,
                """{"batch_id":"$batchId","status":"accepted","duplicate":false,"counts":{"metric_samples":1}}""",
            )
        }
        val remote = RemoteSyncClient(
            RemoteSyncConfiguration("https://noop.example/base", "key-123"),
            http,
        )
        val envelope = RemoteEnvelope(
            batchId = batchId,
            sentAt = "2026-07-24T12:00:00Z",
            draft = RemoteEnvelopeDraft(
                source = RemoteSourceDraft(
                    "android:install:whoop-strap",
                    metadata = mapOf("namespace" to "strap_measured"),
                ),
                streams = RemoteStreams(
                    hr = listOf(RemoteSample(1_700_000_000, 61.0)),
                ),
            ),
        )

        val ack = remote.upload(envelope)
        val body = JSONObject(captured!!.body!!.let { body ->
            okio.Buffer().also { body.writeTo(it) }.readUtf8()
        })
        assertEquals(batchId, ack.batchId)
        assertEquals(batchId, captured!!.header("Idempotency-Key"))
        assertEquals("Bearer key-123", captured!!.header("Authorization"))
        assertEquals("https://noop.example/base/v1/sync", captured!!.url.toString())
        assertEquals(1, body.getInt("schema_version"))
        assertEquals(batchId, body.getString("batch_id"))
        assertEquals(
            1_700_000_000L,
            body.getJSONObject("streams").getJSONArray("hr")
                .getJSONObject(0).getLong("recorded_at"),
        )
        assertFalse(body.has("schemaVersion"))
        assertFalse(body.getJSONObject("source").has("sentAt"))
        assertEquals("2026-07-24T12:00:00Z", body.getJSONObject("source").getString("sent_at"))
    }

    @Test
    fun biometricPostNeverFollowsCrossOriginRedirect() {
        val targetHits = AtomicInteger()
        val target = OneShotHttpServer {
                targetHits.incrementAndGet()
                httpResponse(200, """{"batch_id":"stolen","status":"accepted"}""")
        }
        val source = OneShotHttpServer {
            httpResponse(
                307,
                "",
                mapOf("Location" to "http://127.0.0.1:${target.port}/stolen"),
            )
        }

        try {
            val batchId = "40b67e76-1298-4d66-a2a7-dca6905c5158"
            val remote = RemoteSyncClient(
                RemoteSyncConfiguration(
                    "http://127.0.0.1:${source.port}",
                    "never-forward-me",
                ),
            )
            val error = assertThrows(RemoteSyncException.Server::class.java) {
                kotlinx.coroutines.runBlocking {
                    remote.upload(
                        RemoteEnvelope(
                            batchId,
                            "2026-07-24T12:00:00Z",
                            RemoteEnvelopeDraft(
                                source = RemoteSourceDraft("whoop-strap"),
                                streams = RemoteStreams(
                                    hr = listOf(RemoteSample(1_700_000_000, 61.0)),
                                ),
                            ),
                        ),
                    )
                }
            }

            assertEquals(307, error.statusCode)
            assertEquals(0, targetHits.get())
        } finally {
            source.close()
            target.close()
        }
    }

    @Test
    fun defaultClientDisablesRedirectsAndHttpsDowngrades() {
        val http = RemoteSyncClient.defaultHttp(60)
        assertFalse(http.followRedirects)
        assertFalse(http.followSslRedirects)
    }

    @Test
    fun serverErrorIsStableAndNeverPersistsResponseContent() {
        val http = client { request ->
            response(request, 401, """{"detail":"bad token top-secret biometric-value"}""")
        }
        val remote = RemoteSyncClient(
            RemoteSyncConfiguration("https://noop.example", "top-secret"),
            http,
        )

        val error = assertThrows(RemoteSyncException.Server::class.java) {
            kotlinx.coroutines.runBlocking { remote.authenticatedStatus() }
        }
        assertEquals(
            "The server did not accept the sync credentials (HTTP 401).",
            error.message,
        )
        assertFalse(error.message.orEmpty().contains("top-secret"))
        assertFalse(error.message.orEmpty().contains("biometric-value"))
    }

    @Test
    fun serverErrorClassesHaveActionableStableMessages() {
        assertEquals(
            "The sync payload is too large for the server (HTTP 413).",
            RemoteSyncClient.serverErrorMessage(413),
        )
        assertEquals(
            "The server rejected invalid sync data (HTTP 422).",
            RemoteSyncClient.serverErrorMessage(422),
        )
        assertEquals(
            "The self-hosted server is unavailable (HTTP 503).",
            RemoteSyncClient.serverErrorMessage(503),
        )
    }

    private fun client(block: (Request) -> Response): OkHttpClient =
        OkHttpClient.Builder().addInterceptor(Interceptor { chain -> block(chain.request()) }).build()

    private fun response(request: Request, code: Int, body: String): Response = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(code)
        .message(if (code in 200..299) "OK" else "Error")
        .body(body.toResponseBody("application/json".toMediaType()))
        .build()

    private class OneShotHttpServer(
        private val response: (String) -> String,
    ) : AutoCloseable {
        private val socket = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val port: Int get() = socket.localPort
        private val worker = thread(start = true, isDaemon = true, name = "remote-sync-test-http") {
            try {
                socket.accept().use { connection ->
                    connection.soTimeout = 5_000
                    val request = readRequest(connection.getInputStream())
                    connection.getOutputStream().use { output ->
                        output.write(response(request).toByteArray(StandardCharsets.UTF_8))
                        output.flush()
                    }
                }
            } catch (_: Throwable) {
                // Closing a never-hit target server interrupts accept(), which is expected.
            }
        }

        override fun close() {
            socket.close()
            worker.join(1_000)
        }

        private fun readRequest(input: java.io.InputStream): String {
            val headers = ByteArrayOutputStream()
            var tail = 0
            while (headers.size() < 64 * 1_024) {
                val next = input.read()
                if (next < 0) break
                headers.write(next)
                tail = ((tail shl 8) or next) and 0xffffffff.toInt()
                if (tail == 0x0d0a0d0a) break
            }
            val headerText = headers.toString(StandardCharsets.ISO_8859_1.name())
            val contentLength = Regex(
                """(?im)^Content-Length:\s*(\d+)\s*$""",
            ).find(headerText)?.groupValues?.get(1)?.toIntOrNull() ?: 0
            val body = ByteArray(contentLength)
            var offset = 0
            while (offset < body.size) {
                val count = input.read(body, offset, body.size - offset)
                if (count < 0) break
                offset += count
            }
            return headerText + String(body, 0, offset, StandardCharsets.UTF_8)
        }
    }

    private companion object {
        fun httpResponse(
            code: Int,
            body: String,
            headers: Map<String, String> = emptyMap(),
        ): String {
            val reason = if (code in 200..299) "OK" else "Redirect"
            val bodyBytes = body.toByteArray(StandardCharsets.UTF_8)
            return buildString {
                append("HTTP/1.1 $code $reason\r\n")
                headers.forEach { (name, value) -> append("$name: $value\r\n") }
                append("Content-Type: application/json\r\n")
                append("Content-Length: ${bodyBytes.size}\r\n")
                append("Connection: close\r\n\r\n")
                append(body)
            }
        }
    }
}
