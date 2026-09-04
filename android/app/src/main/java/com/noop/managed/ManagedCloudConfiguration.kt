package com.noop.managed

import com.noop.BuildConfig

data class ManagedCloudConfiguration(
    val storage: ManagedStorageConfiguration,
    val projectId: String,
    val apiKey: String,
    val googleAppId: String,
    val gcmSenderId: String,
) {
    init {
        require(projectId.matches(Regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$")))
        require(apiKey.isNotBlank())
        require(googleAppId.matches(Regex("^1:[0-9]+:android:[0-9a-f]+$")))
        require(gcmSenderId.matches(Regex("^[0-9]{6,20}$")))
    }

    companion object {
        fun load(): ManagedCloudConfiguration? {
            val values = listOf(
                BuildConfig.MANAGED_API_URL,
                BuildConfig.MANAGED_PROJECT_ID,
                BuildConfig.MANAGED_API_KEY,
                BuildConfig.MANAGED_GOOGLE_APP_ID,
                BuildConfig.MANAGED_GCM_SENDER_ID,
                BuildConfig.MANAGED_POLICY_VERSION,
                BuildConfig.MANAGED_POLICY_SHA256,
            ).map(String::trim)
            if (values.any(String::isEmpty)) return null
            return runCatching {
                ManagedCloudConfiguration(
                    storage = ManagedStorageConfiguration(
                        baseUrl = values[0],
                        policyVersion = values[5],
                        policySha256 = values[6],
                    ),
                    projectId = values[1],
                    apiKey = values[2],
                    googleAppId = values[3],
                    gcmSenderId = values[4],
                )
            }.getOrNull()
        }
    }
}
