package com.noop.notif

import android.content.Context
import com.noop.AppDiagnosticsRecorder

/**
 * Device-local presentation choices. These switches change only how already-authorized notifications
 * appear; they never enable collection, Safety paging, location sharing, or a network capability.
 */
internal object NotificationPresentationPreferences {
    private const val FILE = "noop_prefs"
    internal const val KEY_MANAGED_SAFETY_URGENT_SOUND =
        "noop.managedSafetyUrgentSound"
    internal const val KEY_LIVE_HEART_RATE =
        "noop.liveHeartRateNotification"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun managedSafetyUrgentSound(context: Context): Boolean =
        prefs(context).getBoolean(KEY_MANAGED_SAFETY_URGENT_SOUND, false)

    fun setManagedSafetyUrgentSound(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_MANAGED_SAFETY_URGENT_SOUND, enabled).apply()
        AppDiagnosticsRecorder.record(
            "managed_safety.presentation_preference",
            fields = mapOf(
                "urgent_sound" to if (enabled) "enabled" else "disabled",
            ),
        )
    }

    fun liveHeartRate(context: Context): Boolean =
        prefs(context).getBoolean(KEY_LIVE_HEART_RATE, false)

    fun setLiveHeartRate(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_LIVE_HEART_RATE, enabled).apply()
        AppDiagnosticsRecorder.record(
            "live_hr.notification_preference",
            fields = mapOf(
                "presentation" to if (enabled) "enabled" else "disabled",
                "cadence" to "bounded_15s",
            ),
        )
    }
}
