package com.noop.notif

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

enum class NotificationLifecycleState(val wireValue: String) {
    SCHEDULED("scheduled"),
    POSTED("posted"),
    CANCELLED("cancelled"),
    SUPPRESSED("suppressed"),
    UNKNOWN("unknown"),
}

data class NotificationLifecycleEntry(
    val identifier: String,
    val category: String,
    val state: NotificationLifecycleState,
    val timestamp: Long,
)

/** Static identifiers only. Never add a person, device, metric, slot, or delivery token here. */
object NotificationLifecycleId {
    const val CONNECTION_SERVICE = "connection_service"
    const val INACTIVITY = "inactivity"
    const val BATTERY_RUNTIME = "battery_runtime"
    const val BATTERY_LOW = "battery_low"
    const val BATTERY_FULL = "battery_full"
    const val BAND_SMART_ALARM = "band_smart_alarm"
    const val PHONE_SMART_ALARM = "phone_smart_alarm"
    const val WIND_DOWN = "wind_down"
    const val COACH_CHECK_IN = "coach_check_in"
    const val HYDRATION = "hydration"
    const val MORNING_REPORT = "morning_report"
    const val WORKOUT_REPORT = "workout_report"
    const val AUTO_WORKOUT = "auto_workout"
    const val CONTEXTUAL_VITAL = "contextual_vital"
    const val STRAIN_TARGET = "strain_target"
    const val ILLNESS_CHECK_IN = "illness_check_in"
    const val SAFETY_CHECK_IN = "safety_check_in"
    const val SAFETY_CONTACT_SETUP = "safety_contact_setup"
    const val SAFETY_SOS_RESULT = "safety_sos_result"

    internal val all = setOf(
        CONNECTION_SERVICE,
        INACTIVITY,
        BATTERY_RUNTIME,
        BATTERY_LOW,
        BATTERY_FULL,
        BAND_SMART_ALARM,
        PHONE_SMART_ALARM,
        WIND_DOWN,
        COACH_CHECK_IN,
        HYDRATION,
        MORNING_REPORT,
        WORKOUT_REPORT,
        AUTO_WORKOUT,
        CONTEXTUAL_VITAL,
        STRAIN_TARGET,
        ILLNESS_CHECK_IN,
        SAFETY_CHECK_IN,
        SAFETY_CONTACT_SETUP,
        SAFETY_SOS_RESULT,
    )
}

object NotificationLifecycleCategory {
    const val ALARM = "alarm"
    const val REMINDER = "reminder"
    const val STATUS = "status"
    const val RECOMMENDATION = "recommendation"
    const val SERVICE = "service"

    internal val all = setOf(ALARM, REMINDER, STATUS, RECOMMENDATION, SERVICE)
}

/**
 * Bounded local audit of app-side notification transitions. It intentionally cannot store copy,
 * recipient data, metric values, dynamic tokens, or OS-delivery claims.
 */
object NotificationLifecycleLedger {
    internal const val MAX_ENTRIES = 256
    internal const val POSTED_DISCLAIMER =
        "Lifecycle states are app-observed only. Posted means NOOP's notification API call " +
            "returned without throwing; no entry confirms that the OS showed or delivered a notification."

    private const val PREFS_FILE = "noop_notification_lifecycle"
    private const val ENTRIES_KEY = "entries"
    private val entryKeys = setOf("identifier", "category", "state", "timestamp")
    private val lock = Any()

    private fun record(
        context: Context,
        identifier: String,
        category: String,
        state: NotificationLifecycleState,
        timestamp: Long = System.currentTimeMillis(),
    ) {
        runCatching {
            record(
                context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE),
                NotificationLifecycleEntry(identifier, category, state, timestamp),
            )
        }
    }

    fun suppressed(context: Context, identifier: String, category: String) {
        record(context, identifier, category, NotificationLifecycleState.SUPPRESSED)
    }

    fun unknown(context: Context, identifier: String, category: String) {
        record(context, identifier, category, NotificationLifecycleState.UNKNOWN)
    }

    /**
     * Preserves the operation's return value and exception behavior while recording its app-observed
     * outcome. Callers that already own retry/error handling can use this instead of the contained helpers.
     */
    fun <T> observe(
        context: Context,
        identifier: String,
        category: String,
        successState: NotificationLifecycleState,
        operation: () -> T,
    ): T = try {
        operation().also {
            record(context, identifier, category, successState)
        }
    } catch (error: Throwable) {
        unknown(context, identifier, category)
        throw error
    }

    /**
     * Records POSTED only after [notify] returns. A false result means the app observed an exception;
     * UNKNOWN is recorded and the exception remains contained.
     */
    fun posted(
        context: Context,
        identifier: String,
        category: String,
        notify: () -> Unit,
    ): Boolean = observed(
        context,
        identifier,
        category,
        NotificationLifecycleState.POSTED,
        notify,
    )

    /** Records CANCELLED only after the platform cancellation call returns. */
    fun cancelled(
        context: Context,
        identifier: String,
        category: String,
        cancel: () -> Unit,
    ): Boolean = observed(
        context,
        identifier,
        category,
        NotificationLifecycleState.CANCELLED,
        cancel,
    )

    /** Records SCHEDULED only after WorkManager or AlarmManager accepts the request. */
    fun scheduled(
        context: Context,
        identifier: String,
        category: String,
        schedule: () -> Unit,
    ): Boolean = observed(
        context,
        identifier,
        category,
        NotificationLifecycleState.SCHEDULED,
        schedule,
    )

    fun entries(context: Context): List<NotificationLifecycleEntry> = runCatching {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        decode(prefs.getString(ENTRIES_KEY, null))
    }.getOrDefault(emptyList())

    fun diagnosticLines(context: Context): List<String> {
        val snapshot = entries(context)
        return buildList {
            add("─".repeat(40))
            add("Local notification lifecycle")
            add(POSTED_DISCLAIMER)
            if (snapshot.isEmpty()) {
                add("(no lifecycle events recorded)")
            } else {
                snapshot.forEach { entry ->
                    add(
                        "${entry.timestamp} · ${entry.identifier} · ${entry.category} · " +
                            entry.state.wireValue,
                    )
                }
            }
        }
    }

    private fun observed(
        context: Context,
        identifier: String,
        category: String,
        successState: NotificationLifecycleState,
        operation: () -> Unit,
    ): Boolean = runCatching {
        observe(context, identifier, category, successState, operation)
    }.isSuccess

    internal fun record(
        prefs: SharedPreferences,
        entry: NotificationLifecycleEntry,
    ) {
        if (!isValid(entry)) return
        synchronized(lock) {
            val encoded = appendEncoded(
                raw = prefs.getString(ENTRIES_KEY, null),
                entry = entry,
            )
            prefs.edit().putString(ENTRIES_KEY, encoded).apply()
        }
    }

    internal fun appendEncoded(
        raw: String?,
        entry: NotificationLifecycleEntry,
        limit: Int = MAX_ENTRIES,
    ): String {
        val safeLimit = limit.coerceAtLeast(1)
        val current = decode(raw)
        val next = if (isValid(entry)) {
            (current + entry).takeLast(safeLimit)
        } else {
            current.takeLast(safeLimit)
        }
        return encode(next)
    }

    internal fun decode(raw: String?): List<NotificationLifecycleEntry> {
        if (raw.isNullOrBlank()) return emptyList()
        val rows = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (row.keys().asSequence().toSet() != entryKeys) continue
                val identifier = row.opt("identifier") as? String ?: continue
                val category = row.opt("category") as? String ?: continue
                val stateRaw = row.opt("state") as? String ?: continue
                val timestamp = (row.opt("timestamp") as? Number)?.toLong() ?: continue
                val state = NotificationLifecycleState.entries.firstOrNull {
                    it.wireValue == stateRaw
                } ?: continue
                val entry = NotificationLifecycleEntry(
                    identifier = identifier,
                    category = category,
                    state = state,
                    timestamp = timestamp,
                )
                if (isValid(entry)) add(entry)
            }
        }.takeLast(MAX_ENTRIES)
    }

    internal fun encode(entries: List<NotificationLifecycleEntry>): String {
        val rows = JSONArray()
        entries.filter(::isValid).takeLast(MAX_ENTRIES).forEach { entry ->
            rows.put(
                JSONObject()
                    .put("identifier", entry.identifier)
                    .put("category", entry.category)
                    .put("state", entry.state.wireValue)
                    .put("timestamp", entry.timestamp),
            )
        }
        return rows.toString()
    }

    internal fun isValid(entry: NotificationLifecycleEntry): Boolean =
        entry.identifier in NotificationLifecycleId.all &&
            entry.category in NotificationLifecycleCategory.all &&
            entry.timestamp > 0L
}
