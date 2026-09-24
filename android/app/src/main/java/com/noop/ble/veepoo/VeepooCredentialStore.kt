package com.noop.ble.veepoo

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs

interface VeepooCredentialAccess {
    fun save(deviceId: String, password: CharArray): Boolean
    fun load(deviceId: String): CharArray?
    fun clear(deviceId: String): Boolean
}

internal interface VeepooCredentialBackend {
    fun contains(key: String): Boolean
    fun readInt(key: String): Int?
    fun writeInt(key: String, value: Int): Boolean
    fun remove(key: String): Boolean
}

class VeepooCredentialStore internal constructor(
    private val backend: VeepooCredentialBackend,
) : VeepooCredentialAccess {
    constructor(context: Context) : this(SecurePrefsBackend(context.applicationContext))

    override fun save(deviceId: String, password: CharArray): Boolean {
        if (!validDeviceId(deviceId) || !validPassword(password)) return false
        var encoded = 0
        password.forEach { encoded = (encoded * 10) + (it - '0') }
        return backend.writeInt("$KEY_PREFIX$deviceId", encoded)
    }

    override fun load(deviceId: String): CharArray? {
        if (!validDeviceId(deviceId)) return null
        val key = "$KEY_PREFIX$deviceId"
        if (!backend.contains(key)) return null
        val value = backend.readInt(key)
        if (value == null || value !in 0..9_999) {
            backend.remove(key)
            return null
        }
        var remaining = value
        return CharArray(PASSWORD_LENGTH).also { result ->
            for (index in result.lastIndex downTo 0) {
                result[index] = ('0'.code + remaining % 10).toChar()
                remaining /= 10
            }
        }
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
        override fun readInt(key: String): Int? =
            runCatching { prefs.getInt(key, INVALID) }.getOrNull()?.takeUnless { it == INVALID }
        override fun writeInt(key: String, value: Int): Boolean =
            prefs.edit().putInt(key, value).commit()
        override fun remove(key: String): Boolean = prefs.edit().remove(key).commit()
    }

    companion object {
        private const val FILE_NAME = "noop_supplier_band_credentials"
        private const val KEY_PREFIX = "transport_password_"
        private const val PASSWORD_LENGTH = 4
        private const val INVALID = -1
    }
}
