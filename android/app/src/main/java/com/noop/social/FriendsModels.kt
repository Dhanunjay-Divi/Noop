package com.noop.social

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

enum class FriendsSetupState {
    NEEDS_SERVER,
    PENDING_JOIN,
    NEEDS_PROFILE,
    READY,
}

data class FriendVisibility(
    val charge: Boolean = true,
    val effort: Boolean = true,
    val rest: Boolean = true,
    val sleepDuration: Boolean = false,
    val hrv: Boolean = false,
    val rhr: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("charge", charge)
        .put("effort", effort)
        .put("rest", rest)
        .put("sleep_duration", sleepDuration)
        .put("hrv", hrv)
        .put("rhr", rhr)

    companion object {
        fun fromJson(value: JSONObject): FriendVisibility = FriendVisibility(
            charge = value.optBoolean("charge", true),
            effort = value.optBoolean("effort", true),
            rest = value.optBoolean("rest", true),
            sleepDuration = value.optBoolean("sleep_duration", false),
            hrv = value.optBoolean("hrv", false),
            rhr = value.optBoolean("rhr", false),
        )
    }
}

data class FriendProfile(
    val profileId: String,
    val enrollmentId: String,
    val displayName: String,
    val installationId: String,
    val dailyDeviceId: String,
)

data class FriendContact(
    val profileId: String,
    val displayName: String,
    val friendsSince: String,
    val sharing: FriendVisibility,
    val sharedWithMe: FriendVisibility,
    val latest: FriendDailySummary? = null,
)

data class FriendRequest(
    val requestId: String,
    val displayName: String,
    val direction: Direction,
    val createdAt: String,
) {
    enum class Direction { INCOMING, OUTGOING }
}

data class FriendDailySummary(
    val day: String,
    val charge: Double? = null,
    val effort: Double? = null,
    val rest: Double? = null,
    val sleepMinutes: Double? = null,
    val hrv: Double? = null,
    val rhr: Double? = null,
)

data class FriendInvite(
    val inviteId: String,
    val code: String,
    val expiresAt: String,
    val serverAddress: String,
)

data class FriendBootstrap(
    val profile: FriendProfile,
    val memberToken: String,
)

data class FriendJoin(
    val profile: FriendProfile,
    val requestId: String,
    val idempotentReplay: Boolean,
)

data class FriendsSnapshot(
    val friends: List<FriendContact>,
    val requests: List<FriendRequest>,
)

sealed class FriendsException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class Network(message: String, cause: Throwable? = null) : FriendsException(message, cause)
    class Server(val statusCode: Int, message: String) : FriendsException(message)
    class InvalidResponse(message: String) : FriendsException(message)
    class InvalidInput(message: String) : FriendsException(message)
    class Storage(message: String) : FriendsException(message)
}

internal object FriendsJson {
    fun bootstrap(root: JSONObject): FriendBootstrap = FriendBootstrap(
        profile = profile(root.requireObject("profile")),
        memberToken = root.requireString("member_token"),
    )

    fun join(root: JSONObject): FriendJoin {
        val request = root.requireObject("request")
        return FriendJoin(
            profile = profile(root.requireObject("profile")),
            requestId = request.requireUuid("request_id"),
            idempotentReplay = root.optBoolean("idempotent_replay", false),
        )
    }

    fun invite(root: JSONObject, serverAddress: String): FriendInvite {
        val row = root.requireObject("invite")
        return FriendInvite(
            inviteId = row.requireUuid("invite_id"),
            code = root.requireString("code"),
            expiresAt = row.requireString("expires_at"),
            serverAddress = serverAddress,
        )
    }

    fun friends(root: JSONObject): List<FriendContact> =
        root.requireArray("friends").objects().map { row ->
            FriendContact(
                profileId = row.requireUuid("profile_id"),
                displayName = row.requireString("display_name"),
                friendsSince = row.requireString("friends_since"),
                sharing = FriendVisibility.fromJson(row.requireObject("sharing")),
                sharedWithMe = FriendVisibility.fromJson(row.requireObject("shared_with_me")),
            )
        }

    fun requests(root: JSONObject): List<FriendRequest> =
        root.requireArray("requests").objects().mapNotNull { row ->
            if (row.optString("status") != "pending") return@mapNotNull null
            val direction = when (row.optString("direction")) {
                "incoming" -> FriendRequest.Direction.INCOMING
                "outgoing" -> FriendRequest.Direction.OUTGOING
                else -> return@mapNotNull null
            }
            val identity = row.optJSONObject("profile") ?: return@mapNotNull null
            FriendRequest(
                requestId = row.requireUuid("request_id"),
                displayName = identity.requireString("display_name"),
                direction = direction,
                createdAt = row.requireString("created_at"),
            )
        }

    fun feed(root: JSONObject): Map<String, FriendDailySummary> {
        val result = linkedMapOf<String, FriendDailySummary>()
        root.requireArray("days").objects().forEach { row ->
            val profileId = row.requireUuid("profile_id")
            val day = row.requireString("day")
            val values = row.requireObject("summary")
            val candidate = FriendDailySummary(
                day = day,
                charge = values.finiteDoubleOrNull("charge"),
                effort = values.finiteDoubleOrNull("effort"),
                rest = values.finiteDoubleOrNull("rest"),
                sleepMinutes = values.finiteDoubleOrNull("sleep_duration"),
                hrv = values.finiteDoubleOrNull("hrv"),
                rhr = values.finiteDoubleOrNull("rhr"),
            )
            val existing = result[profileId]
            if (existing == null || existing.day < candidate.day) result[profileId] = candidate
        }
        return result
    }

    fun profile(value: JSONObject): FriendProfile = FriendProfile(
        profileId = value.requireUuid("profile_id"),
        enrollmentId = value.requireUuid("enrollment_id"),
        displayName = value.requireString("display_name"),
        installationId = value.requireString("installation_id"),
        dailyDeviceId = value.requireString("daily_device_id"),
    )

    private fun JSONObject.requireObject(key: String): JSONObject =
        optJSONObject(key) ?: throw FriendsException.InvalidResponse(
            "The server response is missing '$key'.",
        )

    private fun JSONObject.requireArray(key: String): JSONArray =
        optJSONArray(key) ?: throw FriendsException.InvalidResponse(
            "The server response is missing '$key'.",
        )

    private fun JSONObject.requireString(key: String): String =
        optString(key).takeIf(String::isNotBlank)
            ?: throw FriendsException.InvalidResponse(
                "The server response is missing '$key'.",
            )

    private fun JSONObject.requireUuid(key: String): String {
        val raw = requireString(key)
        return runCatching { UUID.fromString(raw).toString() }.getOrElse {
            throw FriendsException.InvalidResponse(
                "The server response contains an invalid '$key'.",
            )
        }
    }

    private fun JSONObject.finiteDoubleOrNull(key: String): Double? {
        if (!has(key) || isNull(key)) return null
        return optDouble(key, Double.NaN).takeIf(Double::isFinite)
    }

    private fun JSONArray.objects(): List<JSONObject> = buildList {
        for (index in 0 until length()) {
            val value = optJSONObject(index) ?: throw FriendsException.InvalidResponse(
                "The server returned an invalid list item.",
            )
            add(value)
        }
    }
}
