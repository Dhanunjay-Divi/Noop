package com.noop.alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.noop.notif.AdaptiveDayNotifier

/**
 * Re-arms local wall-clock alarms after reboot, manual clock changes, DST, or travel (#207).
 *
 * AlarmManager schedules are cleared by a restart, so without this a phone that reboots overnight
 * would silently drop the alarm — exactly the failure the safety guarantee exists to prevent. On
 * BOOT_COMPLETED (and the OEM "quick boot" variant) we re-schedule the SAME persisted hard deadline
 * via [SmartAlarmScheduler.rearmPersisted], which no-ops if the alarm is disabled or already past.
 * For a timezone/date/clock change, the persisted epoch is no longer authoritative, so the wake
 * alarm is recomputed from the user's local wall-clock target.
 */
class SmartAlarmBootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {
                runCatching {
                    SmartAlarmScheduler.rearmPersisted(context, SmartAlarmStore.from(context))
                }
                rearmWindDown(context)
                runCatching { AdaptiveDayNotifier.onTimeZoneChanged(context) }
            }

            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_DATE_CHANGED -> {
                runCatching {
                    val smart = SmartAlarmStore.from(context)
                    if (smart.enabled) SmartAlarmScheduler.arm(context, smart)
                }
                rearmWindDown(context)
                if (intent.action == Intent.ACTION_TIMEZONE_CHANGED) {
                    runCatching { AdaptiveDayNotifier.onTimeZoneChanged(context) }
                }
            }
        }
    }

    private fun rearmWindDown(context: Context) {
        runCatching {
            val wind = WindDownStore.from(context)
            if (wind.enabled) {
                val wake = SmartAlarmStore.from(context).targetMinutes
                WindDownScheduler.schedule(context, wind, wake)
            }
        }
    }
}
