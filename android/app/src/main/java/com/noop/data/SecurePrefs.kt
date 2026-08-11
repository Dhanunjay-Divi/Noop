package com.noop.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.concurrent.ConcurrentHashMap

/**
 * Opens each encrypted preferences file once per process and reuses the wrapper.
 *
 * Creating [EncryptedSharedPreferences] performs an Android Keystore round trip and initializes
 * cryptographic primitives. The credential stores can be reached concurrently from UI and BLE
 * threads, so construction is shared through a thread-safe cache and only the application context
 * is retained.
 */
object SecurePrefs {
    private val cache = ConcurrentHashMap<String, SharedPreferences>()

    fun of(context: Context, fileName: String): SharedPreferences =
        cache.computeIfAbsent(fileName) {
            val app = context.applicationContext
            val masterKey = MasterKey.Builder(app)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                app,
                fileName,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }
}
