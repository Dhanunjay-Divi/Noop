package com.noop.managed

import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

data class ManagedSocialBadge(
    val code: String,
    val earnedAt: String,
)

data class ManagedSocialProfile(
    val profileId: UUID,
    val displayName: String,
    val noopId: String,
    val pokeOptIn: Boolean,
    val quietStartMinute: Int,
    val quietEndMinute: Int,
    val timeZone: String,
    val createdAt: String,
    val updatedAt: String,
    val duplicate: Boolean = false,
    val badges: List<ManagedSocialBadge> = emptyList(),
)

data class ManagedSocialLookupProfile(
    val profileId: UUID,
    val displayName: String,
    val noopId: String,
    val isSelf: Boolean,
)

data class ManagedSocialProfilePatch(
    val displayName: String? = null,
    val pokeOptIn: Boolean? = null,
    val quietStartMinute: Int? = null,
    val quietEndMinute: Int? = null,
    val timeZone: String? = null,
) {
    val hasChange: Boolean
        get() = displayName != null ||
            pokeOptIn != null ||
            quietStartMinute != null ||
            quietEndMinute != null ||
            timeZone != null
}

data class ManagedSocialVisibility(
    val charge: Boolean = false,
    val effort: Boolean = false,
    val rest: Boolean = false,
    val sleepDuration: Boolean = false,
    val hrv: Boolean = false,
    val rhr: Boolean = false,
    val pokeAllowed: Boolean = false,
)

data class ManagedSocialVisibilityPatch(
    val charge: Boolean? = null,
    val effort: Boolean? = null,
    val rest: Boolean? = null,
    val sleepDuration: Boolean? = null,
    val hrv: Boolean? = null,
    val rhr: Boolean? = null,
    val pokeAllowed: Boolean? = null,
) {
    val hasChange: Boolean
        get() = charge != null ||
            effort != null ||
            rest != null ||
            sleepDuration != null ||
            hrv != null ||
            rhr != null ||
            pokeAllowed != null
}

data class ManagedSocialSummary(
    val charge: Double? = null,
    val effort: Double? = null,
    val rest: Double? = null,
    val sleepDuration: Double? = null,
    val hrv: Double? = null,
    val rhr: Double? = null,
) {
    val hasValue: Boolean
        get() = charge != null ||
            effort != null ||
            rest != null ||
            sleepDuration != null ||
            hrv != null ||
            rhr != null
}

data class ManagedSocialLatestSummary(
    val day: String,
    val summary: ManagedSocialSummary,
)

data class ManagedSocialFriend(
    val profileId: UUID,
    val displayName: String,
    val friendsSince: String,
    val sharing: ManagedSocialVisibility,
    val sharedWithMe: ManagedSocialVisibility,
    val latest: ManagedSocialLatestSummary?,
    val badges: List<ManagedSocialBadge>,
)

data class ManagedSocialBlockedProfile(
    val profileId: UUID,
    val displayName: String,
    val blockedAt: String,
)

data class ManagedSocialRequest(
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

data class ManagedSocialInvite(
    val inviteId: UUID,
    val capability: String,
    val status: String,
    val createdAt: String,
    val expiresAt: String,
    val duplicate: Boolean = false,
)

data class ManagedSocialFeedDay(
    val profileId: UUID,
    val displayName: String,
    val day: String,
    val summary: ManagedSocialSummary,
)

data class ManagedSocialPoke(
    val pokeId: UUID,
    val recipientProfileId: UUID,
    val recipientDisplayName: String,
    val status: String,
    val createdAt: String,
    val expiresAt: String,
    val duplicate: Boolean = false,
)

data class ManagedSocialPokeClaim(
    val pokeId: UUID,
    val claimId: UUID,
    val senderProfileId: UUID,
    val senderDisplayName: String,
    val createdAt: String,
    val expiresAt: String,
    val claimExpiresAt: String,
)

data class ManagedSocialPokeAcknowledgement(
    val claimId: UUID,
    val notificationOutcome: String,
    val hapticOutcome: String,
)

data class ManagedSocialPokeReceipt(
    val pokeId: UUID,
    val status: String,
    val duplicate: Boolean,
    val notificationOutcome: String,
    val hapticOutcome: String,
)

object ManagedSocialIdentifier {
    private val NOOP_ID = Regex(
        "^NOOP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-" +
            "[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$",
    )
    val invitePattern = Regex("^noopinvite_[A-Za-z0-9_-]{43}$")

    fun canonicalNoopId(value: String): String? =
        value.trim().uppercase().takeIf(NOOP_ID::matches)

    fun makeInviteCapability(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(32).also(random::nextBytes)
        return "noopinvite_" +
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
}
