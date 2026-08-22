package com.noop.data

import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

/**
 * Shared, self-describing metadata for a `.noopbak` ZIP.
 *
 * The payload database remains engine-native (Room on Android, GRDB on Apple), but both clients use
 * these exact JSON keys. Manifest-less archives remain valid legacy backups. A current manifest lets
 * the importer reject a wrong-platform or future-schema restore before opening SQLite and verifies
 * plaintext folder snapshots with streaming SHA-256.
 */
data class BackupManifest(
    val format: String,
    val version: Int,
    val createdAtEpochMs: Long,
    val sourcePlatform: String,
    val databaseEngine: String,
    val databaseSchemaVersion: Int,
    val settingsSchemaVersion: Int?,
    val appVersion: String?,
    val payloads: Payloads,
) {
    data class Payload(val path: String, val bytes: Long, val sha256: String)
    data class Payloads(val database: Payload, val settings: Payload?)

    fun encode(): String {
        fun payloadJson(value: Payload): JSONObject = JSONObject()
            .put("path", value.path)
            .put("bytes", value.bytes)
            .put("sha256", value.sha256)

        val payloadObject = JSONObject().put("database", payloadJson(payloads.database))
        payloads.settings?.let { payloadObject.put("settings", payloadJson(it)) }
        return JSONObject()
            .put("format", format)
            .put("version", version)
            .put("createdAtEpochMs", createdAtEpochMs)
            .put("sourcePlatform", sourcePlatform)
            .put("databaseEngine", databaseEngine)
            .put("databaseSchemaVersion", databaseSchemaVersion)
            .apply {
                settingsSchemaVersion?.let { put("settingsSchemaVersion", it) }
                appVersion?.let { put("appVersion", it) }
            }
            .put("payloads", payloadObject)
            .toString()
    }

    /**
     * A user-facing incompatibility/integrity problem, or null when this manifest and the extracted
     * payloads are safe for this client. Hashes are streamed; the database is never loaded in memory.
     */
    fun validationProblem(
        databaseFile: File,
        settingsFile: File?,
        expectedDatabaseEntryName: String,
        expectedSettingsEntryName: String,
        currentPlatform: String,
        currentDatabaseEngine: String,
        currentDatabaseSchemaVersion: Int,
    ): String? {
        if (format != FORMAT_NAME) return "This file uses an unknown NOOP backup format."
        if (version != FORMAT_VERSION) {
            return "This backup uses unsupported container version $version. Update NOOP and try again."
        }
        if (createdAtEpochMs < 0L || databaseSchemaVersion <= 0) {
            return "This backup manifest contains invalid version metadata."
        }
        if (sourcePlatform !in setOf(PLATFORM_APPLE, PLATFORM_ANDROID) ||
            databaseEngine !in setOf(ENGINE_GRDB, ENGINE_ROOM)
        ) {
            return "This backup manifest contains an unknown source platform or database engine."
        }
        if (sourcePlatform != currentPlatform || databaseEngine != currentDatabaseEngine) {
            val source = if (sourcePlatform == PLATFORM_APPLE) "Apple" else "Android"
            val target = if (currentPlatform == PLATFORM_APPLE) "Apple" else "Android"
            return "This is an $source full-device backup and cannot replace the $target database. " +
                "Use NOOP's portable CSV export to move health history between platforms."
        }
        if (databaseSchemaVersion > currentDatabaseSchemaVersion) {
            return "This backup was created by a newer NOOP database schema. Update NOOP before restoring it."
        }
        if (payloads.database.path != expectedDatabaseEntryName) {
            return "This backup manifest points to an unexpected database payload."
        }
        payloadProblem(payloads.database, databaseFile)?.let {
            return "The backup database $it"
        }

        when {
            payloads.settings == null && settingsFile == null -> {
                if (settingsSchemaVersion != null) {
                    return "This backup manifest declares settings metadata without a settings payload."
                }
            }
            payloads.settings == null && settingsFile != null ->
                return "This backup contains settings that are not covered by its integrity manifest."
            payloads.settings != null && settingsFile == null ->
                return "This backup is missing the settings payload declared by its manifest."
            else -> {
                val settings = requireNotNull(payloads.settings)
                val file = requireNotNull(settingsFile)
                if (settings.path != expectedSettingsEntryName ||
                    settingsSchemaVersion == null || settingsSchemaVersion <= 0
                ) {
                    return "This backup manifest contains invalid settings metadata."
                }
                payloadProblem(settings, file)?.let {
                    return "The backup settings $it"
                }
            }
        }
        return null
    }

    companion object {
        const val ENTRY_NAME = "manifest.json"
        const val FORMAT_NAME = "noop-backup"
        const val FORMAT_VERSION = 1
        const val PLATFORM_APPLE = "apple"
        const val PLATFORM_ANDROID = "android"
        const val ENGINE_GRDB = "grdb"
        const val ENGINE_ROOM = "room"

        fun create(
            databaseFile: File,
            databaseEntryName: String,
            settingsBytes: ByteArray?,
            settingsEntryName: String,
            createdAtEpochMs: Long,
            sourcePlatform: String,
            databaseEngine: String,
            databaseSchemaVersion: Int,
            settingsSchemaVersion: Int?,
            appVersion: String?,
        ): BackupManifest {
            val database = Payload(
                path = databaseEntryName,
                bytes = databaseFile.length(),
                sha256 = sha256(databaseFile),
            )
            val settings = settingsBytes?.let {
                Payload(
                    path = settingsEntryName,
                    bytes = it.size.toLong(),
                    sha256 = sha256(it),
                )
            }
            return BackupManifest(
                format = FORMAT_NAME,
                version = FORMAT_VERSION,
                createdAtEpochMs = createdAtEpochMs,
                sourcePlatform = sourcePlatform,
                databaseEngine = databaseEngine,
                databaseSchemaVersion = databaseSchemaVersion,
                settingsSchemaVersion = if (settings == null) null else settingsSchemaVersion,
                appVersion = appVersion,
                payloads = Payloads(database, settings),
            )
        }

        fun decode(json: String): BackupManifest? = runCatching {
            fun payload(value: JSONObject): Payload = Payload(
                path = value.getString("path"),
                bytes = value.getLong("bytes"),
                sha256 = value.getString("sha256"),
            )

            val root = JSONObject(json)
            val payloads = root.getJSONObject("payloads")
            BackupManifest(
                format = root.getString("format"),
                version = root.getInt("version"),
                createdAtEpochMs = root.getLong("createdAtEpochMs"),
                sourcePlatform = root.getString("sourcePlatform"),
                databaseEngine = root.getString("databaseEngine"),
                databaseSchemaVersion = root.getInt("databaseSchemaVersion"),
                settingsSchemaVersion = if (root.has("settingsSchemaVersion")) {
                    root.getInt("settingsSchemaVersion")
                } else {
                    null
                },
                appVersion = if (root.has("appVersion")) root.getString("appVersion") else null,
                payloads = Payloads(
                    database = payload(payloads.getJSONObject("database")),
                    settings = if (payloads.has("settings") && !payloads.isNull("settings")) {
                        payload(payloads.getJSONObject("settings"))
                    } else {
                        null
                    },
                ),
            )
        }.getOrNull()

        private fun payloadProblem(payload: Payload, file: File): String? {
            if (payload.bytes < 0L || !payload.sha256.matches(Regex("[0-9a-f]{64}"))) {
                return "has invalid integrity metadata."
            }
            if (!file.isFile) return "could not be read."
            if (file.length() != payload.bytes) return "size does not match its integrity manifest."
            if (sha256(file) != payload.sha256) return "hash does not match its integrity manifest."
            return null
        }

        private fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1_048_576)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().toHex()
        }

        private fun sha256(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes).toHex()

        private fun ByteArray.toHex(): String =
            joinToString(separator = "") { "%02x".format(it.toInt() and 0xff) }
    }
}
