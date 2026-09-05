package com.noop.managed

import android.net.Uri
import java.nio.charset.StandardCharsets
import java.net.URI
import java.time.LocalDate
import java.util.UUID

/**
 * Pure policy shared by the managed Friends service, worker, deep-link entry point, and tests.
 *
 * Capability and profile identifiers are intentionally returned only to the caller. Nothing in this
 * helper records them or includes them in diagnostics.
 */
internal object ManagedSocialRuntime {
    const val AUTOMATIC_INTERVAL_MS = 5L * 60L * 1_000L
    private const val DAYS_BACK = 30L

    fun profileNoopId(uri: Uri?): String? =
        profileNoopId(uri?.toString())

    fun profileNoopId(raw: String?): String? {
        val uri = raw?.let { runCatching { URI(it) }.getOrNull() } ?: return null
        if (uri.scheme?.lowercase() != "noop" ||
            uri.host?.lowercase() != "managed-friends" ||
            uri.port != -1 ||
            uri.userInfo != null ||
            uri.path != "/profile" ||
            uri.fragment != null
        ) {
            return null
        }
        val query = uri.rawQuery?.split("&") ?: return null
        if (query.size != 1) return null
        val parts = query.single().split("=", limit = 2)
        if (parts.size != 2 || parts[0] != "noopId") return null
        return ManagedSocialIdentifier.canonicalNoopId(parts[1])
    }

    fun profileUri(noopId: String): Uri? {
        val url = profileUrl(noopId) ?: return null
        return Uri.parse(url)
    }

    fun profileUrl(noopId: String): String? =
        ManagedSocialIdentifier.canonicalNoopId(noopId)
            ?.let { "noop://managed-friends/profile?noopId=$it" }

    fun inviteCapability(uri: Uri?): String? =
        inviteCapability(uri?.toString())

    fun inviteCapability(raw: String?): String? {
        val uri = raw?.let { runCatching { URI(it) }.getOrNull() } ?: return null
        if (uri.scheme?.lowercase() != "noop" ||
            uri.host?.lowercase() != "managed-friends" ||
            uri.port != -1 ||
            uri.userInfo != null ||
            uri.path != "/invite" ||
            uri.fragment != null
        ) {
            return null
        }
        val query = uri.rawQuery?.split("&") ?: return null
        if (query.size != 1) return null
        val parts = query.single().split("=", limit = 2)
        if (parts.size != 2 || parts[0] != "capability") return null
        return parts[1].takeIf(ManagedSocialIdentifier.invitePattern::matches)
    }

    fun inviteUri(capability: String): Uri? =
        inviteUrl(capability)?.let(Uri::parse)

    fun inviteUrl(capability: String): String? =
        capability.takeIf(ManagedSocialIdentifier.invitePattern::matches)
            ?.let { "noop://managed-friends/invite?capability=$it" }

    fun isCatchUpDue(
        lastAttemptMs: Long,
        nowMs: Long = System.currentTimeMillis(),
    ): Boolean = lastAttemptMs <= 0L || nowMs - lastAttemptMs >= AUTOMATIC_INTERVAL_MS

    fun summaryDays(today: LocalDate = LocalDate.now()): List<String> =
        generateSequence(today.minusDays(DAYS_BACK)) { current ->
            current.plusDays(1).takeIf { !it.isAfter(today) }
        }.map(LocalDate::toString).toList()

    fun visibilityUnion(friends: List<ManagedSocialFriend>): ManagedSocialVisibility =
        ManagedSocialVisibility(
            charge = friends.any { it.sharing.charge },
            effort = friends.any { it.sharing.effort },
            rest = friends.any { it.sharing.rest },
            sleepDuration = friends.any { it.sharing.sleepDuration },
            hrv = friends.any { it.sharing.hrv },
            rhr = friends.any { it.sharing.rhr },
            pokeAllowed = friends.any { it.sharing.pokeAllowed },
        )

    fun value(raw: Double?, range: ClosedFloatingPointRange<Double>): Double? =
        raw?.takeIf { it.isFinite() && it in range }

    fun digest(
        day: String,
        summary: ManagedSocialSummary,
        visibility: ManagedSocialVisibility,
    ): String {
        require(runCatching { LocalDate.parse(day) }.isSuccess)
        fun encoded(value: Double?): String = value?.let {
            java.lang.Long.toUnsignedString(it.toRawBits(), 16).padStart(16, '0')
        } ?: "~"
        val canonical = listOf(
            "managed-social-summary-v1",
            day,
            encoded(summary.charge),
            encoded(summary.effort),
            encoded(summary.rest),
            encoded(summary.sleepDuration),
            encoded(summary.hrv),
            encoded(summary.rhr),
            visibility.charge.toString(),
            visibility.effort.toString(),
            visibility.rest.toString(),
            visibility.sleepDuration.toString(),
            visibility.hrv.toString(),
            visibility.rhr.toString(),
        ).joinToString("\u0000")
        return ManagedDigest.sha256(canonical.toByteArray(StandardCharsets.UTF_8))
    }

    fun summaryRequestId(
        accountScopeHash: String,
        day: String,
        digest: String,
    ): UUID = ManagedStableIdentifier.uuid(
        "noop-managed-social-summary-v1\u0000$accountScopeHash\u0000$day\u0000$digest"
            .toByteArray(StandardCharsets.UTF_8),
    )

    fun inviteRedemptionRequestId(
        accountScopeHash: String,
        capability: String,
    ): UUID = ManagedStableIdentifier.uuid(
        "noop-managed-social-redeem-v1\u0000$accountScopeHash\u0000$capability"
            .toByteArray(StandardCharsets.UTF_8),
    )
}
