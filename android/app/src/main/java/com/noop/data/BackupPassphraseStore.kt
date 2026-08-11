package com.noop.data

import android.content.Context

/** Keystore-backed recovery passphrase used only by unattended folder backups. */
object BackupPassphraseStore {
    private const val FILE = "noop_backup_secure_prefs"
    private const val KEY = "folder_backup_passphrase"

    fun save(context: Context, passphrase: String) {
        BackupEnvelope.passphraseProblem(passphrase)?.let { throw IllegalArgumentException(it) }
        SecurePrefs.of(context, FILE).edit().putString(KEY, passphrase).commit().also { saved ->
            if (!saved) throw IllegalStateException("Could not store the backup passphrase securely.")
        }
    }

    fun read(context: Context): String? = SecurePrefs.of(context, FILE).getString(KEY, null)
        ?.takeIf { BackupEnvelope.passphraseProblem(it) == null }

    fun has(context: Context): Boolean = read(context) != null

    fun clear(context: Context) {
        if (!SecurePrefs.of(context, FILE).edit().remove(KEY).commit()) {
            throw IllegalStateException("Could not remove the stored backup passphrase.")
        }
    }
}
