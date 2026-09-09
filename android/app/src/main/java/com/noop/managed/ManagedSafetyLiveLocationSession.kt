package com.noop.managed

import android.content.Context
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Durable latest-location session for one owner-created managed Safety page.
 *
 * Only the opaque incident reference and bounded expiry are persisted. Coordinates remain latest-only
 * on the server and never enter this preference file.
 */
object ManagedSafetyLiveLocationSession {
    data class State(
        val incidentId: String? = null,
        val expiresAtUnix: Long? = null,
    ) {
        fun isActiveAt(nowUnix: Long): Boolean =
            !incidentId.isNullOrBlank() &&
                expiresAtUnix?.let { it > nowUnix } == true
    }

    private const val FILE = "noop_managed_safety_live_location"
    private const val INCIDENT_ID = "incident_id"
    private const val EXPIRES_AT_UNIX = "expires_at_unix"
    internal const val MAXIMUM_SESSION_SECONDS = 12L * 60L * 60L

    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    private var initialized = false

    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        val preferences = preferences(context)
        val restoredId = preferences.getString(INCIDENT_ID, null)
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?.toString()
            ?.lowercase()
        mutableState.value = State(
            incidentId = restoredId,
            expiresAtUnix = preferences.getLong(EXPIRES_AT_UNIX, 0L)
                .takeIf { it > 0L },
        )
        val nowUnix = System.currentTimeMillis() / 1_000L
        if (!mutableState.value.isActiveAt(nowUnix)) {
            mutableState.value = State()
            preferences.edit().clear().apply()
        }
        initialized = true
    }

    @Synchronized
    fun start(
        context: Context,
        incidentId: UUID,
        expiresAtUnix: Long,
        nowUnix: Long = System.currentTimeMillis() / 1_000L,
    ): Boolean {
        initialize(context)
        if (expiresAtUnix <= nowUnix) {
            stop(context, incidentId)
            return false
        }
        val normalizedId = incidentId.toString().lowercase()
        val boundedExpiry = minOf(
            expiresAtUnix,
            nowUnix + MAXIMUM_SESSION_SECONDS,
        )
        val next = State(
            incidentId = normalizedId,
            expiresAtUnix = boundedExpiry,
        )
        val changed = mutableState.value != next
        mutableState.value = next
        preferences(context).edit()
            .putString(INCIDENT_ID, normalizedId)
            .putLong(EXPIRES_AT_UNIX, boundedExpiry)
            .apply()
        return changed
    }

    @Synchronized
    fun stop(context: Context, expectedIncidentId: UUID? = null): Boolean {
        initialize(context)
        if (
            expectedIncidentId != null &&
            mutableState.value.incidentId != expectedIncidentId.toString().lowercase()
        ) {
            return false
        }
        val changed = mutableState.value != State()
        mutableState.value = State()
        preferences(context).edit().clear().apply()
        return changed
    }

    internal fun activeOwnerIncident(
        incidents: List<ManagedSafetyIncident>,
        now: Instant,
    ): ManagedSafetyIncident? =
        incidents.firstOrNull { incident ->
            incident.role == "owner" &&
                incident.shareLocation &&
                incident.status in setOf("open", "acknowledged") &&
                runCatching { Instant.parse(incident.expiresAt) }
                    .getOrNull()
                    ?.isAfter(now) == true
        }

    internal fun remainingSessionSeconds(
        expiresAtUnix: Long,
        nowUnix: Long,
    ): Long =
        (expiresAtUnix - nowUnix).coerceIn(0L, MAXIMUM_SESSION_SECONDS)

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}

internal object ManagedSafetyLocationRetryPolicy {
    fun delayMillis(afterFailedAttempt: Int): Long? = when (afterFailedAttempt) {
        1 -> 2_000L
        2 -> 5_000L
        else -> null
    }
}
