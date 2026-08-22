package com.noop.social

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import com.noop.sync.RemoteBatchIdentity
import com.noop.sync.RemoteSyncPrefs
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.UUID

internal data class FriendMemberContext(
    val endpoint: String,
    val token: String,
    val profileId: String,
    val displayName: String,
    val dailyDeviceId: String,
)

internal data class PendingFriendEnrollment(
    val endpoint: String,
    val token: String,
    val enrollmentId: String,
    val displayName: String,
    val dailyDeviceId: String,
)

/**
 * Durable idempotency state for the summary replacement upload.
 *
 * The same content fingerprint keeps the same batch id after an ambiguous network failure. A
 * different projection gets a new identity, and an acknowledged projection clears only its own
 * identity so a newer in-flight replacement cannot be erased by a late completion.
 */
internal object FriendsUploadIdentityStore {
    private const val KEY_UPLOAD_FINGERPRINT = "upload_fingerprint"
    private const val KEY_UPLOAD_BATCH_ID = "upload_batch_id"
    private const val KEY_UPLOAD_SENT_AT = "upload_sent_at"

    fun resolve(
        values: SharedPreferences,
        fingerprint: String,
        now: Instant = Instant.now(),
    ): RemoteBatchIdentity {
        val existingFingerprint = values.getString(KEY_UPLOAD_FINGERPRINT, null)
        val existingBatchId = values.getString(KEY_UPLOAD_BATCH_ID, null)
        val existingSentAt = values.getString(KEY_UPLOAD_SENT_AT, null)
        if (
            existingFingerprint == fingerprint &&
            !existingBatchId.isNullOrBlank() &&
            !existingSentAt.isNullOrBlank()
        ) {
            return RemoteBatchIdentity(existingBatchId, existingSentAt)
        }

        val identity = RemoteBatchIdentity(
            batchId = UUID.randomUUID().toString(),
            sentAt = now.toString(),
        )
        val saved = values.edit()
            .putString(KEY_UPLOAD_FINGERPRINT, fingerprint)
            .putString(KEY_UPLOAD_BATCH_ID, identity.batchId)
            .putString(KEY_UPLOAD_SENT_AT, identity.sentAt)
            .commit()
        if (!saved) throw FriendsException.Storage("Could not save the Friends upload identity.")
        return identity
    }

    fun acknowledge(values: SharedPreferences, fingerprint: String) {
        if (values.getString(KEY_UPLOAD_FINGERPRINT, null) != fingerprint) return
        values.edit()
            .remove(KEY_UPLOAD_FINGERPRINT)
            .remove(KEY_UPLOAD_BATCH_ID)
            .remove(KEY_UPLOAD_SENT_AT)
            .apply()
    }
}

internal object FriendsPreferences {
    private const val STATE_FILE = "noop_friends"
    private const val SECRET_FILE = "noop_friends_secure"
    private const val KEY_TOKEN = "member_token"
    private const val KEY_ENDPOINT = "endpoint"
    private const val KEY_PROFILE_ID = "profile_id"
    private const val KEY_ENROLLMENT_ID = "enrollment_id"
    private const val KEY_DISPLAY_NAME = "display_name"
    private const val KEY_DAILY_DEVICE_ID = "daily_device_id"
    private const val KEY_PENDING_ENDPOINT = "pending_endpoint"
    private const val KEY_PENDING_ENROLLMENT_ID = "pending_enrollment_id"
    private const val KEY_PENDING_DISPLAY_NAME = "pending_display_name"
    private const val KEY_PENDING_DAILY_DEVICE_ID = "pending_daily_device_id"
    private const val KEY_LAST_AUTOMATIC_MS = "last_automatic_ms"

    private fun state(context: Context) =
        context.applicationContext.getSharedPreferences(STATE_FILE, Context.MODE_PRIVATE)

    private fun secrets(context: Context) = SecurePrefs.of(context, SECRET_FILE)

    fun setupState(context: Context): FriendsSetupState = when {
        memberContext(context) != null -> FriendsSetupState.READY
        // A lost join response must be retried with the same enrollment and member token. Do not
        // expose bootstrap while that durable attempt exists or it could orphan the remote profile.
        pendingEnrollment(context) != null -> FriendsSetupState.PENDING_JOIN
        RemoteSyncPrefs.isConfigured() -> FriendsSetupState.NEEDS_PROFILE
        else -> FriendsSetupState.NEEDS_SERVER
    }

    fun memberContext(context: Context): FriendMemberContext? {
        val values = state(context)
        val token = secrets(context).getString(KEY_TOKEN, null)?.takeIf(String::isNotBlank)
            ?: return null
        val endpoint = values.getString(KEY_ENDPOINT, null)?.takeIf(String::isNotBlank)
            ?: return null
        val profileId = values.getString(KEY_PROFILE_ID, null)?.takeIf(String::isNotBlank)
            ?: return null
        val displayName = values.getString(KEY_DISPLAY_NAME, null)?.takeIf(String::isNotBlank)
            ?: return null
        val dailyDeviceId = values.getString(KEY_DAILY_DEVICE_ID, null)?.takeIf(String::isNotBlank)
            ?: return null
        return FriendMemberContext(endpoint, token, profileId, displayName, dailyDeviceId)
    }

    fun pendingEnrollment(context: Context): PendingFriendEnrollment? {
        val values = state(context)
        val token = secrets(context).getString(KEY_TOKEN, null)?.takeIf(String::isNotBlank)
            ?: return null
        val endpoint = values.getString(KEY_PENDING_ENDPOINT, null)?.takeIf(String::isNotBlank)
            ?: return null
        val enrollmentId = values.getString(KEY_PENDING_ENROLLMENT_ID, null)
            ?.takeIf(String::isNotBlank) ?: return null
        val displayName = values.getString(KEY_PENDING_DISPLAY_NAME, null)
            ?.takeIf(String::isNotBlank) ?: return null
        val dailyDeviceId = values.getString(KEY_PENDING_DAILY_DEVICE_ID, null)
            ?.takeIf(String::isNotBlank) ?: return null
        return PendingFriendEnrollment(
            endpoint,
            token,
            enrollmentId,
            displayName,
            dailyDeviceId,
        )
    }

    fun preparePendingEnrollment(
        context: Context,
        endpoint: String,
        displayName: String,
        dailyDeviceId: String,
    ): PendingFriendEnrollment {
        pendingEnrollment(context)?.let { pending ->
            if (!sameOrigin(pending.endpoint, endpoint)) {
                throw FriendsException.InvalidInput(
                    "Finish or remove the pending invitation for ${pending.endpoint} first.",
                )
            }
            if (pending.dailyDeviceId != dailyDeviceId) {
                throw FriendsException.InvalidInput(
                    "The pending invitation belongs to a different local device.",
                )
            }
            if (pending.displayName != displayName) {
                throw FriendsException.InvalidInput(
                    "Retry the pending invitation with the same display name.",
                )
            }
            return pending
        }

        val token = newMemberToken()
        if (!secrets(context).edit().putString(KEY_TOKEN, token).commit()) {
            throw FriendsException.Storage("Could not protect the Friends member credential.")
        }
        val enrollment = PendingFriendEnrollment(
            endpoint = endpoint,
            token = token,
            enrollmentId = UUID.randomUUID().toString(),
            displayName = displayName,
            dailyDeviceId = dailyDeviceId,
        )
        val saved = state(context).edit()
            .putString(KEY_PENDING_ENDPOINT, enrollment.endpoint)
            .putString(KEY_PENDING_ENROLLMENT_ID, enrollment.enrollmentId)
            .putString(KEY_PENDING_DISPLAY_NAME, enrollment.displayName)
            .putString(KEY_PENDING_DAILY_DEVICE_ID, enrollment.dailyDeviceId)
            .commit()
        if (!saved) {
            secrets(context).edit().remove(KEY_TOKEN).commit()
            throw FriendsException.Storage("Could not save the pending Friends enrollment.")
        }
        return enrollment
    }

    fun persistProfile(
        context: Context,
        profile: FriendProfile,
        endpoint: String,
        memberToken: String,
    ) {
        if (!secrets(context).edit().putString(KEY_TOKEN, memberToken).commit()) {
            throw FriendsException.Storage("Could not protect the Friends member credential.")
        }
        val saved = state(context).edit()
            .putString(KEY_ENDPOINT, endpoint)
            .putString(KEY_PROFILE_ID, profile.profileId)
            .putString(KEY_ENROLLMENT_ID, profile.enrollmentId)
            .putString(KEY_DISPLAY_NAME, profile.displayName)
            .putString(KEY_DAILY_DEVICE_ID, profile.dailyDeviceId)
            .remove(KEY_PENDING_ENDPOINT)
            .remove(KEY_PENDING_ENROLLMENT_ID)
            .remove(KEY_PENDING_DISPLAY_NAME)
            .remove(KEY_PENDING_DAILY_DEVICE_ID)
            .commit()
        if (!saved) throw FriendsException.Storage("Could not save the Friends profile.")
    }

    fun clearProfile(context: Context) {
        val secretCleared = secrets(context).edit().remove(KEY_TOKEN).commit()
        val stateCleared = state(context).edit().clear().commit()
        if (!secretCleared || !stateCleared) {
            throw FriendsException.Storage("Could not clear the Friends profile from this device.")
        }
    }

    fun clearPendingEnrollment(context: Context) {
        val secretCleared = secrets(context).edit().remove(KEY_TOKEN).commit()
        val stateCleared = state(context).edit()
            .remove(KEY_PENDING_ENDPOINT)
            .remove(KEY_PENDING_ENROLLMENT_ID)
            .remove(KEY_PENDING_DISPLAY_NAME)
            .remove(KEY_PENDING_DAILY_DEVICE_ID)
            .commit()
        if (!secretCleared || !stateCleared) {
            throw FriendsException.Storage(
                "Could not clear the pending Friends enrollment from this device.",
            )
        }
    }

    fun lastAutomaticMs(context: Context): Long =
        state(context).getLong(KEY_LAST_AUTOMATIC_MS, 0L)

    fun setLastAutomaticMs(context: Context, value: Long) {
        state(context).edit().putLong(KEY_LAST_AUTOMATIC_MS, value).apply()
    }

    fun uploadIdentity(
        context: Context,
        fingerprint: String,
        now: Instant = Instant.now(),
    ): RemoteBatchIdentity =
        FriendsUploadIdentityStore.resolve(state(context), fingerprint, now)

    fun acknowledgeUpload(context: Context, fingerprint: String) {
        FriendsUploadIdentityStore.acknowledge(state(context), fingerprint)
    }

    private fun newMemberToken(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return "noop_member_" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    private fun sameOrigin(left: String, right: String): Boolean {
        fun origin(value: String): Triple<String, String, Int>? {
            val uri = runCatching { java.net.URI(value) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase() ?: return null
            val host = uri.host?.lowercase() ?: return null
            val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
            return Triple(scheme, host, port)
        }
        return origin(left) == origin(right)
    }
}
