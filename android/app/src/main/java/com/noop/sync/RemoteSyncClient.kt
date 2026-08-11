package com.noop.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

sealed class RemoteSyncException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class Network(message: String, cause: Throwable? = null) : RemoteSyncException(message, cause)
    class Server(val statusCode: Int, message: String) : RemoteSyncException(message)
    class InvalidResponse(message: String) : RemoteSyncException(message)
    class BatchMismatch : RemoteSyncException("The server acknowledged a different sync batch.")
}

interface RemoteSyncUploading {
    suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck
}

interface RemoteStatusChecking {
    suspend fun authenticatedStatus(): RemoteStatus
}

/**
 * Native OkHttp client for the self-hosted v1 API. It never logs requests, payloads or credentials.
 * Both status and sync calls use the same Bearer token; a successful status probe therefore proves
 * that the pasted key is accepted, not merely that an unauthenticated health endpoint is online.
 */
class RemoteSyncClient(
    private val configuration: RemoteSyncConfiguration,
    private val http: OkHttpClient = defaultHttp(configuration.timeoutSeconds),
) : RemoteSyncUploading, RemoteStatusChecking {

    override suspend fun authenticatedStatus(): RemoteStatus = withContext(Dispatchers.IO) {
        val request = baseRequest("v1/status").get().build()
        execute(request) { body ->
            val status = runCatching { JSONObject(body).optString("status") }.getOrDefault("")
            if (status.isBlank()) throw RemoteSyncException.InvalidResponse(
                "The server returned an invalid status response.",
            )
            RemoteStatus(status)
        }
    }

    override suspend fun upload(envelope: RemoteEnvelope): RemoteSyncAck = withContext(Dispatchers.IO) {
        val json = RemoteSyncJson.encode(envelope)
        val request = baseRequest("v1/sync")
            .header("Content-Type", JSON.toString())
            .header("Idempotency-Key", envelope.batchId)
            .post(json.toRequestBody(JSON))
            .build()
        val ack = execute(request) { body -> parseAck(body) }
        if (!ack.batchId.equals(envelope.batchId, ignoreCase = true)) {
            throw RemoteSyncException.BatchMismatch()
        }
        ack
    }

    private fun baseRequest(path: String): Request.Builder = Request.Builder()
        .url("${configuration.baseUrl.trimEnd('/')}/$path")
        .header("Accept", "application/json")
        .header("Authorization", "Bearer ${configuration.apiKey}")
        .header("User-Agent", "Noop-Android/remote-sync-v1")

    private fun <T> execute(request: Request, decode: (String) -> T): T {
        val response = try {
            http.newCall(request).execute()
        } catch (error: IOException) {
            throw RemoteSyncException.Network("Could not reach the self-hosted server.", error)
        }
        response.use {
            if (!it.isSuccessful) {
                throw RemoteSyncException.Server(
                    it.code,
                    serverErrorMessage(it.code),
                )
            }
            val body = runCatching { it.body?.string().orEmpty() }.getOrDefault("")
            return try {
                decode(body)
            } catch (error: RemoteSyncException) {
                throw error
            } catch (error: Throwable) {
                throw RemoteSyncException.InvalidResponse(
                    "The server returned an unreadable response.",
                )
            }
        }
    }

    private fun parseAck(body: String): RemoteSyncAck {
        val json = JSONObject(body)
        val batchId = json.optString("batch_id")
        val status = json.optString("status")
        if (batchId.isBlank() || status.isBlank()) {
            throw RemoteSyncException.InvalidResponse("The server returned an invalid sync response.")
        }
        val countsJson = json.optJSONObject("counts") ?: JSONObject()
        val counts = buildMap {
            val keys = countsJson.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = countsJson.optInt(key, Int.MIN_VALUE)
                if (value != Int.MIN_VALUE) put(key, value)
            }
        }
        return RemoteSyncAck(
            batchId = batchId,
            status = status,
            duplicate = json.optBoolean("duplicate", false),
            counts = counts,
        )
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()

        internal fun serverErrorMessage(statusCode: Int): String = when (statusCode) {
            400 -> "The server rejected the sync request (HTTP 400)."
            401, 403 -> "The server did not accept the sync credentials (HTTP $statusCode)."
            409 -> "The server reported a sync conflict (HTTP 409)."
            413 -> "The sync payload is too large for the server (HTTP 413)."
            422 -> "The server rejected invalid sync data (HTTP 422)."
            429 -> "The server is rate limiting sync requests (HTTP 429)."
            in 500..599 -> "The self-hosted server is unavailable (HTTP $statusCode)."
            else -> "The self-hosted server request failed (HTTP $statusCode)."
        }

        /**
         * Biometric request bodies and credentials must never follow a server-controlled Location
         * header. This blocks both cross-origin exfiltration and HTTPS-to-HTTP downgrade redirects.
         */
        internal fun defaultHttp(timeoutSeconds: Long): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(minOf(timeoutSeconds, 20), TimeUnit.SECONDS)
            .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .writeTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(true)
            .build()
    }
}
