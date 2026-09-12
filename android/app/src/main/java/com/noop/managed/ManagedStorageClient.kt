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
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

data class ManagedStorageRequestDiagnostic(
    val target: String,
    val routeGroup: String,
    val method: String,
    val statusCode: Int?,
    val durationMilliseconds: Long,
    val requestId: String?,
    val outcome: String,
)

class ManagedStorageClient(
    private val configuration: ManagedStorageConfiguration,
    private val http: OkHttpClient = defaultHttp(configuration.timeoutSeconds),
    private val requestObserver: (ManagedStorageRequestDiagnostic) -> Unit = {},
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

    suspend fun registerPushInstallation(
        authorization: ManagedAuthorization,
        environment: ManagedPushEnvironment,
        token: String,
    ): ManagedPushRegistrationInfo = withContext(Dispatchers.IO) {
        if (!token.matches(PUSH_TOKEN)) {
            throw IllegalArgumentException("Invalid managed push token")
        }
        val row = executeJson(
            apiRequest("v1/managed/push/installations/current", authorization)
                .put(
                    JSONObject()
                        .put("platform", "android")
                        .put("environment", environment.wireValue)
                        .put("target_kind", ManagedPushTargetKind.TOKEN.wireValue)
                        .put("token", token)
                        .toString()
                        .toRequestBody(JSON),
                )
                .build(),
        ).requireObject("registration")
        val registration = ManagedPushRegistrationInfo(
            installationId = row.optString("installation_id"),
            platform = row.optString("platform"),
            environment = row.optString("environment"),
            targetKind = row.optString("target_kind"),
            status = row.optString("status"),
            updatedAt = row.optString("updated_at").requiredInstant(),
            duplicate = row.optBoolean("duplicate", false),
        )
        if (registration.installationId != authorization.installationId ||
            registration.platform != "android" ||
            registration.environment != environment.wireValue ||
            registration.targetKind != ManagedPushTargetKind.TOKEN.wireValue ||
            registration.status != "active"
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        registration
    }

    suspend fun revokePushInstallation(
        authorization: ManagedAuthorization,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest("v1/managed/push/installations/current", authorization)
                .delete()
                .build(),
        )
    }

    suspend fun createSafetyInvite(
        authorization: ManagedAuthorization,
        capability: String,
        requestId: UUID,
        expiresInHours: Int = 72,
    ): ManagedSafetyInvite = withContext(Dispatchers.IO) {
        if (!ManagedSafetyIdentifier.invitePattern.matches(capability) ||
            expiresInHours !in 1..168
        ) {
            throw IllegalArgumentException("Invalid managed Safety invitation")
        }
        val invite = parseSafetyInvite(
            executeJson(
                apiRequest("v1/managed/safety/invites", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("capability", capability)
                            .put("expires_in_hours", expiresInHours)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("invite"),
        )
        if (invite.capability != capability) {
            throw ManagedStorageException.InvalidResponse()
        }
        invite
    }

    suspend fun revokeSafetyInvite(
        authorization: ManagedAuthorization,
        inviteId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest(
                "v1/managed/safety/invites/${inviteId.toString().lowercase()}",
                authorization,
            ).delete().build(),
        )
    }

    suspend fun redeemSafetyInvite(
        authorization: ManagedAuthorization,
        capability: String,
        requestId: UUID,
    ): ManagedSafetyRequest = withContext(Dispatchers.IO) {
        if (!ManagedSafetyIdentifier.invitePattern.matches(capability)) {
            throw IllegalArgumentException("Invalid managed Safety invitation")
        }
        parseSafetyRequest(
            executeJson(
                apiRequest("v1/managed/safety/invites:redeem", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("capability", capability)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("request"),
        )
    }

    suspend fun createSafetyRequest(
        authorization: ManagedAuthorization,
        noopId: String,
        requestId: UUID,
    ): ManagedSafetyRequest = withContext(Dispatchers.IO) {
        val canonical = ManagedSocialIdentifier.canonicalNoopId(noopId)
            ?: throw IllegalArgumentException("Invalid NOOP ID")
        parseSafetyRequest(
            executeJson(
                apiRequest("v1/managed/safety/requests", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("noop_id", canonical)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("request"),
        )
    }

    suspend fun safetyRequests(
        authorization: ManagedAuthorization,
    ): List<ManagedSafetyRequest> = withContext(Dispatchers.IO) {
        val rows = executeJson(
            apiRequest("v1/managed/safety/requests", authorization)
                .get()
                .build(),
        ).requireArray("requests")
        if (rows.length() > 100) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                add(parseSafetyRequest(rows.requireObject(index)))
            }
        }
    }

    suspend fun decideSafetyRequest(
        authorization: ManagedAuthorization,
        requestId: UUID,
        accept: Boolean,
    ): ManagedSafetyRequest = withContext(Dispatchers.IO) {
        parseSafetyRequest(
            executeJson(
                apiRequest(
                    "v1/managed/safety/requests/${requestId.toString().lowercase()}",
                    authorization,
                ).post(
                    JSONObject()
                        .put("decision", if (accept) "accept" else "decline")
                        .toString()
                        .toRequestBody(JSON),
                ).build(),
            ).requireObject("request"),
        )
    }

    suspend fun safetyContacts(
        authorization: ManagedAuthorization,
    ): ManagedSafetyContacts = withContext(Dispatchers.IO) {
        val response = executeJson(
            apiRequest("v1/managed/safety/contacts", authorization)
                .get()
                .build(),
        )
        val rows = response.requireArray("contacts")
        if (rows.length() > 25 ||
            response.requiredNonnegativeInt("minimum_required") != 2 ||
            response.requiredNonnegativeInt("maximum_allowed") != 5
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        ManagedSafetyContacts(
            contacts = buildList {
                for (index in 0 until rows.length()) {
                    add(parseSafetyContact(rows.requireObject(index)))
                }
            },
            minimumRequired = 2,
            maximumAllowed = 5,
        )
    }

    suspend fun removeSafetyContact(
        authorization: ManagedAuthorization,
        profileId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest(
                "v1/managed/safety/contacts/${profileId.toString().lowercase()}",
                authorization,
            ).delete().build(),
        )
    }

    suspend fun createSafetyIncident(
        authorization: ManagedAuthorization,
        requestId: UUID,
        trigger: String = "manual_sos",
        durationHours: Int,
        shareLocation: Boolean,
    ): ManagedSafetyIncidentCreation = withContext(Dispatchers.IO) {
        if (trigger !in setOf("manual_sos", "band_sos") ||
            durationHours !in setOf(8, 12)
        ) {
            throw IllegalArgumentException("Invalid managed Safety duration")
        }
        val response = executeJson(
            apiRequest("v1/managed/safety/incidents", authorization)
                .post(
                    JSONObject()
                        .put("request_id", requestId.toString())
                        .put("trigger", trigger)
                        .put("duration_hours", durationHours)
                        .put("share_location", shareLocation)
                        .toString()
                        .toRequestBody(JSON),
                )
                .build(),
        )
        val pushOutcome = response.optString("push_outcome")
        if (pushOutcome !in PUSH_OUTCOMES) {
            throw ManagedStorageException.InvalidResponse()
        }
        ManagedSafetyIncidentCreation(
            incident = parseSafetyIncident(response.requireObject("incident")),
            pushOutcome = pushOutcome,
        )
    }

    suspend fun safetyIncidents(
        authorization: ManagedAuthorization,
    ): List<ManagedSafetyIncident> = withContext(Dispatchers.IO) {
        val rows = executeJson(
            apiRequest("v1/managed/safety/incidents", authorization)
                .get()
                .build(),
        ).requireArray("incidents")
        if (rows.length() > 30) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                add(parseSafetyIncident(rows.requireObject(index)))
            }
        }
    }

    suspend fun safetyIncident(
        authorization: ManagedAuthorization,
        incidentId: UUID,
    ): ManagedSafetyIncident = withContext(Dispatchers.IO) {
        parseSafetyIncident(
            executeJson(
                apiRequest(
                    "v1/managed/safety/incidents/${incidentId.toString().lowercase()}",
                    authorization,
                ).get().build(),
            ).requireObject("incident"),
        ).also {
            if (it.incidentId != incidentId) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
    }

    suspend fun updateSafetyLocation(
        authorization: ManagedAuthorization,
        incidentId: UUID,
        sequence: Long,
        latitude: Double,
        longitude: Double,
        horizontalAccuracyM: Double,
        capturedAt: String,
    ): ManagedSafetyLocation = withContext(Dispatchers.IO) {
        if (sequence <= 0L ||
            !latitude.isFinite() || latitude !in -90.0..90.0 ||
            !longitude.isFinite() || longitude !in -180.0..180.0 ||
            !horizontalAccuracyM.isFinite() ||
            horizontalAccuracyM !in 0.0..10_000.0 ||
            runCatching { Instant.parse(capturedAt) }.isFailure
        ) {
            throw IllegalArgumentException("Invalid managed Safety location")
        }
        parseSafetyLocation(
            executeJson(
                apiRequest(
                    "v1/managed/safety/incidents/" +
                        "${incidentId.toString().lowercase()}/location",
                    authorization,
                ).put(
                    JSONObject()
                        .put("sequence", sequence)
                        .put("latitude", latitude)
                        .put("longitude", longitude)
                        .put("horizontal_accuracy_m", horizontalAccuracyM)
                        .put("captured_at", capturedAt)
                        .toString()
                        .toRequestBody(JSON),
                ).build(),
            ).requireObject("location"),
        )
    }

    suspend fun respondToSafetyIncident(
        authorization: ManagedAuthorization,
        incidentId: UUID,
        responding: Boolean,
    ): ManagedSafetyIncident = withContext(Dispatchers.IO) {
        parseSafetyIncident(
            executeJson(
                apiRequest(
                    "v1/managed/safety/incidents/" +
                        "${incidentId.toString().lowercase()}/response",
                    authorization,
                ).post(
                    JSONObject()
                        .put(
                            "decision",
                            if (responding) "responding" else "cannot_respond",
                        )
                        .toString()
                        .toRequestBody(JSON),
                ).build(),
            ).requireObject("incident"),
        ).also {
            if (it.incidentId != incidentId) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
    }

    suspend fun endSafetyIncident(
        authorization: ManagedAuthorization,
        incidentId: UUID,
        resolved: Boolean,
    ): ManagedSafetyIncident = withContext(Dispatchers.IO) {
        parseSafetyIncident(
            executeJson(
                apiRequest(
                    "v1/managed/safety/incidents/" +
                        "${incidentId.toString().lowercase()}:end",
                    authorization,
                ).post(
                    JSONObject()
                        .put("outcome", if (resolved) "resolved" else "canceled")
                        .toString()
                        .toRequestBody(JSON),
                ).build(),
            ).requireObject("incident"),
        ).also {
            if (it.incidentId != incidentId) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
    }

    suspend fun retrySafetyPush(
        authorization: ManagedAuthorization,
        incidentId: UUID,
    ): ManagedSafetyDelivery = withContext(Dispatchers.IO) {
        parseSafetyDelivery(
            executeJson(
                apiRequest(
                    "v1/managed/safety/incidents/" +
                        "${incidentId.toString().lowercase()}:retry-push",
                    authorization,
                ).post(EMPTY_BODY).build(),
            ).requireObject("delivery"),
        )
    }

    suspend fun createSocialProfile(
        authorization: ManagedAuthorization,
        displayName: String,
        requestId: UUID,
    ): ManagedSocialProfile = withContext(Dispatchers.IO) {
        val normalized = displayName.trim()
        if (normalized.length !in 1..64) {
            throw IllegalArgumentException("Invalid managed Friends display name")
        }
        parseSocialProfile(
            executeJson(
                apiRequest("v1/managed/social/profile", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("display_name", normalized)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("profile"),
        )
    }

    suspend fun socialProfile(
        authorization: ManagedAuthorization,
    ): ManagedSocialProfile = withContext(Dispatchers.IO) {
        parseSocialProfile(
            executeJson(
                apiRequest("v1/managed/social/profile", authorization)
                    .get()
                    .build(),
            ).requireObject("profile"),
        )
    }

    suspend fun deleteSocialProfile(
        authorization: ManagedAuthorization,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest("v1/managed/social/profile", authorization)
                .header("X-Noop-Confirm", "DELETE MANAGED FRIENDS")
                .delete()
                .build(),
        )
    }

    suspend fun updateSocialProfile(
        authorization: ManagedAuthorization,
        patch: ManagedSocialProfilePatch,
    ): ManagedSocialProfile = withContext(Dispatchers.IO) {
        if (!patch.hasChange ||
            patch.displayName?.trim()?.length?.let { it !in 1..64 } == true ||
            patch.quietStartMinute?.let { it !in 0..1439 } == true ||
            patch.quietEndMinute?.let { it !in 0..1439 } == true ||
            patch.timeZone?.let { it.isBlank() || it.length > 64 } == true
        ) {
            throw IllegalArgumentException("Invalid managed Friends profile patch")
        }
        val body = JSONObject().apply {
            patch.displayName?.let { put("display_name", it.trim()) }
            patch.pokeOptIn?.let { put("poke_opt_in", it) }
            patch.quietStartMinute?.let { put("quiet_start_minute", it) }
            patch.quietEndMinute?.let { put("quiet_end_minute", it) }
            patch.timeZone?.let { put("time_zone", it) }
        }
        parseSocialProfile(
            executeJson(
                apiRequest("v1/managed/social/profile", authorization)
                    .patch(body.toString().toRequestBody(JSON))
                    .build(),
            ).requireObject("profile"),
        )
    }

    suspend fun rotateSocialNoopId(
        authorization: ManagedAuthorization,
    ): ManagedSocialProfile = withContext(Dispatchers.IO) {
        parseSocialProfile(
            executeJson(
                apiRequest("v1/managed/social/noop-id:rotate", authorization)
                    .post(EMPTY_BODY)
                    .build(),
            ).requireObject("profile"),
        )
    }

    suspend fun lookupSocialProfile(
        authorization: ManagedAuthorization,
        noopId: String,
    ): ManagedSocialLookupProfile = withContext(Dispatchers.IO) {
        val canonical = ManagedSocialIdentifier.canonicalNoopId(noopId)
            ?: throw IllegalArgumentException("Invalid NOOP ID")
        val row = executeJson(
            apiRequest(
                "v1/managed/social/lookup?noop_id=${queryValue(canonical)}",
                authorization,
            ).get().build(),
        ).requireObject("profile")
        val profile = ManagedSocialLookupProfile(
            profileId = uuidOrThrow(row.optString("profile_id")),
            displayName = row.optString("display_name").requiredText(),
            noopId = row.optString("noop_id"),
            isSelf = row.requiredBoolean("self"),
        )
        if (profile.displayName.length > 64 ||
            ManagedSocialIdentifier.canonicalNoopId(profile.noopId) != profile.noopId
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        profile
    }

    suspend fun createSocialInvite(
        authorization: ManagedAuthorization,
        capability: String,
        requestId: UUID,
        expiresInHours: Int = 72,
    ): ManagedSocialInvite = withContext(Dispatchers.IO) {
        if (!ManagedSocialIdentifier.invitePattern.matches(capability) ||
            expiresInHours !in 1..168
        ) {
            throw IllegalArgumentException("Invalid managed Friends invitation")
        }
        val invite = parseSocialInvite(
            executeJson(
                apiRequest("v1/managed/social/invites", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("capability", capability)
                            .put("expires_in_hours", expiresInHours)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("invite"),
        )
        if (invite.capability != capability) {
            throw ManagedStorageException.InvalidResponse()
        }
        invite
    }

    suspend fun revokeSocialInvite(
        authorization: ManagedAuthorization,
        inviteId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest(
                "v1/managed/social/invites/${inviteId.toString().lowercase()}",
                authorization,
            ).delete().build(),
        )
    }

    suspend fun redeemSocialInvite(
        authorization: ManagedAuthorization,
        capability: String,
        requestId: UUID,
    ): ManagedSocialRequest = withContext(Dispatchers.IO) {
        if (!ManagedSocialIdentifier.invitePattern.matches(capability)) {
            throw IllegalArgumentException("Invalid managed Friends invitation")
        }
        parseSocialRequest(
            executeJson(
                apiRequest("v1/managed/social/invites:redeem", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("capability", capability)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("request"),
        )
    }

    suspend fun createSocialRequest(
        authorization: ManagedAuthorization,
        noopId: String,
        requestId: UUID,
    ): ManagedSocialRequest = withContext(Dispatchers.IO) {
        val canonical = ManagedSocialIdentifier.canonicalNoopId(noopId)
            ?: throw IllegalArgumentException("Invalid NOOP ID")
        parseSocialRequest(
            executeJson(
                apiRequest("v1/managed/social/requests", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put("noop_id", canonical)
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("request"),
        )
    }

    suspend fun socialRequests(
        authorization: ManagedAuthorization,
    ): List<ManagedSocialRequest> = withContext(Dispatchers.IO) {
        val rows = executeJson(
            apiRequest("v1/managed/social/requests", authorization)
                .get()
                .build(),
        ).requireArray("requests")
        if (rows.length() > 100) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                add(parseSocialRequest(rows.requireObject(index)))
            }
        }
    }

    suspend fun decideSocialRequest(
        authorization: ManagedAuthorization,
        requestId: UUID,
        accept: Boolean,
    ): ManagedSocialRequest = withContext(Dispatchers.IO) {
        parseSocialRequest(
            executeJson(
                apiRequest(
                    "v1/managed/social/requests/${requestId.toString().lowercase()}",
                    authorization,
                ).post(
                    JSONObject()
                        .put("decision", if (accept) "accept" else "decline")
                        .toString()
                        .toRequestBody(JSON),
                ).build(),
            ).requireObject("request"),
        )
    }

    suspend fun socialFriends(
        authorization: ManagedAuthorization,
    ): List<ManagedSocialFriend> = withContext(Dispatchers.IO) {
        val rows = executeJson(
            apiRequest("v1/managed/social/friends", authorization)
                .get()
                .build(),
        ).requireArray("friends")
        if (rows.length() > 500) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                add(parseSocialFriend(rows.requireObject(index)))
            }
        }
    }

    suspend fun updateSocialVisibility(
        authorization: ManagedAuthorization,
        friendProfileId: UUID,
        patch: ManagedSocialVisibilityPatch,
    ): ManagedSocialVisibility = withContext(Dispatchers.IO) {
        if (!patch.hasChange) {
            throw IllegalArgumentException("Managed Friends privacy patch is empty")
        }
        val body = JSONObject().apply {
            patch.charge?.let { put("charge", it) }
            patch.effort?.let { put("effort", it) }
            patch.rest?.let { put("rest", it) }
            patch.sleepDuration?.let { put("sleep_duration", it) }
            patch.hrv?.let { put("hrv", it) }
            patch.rhr?.let { put("rhr", it) }
            patch.pokeAllowed?.let { put("poke_allowed", it) }
        }
        parseSocialVisibility(
            executeJson(
                apiRequest(
                    "v1/managed/social/friends/" +
                        "${friendProfileId.toString().lowercase()}/privacy",
                    authorization,
                ).patch(body.toString().toRequestBody(JSON)).build(),
            ).requireObject("sharing"),
        )
    }

    suspend fun removeSocialFriend(
        authorization: ManagedAuthorization,
        profileId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest(
                "v1/managed/social/friends/${profileId.toString().lowercase()}",
                authorization,
            ).delete().build(),
        )
    }

    suspend fun blockSocialProfile(
        authorization: ManagedAuthorization,
        profileId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest(
                "v1/managed/social/blocks/${profileId.toString().lowercase()}",
                authorization,
            ).post(EMPTY_BODY).build(),
        )
    }

    suspend fun socialBlockedProfiles(
        authorization: ManagedAuthorization,
    ): List<ManagedSocialBlockedProfile> = withContext(Dispatchers.IO) {
        val rows = executeJson(
            apiRequest("v1/managed/social/blocks", authorization)
                .get()
                .build(),
        ).requireArray("blocks")
        if (rows.length() > 500) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                add(parseSocialBlockedProfile(rows.requireObject(index)))
            }
        }
    }

    suspend fun unblockSocialProfile(
        authorization: ManagedAuthorization,
        profileId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        executeNoContent(
            apiRequest(
                "v1/managed/social/blocks/${profileId.toString().lowercase()}",
                authorization,
            ).delete().build(),
        )
    }

    suspend fun putSocialSummary(
        authorization: ManagedAuthorization,
        day: String,
        summary: ManagedSocialSummary,
        requestId: UUID,
    ): Unit = withContext(Dispatchers.IO) {
        if (!isDay(day) || !valid(summary)) {
            throw IllegalArgumentException("Invalid managed Friends summary")
        }
        val body = JSONObject()
            .put("request_id", requestId.toString())
            .put("summary", socialSummaryJson(summary))
        val response = executeJson(
            apiRequest("v1/managed/social/summaries/$day", authorization)
                .put(body.toString().toRequestBody(JSON))
                .build(),
        )
        if (!response.has("summary")) throw ManagedStorageException.InvalidResponse()
    }

    suspend fun socialFeed(
        authorization: ManagedAuthorization,
        startDay: String,
        endDay: String,
    ): List<ManagedSocialFeedDay> = withContext(Dispatchers.IO) {
        if (!isDay(startDay) || !isDay(endDay)) {
            throw IllegalArgumentException("Invalid managed Friends feed range")
        }
        val response = executeJson(
            apiRequest(
                "v1/managed/social/feed?start=$startDay&end=$endDay",
                authorization,
            ).get().build(),
        )
        if (response.optString("start") != startDay ||
            response.optString("end") != endDay
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        val rows = response.requireArray("days")
        if (rows.length() > 45_000) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                val row = rows.requireObject(index)
                val day = row.optString("day")
                val displayName = row.optString("display_name").requiredText()
                if (!isDay(day) || displayName.length > 64) {
                    throw ManagedStorageException.InvalidResponse()
                }
                add(
                    ManagedSocialFeedDay(
                        profileId = uuidOrThrow(row.optString("profile_id")),
                        displayName = displayName,
                        day = day,
                        summary = parseSocialSummary(row.requireObject("summary")),
                    ),
                )
            }
        }
    }

    suspend fun createSocialPoke(
        authorization: ManagedAuthorization,
        recipientProfileId: UUID,
        requestId: UUID,
    ): ManagedSocialPoke = withContext(Dispatchers.IO) {
        val poke = parseSocialPoke(
            executeJson(
                apiRequest("v1/managed/social/pokes", authorization)
                    .post(
                        JSONObject()
                            .put("request_id", requestId.toString())
                            .put(
                                "recipient_profile_id",
                                recipientProfileId.toString(),
                            )
                            .toString()
                            .toRequestBody(JSON),
                    )
                    .build(),
            ).requireObject("poke"),
        )
        if (poke.recipientProfileId != recipientProfileId ||
            poke.status != "queued"
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        poke
    }

    suspend fun claimSocialPokes(
        authorization: ManagedAuthorization,
        limit: Int = 3,
    ): List<ManagedSocialPokeClaim> = withContext(Dispatchers.IO) {
        if (limit !in 1..10) throw IllegalArgumentException("Invalid poke claim limit")
        val rows = executeJson(
            apiRequest(
                "v1/managed/social/pokes:claim?limit=$limit",
                authorization,
            ).post(EMPTY_BODY).build(),
        ).requireArray("pokes")
        if (rows.length() > limit) throw ManagedStorageException.InvalidResponse()
        buildList {
            for (index in 0 until rows.length()) {
                add(parseSocialPokeClaim(rows.requireObject(index)))
            }
        }
    }

    suspend fun acknowledgeSocialPoke(
        authorization: ManagedAuthorization,
        pokeId: UUID,
        acknowledgement: ManagedSocialPokeAcknowledgement,
    ): ManagedSocialPokeReceipt = withContext(Dispatchers.IO) {
        if (acknowledgement.notificationOutcome !in NOTIFICATION_OUTCOMES ||
            acknowledgement.hapticOutcome !in HAPTIC_OUTCOMES
        ) {
            throw IllegalArgumentException("Invalid managed poke acknowledgement")
        }
        val row = executeJson(
            apiRequest(
                "v1/managed/social/pokes/${pokeId.toString().lowercase()}:ack",
                authorization,
            ).post(
                JSONObject()
                    .put("claim_id", acknowledgement.claimId.toString())
                    .put(
                        "notification_outcome",
                        acknowledgement.notificationOutcome,
                    )
                    .put("haptic_outcome", acknowledgement.hapticOutcome)
                    .toString()
                    .toRequestBody(JSON),
            ).build(),
        ).requireObject("poke")
        val receipt = ManagedSocialPokeReceipt(
            pokeId = uuidOrThrow(row.optString("poke_id")),
            status = row.optString("status"),
            duplicate = row.optBoolean("duplicate", false),
            notificationOutcome = row.optString("notification_outcome"),
            hapticOutcome = row.optString("haptic_outcome"),
        )
        if (receipt.pokeId != pokeId ||
            receipt.status != "acknowledged" ||
            receipt.notificationOutcome != acknowledgement.notificationOutcome ||
            receipt.hapticOutcome != acknowledgement.hapticOutcome
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        receipt
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
                "v1/managed/changes?after_sequence=$afterSequence&limit=$limit" +
                    "&document_kind=${ManagedDocumentKind.DAY_OWNERSHIP.wireValue}",
                authorization,
            ).get().build(),
        )
        val rows = response.optJSONArray("changes")
            ?: throw ManagedStorageException.InvalidResponse()
        val changes = buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index)
                    ?: throw ManagedStorageException.InvalidResponse()
                val change = parseChange(row)
                if (change.resourceKind == "document" &&
                    change.document?.documentKind != ManagedDocumentKind.DAY_OWNERSHIP
                ) {
                    throw ManagedStorageException.InvalidResponse()
                }
                add(change)
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
            .put(
                "document_kinds",
                JSONArray(listOf(ManagedDocumentKind.DAY_OWNERSHIP.wireValue)),
            )
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
        val document = parseDocument(
            executeJson(
                apiRequest(
                    "v1/managed/documents/${kind.wireValue}/$id$query",
                    authorization,
                ).get().build(),
            ).optJSONObject("document")
                ?: throw ManagedStorageException.InvalidResponse(),
        )
        if (document.documentKind != kind ||
            document.documentId != id ||
            revision != null && document.revision != revision
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        document
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
            add("document_kind=${ManagedDocumentKind.DAY_OWNERSHIP.wireValue}")
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
                if (document.deletedAt != null) {
                    throw ManagedStorageException.InvalidResponse()
                }
                if (document.documentKind != ManagedDocumentKind.DAY_OWNERSHIP) {
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
                sourceId = it.optionalText("source_id")?.let(::uuidOrThrow),
                schemaVersion = it.optInt("schema_version").takeIf { value -> value > 0 },
                contentMode = it.optionalText("content_mode"),
                state = it.optionalText("state"),
                compression = it.optionalText("compression"),
                contentType = it.optionalText("content_type"),
                expectedCompressedBytes = it.optInt("expected_compressed_bytes")
                    .takeIf { value -> value > 0 },
                expectedUncompressedBytes = it.optInt("expected_uncompressed_bytes")
                    .takeIf { value -> value > 0 },
                objectGeneration = it.optLong("object_generation").takeIf { value -> value > 0 },
                expiresAt = it.optionalText("expires_at"),
            )
        }
        val document = row.optJSONObject("document")?.let {
            ManagedChangedDocument(
                documentKind = ManagedDocumentKind.fromWire(it.optString("document_kind")),
                documentId = uuidOrThrow(it.optString("document_id")),
                revision = it.requiredLong("revision"),
                contentMode = it.optString("content_mode"),
                clientKeyId = it.optionalText("client_key_id")?.let(::uuidOrThrow),
                updatedAt = it.optString("updated_at").requiredInstant(),
                deletedAt = it.optionalText("deleted_at")?.requiredInstant(),
            ).also { parsed ->
                val expectedContentMode =
                    expectedDocumentContentMode(parsed.documentKind)
                val deleted = parsed.deletedAt != null
                val validClientKey = when {
                    deleted -> parsed.clientKeyId == null
                    expectedContentMode == "server_readable" ->
                        parsed.clientKeyId == null
                    else -> parsed.clientKeyId != null
                }
                if (parsed.revision <= 0L ||
                    parsed.contentMode != expectedContentMode ||
                    !validClientKey
                ) {
                    throw ManagedStorageException.InvalidResponse()
                }
            }
        }
        val change = ManagedChange(
            sequence = row.requiredLong("sequence"),
            resourceKind = row.optString("resource_kind"),
            resourceId = uuidOrThrow(row.optString("resource_id")),
            operation = row.optString("operation"),
            contentSha256 = row.optionalText("content_sha256"),
            dataClass = row.optionalText("data_class"),
            eventStart = row.optionalText("event_start"),
            eventEnd = row.optionalText("event_end"),
            chunk = chunk,
            document = document,
        )
        if ((change.resourceKind == "document") != (document != null)) {
            throw ManagedStorageException.InvalidResponse()
        }
        if (document != null) {
            val deleted = document.deletedAt != null
            val validDigest = if (deleted) {
                change.contentSha256 == ManagedDigest.sha256(
                    (
                        "deleted:${document.documentKind.wireValue}:" +
                            "${document.documentId.toString().lowercase()}:" +
                            document.revision
                        ).toByteArray(StandardCharsets.UTF_8),
                )
            } else {
                change.contentSha256?.matches(SHA256) == true
            }
            if (change.resourceKind != "document" ||
                change.resourceId != document.documentId ||
                change.chunk != null ||
                !validDigest ||
                (!deleted && change.operation != "upsert") ||
                (deleted && change.operation != "tombstone")
            ) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
        return change
    }

    private fun parseDocument(value: JSONObject): ManagedDocument {
        val payload = when {
            !value.has("payload_json") || value.isNull("payload_json") -> null
            else -> value.optJSONObject("payload_json")
                ?: throw ManagedStorageException.InvalidResponse()
        }
        val deletedAt = value.optionalText("deleted_at")?.requiredInstant()
        val document = ManagedDocument(
            documentKind = ManagedDocumentKind.fromWire(value.optString("document_kind")),
            documentId = uuidOrThrow(value.optString("document_id")),
            revision = value.requiredLong("revision"),
            originInstallationId = value.optString("origin_installation_id"),
            contentMode = value.optString("content_mode"),
            clientKeyId = value.optionalText("client_key_id")?.let(::uuidOrThrow),
            contentSha256 = value.optString("content_sha256"),
            payloadJson = payload,
            payloadCiphertextBase64 = value.optionalText("payload_ciphertext_base64"),
            updatedAt = value.optString("updated_at").requiredInstant(),
            deletedAt = deletedAt,
            duplicate = value.optBoolean("duplicate", false),
        )
        val expectedContentMode =
            expectedDocumentContentMode(document.documentKind)
        if (document.revision <= 0L ||
            !document.originInstallationId.matches(INSTALLATION_ID) ||
            document.contentMode != expectedContentMode ||
            !document.contentSha256.matches(SHA256) ||
            !validDocumentPayload(document)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return document
    }

    private fun validDocumentPayload(document: ManagedDocument): Boolean {
        if (document.deletedAt != null) {
            return document.clientKeyId == null &&
                document.payloadJson == null &&
                document.payloadCiphertextBase64 == null &&
                document.contentSha256 == deletionDigest(document)
        }
        if (document.contentMode == "server_readable") {
            val payload = document.payloadJson ?: return false
            if (document.clientKeyId != null || document.payloadCiphertextBase64 != null) {
                return false
            }
            val canonical = ManagedCanonicalJson.encode(payload)
                .toByteArray(StandardCharsets.UTF_8)
            return canonical.size <= MAX_DOCUMENT_BYTES &&
                ManagedDigest.sha256(canonical) == document.contentSha256
        }

        val encoded = document.payloadCiphertextBase64 ?: return false
        val ciphertext = runCatching { Base64.getDecoder().decode(encoded) }
            .getOrNull() ?: return false
        return document.clientKeyId != null &&
            document.payloadJson == null &&
            Base64.getEncoder().encodeToString(ciphertext) == encoded &&
            ciphertext.size in MIN_ENCRYPTED_DOCUMENT_BYTES..MAX_ENCRYPTED_DOCUMENT_BYTES &&
            ManagedDigest.sha256(ciphertext) == document.contentSha256
    }

    private fun deletionDigest(document: ManagedDocument): String =
        ManagedDigest.sha256(
            (
                "deleted:${document.documentKind.wireValue}:" +
                    "${document.documentId.toString().lowercase()}:${document.revision}"
                ).toByteArray(StandardCharsets.UTF_8),
        )

    private fun expectedDocumentContentMode(kind: ManagedDocumentKind): String =
        if (kind == ManagedDocumentKind.DAY_OWNERSHIP) {
            "server_readable"
        } else {
            "client_encrypted"
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

    private fun parseSafetyInvite(value: JSONObject): ManagedSafetyInvite {
        val invite = ManagedSafetyInvite(
            inviteId = uuidOrThrow(value.optString("invite_id")),
            capability = value.optString("capability"),
            status = value.optString("status"),
            createdAt = value.optString("created_at").requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (!ManagedSafetyIdentifier.invitePattern.matches(invite.capability) ||
            invite.status !in setOf("active", "revoked", "redeemed", "expired")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return invite
    }

    private fun parseSafetyRequest(value: JSONObject): ManagedSafetyRequest {
        val request = ManagedSafetyRequest(
            requestId = uuidOrThrow(value.optString("request_id")),
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            direction = value.optString("direction"),
            source = value.optString("source"),
            status = value.optString("status"),
            createdAt = value.optString("created_at").requiredInstant(),
            decidedAt = value.optionalText("decided_at")?.requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (request.displayName.length > 64 ||
            request.direction !in setOf("incoming", "outgoing") ||
            request.source !in setOf("noop_id", "invite") ||
            request.status !in SAFETY_REQUEST_STATUSES ||
            (request.status == "pending") != (request.decidedAt == null)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return request
    }

    private fun parseSafetyContact(value: JSONObject): ManagedSafetyContact {
        val contact = ManagedSafetyContact(
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            role = value.optString("role"),
            acceptedAt = value.optString("accepted_at").requiredInstant(),
        )
        if (contact.displayName.length > 64 ||
            contact.role !in setOf("contact", "owner")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return contact
    }

    private fun parseSafetyLocation(value: JSONObject): ManagedSafetyLocation {
        val location = ManagedSafetyLocation(
            sequence = value.requiredLong("sequence"),
            latitude = value.optionalFiniteDouble("latitude")
                ?: throw ManagedStorageException.InvalidResponse(),
            longitude = value.optionalFiniteDouble("longitude")
                ?: throw ManagedStorageException.InvalidResponse(),
            horizontalAccuracyM = value.optionalFiniteDouble(
                "horizontal_accuracy_m",
            ) ?: throw ManagedStorageException.InvalidResponse(),
            capturedAt = value.optString("captured_at").requiredInstant(),
            receivedAt = value.optString("received_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (location.sequence <= 0L ||
            location.latitude !in -90.0..90.0 ||
            location.longitude !in -180.0..180.0 ||
            location.horizontalAccuracyM !in 0.0..10_000.0
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return location
    }

    private fun parseSafetyParticipant(value: JSONObject): ManagedSafetyParticipant {
        val push = value.requireObject("push")
        val participant = ManagedSafetyParticipant(
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            status = value.optString("status"),
            pagedAt = value.optString("paged_at").requiredInstant(),
            respondedAt = value.optionalText("responded_at")?.requiredInstant(),
            push = ManagedSafetyPushStatus(
                configured = push.requiredBoolean("configured"),
                reached = push.requiredBoolean("reached"),
            ),
        )
        if (participant.displayName.length > 64 ||
            participant.status !in SAFETY_PARTICIPANT_STATUSES ||
            (participant.status == "pending") !=
            (participant.respondedAt == null) ||
            participant.push.reached && !participant.push.configured
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return participant
    }

    private fun parseSafetyDelivery(value: JSONObject): ManagedSafetyDelivery {
        val installationsTargeted = value.requiredNonnegativeInt(
            "installations_targeted",
        )
        val installationsReached = value.requiredNonnegativeInt(
            "installations_reached",
        )
        val delivery = ManagedSafetyDelivery(
            contactsTargeted = value.requiredNonnegativeInt("contacts_targeted"),
            contactsReached = value.requiredNonnegativeInt("contacts_reached"),
            installationsTargeted = installationsTargeted,
            installationsReached = installationsReached,
            installationsRetryable = if (value.has("installations_retryable")) {
                value.requiredNonnegativeInt("installations_retryable")
            } else {
                (installationsTargeted - installationsReached).coerceAtLeast(0)
            },
            installationsTerminal = if (value.has("installations_terminal")) {
                value.requiredNonnegativeInt("installations_terminal")
            } else {
                0
            },
        )
        if (delivery.contactsReached > delivery.contactsTargeted ||
            delivery.installationsReached > delivery.installationsTargeted ||
            delivery.contactsReached > delivery.installationsReached ||
            delivery.installationsReached + delivery.installationsRetryable +
            delivery.installationsTerminal > delivery.installationsTargeted
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return delivery
    }

    private fun parseSafetyIncident(value: JSONObject): ManagedSafetyIncident {
        val participantsJson = value.requireArray("participants")
        val participants = buildList {
            for (index in 0 until participantsJson.length()) {
                add(parseSafetyParticipant(participantsJson.requireObject(index)))
            }
        }
        val incident = ManagedSafetyIncident(
            incidentId = uuidOrThrow(value.optString("incident_id")),
            role = value.optString("role"),
            ownerProfileId = uuidOrThrow(value.optString("owner_profile_id")),
            ownerDisplayName = value.optString("owner_display_name").requiredText(),
            trigger = value.optString("trigger"),
            status = value.optString("status"),
            durationHours = value.requiredNonnegativeInt("duration_hours"),
            shareLocation = value.requiredBoolean("share_location"),
            createdAt = value.optString("created_at").requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            acknowledgedAt = value.optionalText("acknowledged_at")
                ?.requiredInstant(),
            endedAt = value.optionalText("ended_at")?.requiredInstant(),
            participants = participants,
            location = value.optJSONObject("location")?.let(::parseSafetyLocation),
            delivery = value.optJSONObject("delivery")?.let(::parseSafetyDelivery),
            duplicate = value.optBoolean("duplicate", false),
        )
        val active = incident.status in setOf("open", "acknowledged")
        val terminal = incident.status in setOf(
            "resolved",
            "canceled",
            "expired",
        )
        val countIsValid = if (incident.role == "owner") {
            incident.participants.size in 0..5
        } else {
            incident.participants.size == 1
        }
        if (incident.role !in setOf("owner", "contact") ||
            incident.ownerDisplayName.length > 64 ||
            incident.trigger !in setOf("manual_sos", "band_sos") ||
            (!active && !terminal) ||
            incident.durationHours !in setOf(8, 12) ||
            !countIsValid ||
            incident.participants.map { it.profileId }.toSet().size !=
            incident.participants.size ||
            (!incident.shareLocation && incident.location != null) ||
            (terminal && incident.location != null) ||
            (incident.status == "open" && incident.acknowledgedAt != null) ||
            (incident.status == "acknowledged" &&
                incident.acknowledgedAt == null) ||
            active != (incident.endedAt == null) ||
            (incident.role == "owner" && incident.delivery == null) ||
            (incident.role == "contact" && incident.delivery != null)
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return incident
    }

    private fun parseSocialProfile(value: JSONObject): ManagedSocialProfile {
        val badges = parseSocialBadges(value.optJSONArray("badges") ?: JSONArray())
        val profile = ManagedSocialProfile(
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            noopId = value.optString("noop_id"),
            pokeOptIn = value.requiredBoolean("poke_opt_in"),
            quietStartMinute = value.requiredNonnegativeInt("quiet_start_minute"),
            quietEndMinute = value.requiredNonnegativeInt("quiet_end_minute"),
            timeZone = value.optString("time_zone").requiredText(),
            createdAt = value.optString("created_at").requiredInstant(),
            updatedAt = value.optString("updated_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
            badges = badges,
        )
        if (profile.displayName.length > 64 ||
            ManagedSocialIdentifier.canonicalNoopId(profile.noopId) != profile.noopId ||
            profile.quietStartMinute !in 0..1439 ||
            profile.quietEndMinute !in 0..1439 ||
            profile.timeZone.length > 64
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return profile
    }

    private fun parseSocialBadges(values: JSONArray): List<ManagedSocialBadge> {
        if (values.length() > 3) throw ManagedStorageException.InvalidResponse()
        return buildList {
            for (index in 0 until values.length()) {
                val row = values.requireObject(index)
                val badge = ManagedSocialBadge(
                    code = row.optString("code"),
                    earnedAt = row.optString("earned_at").requiredInstant(),
                )
                if (badge.code !in SOCIAL_BADGES) {
                    throw ManagedStorageException.InvalidResponse()
                }
                add(badge)
            }
        }
    }

    private fun parseSocialInvite(value: JSONObject): ManagedSocialInvite {
        val invite = ManagedSocialInvite(
            inviteId = uuidOrThrow(value.optString("invite_id")),
            capability = value.optString("capability"),
            status = value.optString("status"),
            createdAt = value.optString("created_at").requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (!ManagedSocialIdentifier.invitePattern.matches(invite.capability) ||
            invite.status !in setOf("active", "revoked", "redeemed", "expired")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return invite
    }

    private fun parseSocialRequest(value: JSONObject): ManagedSocialRequest {
        val request = ManagedSocialRequest(
            requestId = uuidOrThrow(value.optString("request_id")),
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            direction = value.optString("direction"),
            source = value.optString("source"),
            status = value.optString("status"),
            createdAt = value.optString("created_at").requiredInstant(),
            decidedAt = value.optString("decided_at")
                .takeIf(String::isNotBlank)
                ?.requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (request.displayName.length > 64 ||
            request.direction !in setOf("incoming", "outgoing") ||
            request.source !in setOf("noop_id", "invite") ||
            request.status !in setOf("pending", "accepted", "declined")
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return request
    }

    private fun parseSocialFriend(value: JSONObject): ManagedSocialFriend {
        val latest = value.optJSONObject("latest")?.let { row ->
            val day = row.optString("day")
            if (!isDay(day)) throw ManagedStorageException.InvalidResponse()
            ManagedSocialLatestSummary(
                day = day,
                summary = parseSocialSummary(row.requireObject("summary")),
            )
        }
        val friend = ManagedSocialFriend(
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            friendsSince = value.optString("friends_since").requiredInstant(),
            sharing = parseSocialVisibility(value.requireObject("sharing")),
            sharedWithMe = parseSocialVisibility(
                value.requireObject("shared_with_me"),
            ),
            latest = latest,
            badges = parseSocialBadges(
                value.optJSONArray("badges") ?: JSONArray(),
            ),
        )
        if (friend.displayName.length > 64) {
            throw ManagedStorageException.InvalidResponse()
        }
        return friend
    }

    private fun parseSocialBlockedProfile(
        value: JSONObject,
    ): ManagedSocialBlockedProfile {
        val blocked = ManagedSocialBlockedProfile(
            profileId = uuidOrThrow(value.optString("profile_id")),
            displayName = value.optString("display_name").requiredText(),
            blockedAt = value.optString("blocked_at").requiredInstant(),
        )
        if (blocked.displayName.length > 64) {
            throw ManagedStorageException.InvalidResponse()
        }
        return blocked
    }

    private fun parseSocialVisibility(value: JSONObject): ManagedSocialVisibility =
        ManagedSocialVisibility(
            charge = value.requiredBoolean("charge"),
            effort = value.requiredBoolean("effort"),
            rest = value.requiredBoolean("rest"),
            sleepDuration = value.requiredBoolean("sleep_duration"),
            hrv = value.requiredBoolean("hrv"),
            rhr = value.requiredBoolean("rhr"),
            pokeAllowed = value.requiredBoolean("poke_allowed"),
        )

    private fun parseSocialSummary(value: JSONObject): ManagedSocialSummary {
        val supported = setOf(
            "charge",
            "effort",
            "rest",
            "sleep_duration",
            "hrv",
            "rhr",
        )
        if (value.keys().asSequence().any { it !in supported }) {
            throw ManagedStorageException.InvalidResponse()
        }
        val summary = ManagedSocialSummary(
            charge = value.optionalFiniteDouble("charge"),
            effort = value.optionalFiniteDouble("effort"),
            rest = value.optionalFiniteDouble("rest"),
            sleepDuration = value.optionalFiniteDouble("sleep_duration"),
            hrv = value.optionalFiniteDouble("hrv"),
            rhr = value.optionalFiniteDouble("rhr"),
        )
        if (!valid(summary)) throw ManagedStorageException.InvalidResponse()
        return summary
    }

    private fun socialSummaryJson(summary: ManagedSocialSummary): JSONObject =
        JSONObject().apply {
            summary.charge?.let { put("charge", it) }
            summary.effort?.let { put("effort", it) }
            summary.rest?.let { put("rest", it) }
            summary.sleepDuration?.let { put("sleep_duration", it) }
            summary.hrv?.let { put("hrv", it) }
            summary.rhr?.let { put("rhr", it) }
        }

    private fun parseSocialPoke(value: JSONObject): ManagedSocialPoke {
        val poke = ManagedSocialPoke(
            pokeId = uuidOrThrow(value.optString("poke_id")),
            recipientProfileId = uuidOrThrow(
                value.optString("recipient_profile_id"),
            ),
            recipientDisplayName = value.optString(
                "recipient_display_name",
            ).requiredText(),
            status = value.optString("status"),
            createdAt = value.optString("created_at").requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            duplicate = value.optBoolean("duplicate", false),
        )
        if (poke.recipientDisplayName.length > 64) {
            throw ManagedStorageException.InvalidResponse()
        }
        return poke
    }

    private fun parseSocialPokeClaim(value: JSONObject): ManagedSocialPokeClaim {
        val claim = ManagedSocialPokeClaim(
            pokeId = uuidOrThrow(value.optString("poke_id")),
            claimId = uuidOrThrow(value.optString("claim_id")),
            senderProfileId = uuidOrThrow(value.optString("sender_profile_id")),
            senderDisplayName = value.optString("sender_display_name").requiredText(),
            createdAt = value.optString("created_at").requiredInstant(),
            expiresAt = value.optString("expires_at").requiredInstant(),
            claimExpiresAt = value.optString("claim_expires_at").requiredInstant(),
        )
        if (claim.senderDisplayName.length > 64) {
            throw ManagedStorageException.InvalidResponse()
        }
        return claim
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

    private fun executeNoContent(request: Request) {
        val response = execute(request)
        response.use {
            val body = runCatching { it.body?.string().orEmpty() }.getOrDefault("")
            if (!it.isSuccessful) throw serverError(it.code, body)
            if (it.code !in setOf(200, 202, 204) || body.isNotBlank()) {
                throw ManagedStorageException.InvalidResponse()
            }
        }
    }

    private fun execute(request: Request): okhttp3.Response {
        val startedAt = System.nanoTime()
        return try {
            http.newCall(request).execute().also { response ->
                observe(
                    request = request,
                    statusCode = response.code,
                    requestId = response.header("X-Noop-Request-ID"),
                    startedAt = startedAt,
                    outcome = if (response.isSuccessful) "completed" else "rejected",
                )
            }
        } catch (error: IOException) {
            observe(
                request = request,
                statusCode = null,
                requestId = null,
                startedAt = startedAt,
                outcome = "transport_failed",
            )
            throw ManagedStorageException.Network(error)
        }
    }

    private fun observe(
        request: Request,
        statusCode: Int?,
        requestId: String?,
        startedAt: Long,
        outcome: String,
    ) {
        val base = configuration.baseUrl.toHttpUrlOrNull()
        val managedApi = base != null &&
            request.url.scheme.equals(base.scheme, ignoreCase = true) &&
            request.url.host.equals(base.host, ignoreCase = true) &&
            request.url.port == base.port
        val routeGroup = if (managedApi) {
            "/" + request.url.pathSegments.take(3).joinToString("/")
        } else {
            "object_store"
        }
        val boundedRequestId = requestId?.takeIf { it.matches(REQUEST_ID) }
        runCatching {
            requestObserver(
                ManagedStorageRequestDiagnostic(
                    target = if (managedApi) "managed_api" else "object_store",
                    routeGroup = routeGroup,
                    method = request.method.uppercase(),
                    statusCode = statusCode,
                    durationMilliseconds = (
                        (System.nanoTime() - startedAt).coerceAtLeast(0L) /
                            1_000_000L
                        ),
                    requestId = boundedRequestId,
                    outcome = outcome,
                ),
            )
        }
    }

    private fun serverError(statusCode: Int, body: String): ManagedStorageException = when (statusCode) {
        401 -> ManagedStorageException.Authentication()
        403 -> ManagedStorageException.Forbidden()
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

    private fun JSONObject.requiredBoolean(name: String): Boolean {
        if (!has(name) || isNull(name) || get(name) !is Boolean) {
            throw ManagedStorageException.InvalidResponse()
        }
        return getBoolean(name)
    }

    private fun JSONObject.optionalText(name: String): String? {
        if (!has(name) || isNull(name)) return null
        return runCatching { getString(name) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
            .trim()
            .takeIf(String::isNotEmpty)
    }

    private fun JSONObject.optionalFiniteDouble(name: String): Double? {
        if (!has(name) || isNull(name)) return null
        val value = runCatching { getDouble(name) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
        return value.takeIf(Double::isFinite)
            ?: throw ManagedStorageException.InvalidResponse()
    }

    private fun JSONObject.requireObject(name: String): JSONObject =
        optJSONObject(name) ?: throw ManagedStorageException.InvalidResponse()

    private fun JSONObject.requireArray(name: String): JSONArray =
        optJSONArray(name) ?: throw ManagedStorageException.InvalidResponse()

    private fun JSONArray.requireObject(index: Int): JSONObject =
        optJSONObject(index) ?: throw ManagedStorageException.InvalidResponse()

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

    private fun valid(summary: ManagedSocialSummary): Boolean =
        listOf(
            summary.charge to 0.0..100.0,
            summary.effort to 0.0..100.0,
            summary.rest to 0.0..100.0,
            summary.sleepDuration to 0.0..2_880.0,
            summary.hrv to 0.0..1_000.0,
            summary.rhr to 20.0..260.0,
        ).all { (value, range) ->
            value == null || value.isFinite() && value in range
        }

    private fun isDay(value: String): Boolean =
        value.matches(Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) &&
            runCatching { java.time.LocalDate.parse(value) }.isSuccess

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val EMPTY_BODY = ByteArray(0).toRequestBody(null)
        private val CRC32C = Regex("^[A-Za-z0-9+/]{6}==$")
        private val REQUEST_ID = Regex("^[0-9a-f]{32}$")
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val DATA_CLASS = Regex("^[a-z][a-z0-9_]{1,63}$")
        private val INSTALLATION_ID =
            Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
        private val PUSH_TOKEN = Regex("^[A-Za-z0-9:_-]{16,4096}$")
        private val PUSH_OUTCOMES =
            setOf("attempted", "deferred", "not_configured")
        private val SAFETY_REQUEST_STATUSES =
            setOf("pending", "accepted", "declined", "canceled", "expired")
        private val SAFETY_PARTICIPANT_STATUSES =
            setOf("pending", "responding", "cannot_respond", "revoked")
        private val SOCIAL_BADGES = setOf("connected", "steady_week", "steady_month")
        private val NOTIFICATION_OUTCOMES =
            setOf("scheduled", "not_authorized", "failed")
        private val HAPTIC_OUTCOMES =
            setOf("requested", "band_unavailable", "not_eligible", "failed")
        private const val MAX_DOCUMENT_BYTES = 1_000_000
        private const val MIN_ENCRYPTED_DOCUMENT_BYTES = 17
        private const val MAX_ENCRYPTED_DOCUMENT_BYTES = 1_048_576

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
