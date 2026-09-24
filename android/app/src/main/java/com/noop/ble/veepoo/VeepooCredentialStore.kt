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
    fun clear(deviceId: String): Boolean
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

    override fun load(deviceId: String): VeepooStoredCredential? {
        if (!validDeviceId(deviceId)) return null
        val key = "$KEY_PREFIX$deviceId"
        if (!backend.contains(key)) return null
        val parts = backend.readString(key)?.split(RECORD_SEPARATOR)
        val password = parts
            ?.takeIf { it.size == 3 && it[0] == RECORD_VERSION }
            ?.get(1)
            ?.toCharArray()
        val binding = parts?.getOrNull(2)?.let(VeepooRevisionBinding::parse)
        if (password == null || !validPassword(password) || binding == null) {
            password?.fill('\u0000')
            backend.remove(key)
            return null
        }
        return VeepooStoredCredential(password, binding)
    }

    override fun clear(deviceId: String): Boolean =
        validDeviceId(deviceId) && backend.remove("$KEY_PREFIX$deviceId")

    private fun validDeviceId(value: String): Boolean =
        value.isNotBlank() && value.length <= 256

    private fun validPassword(value: CharArray): Boolean =
        value.size == PASSWORD_LENGTH && value.all { it in '0'..'9' }

    private class SecurePrefsBackend(context: Context) : VeepooCredentialBackend {
        private val prefs: SharedPreferences = SecurePrefs.of(context, FILE_NAME)
        override fun contains(key: String): Boolean = prefs.contains(key)
        override fun readString(key: String): String? =
            runCatching { prefs.getString(key, null) }.getOrNull()
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
