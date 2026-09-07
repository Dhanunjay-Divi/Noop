package com.noop.ownership

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

internal data class OwnershipInstallationCredential(
    val id: String,
    val token: String,
) {
    companion object {
        fun decodePersisted(raw: String): OwnershipInstallationCredential {
            val value = runCatching {
                val objectValue = JSONObject(raw)
                OwnershipInstallationCredential(
                    id = objectValue.getString("id"),
                    token = objectValue.getString("token"),
                )
            }.getOrNull()
            if (
                value == null ||
                !value.id.matches(INSTALLATION_ID) ||
                !value.token.matches(INSTALLATION_TOKEN)
            ) {
                throw OwnershipException.SecureStorage
            }
            return value
        }

        private val INSTALLATION_ID =
            Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
        private val INSTALLATION_TOKEN =
            Regex("^noopo_[A-Za-z0-9_-]{43}$")
    }
}

internal class OwnershipSecureStore(context: Context) {
    private val preferences: SharedPreferences = EncryptedSharedPreferences.create(
        context.applicationContext,
        FILE,
        MasterKey.Builder(context.applicationContext, MASTER_KEY_ALIAS)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun installationCredential(scope: String): OwnershipInstallationCredential =
        synchronized(this) {
            require(scope.matches(SHA256))
            val key = "$INSTALLATION_PREFIX$scope"
            val persisted = secureStorageOperation {
                preferences.getString(key, null)
            }
            if (persisted != null) {
                return@synchronized OwnershipInstallationCredential
                    .decodePersisted(persisted)
            }
            createCredential().also { created ->
                val encoded = JSONObject()
                    .put("id", created.id)
                    .put("token", created.token)
                    .toString()
                if (!secureStorageOperation {
                        preferences.edit().putString(key, encoded).commit()
                    }
                ) {
                    throw OwnershipException.SecureStorage
                }
            }
        }

    fun checkpoint(scope: String): OwnershipCheckpoint? {
        require(scope.matches(SHA256))
        val persisted = secureStorageOperation {
            preferences.getString("$CHECKPOINT_PREFIX$scope", null)
        }
        return persisted?.let(OwnershipCheckpoint::decodePersisted)
    }

    fun writeCheckpoint(scope: String, checkpoint: OwnershipCheckpoint) {
        require(scope.matches(SHA256))
        if (
            !checkpoint.isValid ||
            !secureStorageOperation {
                preferences.edit()
                    .putString("$CHECKPOINT_PREFIX$scope", checkpoint.toJson())
                    .commit()
            }
        ) {
            throw OwnershipException.SecureStorage
        }
    }

    fun phoneVerificationId(scope: String): String? {
        require(scope.matches(SHA256))
        return secureStorageOperation {
            preferences.getString("$PHONE_PREFIX$scope", null)
        }
            ?.takeIf { it.length in 1..4096 }
    }

    fun writePhoneVerificationId(scope: String, value: String) {
        require(scope.matches(SHA256))
        require(value.length in 1..4096)
        if (!secureStorageOperation {
                preferences.edit().putString("$PHONE_PREFIX$scope", value).commit()
            }
        ) {
            throw OwnershipException.SecureStorage
        }
    }

    fun clearPhoneVerificationId(scope: String): Boolean {
        require(scope.matches(SHA256))
        return bestEffortOwnershipCleanup {
            secureStorageOperation {
                preferences.edit().remove("$PHONE_PREFIX$scope").commit()
            }
        }
    }

    private fun createCredential(): OwnershipInstallationCredential {
        val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
        val token = "noopo_" +
            Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        check(token.matches(INSTALLATION_TOKEN))
        return OwnershipInstallationCredential(
            id = UUID.randomUUID().toString().lowercase(),
            token = token,
        )
    }

    companion object {
        private const val FILE = "noop_ownership_secure_v1"
        private const val MASTER_KEY_ALIAS = "noop_ownership_master_key_v1"
        private const val INSTALLATION_PREFIX = "installation."
        private const val CHECKPOINT_PREFIX = "checkpoint."
        private const val PHONE_PREFIX = "phone_verification."
        private val SHA256 = Regex("^[0-9a-f]{64}$")
        private val INSTALLATION_TOKEN =
            Regex("^noopo_[A-Za-z0-9_-]{43}$")

        fun resetAll(context: Context): Boolean =
            bestEffortOwnershipCleanup {
                val application = context.applicationContext
                val preferencesDeleted = application.deleteSharedPreferences(FILE)
                val preferencesEmpty = application
                    .getSharedPreferences(FILE, Context.MODE_PRIVATE)
                    .all
                    .isEmpty()
                val keyStore = KeyStore.getInstance("AndroidKeyStore").apply {
                    load(null)
                }
                if (keyStore.containsAlias(MASTER_KEY_ALIAS)) {
                    keyStore.deleteEntry(MASTER_KEY_ALIAS)
                }
                preferencesDeleted || preferencesEmpty
            }
    }
}

private inline fun <T> secureStorageOperation(operation: () -> T): T =
    try {
        operation()
    } catch (error: OwnershipException) {
        throw error
    } catch (_: RuntimeException) {
        throw OwnershipException.SecureStorage
    }

internal inline fun bestEffortOwnershipCleanup(cleanup: () -> Boolean): Boolean =
    try {
        cleanup()
    } catch (_: Exception) {
        false
    }
