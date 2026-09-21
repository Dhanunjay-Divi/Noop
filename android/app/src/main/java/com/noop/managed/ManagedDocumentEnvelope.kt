package com.noop.managed

import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

internal data class ManagedDocumentEnvelopeMetadata(
    val accountScopeHash: String,
    val documentKind: ManagedDocumentKind,
    val documentId: UUID,
    val revision: Long,
) {
    init {
        require(accountScopeHash.matches(SHA256))
        require(revision > 0L)
    }

    val authenticatedData: ByteArray
        get() = (
            "noop-managed-document-aad-v1\u0000$accountScopeHash\u0000" +
                "${documentKind.wireValue}\u0000${documentId.toString().lowercase()}\u0000$revision"
            ).toByteArray(StandardCharsets.UTF_8)

    private companion object {
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

internal object ManagedDocumentEnvelope {
    const val MAX_ENVELOPE_BYTES = 1_048_576
    const val MAX_PLAINTEXT_BYTES = MAX_ENVELOPE_BYTES - 40
    private val MAGIC = "NOOPDOC\u0000".toByteArray(StandardCharsets.US_ASCII)

    fun seal(
        plaintext: ByteArray,
        key: ByteArray,
        metadata: ManagedDocumentEnvelopeMetadata,
    ): ByteArray = seal(plaintext, key, metadata, null)

    internal fun seal(
        plaintext: ByteArray,
        key: ByteArray,
        metadata: ManagedDocumentEnvelopeMetadata,
        suppliedNonce: ByteArray?,
    ): ByteArray {
        require(key.size == 32)
        require(plaintext.size <= MAX_PLAINTEXT_BYTES)
        val nonce = suppliedNonce?.copyOf()
            ?: ByteArray(12).also(SecureRandom()::nextBytes)
        require(nonce.size == 12)
        val encrypted = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(
                Cipher.ENCRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, nonce),
            )
            updateAAD(metadata.authenticatedData)
            doFinal(plaintext)
        }
        return MAGIC + byteArrayOf(1, 12, 0, 0) + nonce + encrypted
    }

    fun open(
        envelope: ByteArray,
        key: ByteArray,
        metadata: ManagedDocumentEnvelopeMetadata,
    ): ByteArray {
        require(key.size == 32)
        if (
            envelope.size !in 40..MAX_ENVELOPE_BYTES ||
            !envelope.copyOfRange(0, 8).contentEquals(MAGIC) ||
            envelope[8] != 1.toByte() ||
            envelope[9] != 12.toByte() ||
            envelope[10] != 0.toByte() ||
            envelope[11] != 0.toByte()
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(key, "AES"),
                    GCMParameterSpec(128, envelope.copyOfRange(12, 24)),
                )
                updateAAD(metadata.authenticatedData)
                doFinal(envelope, 24, envelope.size - 24)
            }
        } catch (_: AEADBadTagException) {
            throw ManagedStorageException.InvalidResponse()
        } catch (_: java.security.GeneralSecurityException) {
            throw ManagedStorageException.InvalidResponse()
        }
    }
}

internal data class ManagedWrappedDocumentKey(
    val version: Int = 1,
    val keyId: UUID,
    val wrappingKeyId: UUID,
    val wrappingRevision: Int,
    val algorithm: String = "A256GCM",
    val wrappedKey: ByteArray,
) {
    init {
        require(version == 1)
        require(wrappingRevision > 0)
        require(algorithm == "A256GCM")
        require(wrappedKey.size == 72)
    }

    val wrappedKeySha256: String
        get() = sha256(wrappedKey)

    override fun equals(other: Any?): Boolean =
        other is ManagedWrappedDocumentKey &&
            version == other.version &&
            keyId == other.keyId &&
            wrappingKeyId == other.wrappingKeyId &&
            wrappingRevision == other.wrappingRevision &&
            algorithm == other.algorithm &&
            wrappedKey.contentEquals(other.wrappedKey)

    override fun hashCode(): Int =
        31 * keyId.hashCode() + wrappedKey.contentHashCode()
}

internal object ManagedAccountMasterKeyBinding {
    private const val CONTEXT =
        "noop-managed-account-master-key-confirmation-v1"
    private val SHA256 = Regex("^[0-9a-f]{64}$")
    private val RECOVERY_METHODS = setOf(
        "recovery_key",
        "device_transfer",
        "platform_escrow",
    )

    fun confirmationHmacSha256(
        masterKey: ByteArray,
        accountScopeHash: String,
        keyId: UUID,
        wrappingRevision: Int,
        wrappedKeySha256: String,
        recoveryMethod: String,
    ): String {
        require(masterKey.size == 32)
        require(accountScopeHash.matches(SHA256))
        require(wrappingRevision > 0)
        require(wrappedKeySha256.matches(SHA256))
        require(recoveryMethod in RECOVERY_METHODS)
        val message = listOf(
            CONTEXT,
            accountScopeHash,
            keyId.toString().lowercase(),
            wrappingRevision.toString(),
            wrappedKeySha256,
            recoveryMethod,
        ).joinToString("\u0000")
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(masterKey, "HmacSHA256"))
        return mac.doFinal(message.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    fun matches(
        masterKey: ByteArray,
        accountScopeHash: String,
        receipt: ManagedAccountMasterKeyReceipt,
    ): Boolean = runCatching {
        MessageDigest.isEqual(
            confirmationHmacSha256(
                masterKey = masterKey,
                accountScopeHash = accountScopeHash,
                keyId = receipt.keyId,
                wrappingRevision = receipt.wrappingRevision,
                wrappedKeySha256 = receipt.wrappedKeySha256,
                recoveryMethod = receipt.recoveryMethod,
            ).toByteArray(StandardCharsets.US_ASCII),
            receipt.masterKeyConfirmationHmacSha256
                .toByteArray(StandardCharsets.US_ASCII),
        )
    }.getOrDefault(false)
}

internal data class ManagedAccountMasterKeyReceipt(
    val version: Int = 1,
    val keyId: UUID,
    val wrappingRevision: Int,
    val algorithm: String = "A256GCM",
    val wrappedKey: ByteArray,
    val masterKeyConfirmationHmacSha256: String,
    val recoveryMethod: String,
    val status: String = "active",
) {
    init {
        require(version == 1)
        require(wrappingRevision > 0)
        require(algorithm == "A256GCM")
        require(wrappedKey.size in 40..16_384)
        require(masterKeyConfirmationHmacSha256.matches(SHA256))
        require(recoveryMethod in RECOVERY_METHODS)
        require(status == "active")
    }

    val wrappedKeySha256: String
        get() = sha256(wrappedKey)

    override fun equals(other: Any?): Boolean =
        other is ManagedAccountMasterKeyReceipt &&
            version == other.version &&
            keyId == other.keyId &&
            wrappingRevision == other.wrappingRevision &&
            algorithm == other.algorithm &&
            wrappedKey.contentEquals(other.wrappedKey) &&
            masterKeyConfirmationHmacSha256 ==
                other.masterKeyConfirmationHmacSha256 &&
            recoveryMethod == other.recoveryMethod &&
            status == other.status

    override fun hashCode(): Int =
        31 * keyId.hashCode() + wrappedKey.contentHashCode()

    private companion object {
        val SHA256 = Regex("^[0-9a-f]{64}$")
        val RECOVERY_METHODS = setOf(
            "recovery_key",
            "device_transfer",
            "platform_escrow",
        )
    }
}

internal data class ManagedDocumentKeyRotationPlan(
    val planId: UUID,
    val accountMasterReceipt: ManagedAccountMasterKeyReceipt,
    val wrappedDocumentKeys: List<ManagedWrappedDocumentKey>,
)

internal object ManagedDocumentKeyWrapEnvelope {
    private val MAGIC = "NOOPKEY\u0000".toByteArray(StandardCharsets.US_ASCII)

    fun seal(
        documentKey: ByteArray,
        accountScopeHash: String,
        keyId: UUID,
        wrappingKeyId: UUID,
        wrappingRevision: Int,
        wrappingKey: ByteArray,
        suppliedNonce: ByteArray? = null,
    ): ByteArray {
        require(documentKey.size == 32 && wrappingKey.size == 32)
        val nonce = suppliedNonce?.copyOf()
            ?: ByteArray(12).also(SecureRandom()::nextBytes)
        require(nonce.size == 12)
        val encrypted = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(
                Cipher.ENCRYPT_MODE,
                SecretKeySpec(wrappingKey, "AES"),
                GCMParameterSpec(128, nonce),
            )
            updateAAD(aad(accountScopeHash, keyId, wrappingKeyId, wrappingRevision))
            doFinal(documentKey)
        }
        return MAGIC + byteArrayOf(1, 12, 0, 0) + nonce + encrypted
    }

    fun open(
        envelope: ByteArray,
        accountScopeHash: String,
        keyId: UUID,
        wrappingKeyId: UUID,
        wrappingRevision: Int,
        wrappingKey: ByteArray,
    ): ByteArray {
        if (
            wrappingKey.size != 32 ||
            envelope.size != 72 ||
            !envelope.copyOfRange(0, 8).contentEquals(MAGIC) ||
            !envelope.copyOfRange(8, 12).contentEquals(byteArrayOf(1, 12, 0, 0))
        ) {
            throw ManagedStorageException.InvalidResponse()
        }
        return try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(wrappingKey, "AES"),
                    GCMParameterSpec(128, envelope.copyOfRange(12, 24)),
                )
                updateAAD(aad(accountScopeHash, keyId, wrappingKeyId, wrappingRevision))
                doFinal(envelope, 24, envelope.size - 24)
            }
        } catch (_: java.security.GeneralSecurityException) {
            throw ManagedStorageException.InvalidResponse()
        }
    }

    private fun aad(
        accountScopeHash: String,
        keyId: UUID,
        wrappingKeyId: UUID,
        wrappingRevision: Int,
    ): ByteArray = (
        "noop-managed-document-key-wrap-v1\u0000$accountScopeHash\u0000" +
            "${keyId.toString().lowercase()}\u0000" +
            "${wrappingKeyId.toString().lowercase()}\u0000$wrappingRevision"
        ).toByteArray(StandardCharsets.UTF_8)
}

internal fun sha256(value: ByteArray): String =
    MessageDigest.getInstance("SHA-256")
        .digest(value)
        .joinToString("") { "%02x".format(it) }
