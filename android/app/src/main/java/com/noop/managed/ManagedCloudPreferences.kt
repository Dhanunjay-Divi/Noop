package com.noop.managed

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
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
        private val INSTALLATION_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
        private val INSTALLATION_TOKEN = Regex("^noopm_[A-Za-z0-9_-]{43}$")
        private val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}
