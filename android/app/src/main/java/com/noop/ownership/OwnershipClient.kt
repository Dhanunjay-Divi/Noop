package com.noop.ownership

import com.noop.AppDiagnosticsRecorder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.CacheControl
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class OwnershipAuthorization(
    val identityToken: String,
    val appCheckToken: String,
    val installation: OwnershipInstallationCredential,
)

internal data class OwnershipChallenge(
    val id: UUID,
    val challenge: String,
)

private data class OwnershipTermsManifest(
    val policyVersion: String,
    val locale: String,
    val documentSha256: String,
    val documentUrl: HttpUrl,
)

internal class OwnershipClient(
    private val configuration: OwnershipConfiguration,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .cache(null)
        .followRedirects(false)
        .followSslRedirects(false)
        .callTimeout(30, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build(),
) {
    suspend fun currentTerms(locale: String): OwnershipTermsDocument {
        require(locale.matches(LOCALE))
        val manifestUrl = apiUrl("v1/ownership/terms/current")
            .newBuilder()
            .addQueryParameter("locale", locale)
            .build()
        val manifestData = execute(
            url = manifestUrl,
            method = "GET",
            routeGroup = "terms_manifest",
            includeInstallation = false,
        )
        val manifestObject = jsonObject(manifestData)
        val policyVersion = manifestObject.requiredString(
            "policy_version",
            POLICY_VERSION,
        )
        val returnedLocale = manifestObject.requiredString("locale", LOCALE)
        val sha256 = manifestObject.requiredString("document_sha256", SHA256)
        val documentUrl = manifestObject.requiredString("document_uri")
            .toHttpUrlOrNull()
            ?.takeIf { url ->
                url.isHttps &&
                    url.host.equals(configuration.termsHost, ignoreCase = true) &&
                    url.port == 443 &&
                    url.username.isEmpty() &&
                    url.password.isEmpty() &&
                    url.query == null &&
                    url.fragment == null
            }
            ?: throw OwnershipException.InvalidResponse
        val manifest = OwnershipTermsManifest(
            policyVersion = policyVersion,
            locale = returnedLocale,
            documentSha256 = sha256,
            documentUrl = documentUrl,
        )
        val document = execute(
            url = manifest.documentUrl,
            method = "GET",
            routeGroup = "terms_document",
            includeInstallation = false,
            maximumBytes = TERMS_MAXIMUM_BYTES,
        )
        if (!sha256(document).equals(manifest.documentSha256, ignoreCase = false)) {
            throw OwnershipException.InvalidResponse
        }
        val text = decodeUtf8(document)
        if (
            text.isEmpty() ||
            text.any { character ->
                character.isISOControl() && character !in setOf('\n', '\r', '\t')
            }
        ) {
            throw OwnershipException.InvalidResponse
        }
        return OwnershipTermsDocument(
            policyVersion = manifest.policyVersion,
            locale = manifest.locale,
            sha256 = manifest.documentSha256,
            text = text,
        )
    }

    suspend fun registerAccount(
        requestId: UUID,
        installation: OwnershipInstallationCredential,
        policyVersion: String,
        policySha256: String,
        locale: String,
        plan: NoopProductPlan,
        authorization: OwnershipAuthorization,
    ): OwnershipAccountOverview {
        val body = JSONObject()
            .put("request_id", requestId.toString().lowercase())
            .put("installation_id", installation.id)
            .put("installation_token", installation.token)
            .put("platform", "android")
            .put("policy_version", policyVersion)
            .put("policy_sha256", policySha256)
            .put("locale", locale)
            .put("plan_selection", plan.storedValue)
        return parseOverview(
            execute(
                url = apiUrl("v1/ownership/account"),
                method = "PUT",
                routeGroup = "account",
                authorization = authorization,
                includeInstallation = false,
                body = body,
            ),
        )
    }

    suspend fun acceptTerms(
        requestId: UUID,
        policyVersion: String,
        policySha256: String,
        locale: String,
        authorization: OwnershipAuthorization,
    ) {
        val value = jsonObject(
            execute(
                url = apiUrl("v1/ownership/terms/acceptance"),
                method = "PUT",
                routeGroup = "terms_acceptance",
                authorization = authorization,
                includeInstallation = false,
                body = JSONObject()
                    .put("request_id", requestId.toString().lowercase())
                    .put("policy_version", policyVersion)
                    .put("policy_sha256", policySha256)
                    .put("locale", locale),
            ),
        )
        if (
            value.optString("acceptance_state") != "accepted" ||
            value.optString("policy_version") != policyVersion ||
            value.optString("locale") != locale ||
            value.opt("resumed") !is Boolean
        ) {
            throw OwnershipException.InvalidResponse
        }
    }

    suspend fun bootstrap(
        authorization: OwnershipAuthorization,
    ): OwnershipBootstrapStatus {
        val value = jsonObject(
            execute(
                url = apiUrl("v1/ownership/bootstrap"),
                method = "GET",
                routeGroup = "bootstrap",
                authorization = authorization,
                includeInstallation = false,
            ),
        )
        val accountState = value.requiredString("account_state")
            .takeIf { it in setOf("unregistered", "active") }
            ?: throw OwnershipException.InvalidResponse
        val bandState = value.requiredString("band_state")
            .takeIf { it in setOf("unclaimed", "claimed") }
            ?: throw OwnershipException.InvalidResponse
        val replacementRequired = value.requiredBoolean(
            "replacement_authorization_required",
        )
        val termsAcceptanceRequired = value.requiredBoolean(
            "terms_acceptance_required",
        )
        if (
            replacementRequired !=
            (accountState == "active" && bandState == "claimed") ||
            (accountState != "active" && termsAcceptanceRequired)
        ) {
            throw OwnershipException.InvalidResponse
        }
        return OwnershipBootstrapStatus(
            accountState = accountState,
            bandState = bandState,
            replacementAuthorizationRequired = replacementRequired,
            termsAcceptanceRequired = termsAcceptanceRequired,
        )
    }

    suspend fun createChallenge(
        requestId: UUID,
        appCheckToken: String,
    ): OwnershipChallenge {
        val data = execute(
            url = apiUrl("v1/ownership/possession-challenges"),
            method = "POST",
            routeGroup = "challenge",
            appCheckToken = appCheckToken,
            includeInstallation = false,
            body = JSONObject()
                .put("request_id", requestId.toString().lowercase())
                .put("platform", "android"),
        )
        val value = jsonObject(data)
        val challenge = value.requiredString("challenge", CHALLENGE)
        val challengeId = runCatching {
            UUID.fromString(value.getString("challenge_id"))
        }.getOrNull() ?: throw OwnershipException.InvalidResponse
        return OwnershipChallenge(challengeId, challenge)
    }

    suspend fun claim(
        requestId: UUID,
        challenge: OwnershipChallenge,
        possessionResponse: String,
        authorization: OwnershipAuthorization,
    ) {
        if (possessionResponse.length !in 16..16_384) {
            throw OwnershipException.InvalidResponse
        }
        val data = execute(
            url = apiUrl("v1/ownership/claims"),
            method = "POST",
            routeGroup = "claim",
            authorization = authorization,
            body = JSONObject()
                .put("request_id", requestId.toString().lowercase())
                .put("challenge_id", challenge.id.toString().lowercase())
                .put("challenge", challenge.challenge)
                .put("possession_response", possessionResponse),
        )
        if (jsonObject(data).optString("band_state") != "claimed") {
            throw OwnershipException.InvalidResponse
        }
    }

    suspend fun authorizeInstallation(
        requestId: UUID,
        challenge: OwnershipChallenge,
        possessionResponse: String,
        authorization: OwnershipAuthorization,
    ) {
        if (possessionResponse.length !in 16..16_384) {
            throw OwnershipException.InvalidResponse
        }
        val data = execute(
            url = apiUrl("v1/ownership/installations:authorize"),
            method = "POST",
            routeGroup = "installation_authorize",
            authorization = authorization,
            includeInstallation = false,
            body = JSONObject()
                .put("request_id", requestId.toString().lowercase())
                .put("challenge_id", challenge.id.toString().lowercase())
                .put("challenge", challenge.challenge)
                .put("possession_response", possessionResponse)
                .put("new_installation_id", authorization.installation.id)
                .put("new_installation_token", authorization.installation.token)
                .put("new_platform", "android"),
        )
        val value = jsonObject(data)
        if (
            value.optString("installation_state") != "active" ||
            value.optString("installation_id") != authorization.installation.id
        ) {
            throw OwnershipException.InvalidResponse
        }
    }

    suspend fun overview(
        authorization: OwnershipAuthorization,
    ): OwnershipAccountOverview = parseOverview(
        execute(
            url = apiUrl("v1/ownership/me"),
            method = "GET",
            routeGroup = "overview",
            authorization = authorization,
        ),
    )

    suspend fun installations(
        authorization: OwnershipAuthorization,
    ): List<OwnershipInstallation> {
        val data = execute(
            url = apiUrl("v1/ownership/installations"),
            method = "GET",
            routeGroup = "installations",
            authorization = authorization,
        )
        val array = jsonObject(data).optJSONArray("installations")
            ?: throw OwnershipException.InvalidResponse
        if (array.length() > 10) throw OwnershipException.InvalidResponse
        return (0 until array.length()).map { index ->
            val row = array.optJSONObject(index)
                ?: throw OwnershipException.InvalidResponse
            val id = row.requiredString("installation_id", INSTALLATION_ID)
            val platform = row.requiredString("platform")
                .takeIf { it in setOf("ios", "android") }
                ?: throw OwnershipException.InvalidResponse
            val status = row.requiredString("status")
                .takeIf { it in setOf("active", "revoked") }
                ?: throw OwnershipException.InvalidResponse
            OwnershipInstallation(
                id = id,
                platform = platform,
                status = status,
                current = row.requiredBoolean("current"),
                registeredAt = row.requiredString("registered_at"),
                lastSeenAt = row.requiredString("last_seen_at"),
            )
        }
    }

    suspend fun revokeInstallation(
        installationId: String,
        authorization: OwnershipAuthorization,
    ) {
        if (!installationId.matches(INSTALLATION_ID)) {
            throw OwnershipException.InvalidResponse
        }
        execute(
            url = apiUrl("v1/ownership/installations")
                .newBuilder()
                .addPathSegment(installationId)
                .build(),
            method = "DELETE",
            routeGroup = "installation_revoke",
            authorization = authorization,
        )
    }

    suspend fun requestAccountDeletion(
        requestId: UUID,
        confirmationSha256: String,
        exportAcknowledged: Boolean,
        retentionAcknowledged: Boolean,
        policyVersion: String,
        policySha256: String,
        locale: String,
        authorization: OwnershipAuthorization,
    ): OwnershipAccountDeletion {
        if (
            !confirmationSha256.matches(SHA256) ||
            !policyVersion.matches(POLICY_VERSION) ||
            !policySha256.matches(SHA256) ||
            !locale.matches(LOCALE)
        ) {
            throw OwnershipException.InvalidResponse
        }
        return parseAccountDeletion(
            execute(
                url = apiUrl("v1/ownership/account/deletion-requests"),
                method = "POST",
                routeGroup = "account_deletion_request",
                authorization = authorization,
                body = JSONObject()
                    .put("request_id", requestId.toString().lowercase())
                    .put("confirmation_sha256", confirmationSha256)
                    .put("export_acknowledged", exportAcknowledged)
                    .put("retention_acknowledged", retentionAcknowledged)
                    .put("policy_version", policyVersion)
                    .put("policy_sha256", policySha256)
                    .put("locale", locale),
            ),
        )
    }

    suspend fun accountDeletion(
        requestId: UUID,
        authorization: OwnershipAuthorization,
    ): OwnershipAccountDeletion = parseAccountDeletion(
        execute(
            url = apiUrl(
                "v1/ownership/account/deletion-requests/" +
                    requestId.toString().lowercase(),
            ),
            method = "GET",
            routeGroup = "account_deletion_status",
            authorization = authorization,
            includeInstallation = false,
        ),
    )

    suspend fun cancelAccountDeletion(
        requestId: UUID,
        authorization: OwnershipAuthorization,
    ): OwnershipAccountDeletion = parseAccountDeletion(
        execute(
            url = apiUrl(
                "v1/ownership/account/deletion-requests/" +
                    requestId.toString().lowercase() +
                    "/cancel",
            ),
            method = "POST",
            routeGroup = "account_deletion_cancel",
            authorization = authorization,
        ),
    )

    suspend fun selectPlan(
        plan: NoopProductPlan,
        requestId: UUID,
        authorization: OwnershipAuthorization,
    ) {
        val data = execute(
            url = apiUrl("v1/ownership/plan-selection"),
            method = "PUT",
            routeGroup = "plan",
            authorization = authorization,
            body = JSONObject()
                .put("request_id", requestId.toString().lowercase())
                .put("selection", plan.storedValue),
        )
        val value = jsonObject(data)
        if (
            value.optString("plan_selection") != plan.storedValue ||
            value.optBoolean("noop_plus_entitled", true) ||
            value.optString("payment_state") != "unavailable"
        ) {
            throw OwnershipException.InvalidResponse
        }
    }

    private suspend fun execute(
        url: HttpUrl,
        method: String,
        routeGroup: String,
        authorization: OwnershipAuthorization? = null,
        appCheckToken: String? = null,
        includeInstallation: Boolean = true,
        body: JSONObject? = null,
        maximumBytes: Int = RESPONSE_MAXIMUM_BYTES,
    ): ByteArray = withContext(Dispatchers.IO) {
        val requestBody = body?.toString()
            ?.toRequestBody(JSON_MEDIA_TYPE)
        val builder = Request.Builder()
            .url(url)
            .cacheControl(CacheControl.FORCE_NETWORK)
            .header("Cache-Control", "no-store")
            .header("Accept", "application/json")
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post(requestBody ?: EMPTY_BODY)
            "PUT" -> builder.put(requestBody ?: EMPTY_BODY)
            "DELETE" -> builder.delete(requestBody)
            else -> throw OwnershipException.InvalidConfiguration
        }
        if (authorization != null) {
            builder.header(
                "Authorization",
                "Bearer ${authorization.identityToken}",
            )
            builder.header(
                "X-Firebase-AppCheck",
                authorization.appCheckToken,
            )
            if (includeInstallation) {
                builder.header(
                    "X-Noop-Ownership-Installation-ID",
                    authorization.installation.id,
                )
                builder.header(
                    "X-Noop-Ownership-Installation-Token",
                    authorization.installation.token,
                )
            }
        } else if (appCheckToken != null) {
            builder.header("X-Firebase-AppCheck", appCheckToken)
        }

        val started = System.nanoTime()
        try {
            executeCancellable(builder.build()).use { response ->
                val responseBytes = try {
                    response.readBounded(maximumBytes)
                } catch (error: OwnershipException) {
                    recordRequest(
                        routeGroup = routeGroup,
                        method = method,
                        statusCode = response.code,
                        startedNanos = started,
                        outcome = if (response.isSuccessful) "failed" else "rejected",
                    )
                    throw error
                }
                recordRequest(
                    routeGroup = routeGroup,
                    method = method,
                    statusCode = response.code,
                    startedNanos = started,
                    outcome = if (response.isSuccessful) "completed" else "rejected",
                )
                if (!response.isSuccessful) {
                    throw when (response.code) {
                        401, 403 -> OwnershipException.Authentication
                        404 -> OwnershipException.InvalidState
                        410 -> when (routeGroup) {
                            "claim",
                            "installation_authorize",
                            -> OwnershipException.ChallengeInactive
                            else -> OwnershipException.InvalidState
                        }
                        409 -> when (routeGroup) {
                            "claim" -> OwnershipException.AlreadyClaimed
                            else -> OwnershipException.InvalidState
                        }
                        412 -> if (
                            routeGroup in setOf(
                                "account",
                                "claim",
                                "installation_authorize",
                                "overview",
                                "terms_acceptance",
                                "account_deletion_request",
                            )
                        ) {
                            OwnershipException.TermsChanged
                        } else {
                            OwnershipException.InvalidState
                        }
                        422 -> when (routeGroup) {
                            "claim",
                            "installation_authorize",
                            -> OwnershipException.PossessionRejected
                            else -> OwnershipException.InvalidResponse
                        }
                        429 -> OwnershipException.ServiceUnavailable
                        in 500..599 -> OwnershipException.ServiceUnavailable
                        else -> OwnershipException.InvalidResponse
                    }
                }
                responseBytes
            }
        } catch (error: OwnershipException) {
            throw error
        } catch (error: CancellationException) {
            recordRequest(
                routeGroup = routeGroup,
                method = method,
                statusCode = null,
                startedNanos = started,
                outcome = "canceled",
            )
            throw error
        } catch (_: IOException) {
            recordRequest(
                routeGroup = routeGroup,
                method = method,
                statusCode = null,
                startedNanos = started,
                outcome = "failed",
            )
            throw OwnershipException.Network
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun executeCancellable(request: Request): Response =
        suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(
                object : Callback {
                    override fun onFailure(call: Call, error: IOException) {
                        if (continuation.isActive) {
                            continuation.resumeWithException(error)
                        }
                    }

                    override fun onResponse(call: Call, response: Response) {
                        if (!continuation.isActive) {
                            response.close()
                            return
                        }
                        continuation.resume(response) {
                            response.close()
                        }
                    }
                },
            )
        }

    private fun apiUrl(path: String): HttpUrl =
        configuration.baseUrl.newBuilder()
            .addPathSegments(path)
            .build()

    private fun parseOverview(data: ByteArray): OwnershipAccountOverview {
        val value = jsonObject(data)
        val accountState = value.requiredString("account_state")
            .takeIf { it in setOf("active", "deletion_pending", "retired") }
            ?: throw OwnershipException.InvalidResponse
        val bandState = value.requiredString("band_state")
            .takeIf { it in setOf("unclaimed", "claimed") }
            ?: throw OwnershipException.InvalidResponse
        val activeInstallations = value.requiredInt("active_installations")
        if (activeInstallations !in 0..10) {
            throw OwnershipException.InvalidResponse
        }
        val plan = NoopProductPlan.entries.firstOrNull {
            it.storedValue == value.optString("plan_selection")
        } ?: throw OwnershipException.InvalidResponse
        val noopPlusEntitled = value.requiredBoolean("noop_plus_entitled")
        if (noopPlusEntitled) {
            throw OwnershipException.InvalidResponse
        }
        return OwnershipAccountOverview(
            accountState = accountState,
            emailVerified = value.requiredBoolean("email_verified"),
            phoneVerified = value.requiredBoolean("phone_verified"),
            bandState = bandState,
            activeInstallations = activeInstallations,
            plan = plan,
            noopPlusEntitled = noopPlusEntitled,
        )
    }

    private fun parseAccountDeletion(data: ByteArray): OwnershipAccountDeletion {
        val value = jsonObject(data).requiredObject("deletion")
        val idRaw = value.requiredString("deletion_request_id")
        val id = runCatching { UUID.fromString(idRaw) }.getOrNull()
            ?.takeIf { it.toString() == idRaw.lowercase() }
            ?: throw OwnershipException.InvalidResponse
        val state = value.requiredString("state")
            .takeIf { it in DELETION_STATES }
            ?: throw OwnershipException.InvalidResponse
        val accountState = value.requiredString("account_state")
            .takeIf { it in setOf("active", "deletion_pending", "retired") }
            ?: throw OwnershipException.InvalidResponse
        val requestedAt = value.requiredTimestamp("requested_at")
        val cancelBefore = value.requiredTimestamp("cancel_before")
        val canceledAt = value.requiredNullableTimestamp("canceled_at")
        val cancellationAllowed = value.requiredBoolean("cancellation_allowed")
        val policyVersion = value.requiredString("policy_version", POLICY_VERSION)
        val sessionsRevoked = value.requiredBoolean("sessions_revoked")
        val revokedSessionCount = value.requiredInt("revoked_session_count")
        val cloud = value.requiredObject("cloud_data_deletion")
        val identity = value.requiredObject("identity_deletion")
        val band = value.requiredObject("band_retirement")
        val control = value.requiredObject("control_plane_deletion")
        val cloudState = cloud.requiredDeletionWorkState("state")
        val cloudNotBefore = cloud.requiredTimestamp("not_before")
        val identityState = identity.requiredDeletionWorkState("state")
        val identityBlocker = identity.requiredNullableDeletionToken("blocker")
        val bandRequired = band.requiredBoolean("required")
        val bandEligibility = band.requiredString("eligibility")
            .takeIf { it in BAND_RETIREMENT_ELIGIBILITY }
            ?: throw OwnershipException.InvalidResponse
        val bandState = band.requiredDeletionWorkState("work_state")
        val bandBlocker = band.requiredNullableDeletionToken("blocker")
        val bandPolicyVersion = band.requiredNullableString(
            "policy_version",
            POLICY_VERSION,
        )
        val bandHardwareVersion = band.requiredNullableString(
            "hardware_capability_version",
            POLICY_VERSION,
        )
        val controlState = control.requiredDeletionWorkState("state")
        val controlBlocker = control.requiredNullableDeletionToken("blocker")
        if (
            !value.requiredBoolean("export_acknowledged") ||
            !value.requiredBoolean("retention_acknowledged") ||
            !sessionsRevoked ||
            revokedSessionCount !in 1..10 ||
            !value.requiredBoolean("reauthorization_required") ||
            value.requiredBoolean("destructive_completion_claimed") ||
            value.opt("duplicate") !is Boolean ||
            (state == "canceled") != (canceledAt != null) ||
            cancellationAllowed != (state == "cooling_off") ||
            bandRequired != (bandEligibility != "not_required") ||
            !deletionBlockerIsConsistent(identityState, identityBlocker) ||
            !deletionBlockerIsConsistent(bandState, bandBlocker) ||
            !deletionBlockerIsConsistent(controlState, controlBlocker)
        ) {
            throw OwnershipException.InvalidResponse
        }
        return OwnershipAccountDeletion(
            id = id,
            state = state,
            accountState = accountState,
            requestedAt = requestedAt,
            cancelBefore = cancelBefore,
            canceledAt = canceledAt,
            cancellationAllowed = cancellationAllowed,
            policyVersion = policyVersion,
            sessionsRevoked = sessionsRevoked,
            revokedSessionCount = revokedSessionCount,
            cloudDataState = cloudState,
            cloudDataNotBefore = cloudNotBefore,
            identityState = identityState,
            identityBlocker = identityBlocker,
            bandRetirementRequired = bandRequired,
            bandRetirementEligibility = bandEligibility,
            bandRetirementState = bandState,
            bandRetirementBlocker = bandBlocker,
            bandRetirementPolicyVersion = bandPolicyVersion,
            bandHardwareCapabilityVersion = bandHardwareVersion,
            controlPlaneState = controlState,
            controlPlaneBlocker = controlBlocker,
        )
    }

    private fun deletionBlockerIsConsistent(
        state: String,
        blocker: String?,
    ): Boolean =
        (state == "blocked") == (blocker != null)

    private fun recordRequest(
        routeGroup: String,
        method: String,
        statusCode: Int?,
        startedNanos: Long,
        outcome: String,
    ) {
        val fields = mutableMapOf(
            "target" to "ownership",
            "route_group" to routeGroup,
            "method" to method,
            "duration_ms" to (
                (System.nanoTime() - startedNanos)
                    .coerceAtLeast(0L) / 1_000_000L
                ).toString(),
            "outcome" to outcome,
        )
        if (statusCode != null) fields["status_code"] = statusCode.toString()
        AppDiagnosticsRecorder.record("ownership_http.request", fields)
    }

    companion object {
        private const val RESPONSE_MAXIMUM_BYTES = 1024 * 1024
        private const val TERMS_MAXIMUM_BYTES = 512 * 1024
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
        private val EMPTY_BODY = ByteArray(0).toRequestBody(JSON_MEDIA_TYPE)
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val POLICY_VERSION = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
        private val LOCALE = Regex("^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8}){0,2}$")
        private val CHALLENGE = Regex("^[A-Za-z0-9_-]{43}$")
        private val INSTALLATION_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
        internal val DELETION_TOKEN = Regex("^[a-z][a-z0-9_]{0,63}$")
        private val DELETION_STATES =
            setOf("cooling_off", "scheduled", "blocked", "canceled")
        internal val DELETION_WORK_STATES = setOf(
            "scheduled",
            "blocked",
            "not_required",
            "canceled",
            "processing",
            "completed",
            "failed",
        )
        private val BAND_RETIREMENT_ELIGIBILITY = setOf(
            "not_required",
            "blocked_hardware",
            "eligible_pending_operator",
            "blocked_policy",
        )
    }
}

private fun Response.readBounded(maximumBytes: Int): ByteArray {
    val body = body ?: return ByteArray(0)
    val length = body.contentLength()
    if (length > maximumBytes) throw OwnershipException.InvalidResponse
    val output = ByteArrayOutputStream(
        if (length in 0..maximumBytes.toLong()) length.toInt() else 4096,
    )
    body.byteStream().use { input ->
        val buffer = ByteArray(8192)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > maximumBytes) throw OwnershipException.InvalidResponse
            output.write(buffer, 0, count)
        }
    }
    return output.toByteArray()
}

private fun jsonObject(data: ByteArray): JSONObject = try {
    JSONObject(decodeUtf8(data))
} catch (_: Exception) {
    throw OwnershipException.InvalidResponse
}

private fun JSONObject.requiredString(
    key: String,
    pattern: Regex? = null,
): String {
    if (!has(key) || isNull(key)) throw OwnershipException.InvalidResponse
    val value = opt(key) as? String ?: throw OwnershipException.InvalidResponse
    if (pattern != null && !value.matches(pattern)) {
        throw OwnershipException.InvalidResponse
    }
    return value
}

private fun JSONObject.requiredBoolean(key: String): Boolean {
    if (!has(key) || isNull(key)) throw OwnershipException.InvalidResponse
    return opt(key) as? Boolean ?: throw OwnershipException.InvalidResponse
}

private fun JSONObject.requiredInt(key: String): Int {
    if (!has(key) || isNull(key)) throw OwnershipException.InvalidResponse
    val number = opt(key) as? Number ?: throw OwnershipException.InvalidResponse
    val value = number.toLong()
    if (value !in Int.MIN_VALUE..Int.MAX_VALUE || value.toDouble() != number.toDouble()) {
        throw OwnershipException.InvalidResponse
    }
    return value.toInt()
}

private fun JSONObject.requiredObject(key: String): JSONObject {
    if (!has(key) || isNull(key)) throw OwnershipException.InvalidResponse
    return opt(key) as? JSONObject ?: throw OwnershipException.InvalidResponse
}

private fun JSONObject.requiredNullableString(
    key: String,
    pattern: Regex,
): String? {
    if (!has(key)) throw OwnershipException.InvalidResponse
    if (isNull(key)) return null
    val value = opt(key) as? String ?: throw OwnershipException.InvalidResponse
    if (!value.matches(pattern)) throw OwnershipException.InvalidResponse
    return value
}

private fun JSONObject.requiredNullableDeletionToken(key: String): String? =
    requiredNullableString(key, OwnershipClient.DELETION_TOKEN)

private fun JSONObject.requiredDeletionWorkState(key: String): String =
    requiredString(key)
        .takeIf { it in OwnershipClient.DELETION_WORK_STATES }
        ?: throw OwnershipException.InvalidResponse

private fun JSONObject.requiredTimestamp(key: String): String =
    requiredString(key).also(::validateDeletionTimestamp)

private fun JSONObject.requiredNullableTimestamp(key: String): String? {
    if (!has(key)) throw OwnershipException.InvalidResponse
    if (isNull(key)) return null
    return (opt(key) as? String)
        ?.also(::validateDeletionTimestamp)
        ?: throw OwnershipException.InvalidResponse
}

private fun validateDeletionTimestamp(value: String) {
    if (
        value.length > 64 ||
        runCatching {
            OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME)
        }.isFailure
    ) {
        throw OwnershipException.InvalidResponse
    }
}

private fun sha256(data: ByteArray): String =
    MessageDigest.getInstance("SHA-256")
        .digest(data)
        .joinToString("") { byte -> "%02x".format(byte) }

private fun decodeUtf8(data: ByteArray): String = try {
    Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(data))
        .toString()
} catch (_: Exception) {
    throw OwnershipException.InvalidResponse
}
