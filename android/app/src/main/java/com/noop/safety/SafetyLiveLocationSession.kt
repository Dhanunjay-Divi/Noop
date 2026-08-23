package com.noop.safety

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Durable latest-only location session state for one active, explicitly opened Safety incident. */
object SafetyLiveLocationSession {
    data class State(
        val dispatchId: String? = null,
        val sequence: Long = 0L,
        val expiresAtUnix: Long? = null,
    ) {
        val active: Boolean get() = !dispatchId.isNullOrBlank()

        fun isActiveAt(nowUnix: Long): Boolean =
            active && (expiresAtUnix == null || expiresAtUnix > nowUnix)
    }

    private const val FILE = "noop_safety_live_location"
    private const val DISPATCH_ID = "dispatch_id"
    private const val SEQUENCE = "sequence"
    private const val EXPIRES_AT_UNIX = "expires_at_unix"
    private const val MAXIMUM_SESSION_SECONDS = 60L * 60L

    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()
    private var initialized = false

    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        val prefs = prefs(context)
        mutableState.value = State(
            dispatchId = prefs.getString(DISPATCH_ID, null),
            sequence = prefs.getLong(SEQUENCE, 0L).coerceAtLeast(0L),
            expiresAtUnix = prefs.getLong(EXPIRES_AT_UNIX, 0L).takeIf { it > 0L },
        )
        val now = System.currentTimeMillis() / 1_000L
        if (!mutableState.value.isActiveAt(now)) {
            mutableState.value = State()
            prefs.edit().clear().apply()
        }
        initialized = true
    }

    @Synchronized
    fun start(
        context: Context,
        dispatchId: String,
        expiresAtUnix: Long? = null,
        nowUnix: Long = System.currentTimeMillis() / 1_000L,
    ) {
        initialize(context)
        if (dispatchId.isBlank()) return
        val boundedExpiry = minOf(
            expiresAtUnix?.takeIf { it > nowUnix } ?: (nowUnix + MAXIMUM_SESSION_SECONDS),
            nowUnix + MAXIMUM_SESSION_SECONDS,
        )
        val current = mutableState.value
        val next = if (current.dispatchId == dispatchId) {
            current.copy(expiresAtUnix = minOf(current.expiresAtUnix ?: boundedExpiry, boundedExpiry))
        } else {
            State(dispatchId = dispatchId, sequence = 0L, expiresAtUnix = boundedExpiry)
        }
        mutableState.value = next
        prefs(context).edit()
            .putString(DISPATCH_ID, next.dispatchId)
            .putLong(SEQUENCE, next.sequence)
            .putLong(EXPIRES_AT_UNIX, next.expiresAtUnix ?: boundedExpiry)
            .apply()
    }

    @Synchronized
    fun nextSequence(context: Context, dispatchId: String): Long? {
        initialize(context)
        val current = mutableState.value
        val now = System.currentTimeMillis() / 1_000L
        if (current.dispatchId != dispatchId ||
            current.sequence == Long.MAX_VALUE ||
            !current.isActiveAt(now)
        ) {
            if (!current.isActiveAt(now)) stop(context, expectedDispatchId = dispatchId)
            return null
        }
        val next = current.copy(sequence = current.sequence + 1L)
        mutableState.value = next
        prefs(context).edit().putLong(SEQUENCE, next.sequence).apply()
        return next.sequence
    }

    @Synchronized
    fun stop(context: Context, expectedDispatchId: String? = null) {
        initialize(context)
        if (expectedDispatchId != null &&
            mutableState.value.dispatchId != expectedDispatchId
        ) {
            return
        }
        mutableState.value = State()
        prefs(context).edit().clear().apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}
