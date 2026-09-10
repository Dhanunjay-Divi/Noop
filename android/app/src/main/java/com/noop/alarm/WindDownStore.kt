package com.noop.alarm

import android.content.Context
import android.content.SharedPreferences
import com.noop.analytics.SleepGoalMode

/**
 * Persisted state for the wind-down nudge (#207) — a gentle evening local notification suggesting
 * it's time to start winding down, so the user can hit their usual wake time with enough sleep.
 *
 * NON-safety-critical (unlike the wake alarm): a missed nudge has no consequence, so it uses an
 * inexact daily repeating alarm. The nudge time is DERIVED, not hand-set: usual wake time − sleep
 * need − a short lead, recomputed whenever the inputs change. Single-user, on-device.
 */
class WindDownStore(private val prefs: SharedPreferences) {

    /** Master enable. Default OFF (opt-in like every NOOP automation). */
    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(v) = prefs.edit().putBoolean(KEY_ENABLED, v).apply()

    /** Typical sleep need in minutes (default 8 h). Used to back-compute the nudge from the wake time. */
    var sleepNeedMinutes: Int
        get() = prefs.getInt(KEY_SLEEP_NEED, DEFAULT_SLEEP_NEED).coerceIn(SLEEP_MIN, SLEEP_MAX)
        set(v) = prefs.edit().putInt(KEY_SLEEP_NEED, v.coerceIn(SLEEP_MIN, SLEEP_MAX)).apply()

    val hasExplicitSleepNeed: Boolean
        get() = prefs.contains(KEY_SLEEP_NEED)

    var goalMode: SleepGoalMode
        get() = SleepGoalMode.fromPersisted(prefs.getString(KEY_GOAL_MODE, null))
        set(v) = prefs.edit().putString(KEY_GOAL_MODE, v.persistedValue).apply()

    /** Planner-derived extra sleep opportunity from recent debt. Never reduces [sleepNeedMinutes]. */
    var recoveryMinutes: Int
        get() = prefs.getInt(KEY_RECOVERY, 0).coerceIn(0, RECOVERY_MAX)
        set(v) = prefs.edit().putInt(KEY_RECOVERY, v.coerceIn(0, RECOVERY_MAX)).apply()

    val targetSleepMinutes: Int get() = sleepNeedMinutes + recoveryMinutes

    /** Lead time (minutes) before bed to nudge, so winding down actually finishes by lights-out. */
    var leadMinutes: Int
        get() = prefs.getInt(KEY_LEAD, DEFAULT_LEAD).coerceIn(LEAD_MIN, LEAD_MAX)
        set(v) = prefs.edit().putInt(KEY_LEAD, v.coerceIn(LEAD_MIN, LEAD_MAX)).apply()

    /**
     * Minute-of-day the nudge should fire, derived from a wake time: wake − sleepNeed − lead,
     * wrapped into [0, 1440). With an 06:30 wake, 8 h need and 30 min lead this is 22:00.
     */
    fun nudgeMinuteOfDay(wakeMinutes: Int): Int {
        val raw = wakeMinutes - targetSleepMinutes - leadMinutes
        val day = 24 * 60
        return ((raw % day) + day) % day
    }

    companion object {
        private const val PREFS = "noop_wind_down"
        private const val KEY_ENABLED = "windDown.enabled"
        private const val KEY_SLEEP_NEED = "windDown.sleepNeedMinutes"
        private const val KEY_GOAL_MODE = "windDown.goalMode"
        private const val KEY_RECOVERY = "windDown.recoveryMinutes"
        private const val KEY_LEAD = "windDown.leadMinutes"

        const val DEFAULT_SLEEP_NEED = 8 * 60
        const val DEFAULT_LEAD = 30
        const val SLEEP_MIN = 5 * 60
        const val SLEEP_MAX = 11 * 60
        const val LEAD_MIN = 0
        const val LEAD_MAX = 120
        const val RECOVERY_MAX = 60

        fun from(context: Context): WindDownStore =
            WindDownStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}
