package com.noop.social

import com.noop.sync.RemoteSyncClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException

internal class FriendsClient(
    private val baseUrl: String,
    private val bearerToken: String? = null,
    private val http: OkHttpClient = RemoteSyncClient.defaultHttp(timeoutSeconds = 30),
) {
    suspend fun bootstrap(
        displayName: String,
        installationId: String,
        dailyDeviceId: String,
    ): FriendBootstrap = jsonRequest(
        path = "v1/social/bootstrap",
        method = "POST",
        body = JSONObject()
            .put("display_name", displayName)
            .put("installation_id", installationId)
            .put("daily_device_id", dailyDeviceId),
        authenticated = true,
        decode = FriendsJson::bootstrap,
    )

    suspend fun join(
        code: String,
        displayName: String,
        installationId: String,
        dailyDeviceId: String,
        enrollmentId: String,
        memberToken: String,
    ): FriendJoin = jsonRequest(
        path = "v1/social/invites/join",
        method = "POST",
        body = JSONObject()
            .put("code", code)
            .put("display_name", displayName)
            .put("installation_id", installationId)
            .put("daily_device_id", dailyDeviceId)
            .put("enrollment_id", enrollmentId)
            .put("member_token", memberToken),
        authenticated = false,
        decode = FriendsJson::join,
    )

    suspend fun createInvite(): FriendInvite = jsonRequest(
        path = "v1/social/invites",
        method = "POST",
        body = JSONObject().put("expires_in_hours", 72),
        authenticated = true,
    ) { FriendsJson.invite(it, baseUrl) }

    suspend fun redeem(code: String) {
        jsonRequest(
            path = "v1/social/invites/redeem",
            method = "POST",
            body = JSONObject().put("code", code),
            authenticated = true,
        ) { Unit }
    }

    suspend fun friends(): List<FriendContact> = jsonRequest(
        path = "v1/social/friends",
        method = "GET",
        authenticated = true,
        decode = FriendsJson::friends,
    )

    suspend fun requests(): List<FriendRequest> = jsonRequest(
        path = "v1/social/requests",
        method = "GET",
        authenticated = true,
        decode = FriendsJson::requests,
    )

    suspend fun feed(start: String, end: String): Map<String, FriendDailySummary> = jsonRequest(
        path = "v1/social/feed?start=$start&end=$end",
        method = "GET",
        authenticated = true,
        decode = FriendsJson::feed,
    )

    suspend fun decide(requestId: String, accept: Boolean) {
        jsonRequest(
            path = "v1/social/requests/$requestId",
            method = "POST",
            body = JSONObject().put("decision", if (accept) "accept" else "decline"),
            authenticated = true,
        ) { Unit }
    }

    suspend fun updatePrivacy(friendId: String, visibility: FriendVisibility) {
        jsonRequest(
            path = "v1/social/friends/$friendId/privacy",
            method = "PATCH",
            body = visibility.toJson(),
            authenticated = true,
        ) { Unit }
    }

    suspend fun removeFriend(friendId: String) {
        emptyRequest("v1/social/friends/$friendId", "DELETE")
    }

    suspend fun deleteProfile() {
        emptyRequest(
            path = "v1/social/me",
            method = "DELETE",
            headers = mapOf("X-Noop-Confirm" to "DELETE MY SOCIAL PROFILE"),
        )
    }

    suspend fun deletePendingEnrollment(enrollmentId: String) {
        emptyRequest(
            path = "v1/social/enrollments/$enrollmentId",
            method = "DELETE",
            headers = mapOf(
                "X-Noop-Confirm" to "DELETE PENDING SOCIAL ENROLLMENT",
            ),
        )
    }

    private suspend fun emptyRequest(
        path: String,
        method: String,
        headers: Map<String, String> = emptyMap(),
    ) = withContext(Dispatchers.IO) {
        val builder = requestBuilder(path, authenticated = true)
        headers.forEach(builder::header)
        when (method) {
            "DELETE" -> builder.delete()
            else -> throw IllegalArgumentException("Unsupported Friends method.")
        }
        execute(builder.build())
    }

    private suspend fun <T> jsonRequest(
        path: String,
        method: String,
        body: JSONObject? = null,
        authenticated: Boolean,
        decode: (JSONObject) -> T,
    ): T = withContext(Dispatchers.IO) {
        val builder = requestBuilder(path, authenticated)
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post((body ?: JSONObject()).toString().toRequestBody(JSON))
            "PATCH" -> builder.patch((body ?: JSONObject()).toString().toRequestBody(JSON))
            else -> throw IllegalArgumentException("Unsupported Friends method.")
        }
        val raw = execute(builder.build())
        val json = try {
            JSONObject(raw)
        } catch (error: Throwable) {
            throw FriendsException.InvalidResponse(
                "The server returned an unreadable Friends response.",
            )
        }
        try {
            decode(json)
        } catch (error: FriendsException) {
            throw error
        } catch (error: Throwable) {
            throw FriendsException.InvalidResponse(
                "The server returned an invalid Friends response.",
            )
        }
    }

    private fun requestBuilder(path: String, authenticated: Boolean): Request.Builder {
        val builder = Request.Builder()
            .url("${baseUrl.trimEnd('/')}/$path")
            .header("Accept", "application/json")
            .header("User-Agent", "Noop-Android/friends-v1")
        if (authenticated) {
            val token = bearerToken?.takeIf(String::isNotBlank)
                ?: throw FriendsException.InvalidInput("The Friends credential is missing.")
            builder.header("Authorization", "Bearer $token")
        }
        return builder
    }

    private fun execute(request: Request): String {
        val response = try {
            http.newCall(request).execute()
        } catch (error: IOException) {
            throw FriendsException.Network("Could not reach the private Friends server.", error)
        }
        response.use {
            val body = runCatching { it.body?.string().orEmpty() }.getOrDefault("")
            if (!it.isSuccessful) {
                val detail = runCatching {
                    JSONObject(body).optString("detail").takeIf(String::isNotBlank)
                }.getOrNull()
                throw FriendsException.Server(
                    it.code,
                    detail?.take(300) ?: serverMessage(it.code),
                )
            }
            return body
        }
    }

    private fun serverMessage(status: Int): String = when (status) {
        400, 422 -> "The server rejected invalid Friends data (HTTP $status)."
        401, 403 -> "The Friends credential was not accepted (HTTP $status)."
        404 -> "The invitation or Friends record is no longer available (HTTP 404)."
        409 -> "The Friends request conflicts with existing server state (HTTP 409)."
        429 -> "The server is rate limiting Friends requests (HTTP 429)."
        in 500..599 -> "The private Friends server is unavailable (HTTP $status)."
        else -> "The Friends request failed (HTTP $status)."
    }

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
