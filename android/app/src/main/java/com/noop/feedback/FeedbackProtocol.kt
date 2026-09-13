package com.noop.feedback

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseAuthInvalidUserException
import com.google.firebase.auth.FirebaseUser
import com.noop.BuildConfig
import com.noop.managed.ManagedAppCheckProvider
import com.noop.managed.awaitManaged
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.time.Instant
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSink
import org.json.JSONObject

private const val MAX_FEEDBACK_IDENTITY_SUBJECT_LENGTH = 256

internal data class FeedbackConfiguration(
    val baseUrl: HttpUrl,
    val timeoutSeconds: Long = 60L,
) {
    init {
        val localHosts = setOf("127.0.0.1", "::1", "localhost", "10.0.2.2")
        val validTransport = baseUrl.isHttps || (
            BuildConfig.DEBUG &&
                BuildConfig.MANAGED_ALLOW_LOCAL_HTTP &&
                baseUrl.scheme == "http" &&
                baseUrl.host.lowercase(Locale.US) in localHosts
            )
        require(validTransport)
        require(baseUrl.username.isEmpty() && baseUrl.password.isEmpty())
        require(baseUrl.querySize == 0 && baseUrl.fragment == null)
        require(timeoutSeconds in 1..300)
    }

    companion object {
        fun load(): FeedbackConfiguration? {
            val url = BuildConfig.MANAGED_API_URL.trim().toHttpUrlOrNull() ?: return null
            return runCatching { FeedbackConfiguration(url) }.getOrNull()
        }
    }
}

internal data class FeedbackReservationRequest(
    val appVersion: String,
    val archiveBytes: Long,
    val archiveSha256: String,
    val includesUserNote: Boolean,
    val includesScreenshot: Boolean,
)

internal data class FeedbackUploadCapability(
    val method: String,
    val url: HttpUrl,
    val headers: Headers,
    val expiresAt: String,
)

internal data class FeedbackReservation(
    val reportId: String,
    val reportToken: String,
    val status: String,
    val upload: FeedbackUploadCapability?,
    val retainedUntil: String,
)

internal data class FeedbackRemoteStatus(
    val status: String,
    val receipt: String?,
    val retainedUntil: String?,
)

internal data class FeedbackAuthorization(
    val appCheckToken: String,
    val identityToken: String,
    val identitySubject: String,
)

internal fun feedbackIdentitySubjectSha256(subject: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(subject.toByteArray(Charsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(Locale.US, byte.toInt() and 0xff) }

internal sealed class FeedbackProtocolException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {
    class Configuration : FeedbackProtocolException("Feedback is not configured.")
    class Network(cause: Throwable? = null) :
        FeedbackProtocolException("Feedback could not be reached.", cause)
    class Attestation(cause: Throwable? = null) :
        FeedbackProtocolException("App attestation is unavailable.", cause)
    class Identity(cause: Throwable? = null) :
        FeedbackProtocolException("Feedback identity is unavailable.", cause)
    class Http(val statusCode: Int) :
        FeedbackProtocolException("Feedback request was rejected.")
    class InvalidResponse :
        FeedbackProtocolException("Feedback returned an invalid response.")
}

internal interface FeedbackAuthorizationProvider {
    suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization
}

/**
 * Feedback uses a dedicated named FirebaseApp with an auto-cleaned anonymous identity. This keeps
 * app reports available without a NOOP+ account and prevents feedback auth from changing managed
 * account state.
 */
internal class FirebaseFeedbackAuthorizationProvider(
    context: Context,
    private val allowIdentityReplacement: Boolean = false,
) : FeedbackAuthorizationProvider {
    private val appContext = context.applicationContext

    override suspend fun authorization(forceRefresh: Boolean): FeedbackAuthorization {
        val runtime = runtime()
        val (user, identity) = identity(runtime.auth, forceRefresh)
        val appCheck = try {
            runtime.appCheck.getAppCheckToken(forceRefresh).awaitManaged().token
                .takeIf { it.isNotBlank() && it.length <= MAX_TOKEN_LENGTH }
                ?: throw FeedbackProtocolException.Attestation()
        } catch (error: FeedbackProtocolException) {
            throw error
        } catch (error: Exception) {
            throw FeedbackProtocolException.Attestation(error)
        }
        return FeedbackAuthorization(
            appCheckToken = appCheck,
            identityToken = identity,
            identitySubject = user.uid.takeIf {
                it.isNotBlank() && it.length <= MAX_FEEDBACK_IDENTITY_SUBJECT_LENGTH
            } ?: throw FeedbackProtocolException.Identity(),
        )
    }

    private suspend fun identityUser(auth: FirebaseAuth): FirebaseUser =
        identityLock.withLock {
            auth.currentUser ?: try {
                auth.signInAnonymously().awaitManaged().user
                    ?: throw FeedbackProtocolException.Identity()
            } catch (error: FeedbackProtocolException) {
                throw error
            } catch (error: Exception) {
                throw FeedbackProtocolException.Identity(error)
            }
        }

    private suspend fun identity(
        auth: FirebaseAuth,
        forceRefresh: Boolean,
    ): Pair<FirebaseUser, String> {
        val user = identityUser(auth)
        return try {
            user to identityToken(user, forceRefresh)
        } catch (error: FeedbackProtocolException.Identity) {
            val cause = error.cause
            if (!allowIdentityReplacement || !permitsIdentityReplacement(cause)) {
                throw error
            }
            try {
                auth.signOut()
                val replacement = auth.signInAnonymously().awaitManaged().user
                    ?: throw FeedbackProtocolException.Identity()
                replacement to identityToken(replacement, forceRefresh = true)
            } catch (replacementError: FeedbackProtocolException) {
                throw replacementError
            } catch (replacementError: Exception) {
                throw FeedbackProtocolException.Identity(replacementError)
            }
        }
    }

    private suspend fun identityToken(
        user: FirebaseUser,
        forceRefresh: Boolean,
    ): String = try {
        user.getIdToken(forceRefresh).awaitManaged().token
            ?.takeIf { it.isNotBlank() && it.length <= MAX_TOKEN_LENGTH }
            ?: throw FeedbackProtocolException.Identity()
    } catch (error: FeedbackProtocolException) {
        throw error
    } catch (error: Exception) {
        throw FeedbackProtocolException.Identity(error)
    }

    private fun permitsIdentityReplacement(error: Throwable?): Boolean =
        error is FirebaseAuthInvalidUserException &&
            error.errorCode in STALE_IDENTITY_ERROR_CODES

    private fun runtime(): FeedbackFirebaseRuntime = synchronized(firebaseLock) {
        val projectId = BuildConfig.MANAGED_PROJECT_ID.trim()
        val apiKey = BuildConfig.MANAGED_API_KEY.trim()
        val applicationId = BuildConfig.MANAGED_GOOGLE_APP_ID.trim()
        if (projectId.isEmpty() || apiKey.isEmpty() || applicationId.isEmpty()) {
            throw FeedbackProtocolException.Configuration()
        }
        val existing = runCatching { FirebaseApp.getInstance(FIREBASE_APP_NAME) }.getOrNull()
        val firebase = existing ?: run {
            val builder = FirebaseOptions.Builder()
                .setProjectId(projectId)
                .setApiKey(apiKey)
                .setApplicationId(applicationId)
            BuildConfig.MANAGED_GCM_SENDER_ID.trim()
                .takeIf(String::isNotEmpty)
                ?.let(builder::setGcmSenderId)
            FirebaseApp.initializeApp(appContext, builder.build(), FIREBASE_APP_NAME)
                ?: throw FeedbackProtocolException.Configuration()
        }
        if (firebase.options.projectId != projectId ||
            firebase.options.applicationId != applicationId
        ) {
            throw FeedbackProtocolException.Configuration()
        }
        ManagedAppCheckProvider.install(firebase)
        FeedbackFirebaseRuntime(
            auth = FirebaseAuth.getInstance(firebase),
            appCheck = FirebaseAppCheck.getInstance(firebase),
        )
    }

    private data class FeedbackFirebaseRuntime(
        val auth: FirebaseAuth,
        val appCheck: FirebaseAppCheck,
    )

    private companion object {
        const val FIREBASE_APP_NAME = "noop-feedback"
        const val MAX_TOKEN_LENGTH = 16 * 1024
        val STALE_IDENTITY_ERROR_CODES = setOf(
            "ERROR_USER_NOT_FOUND",
            "ERROR_INVALID_USER_TOKEN",
            "ERROR_USER_TOKEN_EXPIRED",
        )
        val firebaseLock = Any()
        val identityLock = Mutex()
    }
}

internal interface FeedbackTransport {
    suspend fun reserve(
        authorization: FeedbackAuthorization,
        idempotencyKey: UUID,
        request: FeedbackReservationRequest,
    ): FeedbackReservation

    suspend fun upload(
        archive: File,
        expectedBytes: Long,
        expectedSha256: String,
        capability: FeedbackUploadCapability,
        progress: (uploadedBytes: Long, totalBytes: Long) -> Unit,
    )

    suspend fun complete(
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus

    suspend fun status(
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus

    suspend fun cancel(
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus
}

internal class FeedbackApiClient(
    private val configuration: FeedbackConfiguration,
    private val apiHttp: OkHttpClient = defaultHttp(configuration.timeoutSeconds),
    uploadHttp: OkHttpClient? = null,
) : FeedbackTransport {
    internal val signedUploadHttp =
        uploadHttp ?: defaultSignedUploadHttp(configuration.timeoutSeconds)

    override suspend fun reserve(
        authorization: FeedbackAuthorization,
        idempotencyKey: UUID,
        request: FeedbackReservationRequest,
    ): FeedbackReservation {
        if (!request.archiveSha256.matches(SHA256) ||
            request.archiveBytes !in 1..FeedbackArchive.MAX_ARCHIVE_BYTES ||
            !request.appVersion.matches(APP_VERSION)
        ) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        val body = JSONObject()
            .put("schema_version", 1)
            .put("platform", "android")
            .put("app_version", request.appVersion)
            .put("archive_bytes", request.archiveBytes)
            .put("archive_sha256", request.archiveSha256)
            .put("includes_user_note", request.includesUserNote)
            .put("includes_screenshot", request.includesScreenshot)
        val httpRequest = apiRequest(
            method = "POST",
            authorization = authorization,
            path = listOf("v1", "feedback", "reports", "reservations"),
            body = body.toString().toRequestBody(JSON),
        ).newBuilder()
            .header("Idempotency-Key", idempotencyKey.toString().lowercase(Locale.US))
            .build()
        return parseReservation(
            json = executeJson(httpRequest),
            expectedBytes = request.archiveBytes,
            expectedSha256 = request.archiveSha256,
        )
    }

    override suspend fun upload(
        archive: File,
        expectedBytes: Long,
        expectedSha256: String,
        capability: FeedbackUploadCapability,
        progress: (uploadedBytes: Long, totalBytes: Long) -> Unit,
    ) {
        if (capability.method != "PUT" ||
            !validSignedUploadCapability(
                url = capability.url,
                headers = capability.headers,
                expectedBytes = expectedBytes,
                expectedSha256 = expectedSha256,
            ) ||
            !archive.isFile ||
            archive.length() != expectedBytes
        ) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        val body = ProgressFileRequestBody(archive, expectedBytes, progress)
        val builder = Request.Builder()
            .url(capability.url)
            .method("PUT", body)
        capability.headers.forEach { (name, value) ->
            builder.header(name, value)
        }
        execute(builder.build(), signedUploadHttp).use { response ->
            if (!response.isSuccessful) {
                throw FeedbackProtocolException.Http(response.code)
            }
        }
    }

    override suspend fun complete(
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus {
        val response = executeJson(
            reportRequest(
                method = "POST",
                authorization = authorization,
                reportId = reportId,
                reportToken = reportToken,
                body = "{}".toRequestBody(JSON),
                action = "complete",
            ),
        )
        val status = parseStatus(response)
        if (status.status != "sent" || status.receipt == null) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        return status
    }

    override suspend fun status(
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus {
        val request = reportRequest(
            method = "GET",
            authorization = authorization,
            reportId = reportId,
            reportToken = reportToken,
            body = null,
        )
        execute(request).use { response ->
            if (response.code in setOf(404, 410)) {
                return FeedbackRemoteStatus("deleted", receipt = null, retainedUntil = null)
            }
            if (!response.isSuccessful) {
                throw FeedbackProtocolException.Http(response.code)
            }
            return parseStatus(
                runCatching { JSONObject(response.readBoundedBody()) }
                    .getOrElse { throw FeedbackProtocolException.InvalidResponse() },
            )
        }
    }

    override suspend fun cancel(
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
    ): FeedbackRemoteStatus {
        val request = reportRequest(
            method = "DELETE",
            authorization = authorization,
            reportId = reportId,
            reportToken = reportToken,
            body = null,
        )
        execute(request).use { response ->
            if (response.code in setOf(404, 410)) {
                return FeedbackRemoteStatus("deleted", receipt = null, retainedUntil = null)
            }
            if (!response.isSuccessful) {
                throw FeedbackProtocolException.Http(response.code)
            }
            if (response.code == 204) {
                return FeedbackRemoteStatus("deleted", receipt = null, retainedUntil = null)
            }
            val body = response.readBoundedBodyOrEmpty()
            if (body.isBlank()) {
                return FeedbackRemoteStatus("deleting", receipt = null, retainedUntil = null)
            }
            return runCatching { parseStatus(JSONObject(body)) }
                .getOrElse { throw FeedbackProtocolException.InvalidResponse() }
        }
    }

    private fun reportRequest(
        method: String,
        authorization: FeedbackAuthorization,
        reportId: String,
        reportToken: String,
        body: RequestBody?,
        action: String? = null,
    ): Request {
        validateReportCredentials(reportId, reportToken)
        val path = buildList {
            add("v1")
            add("feedback")
            add("reports")
            add(reportId)
            action?.let(::add)
        }
        return apiRequest(
            method = method,
            authorization = authorization,
            path = path,
            body = body,
        ).newBuilder()
            .header("X-NOOP-Feedback-Token", reportToken)
            .build()
    }

    private fun validateReportCredentials(reportId: String, reportToken: String) {
        if (!reportId.matches(SERVER_ID) || !reportToken.matches(SERVER_TOKEN)) {
            throw FeedbackProtocolException.InvalidResponse()
        }
    }

    private fun apiRequest(
        method: String,
        authorization: FeedbackAuthorization,
        path: List<String>,
        body: RequestBody?,
    ): Request {
        if (authorization.appCheckToken.isBlank() ||
            authorization.appCheckToken.length > MAX_AUTHORIZATION_TOKEN_LENGTH
        ) {
            throw FeedbackProtocolException.Attestation()
        }
        if (authorization.identityToken.isBlank() ||
            authorization.identityToken.length > MAX_AUTHORIZATION_TOKEN_LENGTH
        ) {
            throw FeedbackProtocolException.Identity()
        }
        val url = configuration.baseUrl.newBuilder().apply {
            path.forEach(::addPathSegment)
        }.build()
        return Request.Builder()
            .url(url)
            .header("X-Firebase-AppCheck", authorization.appCheckToken)
            .header("Authorization", "Bearer ${authorization.identityToken}")
            .method(method, body)
            .build()
    }

    private fun parseReservation(
        json: JSONObject,
        expectedBytes: Long,
        expectedSha256: String,
    ): FeedbackReservation {
        val reportId = json.requiredOpaque("report_id", SERVER_ID)
        val reportToken = json.requiredOpaque("report_token", SERVER_TOKEN)
        val status = json.requiredStatus()
        val retainedUntil = json.requiredInstant("retained_until")
        val upload = if (status == "reserved") {
            json.optJSONObject("upload")
                ?: throw FeedbackProtocolException.InvalidResponse()
        } else {
            if (json.has("upload") && !json.isNull("upload")) {
                throw FeedbackProtocolException.InvalidResponse()
            }
            null
        }
        val capability = upload?.let {
            parseUploadCapability(
                upload = it,
                expectedBytes = expectedBytes,
                expectedSha256 = expectedSha256,
            )
        }
        return FeedbackReservation(
            reportId = reportId,
            reportToken = reportToken,
            status = status,
            upload = capability,
            retainedUntil = retainedUntil,
        )
    }

    private fun parseUploadCapability(
        upload: JSONObject,
        expectedBytes: Long,
        expectedSha256: String,
    ): FeedbackUploadCapability {
        val method = upload.optString("method")
        if (method != "PUT") throw FeedbackProtocolException.InvalidResponse()
        val url = upload.optString("url").toHttpUrlOrNull()
            ?: throw FeedbackProtocolException.InvalidResponse()
        val headersJson = upload.optJSONObject("headers")
            ?: throw FeedbackProtocolException.InvalidResponse()
        if (headersJson.length() > MAX_UPLOAD_HEADERS) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        val headersBuilder = Headers.Builder()
        val seenHeaders = linkedSetOf<String>()
        headersJson.keys().forEach { name ->
            val value = headersJson.opt(name) as? String
                ?: throw FeedbackProtocolException.InvalidResponse()
            val canonical = name.lowercase(Locale.US)
            if (!seenHeaders.add(canonical) ||
                !isAllowedSignedUploadHeader(canonical) ||
                name.length !in 1..128 ||
                value.length > 2_048 ||
                value.contains('\r') ||
                value.contains('\n')
            ) {
                throw FeedbackProtocolException.InvalidResponse()
            }
            runCatching { headersBuilder.add(name, value) }
                .getOrElse { throw FeedbackProtocolException.InvalidResponse() }
        }
        val headers = headersBuilder.build()
        if (!validSignedUploadCapability(
                url = url,
                headers = headers,
                expectedBytes = expectedBytes,
                expectedSha256 = expectedSha256,
            )
        ) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        return FeedbackUploadCapability(
            method = method,
            url = url,
            headers = headers,
            expiresAt = upload.requiredInstant("expires_at"),
        )
    }

    private fun parseStatus(json: JSONObject): FeedbackRemoteStatus {
        val status = json.requiredStatus()
        val receipt = if (json.isNull("receipt") || !json.has("receipt")) {
            null
        } else {
            json.requiredOpaque("receipt", RECEIPT)
        }
        val retainedUntil = json.requiredInstant("retained_until")
        if (status == "sent" && receipt == null) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        if (status != "sent" && receipt != null) {
            throw FeedbackProtocolException.InvalidResponse()
        }
        return FeedbackRemoteStatus(status, receipt, retainedUntil)
    }

    private fun isAllowedLocalUploadUrl(url: HttpUrl): Boolean {
        if (url.username.isNotEmpty() || url.password.isNotEmpty() || url.fragment != null) {
            return false
        }
        return BuildConfig.DEBUG &&
            BuildConfig.MANAGED_ALLOW_LOCAL_HTTP &&
            url.scheme == "http" &&
            url.host.lowercase(Locale.US) in localDebugUploadHosts
    }

    private fun validSignedUploadCapability(
        url: HttpUrl,
        headers: Headers,
        expectedBytes: Long,
        expectedSha256: String,
    ): Boolean {
        if (url.username.isNotEmpty() || url.password.isNotEmpty() || url.fragment != null ||
            !expectedSha256.matches(SHA256)
        ) {
            return false
        }
        val signedHeaders = when {
            url.isHttps &&
                url.port == 443 &&
                url.host.equals("storage.googleapis.com", ignoreCase = true) ->
                gcsSignedHeaderNames(url) ?: return false
            isAllowedLocalUploadUrl(url) -> null
            else -> return false
        }

        val folded = linkedMapOf<String, String>()
        for (index in 0 until headers.size) {
            val name = headers.name(index)
            val canonical = name.lowercase(Locale.US)
            val value = headers.value(index)
            if (folded.put(canonical, value) != null ||
                !isAllowedSignedUploadHeader(canonical) ||
                name.length !in 1..128 ||
                value.length > 2_048 ||
                value.contains('\r') ||
                value.contains('\n')
            ) {
                return false
            }
        }
        if (folded["content-length"] != expectedBytes.toString() ||
            folded["content-type"]?.lowercase(Locale.US) != "application/zip" ||
            folded["x-goog-content-sha256"] != expectedSha256 ||
            folded["x-goog-meta-noop-sha256"] != expectedSha256 ||
            folded["x-goog-if-generation-match"] != "0"
        ) {
            return false
        }
        return signedHeaders == null || folded.keys.all(signedHeaders::contains)
    }

    private fun gcsSignedHeaderNames(url: HttpUrl): Set<String>? {
        val values = linkedMapOf<String, String>()
        for (index in 0 until url.querySize) {
            val name = url.queryParameterName(index).lowercase(Locale.US)
            val value = url.queryParameterValue(index) ?: return null
            if (values.put(name, value) != null) return null
        }
        val required = setOf(
            "x-goog-algorithm",
            "x-goog-credential",
            "x-goog-date",
            "x-goog-expires",
            "x-goog-signature",
            "x-goog-signedheaders",
        )
        if (required.any { values[it].isNullOrEmpty() } ||
            values["x-goog-algorithm"] != "GOOG4-RSA-SHA256"
        ) {
            return null
        }
        val expires = values["x-goog-expires"]?.toLongOrNull() ?: return null
        if (expires !in 1..604_800) return null
        val ordered = values["x-goog-signedheaders"]
            ?.split(';')
            ?.map { it.lowercase(Locale.US) }
            ?: return null
        val unique = ordered.toSet()
        if (ordered.any(String::isBlank) ||
            ordered.size != unique.size ||
            "host" !in unique
        ) {
            return null
        }
        return unique
    }

    private fun isAllowedSignedUploadHeader(canonical: String): Boolean =
        canonical == "content-length" ||
            canonical == "content-type" ||
            canonical.startsWith("x-goog-")

    private suspend fun executeJson(request: Request): JSONObject {
        execute(request).use { response ->
            if (!response.isSuccessful) {
                throw FeedbackProtocolException.Http(response.code)
            }
            val body = response.readBoundedBody()
            return runCatching { JSONObject(body) }
                .getOrElse { throw FeedbackProtocolException.InvalidResponse() }
        }
    }

    private suspend fun execute(
        request: Request,
        client: OkHttpClient = apiHttp,
    ): Response = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(
            object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(
                            FeedbackProtocolException.Network(error),
                        )
                    }
                }

                override fun onResponse(call: Call, response: Response) {
                    if (continuation.isActive) {
                        continuation.resume(response)
                    } else {
                        response.close()
                    }
                }
            },
        )
    }

    private class ProgressFileRequestBody(
        private val file: File,
        private val expectedBytes: Long,
        private val progress: (Long, Long) -> Unit,
    ) : RequestBody() {
        override fun contentType(): MediaType? = null
        override fun contentLength(): Long = expectedBytes

        override fun writeTo(sink: BufferedSink) {
            var uploaded = 0L
            val buffer = ByteArray(64 * 1024)
            FileInputStream(file).use { input ->
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    sink.write(buffer, 0, read)
                    uploaded += read.toLong()
                    progress(uploaded, expectedBytes)
                }
            }
            if (uploaded != expectedBytes) {
                throw IOException("Feedback archive length changed.")
            }
        }
    }

    internal companion object {
        val JSON = "application/json; charset=utf-8".toMediaType()
        val SHA256 = Regex("^[0-9a-f]{64}$")
        val APP_VERSION = Regex("^[A-Za-z0-9][A-Za-z0-9.+_-]{0,31}$")
        val SERVER_ID = Regex(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-" +
                "[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$",
        )
        val SERVER_TOKEN = Regex("^(?:v[0-9]{1,4}\\.)?[A-Za-z0-9_-]{43}$")
        val RECEIPT = Regex("^NF-[A-Z2-7]{16}$")
        val localDebugUploadHosts = setOf(
            "127.0.0.1",
            "::1",
            "localhost",
            "10.0.2.2",
        )
        const val MAX_AUTHORIZATION_TOKEN_LENGTH = 16 * 1024
        const val MAX_UPLOAD_HEADERS = 32
        internal const val MAX_RESPONSE_BYTES = 64L * 1024L

        fun defaultHttp(timeoutSeconds: Long): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .writeTimeout(2L * timeoutSeconds, TimeUnit.SECONDS)
                .callTimeout(3L * timeoutSeconds, TimeUnit.SECONDS)
                .followRedirects(false)
                .followSslRedirects(false)
                .build()

        internal fun defaultSignedUploadHttp(timeoutSeconds: Long): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
                .writeTimeout(2L * timeoutSeconds, TimeUnit.SECONDS)
                .callTimeout(3L * timeoutSeconds, TimeUnit.SECONDS)
                .followRedirects(false)
                .followSslRedirects(false)
                .cookieJar(CookieJar.NO_COOKIES)
                .authenticator(Authenticator.NONE)
                .proxyAuthenticator(Authenticator.NONE)
                .build()
    }
}

private fun JSONObject.requiredOpaque(
    name: String,
    pattern: Regex,
): String = optString(name).takeIf(pattern::matches)
    ?: throw FeedbackProtocolException.InvalidResponse()

private fun JSONObject.requiredStatus(): String =
    optString("status").takeIf {
        it in setOf("reserved", "sent", "rejected", "deleting", "deleted")
    }
        ?: throw FeedbackProtocolException.InvalidResponse()

private fun JSONObject.requiredInstant(name: String): String {
    val value = optString(name)
    if (value.isBlank() || value.length > 64 ||
        runCatching { Instant.parse(value) }.isFailure
    ) {
        throw FeedbackProtocolException.InvalidResponse()
    }
    return value
}

private fun Response.readBoundedBody(): String {
    val responseBody = body ?: throw FeedbackProtocolException.InvalidResponse()
    val source = responseBody.source()
    source.request(FeedbackApiClient.MAX_RESPONSE_BYTES + 1L)
    if (source.buffer.size > FeedbackApiClient.MAX_RESPONSE_BYTES) {
        throw FeedbackProtocolException.InvalidResponse()
    }
    return source.buffer.readUtf8()
}

private fun Response.readBoundedBodyOrEmpty(): String {
    val responseBody = body ?: return ""
    val source = responseBody.source()
    source.request(FeedbackApiClient.MAX_RESPONSE_BYTES + 1L)
    if (source.buffer.size > FeedbackApiClient.MAX_RESPONSE_BYTES) {
        throw FeedbackProtocolException.InvalidResponse()
    }
    return source.buffer.readUtf8()
}
