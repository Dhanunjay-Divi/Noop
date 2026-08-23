package com.noop.automation

import android.content.Context
import java.util.UUID

/**
 * One explicit action a fresh band double-tap may consume. Safety, medication, and emergency actions
 * are intentionally not representable: an ambiguous gesture must never confirm or cancel them.
 */
enum class TapAutomationKind(val priority: Int) {
    ALARM_DISMISS(300),
    ALARM_SNOOZE(300),
    HYDRATION_CONFIRM(200),
    REMINDER_ACKNOWLEDGE(100),
}

data class PendingTapAutomation(
    val token: String,
    val kind: TapAutomationKind,
    /** Action-specific validated integer: hydration millilitres or alarm snooze minutes. */
    val value: Int,
    /** Optional occurrence identity, such as a hydration reminder slot. */
    val contextKey: String?,
    val createdAtMs: Long,
    val expiresAtMs: Long,
) {
    fun isActive(nowMs: Long): Boolean = nowMs >= createdAtMs && nowMs < expiresAtMs

    companion object {
        fun create(
            kind: TapAutomationKind,
            value: Int = 0,
            contextKey: String? = null,
            nowMs: Long = System.currentTimeMillis(),
            windowMinutes: Int,
            token: String = UUID.randomUUID().toString(),
        ): PendingTapAutomation = PendingTapAutomation(
            token = token,
            kind = kind,
            value = value,
            contextKey = contextKey,
            createdAtMs = nowMs,
            expiresAtMs = nowMs + windowMinutes.coerceIn(1, 30) * 60_000L,
        )
    }
}

/** Pure, single-slot priority and exactly-once state machine. */
class PendingTapAutomationState(initial: PendingTapAutomation? = null) {
    var pending: PendingTapAutomation? = initial
        private set

    fun arm(action: PendingTapAutomation, nowMs: Long): Boolean {
        discardExpired(nowMs)
        if ((pending?.kind?.priority ?: Int.MIN_VALUE) > action.kind.priority) return false
        pending = action
        return true
    }

    fun consume(nowMs: Long): PendingTapAutomation? {
        discardExpired(nowMs)
        val action = pending ?: return null
        pending = null
        return action
    }

    fun discardExpired(nowMs: Long) {
        if (pending?.isActive(nowMs) == false) pending = null
    }

    fun clear(kind: TapAutomationKind) {
        if (pending?.kind == kind) pending = null
    }
}

/**
 * Durable pending token plus an in-process gesture receipt. The receipt lets the foreground service
 * and Activity-scoped ViewModel race safely: whichever consumes first performs the action, and the
 * other sees [GestureResult.AlreadyConsumed] instead of falling through to the normal shortcut.
 */
object TapAutomationStore {
    private const val FILE = "noop_tap_automation"
    private const val TOKEN = "pending.token"
    private const val KIND = "pending.kind"
    private const val VALUE = "pending.value"
    private const val CONTEXT = "pending.context"
    private const val CREATED = "pending.createdAtMs"
    private const val EXPIRES = "pending.expiresAtMs"

    private val lock = Any()
    private var lastConsumedGestureSequence = Long.MIN_VALUE

    sealed class GestureResult {
        data class Consumed(val action: PendingTapAutomation) : GestureResult()
        object AlreadyConsumed : GestureResult()
        object None : GestureResult()
    }

    fun arm(context: Context, action: PendingTapAutomation, nowMs: Long = System.currentTimeMillis()): Boolean =
        synchronized(lock) {
            val state = PendingTapAutomationState(load(context))
            val armed = state.arm(action, nowMs)
            save(context, state.pending)
            armed
        }

    fun consumeForGesture(
        context: Context,
        gestureSequence: Long,
        nowMs: Long = System.currentTimeMillis(),
    ): GestureResult = synchronized(lock) {
        if (gestureSequence == lastConsumedGestureSequence) return@synchronized GestureResult.AlreadyConsumed
        val state = PendingTapAutomationState(load(context))
        val action = state.consume(nowMs)
        save(context, state.pending)
        if (action == null) {
            GestureResult.None
        } else {
            lastConsumedGestureSequence = gestureSequence
            GestureResult.Consumed(action)
        }
    }

    fun clear(context: Context) = synchronized(lock) {
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun clear(context: Context, kind: TapAutomationKind) = synchronized(lock) {
        val state = PendingTapAutomationState(load(context))
        state.clear(kind)
        save(context, state.pending)
    }

    internal fun resetProcessReceiptForTests() = synchronized(lock) {
        lastConsumedGestureSequence = Long.MIN_VALUE
    }

    private fun load(context: Context): PendingTapAutomation? {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val token = prefs.getString(TOKEN, null) ?: return null
        val kind = prefs.getString(KIND, null)?.let {
            runCatching { TapAutomationKind.valueOf(it) }.getOrNull()
        } ?: return null
        return PendingTapAutomation(
            token = token,
            kind = kind,
            value = prefs.getInt(VALUE, 0),
            contextKey = prefs.getString(CONTEXT, null),
            createdAtMs = prefs.getLong(CREATED, 0L),
            expiresAtMs = prefs.getLong(EXPIRES, 0L),
        )
    }

    private fun save(context: Context, pending: PendingTapAutomation?) {
        val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        if (pending == null) {
            prefs.edit().clear().apply()
            return
        }
        prefs.edit()
            .putString(TOKEN, pending.token)
            .putString(KIND, pending.kind.name)
            .putInt(VALUE, pending.value)
            .putString(CONTEXT, pending.contextKey)
            .putLong(CREATED, pending.createdAtMs)
            .putLong(EXPIRES, pending.expiresAtMs)
            .apply()
    }
}

enum class AlarmTapResponse { DISMISS, SNOOZE }

object AlarmTapAutomationPrefs {
    private const val FILE = "noop_tap_alarm"
    private const val ENABLED = "alarm.enabled"
    private const val RESPONSE = "alarm.response"
    private const val WINDOW_MINUTES = "alarm.windowMinutes"
    private const val SNOOZE_MINUTES = "alarm.snoozeMinutes"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean = prefs(context).getBoolean(ENABLED, false)
    fun setEnabled(context: Context, enabled: Boolean) =
        prefs(context).edit().putBoolean(ENABLED, enabled).apply()

    fun response(context: Context): AlarmTapResponse =
        prefs(context).getString(RESPONSE, null)?.let {
            runCatching { AlarmTapResponse.valueOf(it) }.getOrNull()
        } ?: AlarmTapResponse.DISMISS

    fun setResponse(context: Context, response: AlarmTapResponse) =
        prefs(context).edit().putString(RESPONSE, response.name).apply()

    fun windowMinutes(context: Context): Int =
        prefs(context).getInt(WINDOW_MINUTES, 15).coerceIn(5, 30)

    fun setWindowMinutes(context: Context, minutes: Int) =
        prefs(context).edit().putInt(WINDOW_MINUTES, minutes.coerceIn(5, 30)).apply()

    fun snoozeMinutes(context: Context): Int =
        prefs(context).getInt(SNOOZE_MINUTES, 10).coerceIn(5, 30)

    fun setSnoozeMinutes(context: Context, minutes: Int) =
        prefs(context).edit().putInt(SNOOZE_MINUTES, minutes.coerceIn(5, 30)).apply()

    fun armForActiveAlarm(context: Context, nowMs: Long = System.currentTimeMillis()) {
        if (!enabled(context)) return
        val response = response(context)
        TapAutomationStore.arm(
            context,
            PendingTapAutomation.create(
                kind = if (response == AlarmTapResponse.SNOOZE) {
                    TapAutomationKind.ALARM_SNOOZE
                } else {
                    TapAutomationKind.ALARM_DISMISS
                },
                value = if (response == AlarmTapResponse.SNOOZE) snoozeMinutes(context) else 0,
                nowMs = nowMs,
                windowMinutes = windowMinutes(context),
            ),
            nowMs,
        )
    }
}
