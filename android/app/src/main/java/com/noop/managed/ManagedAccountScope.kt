package com.noop.managed

import java.nio.charset.StandardCharsets

internal sealed class ManagedAccountScopeException :
    IllegalStateException() {
    data object InvalidIdentity : ManagedAccountScopeException()
    data object InvalidPersistedBinding : ManagedAccountScopeException()
    data object IdentityMismatch : ManagedAccountScopeException()
}

internal data class ManagedAccountScopeBinding(
    val identityScopeHash: String,
    val dataScopeHash: String,
    val dataScopeVersion: Int,
    val requiresPersistence: Boolean,
) {
    init {
        require(identityScopeHash.matches(SHA256))
        require(dataScopeHash.matches(SHA256))
        require(dataScopeVersion in 1..2)
    }

    private companion object {
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

internal object ManagedAccountScope {
    const val BINDING_SCHEMA_VERSION = 1

    fun legacy(uid: String): String {
        requireIdentity(uid)
        return ManagedDigest.sha256(
            "noop-managed-account-v1\u0000$uid"
                .toByteArray(StandardCharsets.UTF_8),
        )
    }

    fun identity(projectId: String, tenantId: String?, uid: String): String {
        val tenant = tenantId.orEmpty()
        requireIdentity(projectId)
        requireIdentity(tenant, allowEmpty = true)
        requireIdentity(uid)
        val seed = buildString {
            append("noop-managed-account-v2\u0000")
            append(lengthPrefixed(projectId))
            append('\u0000')
            append(lengthPrefixed(tenant))
            append('\u0000')
            append(lengthPrefixed(uid))
        }
        return ManagedDigest.sha256(seed.toByteArray(StandardCharsets.UTF_8))
    }

    fun resolve(
        projectId: String,
        tenantId: String?,
        uid: String,
        enrolledDataScopeHash: String?,
        persistedIdentityScopeHash: String?,
        persistedDataScopeVersion: Int?,
    ): ManagedAccountScopeBinding {
        val legacyScope = legacy(uid)
        val identityScope = identity(projectId, tenantId, uid)
        val hasAnyPersistedBinding =
            persistedIdentityScopeHash != null || persistedDataScopeVersion != null

        if (hasAnyPersistedBinding) {
            if (persistedIdentityScopeHash != null &&
                persistedIdentityScopeHash != identityScope
            ) {
                throw ManagedAccountScopeException.IdentityMismatch
            }
            if (enrolledDataScopeHash == null ||
                persistedIdentityScopeHash == null ||
                persistedDataScopeVersion == null ||
                !enrolledDataScopeHash.matches(SHA256)
            ) {
                throw ManagedAccountScopeException.InvalidPersistedBinding
            }
            val expectedDataScope = when (persistedDataScopeVersion) {
                1 -> legacyScope
                2 -> identityScope
                else -> throw ManagedAccountScopeException.InvalidPersistedBinding
            }
            if (enrolledDataScopeHash != expectedDataScope) {
                throw ManagedAccountScopeException.InvalidPersistedBinding
            }
            return ManagedAccountScopeBinding(
                identityScopeHash = identityScope,
                dataScopeHash = enrolledDataScopeHash,
                dataScopeVersion = persistedDataScopeVersion,
                requiresPersistence = false,
            )
        }

        if (enrolledDataScopeHash == null) {
            return ManagedAccountScopeBinding(
                identityScopeHash = identityScope,
                dataScopeHash = identityScope,
                dataScopeVersion = 2,
                requiresPersistence = true,
            )
        }
        if (!enrolledDataScopeHash.matches(SHA256)) {
            throw ManagedAccountScopeException.InvalidPersistedBinding
        }
        return when (enrolledDataScopeHash) {
            legacyScope -> ManagedAccountScopeBinding(
                identityScopeHash = identityScope,
                dataScopeHash = legacyScope,
                dataScopeVersion = 1,
                requiresPersistence = true,
            )
            identityScope -> ManagedAccountScopeBinding(
                identityScopeHash = identityScope,
                dataScopeHash = identityScope,
                dataScopeVersion = 2,
                requiresPersistence = true,
            )
            else -> throw ManagedAccountScopeException.IdentityMismatch
        }
    }

    private fun requireIdentity(value: String, allowEmpty: Boolean = false) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        if ((!allowEmpty && bytes.isEmpty()) ||
            bytes.size > 1_024 ||
            value.indexOf('\u0000') >= 0
        ) {
            throw ManagedAccountScopeException.InvalidIdentity
        }
    }

    private fun lengthPrefixed(value: String): String =
        "${value.toByteArray(StandardCharsets.UTF_8).size}:$value"

    private val SHA256 = Regex("^[0-9a-f]{64}$")
}
