package com.noop.ownership

import com.noop.BuildConfig
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

data class OwnershipConfiguration(
    val baseUrl: HttpUrl,
    val termsHost: String,
    val projectId: String,
    val apiKey: String,
    val googleAppId: String,
    val gcmSenderId: String,
) {
    init {
        require(baseUrl.query == null)
        require(baseUrl.fragment == null)
        require(baseUrl.username.isEmpty())
        require(baseUrl.password.isEmpty())
        require(baseUrl.encodedPath == "/")
        require(termsHost.matches(Regex("^[A-Za-z0-9.-]{1,253}$")))
        require(projectId.matches(Regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$")))
        require(apiKey.isNotBlank())
        require(googleAppId.matches(Regex("^1:[0-9]+:android:[0-9a-f]+$")))
        require(gcmSenderId.matches(Regex("^[0-9]{6,20}$")))
    }

    companion object {
        fun load(): OwnershipConfiguration? {
            if (!BuildConfig.OWNERSHIP_ACTIVATION_ENABLED) return null
            val apiUrl = BuildConfig.OWNERSHIP_API_URL.trim()
            val termsHost = BuildConfig.OWNERSHIP_TERMS_HOST.trim().lowercase()
            val projectId = BuildConfig.MANAGED_PROJECT_ID.trim()
            val apiKey = BuildConfig.MANAGED_API_KEY.trim()
            val googleAppId = BuildConfig.MANAGED_GOOGLE_APP_ID.trim()
            val gcmSenderId = BuildConfig.MANAGED_GCM_SENDER_ID.trim()
            if (
                listOf(
                    apiUrl,
                    termsHost,
                    projectId,
                    apiKey,
                    googleAppId,
                    gcmSenderId,
                ).any(String::isEmpty)
            ) {
                return null
            }
            return runCatching {
                val baseUrl = apiUrl.toHttpUrlOrNull()
                    ?: throw IllegalArgumentException("Invalid ownership URL")
                val local = baseUrl.host in setOf("127.0.0.1", "localhost", "::1")
                val validScheme = baseUrl.isHttps ||
                    (
                        BuildConfig.DEBUG &&
                            BuildConfig.OWNERSHIP_ALLOW_LOCAL_HTTP &&
                            local &&
                            baseUrl.scheme == "http"
                        )
                require(validScheme)
                OwnershipConfiguration(
                    baseUrl = baseUrl,
                    termsHost = termsHost,
                    projectId = projectId,
                    apiKey = apiKey,
                    googleAppId = googleAppId,
                    gcmSenderId = gcmSenderId,
                )
            }.getOrNull()
        }
    }
}
