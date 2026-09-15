package com.noop.ui

import android.content.Context
import android.content.SharedPreferences

/**
 * Process-local committed view of Adaptive Day consent.
 *
 * SharedPreferences exposes editor changes in memory before a failed disk commit returns. All
 * evaluators read through this gate so they continue seeing the last committed value throughout a
 * failed transaction. Disable transactions atomically persist consent plus a cleanup-pending marker.
 */
internal object AdaptiveDayConsentGate {
    @Volatile private var guidanceValue: Boolean? = null
    @Volatile private var calendarValue: Boolean? = null

    fun guidance(context: Context): Boolean =
        guidance(NoopPrefs.of(context.applicationContext))

    internal fun guidance(prefs: SharedPreferences): Boolean {
        guidanceValue?.let { return it }
        return synchronized(this) {
            guidanceValue ?: prefs.getBoolean(NoopPrefs.KEY_ADAPTIVE_DAY_GUIDANCE, false)
                .also { guidanceValue = it }
        }
    }

    fun plannedWorkoutCalendar(context: Context): Boolean =
        plannedWorkoutCalendar(NoopPrefs.of(context.applicationContext))

    internal fun plannedWorkoutCalendar(prefs: SharedPreferences): Boolean {
        calendarValue?.let { return it }
        return synchronized(this) {
            calendarValue ?: prefs.getBoolean(NoopPrefs.KEY_PLANNED_WORKOUT_CALENDAR, false)
                .also { calendarValue = it }
        }
    }

    @Synchronized
    fun commitGuidance(context: Context, enabled: Boolean): Boolean {
        return commitGuidance(NoopPrefs.of(context.applicationContext), enabled)
    }

    @Synchronized
    internal fun commitGuidance(prefs: SharedPreferences, enabled: Boolean): Boolean {
        val previous = guidance(prefs)
        val previousPending = NoopPrefs.adaptiveDayCleanupPending(prefs)
        val committed = NoopPrefs.commitAdaptiveDayGuidance(
            prefs = prefs,
            enabled = enabled,
            cleanupPending = !enabled,
        )
        if (committed) {
            guidanceValue = enabled
            return true
        }
        NoopPrefs.commitAdaptiveDayGuidance(
            prefs = prefs,
            enabled = previous,
            cleanupPending = previousPending,
        )
        guidanceValue = previous
        return false
    }

    @Synchronized
    fun commitPlannedWorkoutCalendar(context: Context, enabled: Boolean): Boolean {
        return commitPlannedWorkoutCalendar(NoopPrefs.of(context.applicationContext), enabled)
    }

    @Synchronized
    internal fun commitPlannedWorkoutCalendar(
        prefs: SharedPreferences,
        enabled: Boolean,
    ): Boolean {
        val previous = plannedWorkoutCalendar(prefs)
        val previousPending = NoopPrefs.plannedWorkoutCleanupPending(prefs)
        val committed = NoopPrefs.commitPlannedWorkoutCalendar(
            prefs = prefs,
            enabled = enabled,
            cleanupPending = !enabled,
        )
        if (committed) {
            calendarValue = enabled
            return true
        }
        NoopPrefs.commitPlannedWorkoutCalendar(
            prefs = prefs,
            enabled = previous,
            cleanupPending = previousPending,
        )
        calendarValue = previous
        return false
    }

    fun guidanceCleanupPending(context: Context): Boolean =
        NoopPrefs.adaptiveDayCleanupPending(context.applicationContext)

    fun plannedWorkoutCleanupPending(context: Context): Boolean =
        NoopPrefs.plannedWorkoutCleanupPending(context.applicationContext)

    fun clearGuidanceCleanupPending(context: Context): Boolean =
        NoopPrefs.clearAdaptiveDayCleanupPending(context.applicationContext)

    fun clearPlannedWorkoutCleanupPending(context: Context): Boolean =
        NoopPrefs.clearPlannedWorkoutCleanupPending(context.applicationContext)

    @Synchronized
    internal fun resetForTests() {
        guidanceValue = null
        calendarValue = null
    }
}
