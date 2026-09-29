package com.noop.ble.veepoo

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import java.security.MessageDigest

interface VeepooCredentialAccess {
    fun save(
        deviceId: String,
        password: CharArray,
        revisionBinding: VeepooRevisionBinding,
    ): Boolean

    fun load(deviceId: String): VeepooStoredCredential?
    fun readForRetention(deviceId: String): VeepooCredentialRead =
        try {
            load(deviceId)?.let(VeepooCredentialRead::Available)
                ?: VeepooCredentialRead.Missing
        } catch (_: Throwable) {
            VeepooCredentialRead.Unavailable
        }
    fun clear(deviceId: String): Boolean
}

interface VeepooCredentialCleanupAccess {
    fun markPending(deviceId: String): Boolean
    fun pendingDeviceIds(): VeepooCredentialCleanupRead
    fun clearPending(deviceId: String): Boolean
    fun markRejectedPending(deviceId: String): Boolean
    fun rejectedPendingDeviceIds(): VeepooCredentialCleanupRead
    fun clearRejectedPending(deviceId: String): Boolean
}

sealed interface VeepooCredentialCleanupRead {
    data class Available(val deviceIds: Set<String>) : VeepooCredentialCleanupRead
    data object Unavailable : VeepooCredentialCleanupRead
}

internal interface VeepooCredentialCleanupBackend {
    fun read(kind: VeepooCredentialCleanupKind): VeepooCredentialCleanupRead
    fun write(kind: VeepooCredentialCleanupKind, deviceIds: Set<String>): Boolean
}

internal enum class VeepooCredentialCleanupKind {
    ARCHIVE,
    AUTHENTICATION_REJECTED,
}

/**
 * Restart-safe cleanup ledger for a generated supplier id whose credential was saved before registry
 * adoption failed. It stores opaque generated ids only, never credentials, hardware identifiers, or
 * health data. A registered row always wins during reconciliation so a stale ledger entry can never
 * delete the credential for a successfully adopted band.
 */
class VeepooCredentialCleanupStore internal constructor(
    private val backend: VeepooCredentialCleanupBackend,
) : VeepooCredentialCleanupAccess {
    constructor(context: Context) : this(
        SharedPreferencesCleanupBackend(
            context.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE),
        ),
    )

    override fun markPending(deviceId: String): Boolean =
        markPending(VeepooCredentialCleanupKind.ARCHIVE, deviceId)

    override fun pendingDeviceIds(): VeepooCredentialCleanupRead =
        pendingDeviceIds(VeepooCredentialCleanupKind.ARCHIVE)

    override fun clearPending(deviceId: String): Boolean =
        clearPending(VeepooCredentialCleanupKind.ARCHIVE, deviceId)

    override fun markRejectedPending(deviceId: String): Boolean =
        markPending(VeepooCredentialCleanupKind.AUTHENTICATION_REJECTED, deviceId)

    override fun rejectedPendingDeviceIds(): VeepooCredentialCleanupRead =
        pendingDeviceIds(VeepooCredentialCleanupKind.AUTHENTICATION_REJECTED)

    override fun clearRejectedPending(deviceId: String): Boolean =
        clearPending(VeepooCredentialCleanupKind.AUTHENTICATION_REJECTED, deviceId)

    private fun markPending(
        kind: VeepooCredentialCleanupKind,
        deviceId: String,
    ): Boolean {
        if (!validDeviceId(deviceId)) return false
        val current = when (val read = backend.read(kind)) {
            is VeepooCredentialCleanupRead.Available -> read.deviceIds
            VeepooCredentialCleanupRead.Unavailable -> return false
        }
        if (deviceId in current) return true
        if (current.size >= MAX_PENDING_IDS) return false
        return backend.write(kind, current + deviceId)
    }

    private fun pendingDeviceIds(
        kind: VeepooCredentialCleanupKind,
    ): VeepooCredentialCleanupRead =
        when (val read = backend.read(kind)) {
            is VeepooCredentialCleanupRead.Available -> {
                VeepooCredentialCleanupRead.Available(
                    read.deviceIds
                        .asSequence()
                        .filter(::validDeviceId)
                        .take(MAX_PENDING_IDS)
                        .toSet(),
                )
            }
            VeepooCredentialCleanupRead.Unavailable -> read
        }

    private fun clearPending(
        kind: VeepooCredentialCleanupKind,
        deviceId: String,
    ): Boolean {
        if (!validDeviceId(deviceId)) return false
        val current = when (val read = backend.read(kind)) {
            is VeepooCredentialCleanupRead.Available -> read.deviceIds
            VeepooCredentialCleanupRead.Unavailable -> return false
        }
        if (deviceId !in current) return true
        return backend.write(kind, current - deviceId)
    }

    private fun validDeviceId(value: String): Boolean =
        value.isNotBlank() &&
            value.length <= MAX_DEVICE_ID_LENGTH &&
            value.none(Char::isISOControl)

    private class SharedPreferencesCleanupBackend(
        private val preferences: SharedPreferences,
    ) : VeepooCredentialCleanupBackend {
        override fun read(kind: VeepooCredentialCleanupKind): VeepooCredentialCleanupRead =
            try {
                VeepooCredentialCleanupRead.Available(
                    preferences.getStringSet(key(kind), emptySet())
                        ?.toSet()
                        .orEmpty(),
                )
            } catch (_: Throwable) {
                VeepooCredentialCleanupRead.Unavailable
            }

        override fun write(
            kind: VeepooCredentialCleanupKind,
            deviceIds: Set<String>,
        ): Boolean =
            try {
                val editor = preferences.edit()
                if (deviceIds.isEmpty()) {
                    editor.remove(key(kind))
                } else {
                    editor.putStringSet(key(kind), deviceIds.toSet())
                }
                editor.commit()
            } catch (_: Throwable) {
                false
            }

        private fun key(kind: VeepooCredentialCleanupKind): String =
            when (kind) {
                VeepooCredentialCleanupKind.ARCHIVE -> KEY_PENDING_IDS
                VeepooCredentialCleanupKind.AUTHENTICATION_REJECTED ->
                    KEY_REJECTED_PENDING_IDS
            }
    }

    companion object {
        private const val FILE_NAME = "noop_supplier_band_cleanup"
        private const val KEY_PENDING_IDS = "pending_credential_cleanup_ids"
        private const val KEY_REJECTED_PENDING_IDS =
            "pending_rejected_credential_cleanup_ids"
        private const val MAX_PENDING_IDS = 64
        private const val MAX_DEVICE_ID_LENGTH = 256
    }
}

sealed interface VeepooCredentialRead {
    data class Available(val credential: VeepooStoredCredential) : VeepooCredentialRead
    data object Missing : VeepooCredentialRead
    data object Unavailable : VeepooCredentialRead
}

class VeepooRevisionBinding private constructor(
    internal val fingerprint: String,
) {
    fun matches(hardwareRevision: String, firmwareVersion: String): Boolean =
        from(hardwareRevision, firmwareVersion) == this

    override fun toString(): String = "VeepooRevisionBinding"

    override fun equals(other: Any?): Boolean =
        other is VeepooRevisionBinding && fingerprint == other.fingerprint

    override fun hashCode(): Int = fingerprint.hashCode()

    companion object {
        internal fun from(
            hardwareRevision: String,
            firmwareVersion: String,
        ): VeepooRevisionBinding? {
            val hardware = normalizeRevision(hardwareRevision) ?: return null
            val firmware = normalizeRevision(firmwareVersion) ?: return null
            val input = buildString {
                append(FINGERPRINT_DOMAIN)
                append('\u0000')
                append(hardware)
                append('\u0000')
                append(firmware)
            }.toByteArray(Charsets.UTF_8)
            val digest = MessageDigest.getInstance("SHA-256").digest(input)
            return VeepooRevisionBinding(digest.toLowerHex())
        }

        internal fun parse(value: String): VeepooRevisionBinding? =
            value.takeIf { FINGERPRINT.matches(it) }?.let(::VeepooRevisionBinding)

        private fun normalizeRevision(value: String): String? =
            value.trim().takeIf {
                it.isNotEmpty() &&
                    it.length <= MAX_REVISION_LENGTH &&
                    it.none(Char::isISOControl)
            }

        private fun ByteArray.toLowerHex(): String {
            val output = CharArray(size * 2)
            forEachIndexed { index, byte ->
                val value = byte.toInt() and 0xff
                output[index * 2] = HEX[value ushr 4]
                output[index * 2 + 1] = HEX[value and 0x0f]
            }
            return output.concatToString()
        }

        private const val FINGERPRINT_DOMAIN = "noop-supplier-revision-v1"
        private const val MAX_REVISION_LENGTH = 128
        private const val HEX = "0123456789abcdef"
        private val FINGERPRINT = Regex("[0-9a-f]{64}")
    }
}

class VeepooStoredCredential internal constructor(
    val password: CharArray,
    val revisionBinding: VeepooRevisionBinding,
) : AutoCloseable {
    override fun close() {
        password.fill('\u0000')
    }

    override fun toString(): String = "VeepooStoredCredential"
}

internal interface VeepooCredentialBackend {
    fun contains(key: String): Boolean
    fun readString(key: String): String?
    fun writeString(key: String, value: String): Boolean
    fun remove(key: String): Boolean
}

class VeepooCredentialStore internal constructor(
    private val backend: VeepooCredentialBackend,
) : VeepooCredentialAccess {
    constructor(context: Context) : this(SecurePrefsBackend(context.applicationContext))

    override fun save(
        deviceId: String,
        password: CharArray,
        revisionBinding: VeepooRevisionBinding,
    ): Boolean {
        if (!validDeviceId(deviceId) || !validPassword(password)) return false
        val record = listOf(
            RECORD_VERSION,
            password.concatToString(),
            revisionBinding.fingerprint,
        ).joinToString(RECORD_SEPARATOR)
        return backend.writeString("$KEY_PREFIX$deviceId", record)
    }

    override fun load(deviceId: String): VeepooStoredCredential? =
        when (val result = readForRetention(deviceId)) {
            is VeepooCredentialRead.Available -> result.credential
            VeepooCredentialRead.Missing,
            VeepooCredentialRead.Unavailable,
            -> null
        }

    override fun readForRetention(deviceId: String): VeepooCredentialRead {
        if (!validDeviceId(deviceId)) return VeepooCredentialRead.Missing
        val key = "$KEY_PREFIX$deviceId"
        val encoded = try {
            if (!backend.contains(key)) return VeepooCredentialRead.Missing
            backend.readString(key)
        } catch (_: Throwable) {
            return VeepooCredentialRead.Unavailable
        }
        val parts = encoded?.split(RECORD_SEPARATOR)
        val password = parts
            ?.takeIf { it.size == 3 && it[0] == RECORD_VERSION }
            ?.get(1)
            ?.toCharArray()
        val binding = parts?.getOrNull(2)?.let(VeepooRevisionBinding::parse)
        if (password == null || !validPassword(password) || binding == null) {
            password?.fill('\u0000')
            return removeMalformedCredential(key)
        }
        return VeepooCredentialRead.Available(VeepooStoredCredential(password, binding))
    }

    override fun clear(deviceId: String): Boolean =
        validDeviceId(deviceId) && backend.remove("$KEY_PREFIX$deviceId")

    private fun validDeviceId(value: String): Boolean =
        value.isNotBlank() && value.length <= 256

    private fun validPassword(value: CharArray): Boolean =
        value.size == PASSWORD_LENGTH && value.all { it in '0'..'9' }

    private fun removeMalformedCredential(key: String): VeepooCredentialRead {
        val removed = try {
            backend.remove(key)
        } catch (_: Throwable) {
            return VeepooCredentialRead.Unavailable
        }
        return if (removed) {
            VeepooCredentialRead.Missing
        } else {
            // A failed durable removal means the malformed secret may still exist.
            VeepooCredentialRead.Unavailable
        }
    }

    private class SecurePrefsBackend(context: Context) : VeepooCredentialBackend {
        private val prefs: SharedPreferences = SecurePrefs.of(context, FILE_NAME)
        override fun contains(key: String): Boolean = prefs.contains(key)
        override fun readString(key: String): String? =
            try {
                prefs.getString(key, null)
            } catch (_: ClassCastException) {
                null
            }
        override fun writeString(key: String, value: String): Boolean =
            prefs.edit().putString(key, value).commit()
        override fun remove(key: String): Boolean = prefs.edit().remove(key).commit()
    }

    companion object {
        private const val FILE_NAME = "noop_supplier_band_credentials"
        private const val KEY_PREFIX = "transport_password_"
        private const val PASSWORD_LENGTH = 4
        private const val RECORD_VERSION = "v1"
        private const val RECORD_SEPARATOR = "|"
    }
}
