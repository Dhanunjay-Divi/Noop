package com.noop.managed

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal data class ManagedDocumentKey(
    val keyId: UUID,
    val keyData: ByteArray,
) {
    init {
        require(keyData.size == 32)
    }

    override fun equals(other: Any?): Boolean =
        other is ManagedDocumentKey &&
            keyId == other.keyId &&
            keyData.contentEquals(other.keyData)

    override fun hashCode(): Int = 31 * keyId.hashCode() + keyData.contentHashCode()
}

internal interface ManagedDocumentKeyProvider {
    fun recoveryEnrollmentComplete(accountScopeHash: String): Boolean
    fun activeDocumentKey(accountScopeHash: String): ManagedDocumentKey
    fun documentKey(accountScopeHash: String, keyId: UUID): ManagedDocumentKey
}

internal interface ManagedDocumentKeyVaultStorage {
    fun load(accountScopeHash: String): String?
    fun save(accountScopeHash: String, value: String)
    fun remove(accountScopeHash: String)
}

internal class ManagedDocumentKeyVault(
    private val storage: ManagedDocumentKeyVaultStorage,
) : ManagedDocumentKeyProvider {
    @Synchronized
    override fun recoveryEnrollmentComplete(accountScopeHash: String): Boolean {
        requireAccount(accountScopeHash)
        return state(accountScopeHash).optJSONObject("recovery_enrollment") != null
    }

    @Synchronized
    fun completeRecoveryEnrollment(
        accountScopeHash: String,
        masterKey: ByteArray,
        serverReceipt: ManagedAccountMasterKeyReceipt,
    ) {
        requireAccount(accountScopeHash)
        require(masterKey.size == 32)
        require(
            ManagedAccountMasterKeyBinding.matches(
                masterKey = masterKey,
                accountScopeHash = accountScopeHash,
                receipt = serverReceipt,
            ),
        )
        val value = state(accountScopeHash)
        require(
            value.optJSONObject("recovery_enrollment") == null &&
                value.optString("active_master_key_id").isEmpty() &&
                value.getJSONObject("document_keys").length() == 0 &&
                value.optJSONObject("pending_master_rotation") == null,
        )
        value
            .put("active_master_key_id", serverReceipt.keyId.toString().lowercase())
            .put("master_key_base64", Base64.getEncoder().encodeToString(masterKey))
            .put("master_wrapping_revision", serverReceipt.wrappingRevision)
            .put("recovery_enrollment", masterReceiptJson(serverReceipt))
        save(accountScopeHash, value)
    }

    @Synchronized
    fun createDocumentKey(
        accountScopeHash: String,
        keyId: UUID = UUID.randomUUID(),
    ): ManagedDocumentKey {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        requireEnrolled(value)
        require(value.optJSONObject("pending_master_rotation") == null)
        val id = keyId.toString().lowercase()
        val keys = value.getJSONObject("document_keys")
        val wrappedKeys = value.getJSONObject("wrapped_document_keys")
        val revoked = value.getJSONArray("revoked_document_key_ids").strings()
        require(!keys.has(id) && !wrappedKeys.has(id) && id !in revoked)
        val key = ByteArray(32).also(SecureRandom()::nextBytes)
        val masterKeyId = UUID.fromString(value.getString("active_master_key_id"))
        val masterKey = Base64.getDecoder().decode(value.getString("master_key_base64"))
        val wrappingRevision = value.getInt("master_wrapping_revision")
        val wrapped = ManagedWrappedDocumentKey(
            keyId = keyId,
            wrappingKeyId = masterKeyId,
            wrappingRevision = wrappingRevision,
            wrappedKey = ManagedDocumentKeyWrapEnvelope.seal(
                documentKey = key,
                accountScopeHash = accountScopeHash,
                keyId = keyId,
                wrappingKeyId = masterKeyId,
                wrappingRevision = wrappingRevision,
                wrappingKey = masterKey,
            ),
        )
        keys.put(id, Base64.getEncoder().encodeToString(key))
        wrappedKeys.put(id, wrappedKeyJson(wrapped))
        value.put("active_document_key_id", id)
        save(accountScopeHash, value)
        return ManagedDocumentKey(keyId, key)
    }

    @Synchronized
    override fun activeDocumentKey(accountScopeHash: String): ManagedDocumentKey {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        requireEnrolled(value)
        val id = value.optString("active_document_key_id")
            .takeIf(String::isNotEmpty)
            ?: throw ManagedStorageException.InvalidResponse()
        return key(value, UUID.fromString(id))
    }

    @Synchronized
    override fun documentKey(
        accountScopeHash: String,
        keyId: UUID,
    ): ManagedDocumentKey {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        requireEnrolled(value)
        return key(value, keyId)
    }

    @Synchronized
    fun wrappedDocumentKeys(accountScopeHash: String): List<ManagedWrappedDocumentKey> {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        requireEnrolled(value)
        val revoked = value.getJSONArray("revoked_document_key_ids").strings()
        val keys = value.getJSONObject("document_keys")
        val wrapped = value.getJSONObject("wrapped_document_keys")
        require(keys.length() == wrapped.length())
        return wrapped.keys().asSequence().toList().sorted()
            .filterNot(revoked::contains)
            .map { id ->
                require(keys.has(id))
                parseWrappedKey(wrapped.getJSONObject(id))
            }
    }

    @Synchronized
    fun prepareAccountMasterKeyRotation(
        accountScopeHash: String,
        newMasterKey: ByteArray,
        serverReceipt: ManagedAccountMasterKeyReceipt,
        planId: UUID = UUID.randomUUID(),
    ): ManagedDocumentKeyRotationPlan {
        requireAccount(accountScopeHash)
        require(newMasterKey.size == 32)
        require(
            ManagedAccountMasterKeyBinding.matches(
                masterKey = newMasterKey,
                accountScopeHash = accountScopeHash,
                receipt = serverReceipt,
            ),
        )
        val value = state(accountScopeHash)
        requireEnrolled(value)
        require(value.optJSONObject("pending_master_rotation") == null)
        require(
            serverReceipt.keyId.toString().lowercase() !=
                value.getString("active_master_key_id"),
        )
        require(
            serverReceipt.wrappingRevision >
                value.getInt("master_wrapping_revision"),
        )
        val wrapped = JSONObject()
        val keys = value.getJSONObject("document_keys")
        keys.keys().asSequence().toList().sorted().forEach { id ->
            val keyId = UUID.fromString(id)
            val record = ManagedWrappedDocumentKey(
                keyId = keyId,
                wrappingKeyId = serverReceipt.keyId,
                wrappingRevision = serverReceipt.wrappingRevision,
                wrappedKey = ManagedDocumentKeyWrapEnvelope.seal(
                    documentKey = Base64.getDecoder().decode(keys.getString(id)),
                    accountScopeHash = accountScopeHash,
                    keyId = keyId,
                    wrappingKeyId = serverReceipt.keyId,
                    wrappingRevision = serverReceipt.wrappingRevision,
                    wrappingKey = newMasterKey,
                ),
            )
            wrapped.put(id, wrappedKeyJson(record))
        }
        value.put(
            "pending_master_rotation",
            JSONObject()
                .put("plan_id", planId.toString().lowercase())
                .put("account_master_receipt", masterReceiptJson(serverReceipt))
                .put(
                    "master_key_base64",
                    Base64.getEncoder().encodeToString(newMasterKey),
                )
                .put("wrapped_document_keys", wrapped),
        )
        save(accountScopeHash, value)
        return rotationPlan(value.getJSONObject("pending_master_rotation"))
    }

    @Synchronized
    fun pendingAccountMasterKeyRotation(
        accountScopeHash: String,
    ): ManagedDocumentKeyRotationPlan? {
        requireAccount(accountScopeHash)
        val pending = state(accountScopeHash).optJSONObject("pending_master_rotation")
            ?: return null
        return rotationPlan(pending)
    }

    @Synchronized
    fun commitAccountMasterKeyRotation(
        accountScopeHash: String,
        planId: UUID,
        acknowledgedDocumentKeys: List<ManagedWrappedDocumentKey>,
    ) {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        val pending = value.optJSONObject("pending_master_rotation")
            ?: throw ManagedStorageException.InvalidResponse()
        require(pending.getString("plan_id") == planId.toString().lowercase())
        val expected = pending.getJSONObject("wrapped_document_keys")
        val acknowledged = linkedMapOf<String, ManagedWrappedDocumentKey>()
        acknowledgedDocumentKeys.forEach { record ->
            val id = record.keyId.toString().lowercase()
            require(acknowledged.put(id, record) == null)
        }
        require(acknowledged.size == expected.length())
        expected.keys().forEach { id ->
            require(
                acknowledged[id] == parseWrappedKey(expected.getJSONObject(id)),
            )
        }
        val receipt = parseMasterReceipt(
            pending.getJSONObject("account_master_receipt"),
        )
        value
            .put("active_master_key_id", receipt.keyId.toString().lowercase())
            .put("master_key_base64", pending.getString("master_key_base64"))
            .put("master_wrapping_revision", receipt.wrappingRevision)
            .put("recovery_enrollment", masterReceiptJson(receipt))
            .put("wrapped_document_keys", expected)
        value.remove("pending_master_rotation")
        save(accountScopeHash, value)
    }

    @Synchronized
    fun cancelAccountMasterKeyRotation(
        accountScopeHash: String,
        planId: UUID,
    ) {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        val pending = value.optJSONObject("pending_master_rotation")
            ?: throw ManagedStorageException.InvalidResponse()
        require(pending.getString("plan_id") == planId.toString().lowercase())
        value.remove("pending_master_rotation")
        save(accountScopeHash, value)
    }

    @Synchronized
    fun recoverDocumentKey(
        accountScopeHash: String,
        wrapped: ManagedWrappedDocumentKey,
        masterKey: ByteArray,
        makeActive: Boolean,
    ) {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        requireEnrolled(value)
        val id = wrapped.keyId.toString().lowercase()
        if (id in value.getJSONArray("revoked_document_key_ids").strings()) {
            throw ManagedStorageException.InvalidResponse()
        }
        val key = ManagedDocumentKeyWrapEnvelope.open(
            envelope = wrapped.wrappedKey,
            accountScopeHash = accountScopeHash,
            keyId = wrapped.keyId,
            wrappingKeyId = wrapped.wrappingKeyId,
            wrappingRevision = wrapped.wrappingRevision,
            wrappingKey = masterKey,
        )
        value.getJSONObject("document_keys")
            .put(id, Base64.getEncoder().encodeToString(key))
        value.getJSONObject("wrapped_document_keys")
            .put(id, wrappedKeyJson(wrapped))
        if (makeActive) value.put("active_document_key_id", id)
        save(accountScopeHash, value)
    }

    @Synchronized
    fun revokeDocumentKey(accountScopeHash: String, keyId: UUID) {
        requireAccount(accountScopeHash)
        val value = state(accountScopeHash)
        val id = keyId.toString().lowercase()
        val keys = value.getJSONObject("document_keys")
        val wrapped = value.getJSONObject("wrapped_document_keys")
        val revoked = value.getJSONArray("revoked_document_key_ids")
        if (!keys.has(id) && id !in revoked.strings()) {
            throw ManagedStorageException.InvalidResponse()
        }
        keys.remove(id)
        wrapped.remove(id)
        if (id !in revoked.strings()) revoked.put(id)
        if (value.optString("active_document_key_id") == id) {
            value.remove("active_document_key_id")
        }
        save(accountScopeHash, value)
    }

    @Synchronized
    fun removeAccount(accountScopeHash: String) {
        requireAccount(accountScopeHash)
        storage.remove(accountScopeHash)
    }

    private fun key(value: JSONObject, keyId: UUID): ManagedDocumentKey {
        val id = keyId.toString().lowercase()
        if (id in value.getJSONArray("revoked_document_key_ids").strings()) {
            throw ManagedStorageException.InvalidResponse()
        }
        val encoded = value.getJSONObject("document_keys").optString(id)
            .takeIf(String::isNotEmpty)
            ?: throw ManagedStorageException.InvalidResponse()
        return ManagedDocumentKey(keyId, Base64.getDecoder().decode(encoded))
    }

    private fun state(accountScopeHash: String): JSONObject {
        val persisted = storage.load(accountScopeHash)
        if (persisted == null) {
            return JSONObject()
                .put("version", 3)
                .put("master_wrapping_revision", 0)
                .put("document_keys", JSONObject())
                .put("wrapped_document_keys", JSONObject())
                .put("revoked_document_key_ids", JSONArray())
        }
        return runCatching { JSONObject(persisted) }
            .getOrElse { throw ManagedStorageException.InvalidResponse() }
            .also {
                if (
                    it.optInt("version") != 3 ||
                    it.optJSONObject("document_keys") == null ||
                    it.optJSONObject("wrapped_document_keys") == null ||
                    it.optJSONArray("revoked_document_key_ids") == null
                ) {
                    throw ManagedStorageException.InvalidResponse()
                }
                validateBoundMasterState(it, accountScopeHash)
            }
    }

    private fun save(accountScopeHash: String, value: JSONObject) {
        storage.save(accountScopeHash, ManagedCanonicalJson.encode(value))
    }

    private fun requireEnrolled(value: JSONObject) {
        if (
            value.optJSONObject("recovery_enrollment") == null ||
            value.optString("active_master_key_id").isEmpty() ||
            value.optString("master_key_base64").isEmpty() ||
            value.optInt("master_wrapping_revision") <= 0
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun rotationPlan(value: JSONObject): ManagedDocumentKeyRotationPlan {
        val wrapped = value.getJSONObject("wrapped_document_keys")
        return ManagedDocumentKeyRotationPlan(
            planId = UUID.fromString(value.getString("plan_id")),
            accountMasterReceipt = parseMasterReceipt(
                value.getJSONObject("account_master_receipt"),
            ),
            wrappedDocumentKeys = wrapped.keys().asSequence().toList().sorted().map {
                parseWrappedKey(wrapped.getJSONObject(it))
            },
        )
    }

    private fun masterReceiptJson(
        receipt: ManagedAccountMasterKeyReceipt,
    ): JSONObject = JSONObject()
        .put("version", receipt.version)
        .put("key_id", receipt.keyId.toString().lowercase())
        .put("wrapping_revision", receipt.wrappingRevision)
        .put("algorithm", receipt.algorithm)
        .put(
            "wrapped_key_base64",
            Base64.getEncoder().encodeToString(receipt.wrappedKey),
        )
        .put("wrapped_key_sha256", receipt.wrappedKeySha256)
        .put(
            "master_key_confirmation_hmac_sha256",
            receipt.masterKeyConfirmationHmacSha256,
        )
        .put("recovery_method", receipt.recoveryMethod)
        .put("status", receipt.status)

    private fun parseMasterReceipt(value: JSONObject): ManagedAccountMasterKeyReceipt {
        val wrapped = Base64.getDecoder().decode(
            value.getString("wrapped_key_base64"),
        )
        require(sha256(wrapped) == value.getString("wrapped_key_sha256"))
        return ManagedAccountMasterKeyReceipt(
            version = value.getInt("version"),
            keyId = UUID.fromString(value.getString("key_id")),
            wrappingRevision = value.getInt("wrapping_revision"),
            algorithm = value.getString("algorithm"),
            wrappedKey = wrapped,
            masterKeyConfirmationHmacSha256 = value.getString(
                "master_key_confirmation_hmac_sha256",
            ),
            recoveryMethod = value.getString("recovery_method"),
            status = value.getString("status"),
        )
    }

    private fun wrappedKeyJson(record: ManagedWrappedDocumentKey): JSONObject =
        JSONObject()
            .put("version", record.version)
            .put("key_id", record.keyId.toString().lowercase())
            .put("wrapping_key_id", record.wrappingKeyId.toString().lowercase())
            .put("wrapping_revision", record.wrappingRevision)
            .put("algorithm", record.algorithm)
            .put(
                "wrapped_key_base64",
                Base64.getEncoder().encodeToString(record.wrappedKey),
            )
            .put("wrapped_key_sha256", record.wrappedKeySha256)

    private fun parseWrappedKey(value: JSONObject): ManagedWrappedDocumentKey {
        val wrapped = Base64.getDecoder().decode(
            value.getString("wrapped_key_base64"),
        )
        require(sha256(wrapped) == value.getString("wrapped_key_sha256"))
        return ManagedWrappedDocumentKey(
            version = value.getInt("version"),
            keyId = UUID.fromString(value.getString("key_id")),
            wrappingKeyId = UUID.fromString(value.getString("wrapping_key_id")),
            wrappingRevision = value.getInt("wrapping_revision"),
            algorithm = value.getString("algorithm"),
            wrappedKey = wrapped,
        )
    }

    private fun requireAccount(accountScopeHash: String) {
        require(accountScopeHash.matches(SHA256))
    }

    private fun validateBoundMasterState(
        value: JSONObject,
        accountScopeHash: String,
    ) {
        val recovery = value.optJSONObject("recovery_enrollment")
        if (recovery == null) {
            require(value.optString("active_master_key_id").isEmpty())
            require(value.optString("master_key_base64").isEmpty())
            require(value.optInt("master_wrapping_revision") == 0)
        } else {
            val receipt = parseMasterReceipt(recovery)
            val masterKey = Base64.getDecoder().decode(
                value.getString("master_key_base64"),
            )
            require(masterKey.size == 32)
            require(
                value.getString("active_master_key_id") ==
                    receipt.keyId.toString().lowercase(),
            )
            require(
                value.getInt("master_wrapping_revision") ==
                    receipt.wrappingRevision,
            )
            require(
                ManagedAccountMasterKeyBinding.matches(
                    masterKey = masterKey,
                    accountScopeHash = accountScopeHash,
                    receipt = receipt,
                ),
            )
        }
        value.optJSONObject("pending_master_rotation")?.let { pending ->
            val receipt = parseMasterReceipt(
                pending.getJSONObject("account_master_receipt"),
            )
            val masterKey = Base64.getDecoder().decode(
                pending.getString("master_key_base64"),
            )
            require(masterKey.size == 32)
            require(
                ManagedAccountMasterKeyBinding.matches(
                    masterKey = masterKey,
                    accountScopeHash = accountScopeHash,
                    receipt = receipt,
                ),
            )
        }
    }

    private fun JSONArray.strings(): Set<String> = buildSet {
        for (index in 0 until length()) add(getString(index))
    }

    private companion object {
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

internal class AndroidManagedDocumentKeyVaultStorage(context: Context) :
    ManagedDocumentKeyVaultStorage {
    private val preferences = EncryptedSharedPreferences.create(
        context.applicationContext,
        FILE,
        MasterKey.Builder(context.applicationContext, MASTER_KEY_ALIAS)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override fun load(accountScopeHash: String): String? =
        preferences.getString(accountScopeHash, null)

    override fun save(accountScopeHash: String, value: String) {
        if (!preferences.edit().putString(accountScopeHash, value).commit()) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    override fun remove(accountScopeHash: String) {
        if (!preferences.edit().remove(accountScopeHash).commit()) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private companion object {
        const val FILE = "noop_managed_document_keys_v1"
        const val MASTER_KEY_ALIAS = "noop_managed_document_keys_master_v1"
    }
}
