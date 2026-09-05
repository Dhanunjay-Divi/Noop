package com.noop.managed

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

internal class ManagedCloudPreferences(context: Context) {
    private val preferences: SharedPreferences = EncryptedSharedPreferences.create(
        context.applicationContext,
        FILE,
        MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    val installationId: String
        get() = synchronized(this) {
            preferences.getString(KEY_INSTALLATION_ID, null)
                ?.takeIf { it.matches(INSTALLATION_ID) }
                ?: UUID.randomUUID().toString().lowercase().also {
                    check(preferences.edit().putString(KEY_INSTALLATION_ID, it).commit()) {
                        "Could not persist the NOOP+ installation identity."
                    }
                }
        }

    fun installationToken(accountScopeHash: String): String = synchronized(this) {
        require(accountScopeHash.matches(SHA256))
        val key = "$KEY_INSTALLATION_TOKEN_PREFIX$accountScopeHash"
        preferences.getString(key, null)
            ?.takeIf { it.matches(INSTALLATION_TOKEN) }
            ?: ByteArray(32).also(SecureRandom()::nextBytes).let { bytes ->
                "noopm_" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
            }.also { created ->
                check(created.matches(INSTALLATION_TOKEN))
                check(preferences.edit().putString(key, created).commit()) {
                    "Could not persist the NOOP+ installation credential."
                }
            }
    }

    var verificationId: String?
        get() = preferences.getString(KEY_VERIFICATION_ID, null)
        set(value) = putString(KEY_VERIFICATION_ID, value)

    var deletionVerificationId: String?
        get() = preferences.getString(KEY_DELETION_VERIFICATION_ID, null)
        set(value) = putString(KEY_DELETION_VERIFICATION_ID, value)

    fun enrollmentRequestId(): UUID = synchronized(this) {
        preferences.getString(KEY_ENROLLMENT_REQUEST_ID, null)
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?: UUID.randomUUID().also {
                check(
                    preferences.edit()
                        .putString(KEY_ENROLLMENT_REQUEST_ID, it.toString().lowercase())
                        .commit(),
                ) { "Could not persist the NOOP+ enrollment request." }
            }
    }

    fun socialProfileRequestId(): UUID =
        stableRequestId(KEY_SOCIAL_PROFILE_REQUEST_ID)

    fun socialInviteRequestId(): UUID =
        stableRequestId(KEY_SOCIAL_INVITE_REQUEST_ID)

    fun clearSocialProfileRequestId() {
        preferences.edit().remove(KEY_SOCIAL_PROFILE_REQUEST_ID).apply()
    }

    fun clearSocialInviteRequestId() {
        preferences.edit().remove(KEY_SOCIAL_INVITE_REQUEST_ID).apply()
    }

    fun socialInviteCapability(): String = synchronized(this) {
        preferences.getString(KEY_SOCIAL_INVITE_CAPABILITY, null)
            ?.takeIf(ManagedSocialIdentifier.invitePattern::matches)
            ?: ManagedSocialIdentifier.makeInviteCapability().also { created ->
                check(ManagedSocialIdentifier.invitePattern.matches(created))
                check(
                    preferences.edit()
                        .putString(KEY_SOCIAL_INVITE_CAPABILITY, created)
                        .commit(),
                ) { "Could not persist the managed Friends invitation." }
            }
    }

    fun clearSocialInviteCapability() {
        preferences.edit().remove(KEY_SOCIAL_INVITE_CAPABILITY).apply()
    }

    var pendingSocialInviteCapability: String?
        get() = preferences.getString(KEY_PENDING_SOCIAL_INVITE, null)
            ?.takeIf(ManagedSocialIdentifier.invitePattern::matches)
        set(value) {
            require(value == null || ManagedSocialIdentifier.invitePattern.matches(value))
            putString(KEY_PENDING_SOCIAL_INVITE, value)
        }

    var pendingSocialNoopId: String?
        get() = preferences.getString(KEY_PENDING_SOCIAL_NOOP_ID, null)
            ?.let(ManagedSocialIdentifier::canonicalNoopId)
        set(value) {
            require(value == null || ManagedSocialIdentifier.canonicalNoopId(value) != null)
            putString(
                KEY_PENDING_SOCIAL_NOOP_ID,
                value?.let(ManagedSocialIdentifier::canonicalNoopId),
            )
        }

    var socialLastAttemptMs: Long
        get() = preferences.getLong(KEY_SOCIAL_LAST_ATTEMPT_MS, 0L)
        set(value) {
            preferences.edit()
                .putLong(KEY_SOCIAL_LAST_ATTEMPT_MS, value.coerceAtLeast(0L))
                .apply()
        }

    var socialEnabled: Boolean
        get() = preferences.getBoolean(KEY_SOCIAL_ENABLED, false)
        set(value) {
            preferences.edit().putBoolean(KEY_SOCIAL_ENABLED, value).apply()
        }

    fun socialSummaryDigests(accountScopeHash: String): MutableMap<String, String> =
        synchronized(this) {
            require(accountScopeHash.matches(SHA256))
            if (preferences.getString(KEY_SOCIAL_SUMMARY_SCOPE, null) != accountScopeHash) {
                check(
                    preferences.edit()
                        .putString(KEY_SOCIAL_SUMMARY_SCOPE, accountScopeHash)
                        .remove(KEY_SOCIAL_SUMMARY_DIGESTS)
                        .commit(),
                )
            }
            val raw = preferences.getString(KEY_SOCIAL_SUMMARY_DIGESTS, null)
                ?: return@synchronized mutableMapOf()
            runCatching {
                val objectValue = JSONObject(raw)
                buildMap {
                    objectValue.keys().forEach { day ->
                        val digest = objectValue.optString(day)
                        if (day.matches(DAY) && digest.matches(SHA256)) {
                            put(day, digest)
                        }
                    }
                }.toMutableMap()
            }.getOrDefault(mutableMapOf())
        }

    fun storeSocialSummaryDigests(
        accountScopeHash: String,
        values: Map<String, String>,
    ) = synchronized(this) {
        require(accountScopeHash.matches(SHA256))
        val normalized = values
            .filter { (day, digest) -> day.matches(DAY) && digest.matches(SHA256) }
            .toSortedMap()
        check(
            preferences.edit()
                .putString(KEY_SOCIAL_SUMMARY_SCOPE, accountScopeHash)
                .putString(KEY_SOCIAL_SUMMARY_DIGESTS, JSONObject(normalized).toString())
                .commit(),
        )
    }

    fun socialDeliveryReceipt(pokeId: UUID): ManagedSocialDeliveryReceipt? =
        socialDeliveryReceipts().firstOrNull { it.pokeId == pokeId }

    fun storeSocialDeliveryReceipt(receipt: ManagedSocialDeliveryReceipt) {
        val retained = (
            socialDeliveryReceipts().filterNot { it.pokeId == receipt.pokeId } + receipt
            ).takeLast(MAX_SOCIAL_DELIVERY_RECEIPTS)
        val encoded = JSONArray().apply {
            retained.forEach { value ->
                put(
                    JSONObject()
                        .put("poke_id", value.pokeId.toString().lowercase())
                        .put("notification_outcome", value.notificationOutcome)
                        .put("haptic_outcome", value.hapticOutcome)
                        .put("recorded_at_ms", value.recordedAtMs),
                )
            }
        }
        preferences.edit()
            .putString(KEY_SOCIAL_DELIVERY_RECEIPTS, encoded.toString())
            .apply()
    }

    fun clearSocialState() {
        preferences.edit()
            .remove(KEY_SOCIAL_PROFILE_REQUEST_ID)
            .remove(KEY_SOCIAL_INVITE_REQUEST_ID)
            .remove(KEY_SOCIAL_INVITE_CAPABILITY)
            .remove(KEY_PENDING_SOCIAL_INVITE)
            .remove(KEY_PENDING_SOCIAL_NOOP_ID)
            .remove(KEY_SOCIAL_SUMMARY_SCOPE)
            .remove(KEY_SOCIAL_SUMMARY_DIGESTS)
            .remove(KEY_SOCIAL_LAST_ATTEMPT_MS)
            .remove(KEY_SOCIAL_DELIVERY_RECEIPTS)
            .remove(KEY_SOCIAL_ENABLED)
            .apply()
    }

    fun completeEnrollment(accountScopeHash: String, policyVersion: String) {
        check(
            preferences.edit()
                .putString(KEY_ENROLLED_SCOPE_HASH, accountScopeHash)
                .putString(KEY_ENROLLED_POLICY, policyVersion)
                .putBoolean(KEY_AUTOMATIC, true)
                .remove(KEY_ENROLLMENT_REQUEST_ID)
                .commit(),
        ) { "Could not persist NOOP+ enrollment." }
    }

    fun isEnrolled(accountScopeHash: String, policyVersion: String): Boolean =
        preferences.getString(KEY_ENROLLED_SCOPE_HASH, null) == accountScopeHash &&
            preferences.getString(KEY_ENROLLED_POLICY, null) == policyVersion

    var automatic: Boolean
        get() = preferences.getBoolean(KEY_AUTOMATIC, false)
        set(value) {
            preferences.edit().putBoolean(KEY_AUTOMATIC, value).apply()
        }

    var optimizePhoneStorage: Boolean
        get() = preferences.getBoolean(KEY_OPTIMIZE_PHONE_STORAGE, false)
        set(value) {
            preferences.edit().putBoolean(KEY_OPTIMIZE_PHONE_STORAGE, value).apply()
        }

    var lastAttemptMs: Long
        get() = preferences.getLong(KEY_LAST_ATTEMPT_MS, 0L)
        set(value) {
            preferences.edit().putLong(KEY_LAST_ATTEMPT_MS, value.coerceAtLeast(0L)).apply()
        }

    var lastSuccessMs: Long
        get() = preferences.getLong(KEY_LAST_SUCCESS_MS, 0L)
        set(value) {
            preferences.edit().putLong(KEY_LAST_SUCCESS_MS, value.coerceAtLeast(0L)).apply()
        }

    var status: String
        get() = preferences.getString(KEY_STATUS, "").orEmpty()
        set(value) {
            preferences.edit().putString(KEY_STATUS, value.take(512)).apply()
        }

    var erasureJobId: UUID?
        get() = preferences.getString(KEY_ERASURE_JOB_ID, null)
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
        set(value) = putString(KEY_ERASURE_JOB_ID, value?.toString()?.lowercase())

    var erasureNotBefore: String?
        get() = preferences.getString(KEY_ERASURE_NOT_BEFORE, null)
        set(value) = putString(KEY_ERASURE_NOT_BEFORE, value)

    fun disconnect() {
        preferences.edit()
            .remove(KEY_VERIFICATION_ID)
            .remove(KEY_DELETION_VERIFICATION_ID)
            .putBoolean(KEY_AUTOMATIC, false)
            .putBoolean(KEY_OPTIMIZE_PHONE_STORAGE, false)
            .apply()
    }

    fun clearEnrollment() {
        preferences.edit()
            .remove(KEY_ENROLLED_SCOPE_HASH)
            .remove(KEY_ENROLLED_POLICY)
            .remove(KEY_ENROLLMENT_REQUEST_ID)
            .remove(KEY_VERIFICATION_ID)
            .remove(KEY_DELETION_VERIFICATION_ID)
            .remove(KEY_ERASURE_JOB_ID)
            .remove(KEY_ERASURE_NOT_BEFORE)
            .putBoolean(KEY_AUTOMATIC, false)
            .putBoolean(KEY_OPTIMIZE_PHONE_STORAGE, false)
            .apply()
        clearSocialState()
    }

    private fun stableRequestId(key: String): UUID = synchronized(this) {
        preferences.getString(key, null)
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?: UUID.randomUUID().also {
                check(
                    preferences.edit()
                        .putString(key, it.toString().lowercase())
                        .commit(),
                ) { "Could not persist the managed Friends request." }
            }
    }

    private fun socialDeliveryReceipts(
        nowMs: Long = System.currentTimeMillis(),
    ): List<ManagedSocialDeliveryReceipt> {
        val cutoff = nowMs - SOCIAL_DELIVERY_RETENTION_MS
        val raw = preferences.getString(KEY_SOCIAL_DELIVERY_RECEIPTS, null)
            ?: return emptyList()
        return runCatching {
            val values = JSONArray(raw)
            buildList {
                for (index in 0 until values.length()) {
                    val row = values.optJSONObject(index) ?: continue
                    val receipt = ManagedSocialDeliveryReceipt(
                        pokeId = UUID.fromString(row.optString("poke_id")),
                        notificationOutcome = row.optString("notification_outcome"),
                        hapticOutcome = row.optString("haptic_outcome"),
                        recordedAtMs = row.optLong("recorded_at_ms", -1L),
                    )
                    if (receipt.recordedAtMs >= cutoff &&
                        receipt.recordedAtMs <= nowMs &&
                        receipt.notificationOutcome in SOCIAL_NOTIFICATION_OUTCOMES &&
                        receipt.hapticOutcome in SOCIAL_HAPTIC_OUTCOMES
                    ) {
                        add(receipt)
                    }
                }
            }.takeLast(MAX_SOCIAL_DELIVERY_RECEIPTS)
        }.getOrDefault(emptyList())
    }

    private fun putString(key: String, value: String?) {
        preferences.edit().apply {
            if (value == null) remove(key) else putString(key, value)
        }.apply()
    }

    companion object {
        private const val FILE = "noop_managed_cloud_secure_v1"
        private const val KEY_INSTALLATION_ID = "installation_id"
        private const val KEY_INSTALLATION_TOKEN_PREFIX = "installation_token_"
        private const val KEY_VERIFICATION_ID = "verification_id"
        private const val KEY_DELETION_VERIFICATION_ID = "deletion_verification_id"
        private const val KEY_ENROLLMENT_REQUEST_ID = "enrollment_request_id"
        private const val KEY_ENROLLED_SCOPE_HASH = "enrolled_scope_hash"
        private const val KEY_ENROLLED_POLICY = "enrolled_policy"
        private const val KEY_AUTOMATIC = "automatic"
        private const val KEY_OPTIMIZE_PHONE_STORAGE = "optimize_phone_storage"
        private const val KEY_LAST_ATTEMPT_MS = "last_attempt_ms"
        private const val KEY_LAST_SUCCESS_MS = "last_success_ms"
        private const val KEY_STATUS = "status"
        private const val KEY_ERASURE_JOB_ID = "erasure_job_id"
        private const val KEY_ERASURE_NOT_BEFORE = "erasure_not_before"
        private const val KEY_SOCIAL_PROFILE_REQUEST_ID =
            "social_profile_request_id"
        private const val KEY_SOCIAL_INVITE_REQUEST_ID =
            "social_invite_request_id"
        private const val KEY_SOCIAL_INVITE_CAPABILITY =
            "social_invite_capability"
        private const val KEY_PENDING_SOCIAL_INVITE =
            "pending_social_invite"
        private const val KEY_PENDING_SOCIAL_NOOP_ID =
            "pending_social_noop_id"
        private const val KEY_SOCIAL_SUMMARY_SCOPE = "social_summary_scope"
        private const val KEY_SOCIAL_SUMMARY_DIGESTS = "social_summary_digests"
        private const val KEY_SOCIAL_LAST_ATTEMPT_MS = "social_last_attempt_ms"
        private const val KEY_SOCIAL_DELIVERY_RECEIPTS =
            "social_delivery_receipts"
        private const val KEY_SOCIAL_ENABLED = "social_enabled"
        private const val MAX_SOCIAL_DELIVERY_RECEIPTS = 64
        private const val SOCIAL_DELIVERY_RETENTION_MS = 7L * 24 * 60 * 60 * 1_000
        private val INSTALLATION_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
        private val INSTALLATION_TOKEN = Regex("^noopm_[A-Za-z0-9_-]{43}$")
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val DAY = Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
        private val SOCIAL_NOTIFICATION_OUTCOMES =
            setOf("scheduled", "not_authorized", "failed")
        private val SOCIAL_HAPTIC_OUTCOMES =
            setOf("requested", "band_unavailable", "not_eligible", "failed")
    }
}

internal data class ManagedSocialDeliveryReceipt(
    val pokeId: UUID,
    val notificationOutcome: String,
    val hapticOutcome: String,
    val recordedAtMs: Long,
)
