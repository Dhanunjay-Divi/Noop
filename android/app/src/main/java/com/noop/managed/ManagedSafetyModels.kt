package com.noop.managed

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID

enum class ManagedPushEnvironment(val wireValue: String) {
    DEVELOPMENT("development"),
    PRODUCTION("production"),
}

enum class ManagedPushTargetKind(val wireValue: String) {
    TOKEN("token"),
    FID("fid"),
}

data class ManagedPushRegistrationInfo(
    val installationId: String,
    val platform: String,
    val environment: String,
    val targetKind: String,
    val status: String,
    val updatedAt: String,
    val duplicate: Boolean,
)

data class ManagedSafetyInvite(
    val inviteId: UUID,
    val capability: String,
    val status: String,
    val createdAt: String,
    val expiresAt: String,
    val duplicate: Boolean = false,
)

data class ManagedSafetyRequest(
    val requestId: UUID,
    val profileId: UUID,
    val displayName: String,
    val direction: String,
    val source: String,
    val status: String,
    val createdAt: String,
    val decidedAt: String?,
    val expiresAt: String,
    val duplicate: Boolean = false,
) {
    val isIncoming: Boolean get() = direction == "incoming"
}

data class ManagedSafetyContact(
    val profileId: UUID,
    val displayName: String,
    val role: String,
    val acceptedAt: String,
)

data class ManagedSafetyContacts(
    val contacts: List<ManagedSafetyContact>,
    val minimumRequired: Int,
    val maximumAllowed: Int,
)

data class ManagedSafetyPushStatus(
    val configured: Boolean,
    val reached: Boolean,
)

data class ManagedSafetyParticipant(
    val profileId: UUID,
    val displayName: String,
    val status: String,
    val pagedAt: String,
    val respondedAt: String?,
    val push: ManagedSafetyPushStatus,
)

data class ManagedSafetyLocation(
    val sequence: Long,
    val latitude: Double,
    val longitude: Double,
    val horizontalAccuracyM: Double,
    val capturedAt: String,
    val receivedAt: String,
    val duplicate: Boolean = false,
)

data class ManagedSafetyDelivery(
    val contactsTargeted: Int,
    val contactsReached: Int,
    val installationsTargeted: Int,
    val installationsReached: Int,
    val installationsRetryable: Int = 0,
    val installationsTerminal: Int = 0,
)

data class ManagedSafetyIncident(
    val incidentId: UUID,
    val role: String,
    val ownerProfileId: UUID,
    val ownerDisplayName: String,
    val trigger: String,
    val status: String,
    val durationHours: Int,
    val shareLocation: Boolean,
    val createdAt: String,
    val expiresAt: String,
    val acknowledgedAt: String?,
    val endedAt: String?,
    val participants: List<ManagedSafetyParticipant>,
    val location: ManagedSafetyLocation?,
    val delivery: ManagedSafetyDelivery?,
    val duplicate: Boolean = false,
)

data class ManagedSafetyIncidentCreation(
    val incident: ManagedSafetyIncident,
    val pushOutcome: String,
)

object ManagedSafetyIdentifier {
    val invitePattern = Regex("^noopsafety_[A-Za-z0-9_-]{43}$")

    fun makeInviteCapability(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(32).also(random::nextBytes)
        return "noopsafety_" +
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    fun inviteUrl(capability: String): String? =
        capability.takeIf(invitePattern::matches)
            ?.let { "noop://managed-safety/invite?capability=$it" }

    fun inviteCapability(url: String): String? = runCatching {
        val parsed = URI(url)
        if (!parsed.scheme.equals("noop", ignoreCase = true) ||
            !parsed.host.equals("managed-safety", ignoreCase = true) ||
            parsed.port != -1 ||
            parsed.userInfo != null ||
            parsed.path != "/invite" ||
            parsed.fragment != null
        ) {
            return null
        }
        val query = parsed.rawQuery ?: return null
        if (!query.startsWith("capability=") || query.contains("&")) return null
        URLDecoder.decode(
            query.removePrefix("capability="),
            StandardCharsets.UTF_8.name(),
        ).takeIf(invitePattern::matches)
    }.getOrNull()

    fun inviteRedemptionRequestId(
        accountScopeHash: String,
        capability: String,
    ): UUID {
        require(accountScopeHash.matches(Regex("^[0-9a-f]{64}$")))
        require(invitePattern.matches(capability))
        return ManagedStableIdentifier.uuid(
            "noop-managed-safety-redeem-v1\u0000$accountScopeHash\u0000$capability"
                .toByteArray(StandardCharsets.UTF_8),
        )
    }
}

object ManagedSafetyPushPayload {
    private const val KIND = "managed_safety_incident"
    private const val SCHEMA = "1"
    private const val ROUTE = "safety"

    fun incidentId(
        values: Map<String, String>,
        now: Instant = Instant.now(),
    ): UUID? {
        if (values["kind"] != KIND ||
            values["schema"] != SCHEMA ||
            values["route"] != ROUTE
        ) {
            return null
        }
        val expiresAt = values["expires_at"]
            ?.let { runCatching { Instant.parse(it) }.getOrNull() }
            ?: return null
        if (!expiresAt.isAfter(now)) return null
        return values["incident_id"]
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
    }
}
