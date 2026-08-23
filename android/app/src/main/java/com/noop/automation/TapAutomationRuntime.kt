package com.noop.automation

import android.content.Context
import com.noop.alarm.SmartAlarmReceiver
import com.noop.alarm.SmartAlarmScheduler
import com.noop.analytics.HydrationStore
import com.noop.ble.WhoopBleClient
import com.noop.data.WhoopRepository
import com.noop.notif.HydrationReminderEscalationScheduler
import com.noop.notif.HydrationReminderPrefs
import com.noop.notif.SmartAlarmNotifier

/** Performs an already-consumed token. Callers must never invoke this for [GestureResult.None]. */
object TapAutomationRuntime {
    suspend fun perform(
        context: Context,
        action: PendingTapAutomation,
        repository: WhoopRepository,
        ble: WhoopBleClient,
    ): String {
        return when (action.kind) {
            TapAutomationKind.ALARM_DISMISS -> {
                dismissAlarm(context, ble)
                "Double-tap -> dismissed active alarm"
            }
            TapAutomationKind.ALARM_SNOOZE -> {
                val minutes = action.value.coerceIn(5, 30)
                val scheduled = scheduleSnoozeBeforeDismiss(
                    minutes = minutes,
                    schedule = { SmartAlarmScheduler.scheduleSnooze(context, it) },
                    dismiss = { dismissAlarm(context, ble) },
                )
                if (scheduled) {
                    "Double-tap -> snoozed alarm for $minutes min"
                } else {
                    "Double-tap -> snooze unavailable; active alarm left on"
                }
            }
            TapAutomationKind.HYDRATION_CONFIRM -> {
                val amountMl = action.value.coerceIn(50, 1_000)
                HydrationStore.log(repository, amountMl)
                action.contextKey?.let {
                    HydrationReminderPrefs.markConfirmedSlot(context, it)
                    HydrationReminderEscalationScheduler.cancel(context, it)
                }
                ble.buzz(1)
                "Double-tap -> confirmed $amountMl ml water"
            }
            TapAutomationKind.REMINDER_ACKNOWLEDGE ->
                "Double-tap -> acknowledged reminder"
        }
    }

    private fun dismissAlarm(context: Context, ble: WhoopBleClient) {
        SmartAlarmReceiver.dismissActive(context)
        SmartAlarmNotifier.dismiss(context)
        ble.stopHaptics()
    }

    /**
     * The replacement must exist before the active wake cue is dismissed. A false return or thrown
     * scheduler error deliberately leaves the current alarm active.
     */
    internal fun scheduleSnoozeBeforeDismiss(
        minutes: Int,
        schedule: (Int) -> Boolean,
        dismiss: () -> Unit,
    ): Boolean {
        val scheduled = schedule(minutes.coerceIn(5, 30))
        if (scheduled) dismiss()
        return scheduled
    }
}
