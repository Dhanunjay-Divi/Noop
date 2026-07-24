package com.noop.sync

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import org.json.JSONObject

class RemoteSyncConfigurationException(message: String) : IllegalArgumentException(message)

data class RemoteSyncConfiguration(
    val baseUrl: String,
    val apiKey: String,
    val timeoutSeconds: Long = 60,
) {
    init {
        require(apiKey.isNotBlank()) { "The server API key is required." }
        require(timeoutSeconds > 0) { "The request timeout must be greater than zero." }
        require(baseUrl == RemoteEndpointPolicy.normalize(baseUrl)) {
            "The server URL must be normalized before use."
        }
    }
}

/** URL boundary shared by the settings screen and HTTP client. */
object RemoteEndpointPolicy {
    /**
     * Public destinations must use TLS. Cleartext is allowed only for loopback, RFC1918/link-local
     * development hosts, matching the Apple client. Embedded credentials, fragments and queries are
     * rejected so the Bearer token remains the sole authentication mechanism.
     */
    fun normalize(input: String): String {
        var candidate = input.trim()
        if (candidate.isEmpty()) throw RemoteSyncConfigurationException("Enter a server URL.")
        if (!candidate.contains("://")) candidate = "https://$candidate"

        val uri = runCatching { URI(candidate) }.getOrElse {
            throw RemoteSyncConfigurationException("Enter a valid server URL.")
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") {
            throw RemoteSyncConfigurationException("The server URL must use HTTPS or HTTP.")
        }
        if (uri.host.isNullOrBlank()) {
            throw RemoteSyncConfigurationException("The server URL must include a host.")
        }
        if (uri.userInfo != null) {
            throw RemoteSyncConfigurationException("Do not put a username or password in the server URL.")
        }
        if (uri.rawQuery != null || uri.rawFragment != null) {
            throw RemoteSyncConfigurationException("Remove query parameters and fragments from the server URL.")
        }
        if (scheme == "http" && !isPrivateHost(uri.host)) {
            throw RemoteSyncConfigurationException(
                "Use HTTPS, or HTTP only for localhost/private-LAN servers.",
            )
        }
        val normalizedPath = when {
            uri.rawPath.isNullOrEmpty() || uri.rawPath == "/" -> ""
            else -> uri.rawPath.trimEnd('/')
        }
        return URI(
            scheme,
            null,
            uri.host,
            uri.port,
            normalizedPath,
            null,
            null,
        ).toASCIIString()
    }

    fun isPrivateHost(rawHost: String?): Boolean {
        val host = rawHost
            ?.trim()
            ?.removePrefix("[")
            ?.removeSuffix("]")
            ?.lowercase()
            .orEmpty()
        if (host.isEmpty()) return false
        if (host == "localhost" || host == "::1" || host.endsWith(".local")) return true

        // Do not use mapNotNull here: "10.0.0.1.evil.com" would otherwise collapse to four
        // numeric labels and incorrectly become eligible for cleartext biometric uploads.
        val ipv4Labels = host.split('.')
        val ipv4 = ipv4Labels
            .takeIf { labels ->
                labels.size == 4 && labels.all {
                    it.matches(Regex("""\d{1,3}""")) &&
                        (it == "0" || !it.startsWith('0'))
                }
            }
            ?.map(String::toInt)
        if (ipv4 != null && ipv4.all { it in 0..255 }) {
            return ipv4[0] == 10 ||
                ipv4[0] == 127 ||
                (ipv4[0] == 169 && ipv4[1] == 254) ||
                (ipv4[0] == 192 && ipv4[1] == 168) ||
                (ipv4[0] == 172 && ipv4[1] in 16..31)
        }

        // A hostname merely beginning with "fc", "fd" or "fe80" is not an IPv6 literal. The
        // character guard plus ':' requirement keeps InetAddress from performing a DNS lookup.
        val ipv6Literal = host.substringBefore('%')
        if (!ipv6Literal.contains(':') ||
            ipv6Literal.any { it !in '0'..'9' && it !in 'a'..'f' && it != ':' && it != '.' }
        ) {
            return false
        }
        val address = runCatching { InetAddress.getByName(ipv6Literal) }.getOrNull()
            as? Inet6Address
            ?: return false
        val firstByte = address.address.first().toInt() and 0xff
        return address.isLoopbackAddress ||
            address.isLinkLocalAddress ||
            (firstByte and 0xfe) == 0xfc // fc00::/7 unique-local range
    }
}

/** Small persistence seam so coordinator retry semantics are plain-JVM testable. */
interface RemoteBatchIdentityStore {
    fun resolve(fingerprint: String, now: Instant = Instant.now()): RemoteBatchIdentity
    fun acknowledge(fingerprint: String)
}

/**
 * Fixed bounds for one replay of derived history.
 *
 * A replay can span multiple WorkManager/process launches, so recomputing either bound from "now"
 * after a keyset cursor has advanced could omit rows that move across the changing boundary.
 */
data class RemoteDerivedWindow(
    val fromTs: Long,
    val toTs: Long,
    val fromDay: String,
    val toDay: String,
) {
    val isValid: Boolean
        get() = fromTs <= toTs &&
            fromDay.isNotBlank() &&
            toDay.isNotBlank() &&
            fromDay <= toDay

    companion object {
        fun endingAt(
            now: Instant,
            historyDays: Int,
            zoneId: ZoneId = ZoneId.systemDefault(),
        ): RemoteDerivedWindow {
            val days = historyDays.coerceIn(1, 3_650)
            val from = now.minusSeconds(days.toLong() * 86_400L)
            return RemoteDerivedWindow(
                fromTs = from.epochSecond,
                toTs = now.epochSecond,
                fromDay = from.atZone(zoneId).toLocalDate().toString(),
                toDay = now.atZone(zoneId).toLocalDate().toString(),
            )
        }
    }
}

/**
 * Natural-key watermarks for a derived page. Keyset cursors do not skip rows when an earlier local
 * row is edited or deleted between WorkManager runs, unlike a persisted SQL OFFSET. A completion
 * marker is retained during a global replay so a namespace that finished early is not restarted
 * while another namespace still has backlog.
 */
data class RemoteDerivedCursor(
    val started: Boolean = false,
    val sleepStartTs: Long? = null,
    val workoutStartTs: Long? = null,
    val workoutSport: String? = null,
    val journalDay: String? = null,
    val journalQuestion: String? = null,
    val isComplete: Boolean = false,
) {
    fun markingComplete(): RemoteDerivedCursor = copy(started = true, isComplete = true)
}

/** Durable page watermark for low-volume derived rows when a namespace exceeds one API request. */
interface RemoteDerivedCursorStore {
    fun derivedCursor(remoteDeviceId: String): RemoteDerivedCursor
    fun setDerivedCursor(remoteDeviceId: String, cursor: RemoteDerivedCursor)
    fun clearDerivedCursor(remoteDeviceId: String)
}

/**
 * Non-secret sync state plus a Keystore-backed Bearer token. Automatic upload is OFF by default.
 * Neither API keys nor biometric payloads are written to ordinary SharedPreferences.
 */
object RemoteSyncPrefs : RemoteBatchIdentityStore, RemoteDerivedCursorStore {
    private const val STATE_FILE = "noop_remote_sync"
    private const val SECRET_FILE = "noop_remote_sync_secure"
    private const val KEY_ENDPOINT = "endpoint"
    private const val KEY_AUTO = "automatic"
    private const val KEY_LAST_ATTEMPT = "last_attempt_ms"
    private const val KEY_LAST_SUCCESS = "last_success_ms"
    private const val KEY_LAST_STATUS = "last_status"
    private const val KEY_LAST_RAW_ROWS = "last_raw_rows"
    private const val KEY_REPLAY = "needs_full_replay"
    private const val KEY_REPLAY_IN_PROGRESS = "full_replay_in_progress"
    private const val KEY_REPLAY_WINDOW = "full_replay_window"
    private const val KEY_INSTALLATION = "installation_id"
    private const val KEY_TOKEN = "bearer_token"
    private const val KEY_BATCH_ID_PREFIX = "batch_id."
    private const val KEY_BATCH_SENT_AT_PREFIX = "batch_sent_at."
    private const val KEY_DERIVED_CURSOR_PREFIX = "derived_cursor."

    @Volatile private var appContext: Context? = null

    fun initialize(context: Context) {
        appContext = context.applicationContext
    }

    private fun context(): Context =
        checkNotNull(appContext) { "RemoteSyncPrefs.initialize must be called first." }

    private fun state(): SharedPreferences =
        context().getSharedPreferences(STATE_FILE, Context.MODE_PRIVATE)

    private fun secrets(): SharedPreferences {
        val masterKey = MasterKey.Builder(context())
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context(),
            SECRET_FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun endpoint(): String = state().getString(KEY_ENDPOINT, null).orEmpty()
    fun apiKey(): String? = secrets().getString(KEY_TOKEN, null)?.takeIf(String::isNotBlank)
    fun isConfigured(): Boolean = endpoint().isNotBlank() && apiKey() != null

    fun automatic(): Boolean = state().getBoolean(KEY_AUTO, false)
    fun setAutomatic(enabled: Boolean) = state().edit().putBoolean(KEY_AUTO, enabled).apply()

    fun lastAttemptMs(): Long = state().getLong(KEY_LAST_ATTEMPT, 0)
    fun lastSuccessMs(): Long = state().getLong(KEY_LAST_SUCCESS, 0)
    fun lastStatus(): String = state().getString(KEY_LAST_STATUS, null).orEmpty()
    fun lastRawRows(): Int = state().getInt(KEY_LAST_RAW_ROWS, 0)
    fun needsFullReplay(): Boolean = state().getBoolean(KEY_REPLAY, false)
    fun replayInProgress(): Boolean = state().getBoolean(KEY_REPLAY_IN_PROGRESS, false)

    fun replayWindow(): RemoteDerivedWindow? {
        val raw = state().getString(KEY_REPLAY_WINDOW, null) ?: return null
        return runCatching {
            val json = JSONObject(raw)
            RemoteDerivedWindow(
                fromTs = json.getLong("from_ts"),
                toTs = json.getLong("to_ts"),
                fromDay = json.getString("from_day"),
                toDay = json.getString("to_day"),
            ).takeIf(RemoteDerivedWindow::isValid)
        }.getOrNull()
    }

    fun setLastAttemptMs(value: Long) = state().edit().putLong(KEY_LAST_ATTEMPT, value).apply()
    fun setLastStatus(value: String) = state().edit().putString(KEY_LAST_STATUS, value.take(500)).apply()
    fun setNeedsFullReplay(value: Boolean) {
        check(state().edit().putBoolean(KEY_REPLAY, value).commit()) {
            "Could not persist the remote replay request."
        }
    }

    /** Publish the replay marker and its immutable bounds in one durable preference transaction. */
    fun beginReplay(window: RemoteDerivedWindow) {
        require(window.isValid) { "The remote derived-data replay window is invalid." }
        val json = JSONObject()
            .put("from_ts", window.fromTs)
            .put("to_ts", window.toTs)
            .put("from_day", window.fromDay)
            .put("to_day", window.toDay)
        check(
            state().edit()
                .putString(KEY_REPLAY_WINDOW, json.toString())
                .putBoolean(KEY_REPLAY_IN_PROGRESS, true)
                .commit(),
        ) { "Could not persist the remote replay window." }
    }

    /**
     * Clear every derived completion marker and the global replay state atomically. A process death
     * cannot therefore leave an active replay whose already-complete namespace has been restarted.
     */
    fun finishReplay(derivedRemoteDeviceIds: Collection<String>) {
        val editor = state().edit()
            .remove(KEY_REPLAY_WINDOW)
            .putBoolean(KEY_REPLAY_IN_PROGRESS, false)
        derivedRemoteDeviceIds.forEach {
            editor.remove(KEY_DERIVED_CURSOR_PREFIX + it)
        }
        check(editor.commit()) { "Could not finish the remote history replay." }
    }

    fun recordSuccess(nowMs: Long, rawRows: Int, status: String) {
        state().edit()
            .putLong(KEY_LAST_SUCCESS, nowMs)
            .putInt(KEY_LAST_RAW_ROWS, rawRows)
            .putString(KEY_LAST_STATUS, status.take(500))
            .apply()
    }

    fun installationId(): String {
        val prefs = state()
        prefs.getString(KEY_INSTALLATION, null)?.takeIf(String::isNotBlank)?.let { return it }
        val value = UUID.randomUUID().toString().lowercase()
        prefs.edit().putString(KEY_INSTALLATION, value).commit()
        return value
    }

    /**
     * Save a validated destination and optional replacement key. A destination change schedules one
     * complete idempotent replay; the actual reset occurs immediately before a sync attempt.
     */
    fun saveConfiguration(endpointInput: String, newApiKey: String, automatic: Boolean): String {
        val endpoint = RemoteEndpointPolicy.normalize(endpointInput)
        val trimmedKey = newApiKey.trim()
        if (trimmedKey.isNotEmpty() &&
            !secrets().edit().putString(KEY_TOKEN, trimmedKey).commit()
        ) {
            throw RemoteSyncConfigurationException("The API key could not be saved securely.")
        }
        if (apiKey() == null) throw RemoteSyncConfigurationException("Enter the server API key.")

        val oldEndpoint = endpoint()
        val prefs = state()
        val editor = prefs.edit()
            .putString(KEY_ENDPOINT, endpoint)
            .putBoolean(KEY_AUTO, automatic)
        if (oldEndpoint != endpoint) {
            editor
                .putBoolean(KEY_REPLAY, true)
                .remove(KEY_REPLAY_IN_PROGRESS)
                .remove(KEY_REPLAY_WINDOW)
            prefs.all.keys
                .filter {
                    it.startsWith(KEY_BATCH_ID_PREFIX) ||
                        it.startsWith(KEY_BATCH_SENT_AT_PREFIX) ||
                        it.startsWith(KEY_DERIVED_CURSOR_PREFIX)
                }
                .forEach(editor::remove)
        }
        if (!editor.commit()) {
            throw RemoteSyncConfigurationException("The remote sync configuration could not be saved.")
        }
        return endpoint
    }

    /**
     * Forget only the optional remote destination and its operational state. Local biometric rows
     * and anything already accepted by the user's server are intentionally untouched.
     */
    fun clearConfiguration() {
        val prefs = state()
        if (!prefs.edit().putBoolean(KEY_AUTO, false).commit()) {
            throw RemoteSyncConfigurationException("Automatic remote sync could not be disabled.")
        }
        if (!secrets().edit().remove(KEY_TOKEN).commit()) {
            throw RemoteSyncConfigurationException("The saved API key could not be removed.")
        }

        val editor = prefs.edit()
            .remove(KEY_ENDPOINT)
            .remove(KEY_AUTO)
            .remove(KEY_LAST_ATTEMPT)
            .remove(KEY_LAST_SUCCESS)
            .remove(KEY_LAST_STATUS)
            .remove(KEY_LAST_RAW_ROWS)
            .remove(KEY_REPLAY)
            .remove(KEY_REPLAY_IN_PROGRESS)
            .remove(KEY_REPLAY_WINDOW)
        prefs.all.keys
            .filter {
                it.startsWith(KEY_BATCH_ID_PREFIX) ||
                    it.startsWith(KEY_BATCH_SENT_AT_PREFIX) ||
                    it.startsWith(KEY_DERIVED_CURSOR_PREFIX)
            }
            .forEach(editor::remove)
        if (!editor.commit()) {
            throw RemoteSyncConfigurationException("The remote sync state could not be cleared.")
        }
    }

    fun configuration(timeoutSeconds: Long = 60): RemoteSyncConfiguration {
        val key = apiKey() ?: throw RemoteSyncConfigurationException("Save an API key first.")
        val normalized = RemoteEndpointPolicy.normalize(endpoint())
        return RemoteSyncConfiguration(normalized, key, timeoutSeconds)
    }

    override fun resolve(fingerprint: String, now: Instant): RemoteBatchIdentity {
        val prefs = state()
        val existingId = prefs.getString(KEY_BATCH_ID_PREFIX + fingerprint, null)
        val existingSentAt = prefs.getString(KEY_BATCH_SENT_AT_PREFIX + fingerprint, null)
        if (existingId != null && existingSentAt != null) {
            return RemoteBatchIdentity(existingId, existingSentAt)
        }
        val identity = RemoteBatchIdentity(
            batchId = UUID.randomUUID().toString().lowercase(),
            sentAt = now.toString(),
        )
        // Commit before network I/O: a process death after send reuses the exact identity on restart.
        val persisted = prefs.edit()
            .putString(KEY_BATCH_ID_PREFIX + fingerprint, identity.batchId)
            .putString(KEY_BATCH_SENT_AT_PREFIX + fingerprint, identity.sentAt)
            .commit()
        check(persisted) { "Could not persist the remote sync retry identity." }
        return identity
    }

    override fun acknowledge(fingerprint: String) {
        state().edit()
            .remove(KEY_BATCH_ID_PREFIX + fingerprint)
            .remove(KEY_BATCH_SENT_AT_PREFIX + fingerprint)
            .commit()
    }

    override fun derivedCursor(remoteDeviceId: String): RemoteDerivedCursor {
        val raw = state().getString(KEY_DERIVED_CURSOR_PREFIX + remoteDeviceId, null)
            ?: return RemoteDerivedCursor()
        return runCatching {
            val json = JSONObject(raw)
            RemoteDerivedCursor(
                started = json.optBoolean("started", false),
                sleepStartTs = json.optNullableLong("sleep_start_ts"),
                workoutStartTs = json.optNullableLong("workout_start_ts"),
                workoutSport = json.optNullableString("workout_sport"),
                journalDay = json.optNullableString("journal_day"),
                journalQuestion = json.optNullableString("journal_question"),
                isComplete = json.optBoolean("is_complete", false),
            )
        }.getOrDefault(RemoteDerivedCursor())
    }

    override fun setDerivedCursor(remoteDeviceId: String, cursor: RemoteDerivedCursor) {
        val json = JSONObject()
            .put("started", cursor.started)
            .putNullable("sleep_start_ts", cursor.sleepStartTs)
            .putNullable("workout_start_ts", cursor.workoutStartTs)
            .putNullable("workout_sport", cursor.workoutSport)
            .putNullable("journal_day", cursor.journalDay)
            .putNullable("journal_question", cursor.journalQuestion)
            .put("is_complete", cursor.isComplete)
        check(
            state().edit()
                .putString(KEY_DERIVED_CURSOR_PREFIX + remoteDeviceId, json.toString())
                .commit(),
        ) { "Could not persist the remote derived-data cursor." }
    }

    override fun clearDerivedCursor(remoteDeviceId: String) {
        check(
            state().edit().remove(KEY_DERIVED_CURSOR_PREFIX + remoteDeviceId).commit(),
        ) { "Could not clear the remote derived-data cursor." }
    }

    private fun JSONObject.optNullableLong(key: String): Long? =
        if (has(key) && !isNull(key)) getLong(key) else null

    private fun JSONObject.optNullableString(key: String): String? =
        if (has(key) && !isNull(key)) getString(key) else null

    private fun JSONObject.putNullable(key: String, value: Any?): JSONObject =
        put(key, value ?: JSONObject.NULL)
}
