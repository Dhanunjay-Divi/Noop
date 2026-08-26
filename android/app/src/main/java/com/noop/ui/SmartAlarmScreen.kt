package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.ScoreConfidence
import com.noop.analytics.SleepDebt
import com.noop.analytics.SleepGoalMode
import com.noop.analytics.SleepPlan
import com.noop.analytics.SleepPlanner
import com.noop.automation.AlarmTapAutomationPrefs
import com.noop.automation.AlarmTapResponse
import com.noop.ble.PuffinExperiment
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import kotlin.math.abs

/**
 * Smart alarm (#207) — Android phone-based wake, with a guaranteed hard-deadline fallback.
 *
 * The user picks the EARLIEST acceptable wake time and a window length. NOOP watches the overnight
 * strap stream and, if it spots a lighter sleep phase inside the window, wakes you then — but a
 * GUARANTEED exact OS alarm is always scheduled at the window's END (via AlarmManager), independent
 * of Bluetooth, the strap, or the app being alive. The smart logic can only ever move the alarm
 * EARLIER; it can never cancel or skip the fallback. So you're woken by the window's end no matter
 * what. This screen is explicit about that safety guarantee.
 *
 * This is the ONE alarm surface (#766). It hosts the phone-based Wake Window above, the strap's own
 * standalone firmware wake-alarm (moved here from Automations), and the cross-platform WIND-DOWN nudge,
 * so every wake/alarm control lives together instead of being split across two screens.
 */
@Composable
fun SmartAlarmScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val enabled by vm.phoneAlarmEnabled.collectAsStateWithLifecycle()
    val targetMinutes by vm.phoneAlarmTargetMinutes.collectAsStateWithLifecycle()
    val windowMinutes by vm.phoneAlarmWindowMinutes.collectAsStateWithLifecycle()
    val buzzWhoop4 by vm.buzzWhoop4Enabled.collectAsStateWithLifecycle()
    val sleepTargetMinutes by vm.windDownSleepNeedMinutes.collectAsStateWithLifecycle()
    val sleepGoalMode by vm.windDownGoalMode.collectAsStateWithLifecycle()
    val windDownLeadMinutes by vm.windDownLeadMinutes.collectAsStateWithLifecycle()
    val days by vm.recentDays.collectAsStateWithLifecycle()
    // #536: the hint adapts to bond state — the strap can only be armed when a WHOOP 4.0 is connected.
    val liveState = vm.live.collectAsStateWithLifecycle().value
    val bonded = liveState.bonded
    val strapName = "Noop Band"

    // True when exact alarms are permitted. Re-read on each (re)composition because the user can grant
    // it in Settings and come back — there's no result callback for this special-access permission.
    var canSchedule by remember { mutableStateOf(vm.canScheduleExactAlarms()) }
    var alarmTapEnabled by remember { mutableStateOf(AlarmTapAutomationPrefs.enabled(context)) }
    var alarmTapResponse by remember { mutableStateOf(AlarmTapAutomationPrefs.response(context)) }
    var alarmTapWindow by remember { mutableStateOf(AlarmTapAutomationPrefs.windowMinutes(context)) }
    var alarmTapSnooze by remember { mutableStateOf(AlarmTapAutomationPrefs.snoozeMinutes(context)) }

    // Load the same full sleep-block union and learned main-night timing as the Sleep tab so recorded
    // naps repay the planner's recent balance without changing the canonical nightly total.
    var plannerSleeps by remember { mutableStateOf<List<SleepSession>>(emptyList()) }
    var habitualMidsleep by remember { mutableStateOf<Long?>(null) }
    LaunchedEffect(days) {
        plannerSleeps = runCatching {
            val now = System.currentTimeMillis() / 1000L
            val imported = vm.repo.sleepSessionsUnion(vm.activeStrapId, 0L, now)
            val computed = vm.repo.computedSleepSessionsUnion(vm.activeStrapId, 0L, now)
            WhoopRepository.mergeSleep(imported, computed)
                .sortedBy { it.effectiveStartTs }
        }.getOrDefault(emptyList())
        habitualMidsleep = runCatching {
            vm.repo.habitualMidsleepSec(vm.activeStrapId)
        }.getOrNull()
    }
    val napMinutesByDay = remember(plannerSleeps, habitualMidsleep) {
        napSleepMinutesByDay(plannerSleeps, habitualMidsleep)
    }
    val plannerLedger = remember(days, napMinutesByDay, sleepTargetMinutes) {
        SleepDebt.ledger(
            days.map { day ->
                day.day to SleepDebt.creditedSleepMin(
                    day.totalSleepMin,
                    napMinutesByDay[day.day] ?: 0.0,
                )
            },
            needHours = sleepTargetMinutes / 60.0,
        )
    }
    val sleepPlan = remember(
        targetMinutes,
        sleepTargetMinutes,
        sleepGoalMode,
        windDownLeadMinutes,
        plannerLedger,
    ) {
        SleepPlanner.plan(
            wakeMinute = targetMinutes,
            sleepTargetMinutes = sleepTargetMinutes,
            windDownLeadMinutes = windDownLeadMinutes,
            debtBalanceMinutes = plannerLedger.balanceMin.takeIf { plannerLedger.nightCount > 0 },
            historyNights = plannerLedger.nightCount,
            goalMode = sleepGoalMode,
        )
    }
    LaunchedEffect(sleepPlan.recoveryMinutes) {
        vm.setWindDownRecoveryMinutes(sleepPlan.recoveryMinutes)
    }

    // PERF (#707): lazy scaffold — each card is one `item`. Order +
    // spacing unchanged (LazyColumn reproduces the eager `spacedBy(20.dp)`); only on-screen cards compose +
    // are accessibility-walked.
    LazyScreenScaffold(
        title = stringResource(R.string.sleep_planner_title),
        subtitle = stringResource(R.string.sleep_planner_subtitle),
    ) {
        item { SleepPlanCard(sleepPlan, enabled, habitualMidsleep) }

        // The guaranteed-wake card always shows so the safety promise is the first thing read.
        item { WindowCard(enabled = enabled, targetMinutes = targetMinutes, windowMinutes = windowMinutes) }

        item {
        AlarmSettingsCard {
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_wake_me_with_a_smart_alarm_bbbd082d),
                help = "A guaranteed OS alarm is set for the end of your window; Noop Band data can move it earlier if you're sleeping lightly.",
                checked = enabled,
                onChange = { want ->
                    if (want && !vm.canScheduleExactAlarms()) {
                        // No callback for this special-access grant — send the user to the system page,
                        // and re-read the state when they return (canSchedule recomputes on recompose).
                        requestExactAlarmAccess(context)
                        canSchedule = vm.canScheduleExactAlarms()
                    } else {
                        val ok = vm.setPhoneAlarmEnabled(want)
                        canSchedule = vm.canScheduleExactAlarms()
                        if (!ok) requestExactAlarmAccess(context)
                    }
                },
            )

            if (enabled && !canSchedule) {
                RowDividerLocal()
                Text(
                    uiString(R.string.l10n_smart_alarm_screen_noop_doesn_t_have_permission_to_5b67cef0) +
                        "Tap to allow it in system settings.",
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            requestExactAlarmAccess(context)
                            canSchedule = vm.canScheduleExactAlarms()
                        },
                )
            }

            if (enabled) {
                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_smart_alarm_screen_wake_me_no_earlier_than_67411622), style = NoopType.body, color = Palette.textPrimary)
                        Text(uiString(R.string.l10n_smart_alarm_screen_the_earliest_noop_will_wake_you_b641a2d4), style = NoopType.footnote, color = Palette.textTertiary)
                    }
                    Spacer(Modifier.width(16.dp))
                    TimeChip(
                        minutes = targetMinutes,
                        accessibilityLabel = "Earliest wake time",
                        onPicked = { vm.setPhoneAlarmTargetMinutes(it) },
                    )
                }

                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_smart_alarm_screen_window_length_46179fcb), style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_smart_alarm_screen_the_guaranteed_alarm_fires_this_long_b0c51052),
                            style = NoopType.footnote, color = Palette.textTertiary,
                        )
                    }
                    Spacer(Modifier.width(16.dp))
                    WindowStepper(
                        windowMinutes = windowMinutes,
                        onChange = { vm.setPhoneAlarmWindowMinutes(it) },
                    )
                }

                RowDividerLocal()
                ToggleRowLocal(
                    label = stringResource(R.string.smart_alarm_tap_response_label),
                    help = stringResource(R.string.smart_alarm_tap_response_help),
                    checked = alarmTapEnabled,
                    onChange = {
                        alarmTapEnabled = it
                        AlarmTapAutomationPrefs.setEnabled(context, it)
                    },
                )
                if (alarmTapEnabled) {
                    AlarmTapResponsePicker(
                        selected = alarmTapResponse,
                        onSelect = {
                            alarmTapResponse = it
                            AlarmTapAutomationPrefs.setResponse(context, it)
                        },
                    )
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            stringResource(R.string.smart_alarm_tap_window_label),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                        Spacer(Modifier.weight(1f))
                        TapMinuteStepper(
                            minutes = alarmTapWindow,
                            onChange = {
                                alarmTapWindow = it
                                AlarmTapAutomationPrefs.setWindowMinutes(context, it)
                            },
                            accessibility = stringResource(R.string.smart_alarm_tap_window_accessibility),
                        )
                    }
                    if (alarmTapResponse == AlarmTapResponse.SNOOZE) {
                        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                stringResource(R.string.smart_alarm_snooze_length_label),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                            Spacer(Modifier.weight(1f))
                            TapMinuteStepper(
                                minutes = alarmTapSnooze,
                                onChange = {
                                    alarmTapSnooze = it
                                    AlarmTapAutomationPrefs.setSnoozeMinutes(context, it)
                                },
                                accessibility = stringResource(R.string.smart_alarm_tap_snooze_accessibility),
                            )
                        }
                    }
                }
            }

            // #536: companion strap-buzz, always visible so it's discoverable. Arms the strap's own firmware
            // alarm at the earliest wake time, so the strap buzzes first and the OS alarm backs it up.
            // #821: label + copy name the CONNECTED strap generation (strapName), not a hardcoded "WHOOP 4".
            RowDividerLocal()
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_buzz_strapname_813772f4, strapName),
                help = if (bonded)
                    "Also arms $strapName to vibrate at your earliest wake time, so the band wakes you first and the phone alarm is the guaranteed backup."
                else
                    "Connect Noop Band to use this. It arms the band to vibrate at your earliest wake time as a gentler first wake-up.",
                checked = buzzWhoop4,
                onChange = { vm.setBuzzWhoop4Enabled(it) },
            )
        }
        }

        // #766: the strap's own firmware wake-alarm (its own time + weekdays + per-day overrides). Moved
        // here from Automations so every wake/alarm control sits on the one Alarms screen instead of being
        // conflated with the wind-down reminder. Distinct from "Buzz WHOOP 4" above, which arms the strap
        // at the PHONE alarm's time; this card is the strap's standalone schedule.
        item { StrapAlarmCard(vm) }

        // The cross-platform wind-down nudge lives here too.
        item {
            WindDownCard(
                vm = vm,
                plan = sleepPlan,
                wakeMinutes = targetMinutes,
                sleepTargetMinutes = sleepTargetMinutes,
                leadMinutes = windDownLeadMinutes,
            )
        }

        // #821: the "how the smart wake works" explainer sat in the MIDDLE of the page (between the wake-alarm
        // settings and the strap alarm), which read as an interruption. It's reference detail, not a control,
        // so it belongs at the BOTTOM after every alarm/reminder control, moved here.
        item { ExplanationCard() }
    }
}

/**
 * The strap's standalone silent wake-alarm (#766, moved from AutomationsScreen). Arms the strap's own
 * firmware alarm at the chosen time/weekdays over BLE, so it buzzes even if NOOP is closed. Reuses the
 * shared [AlarmWeekdayPicker] / [AlarmDayOverridePicker] from AutomationsScreen (same behaviour, just a
 * new home). Functions are untouched: it drives the same `viewModel.setSmartAlarm*` calls as before.
 */
@Composable
private fun StrapAlarmCard(vm: AppViewModel) {
    val context = LocalContext.current
    val smartAlarm by vm.smartAlarmEnabled.collectAsStateWithLifecycle()
    val alarmMinutes by vm.smartAlarmMinutes.collectAsStateWithLifecycle()
    val alarmWeekdays by vm.smartAlarmWeekdays.collectAsStateWithLifecycle()
    val alarmDayOverrides by vm.smartAlarmDayOverrides.collectAsStateWithLifecycle()
    val live = vm.live.collectAsStateWithLifecycle().value
    // The firmware alarm is EXPERIMENTAL on a WHOOP 5/MG: it only arms when Experimental probes are on,
    // otherwise enabling it silently arms nothing (#111), so the UI says so instead of promising a wake.
    val experimentalOn = PuffinExperiment.from(context).isEnabled

    NoopCard(padding = 20.dp, tint = if (smartAlarm) Palette.accent else null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline("Morning")
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Alarm, contentDescription = null, tint = Palette.accent)
                    Spacer(Modifier.width(10.dp))
                    Text("Noop Band wake alarm", style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            // Truth-sync (#535): the WHOOP 4.0 alarm payload was captured from the official app and
            // confirmed buzzing on a real 4.0 by the capture author, so the copy no longer calls the
            // 4.0 path experimental. The 5/MG Experimental-gate branch below is deliberately untouched.
            ToggleRowLocal(
                label = "Wake me with a band vibration",
                help = "Arms Noop Band to vibrate at your wake time, even if NOOP is closed. Keep a backup alarm for anything you truly cannot miss.",
                checked = smartAlarm,
                onChange = { vm.setSmartAlarmEnabled(it) },
            )
            if (smartAlarm) {
                RowDividerLocal()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(uiString(R.string.l10n_smart_alarm_screen_wake_at_49089991), style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(
                        minutes = alarmMinutes,
                        accessibilityLabel = "Noop Band alarm wake time",
                        onPicked = { vm.setSmartAlarmMinutes(it) },
                    )
                }
                RowDividerLocal()
                AlarmWeekdayPicker(
                    selected = alarmWeekdays,
                    onToggle = { dow -> vm.setSmartAlarmWeekdays(toggledSmartAlarmWeekday(dow, alarmWeekdays)) },
                )
                RowDividerLocal()
                // Per-weekday wake-time OVERRIDES (#554): a different time for any day the alarm fires on.
                AlarmDayOverridePicker(
                    defaultMinutes = alarmMinutes,
                    enabledDays = alarmWeekdays,
                    overrides = alarmDayOverrides,
                    onSetOverride = { dow, minutes -> vm.setSmartAlarmDayOverride(dow, minutes) },
                )
                RowDividerLocal()
                if (live.whoop5Detected && !experimentalOn) {
                    Text(
                        "This Noop Band firmware needs Experimental mode before wrist wake can be armed. " +
                            "Your time is saved, but the band is not armed yet. Keep a backup alarm.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                } else if (live.whoop5Detected) {
                    // 5/MG with Experimental ON: the strap IS armed (experimental rev-4 payload) but a
                    // strap-driven wake has NEVER been captured on 5/MG, so the "confirmed on 4.0" copy must
                    // NOT show here (#864 honesty). Byte-identical wording to the Swift SmartAlarmView twin.
                    Text(
                        if (live.bonded)
                            "Armed using the experimental band command. Wrist wake is still under validation for this firmware, so keep a backup alarm."
                        else
                            "Connect Noop Band to arm wrist wake. Keep a backup alarm for anything you truly cannot miss.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                } else {
                    Text(
                        if (live.bonded)
                            "Armed on Noop Band, so it can vibrate even if your phone is asleep or NOOP is closed. Keep a backup alarm for anything you truly cannot miss."
                        else
                            "Connect Noop Band to arm wrist wake. Keep a backup alarm for anything you truly cannot miss.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

// MARK: - Cards

/** The shared planner readout. Reminder state affects delivery, never the underlying bedtime math. */
@Composable
private fun SleepPlanCard(
    plan: SleepPlan,
    reminderEnabled: Boolean,
    habitualMidsleepSeconds: Long?,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius)),
    ) {
        ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Rest)
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline(stringResource(R.string.sleep_planner_tonight_plan))
                Spacer(Modifier.weight(1f))
                Text(planConfidenceLabel(plan.confidence), style = NoopType.caption, color = Palette.textTertiary)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                PlanTime(stringResource(R.string.sleep_planner_wind_down), plan.windDownMinute, DomainTheme.Rest.color, Modifier.weight(1f))
                Text("→", style = NoopType.title2, color = Palette.textTertiary)
                PlanTime(stringResource(R.string.sleep_planner_bedtime), plan.bedtimeMinute, DomainTheme.Rest.bright, Modifier.weight(1f))
                Text("→", style = NoopType.title2, color = Palette.textTertiary)
                PlanTime(stringResource(R.string.sleep_planner_wake), plan.wakeMinute, DomainTheme.Rest.bright, Modifier.weight(1f))
            }
            Text(planSummary(plan), style = NoopType.footnote, color = Palette.textSecondary)
            observedTimingSummary(plan, habitualMidsleepSeconds)?.let { timing ->
                Text(timing, style = NoopType.caption, color = Palette.textTertiary)
            }
            Text(
                if (reminderEnabled)
                    stringResource(R.string.sleep_planner_reminder_on, hhmm(plan.windDownMinute))
                else
                    stringResource(R.string.sleep_planner_reminder_off),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun PlanTime(label: String, minute: Int, color: androidx.compose.ui.graphics.Color, modifier: Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Overline(label)
        Text(hhmm(minute), style = NoopType.number(24f), color = color)
    }
}

@Composable
private fun planSummary(plan: SleepPlan): String {
    val opportunity = durationLabel(plan.sleepOpportunityMinutes)
    when (plan.goalMode) {
        SleepGoalMode.TARGET -> {
            val balance = plan.debtBalanceMinutes
            return if (balance != null && balance < -SleepDebt.ON_TARGET_BAND_MIN) {
                "$opportunity fixed sleep opportunity. Recent history is " +
                    "${durationLabel(abs(balance).toInt())} short, but Target mode does not " +
                    "change the amount you set."
            } else {
                "$opportunity fixed sleep opportunity from the target you set."
            }
        }
        SleepGoalMode.EXTRA_OPPORTUNITY ->
            return "$opportunity sleep opportunity. Extra mode reserves at least 30 minutes " +
                "beyond your target; a supported recent shortfall can raise that addition, " +
                "capped at 1 hour."
        SleepGoalMode.BALANCE -> Unit
    }
    if (plan.historyNights < SleepPlanner.MINIMUM_DEBT_NIGHTS) {
        return stringResource(R.string.sleep_planner_summary_calibrating, opportunity)
    }
    if (plan.recoveryMinutes > 0) {
        return stringResource(
            R.string.sleep_planner_summary_recovery,
            opportunity,
            durationLabel(plan.baseSleepMinutes),
            durationLabel(plan.recoveryMinutes),
            durationLabel(abs(plan.debtBalanceMinutes ?: 0.0).toInt()),
        )
    }
    val balance = plan.debtBalanceMinutes
    if (balance != null && balance > SleepDebt.ON_TARGET_BAND_MIN) {
        return stringResource(
            R.string.sleep_planner_summary_surplus,
            opportunity,
            durationLabel(balance.toInt()),
        )
    }
    return stringResource(R.string.sleep_planner_summary_on_target, opportunity)
}

@Composable
private fun observedTimingSummary(plan: SleepPlan, habitualMidsleepSeconds: Long?): String? {
    val shift = SleepPlanner.observedTimingShiftMinutes(plan, habitualMidsleepSeconds) ?: return null
    if (abs(shift) <= 30) {
        return "Tonight is within 30 minutes of your observed sleep timing."
    }
    val direction = if (shift < 0) "earlier" else "later"
    return "Tonight is ${durationLabel(abs(shift))} $direction than your observed sleep timing. " +
        "This describes your recent behavior, not a biological chronotype."
}

@Composable
private fun planConfidenceLabel(confidence: ScoreConfidence): String = when (confidence) {
    ScoreConfidence.CALIBRATING -> stringResource(R.string.sleep_planner_confidence_calibrating)
    ScoreConfidence.BUILDING -> stringResource(R.string.sleep_planner_confidence_building)
    ScoreConfidence.SOLID -> stringResource(R.string.sleep_planner_confidence_solid)
}

/**
 * The always-visible "you WILL be woken by" guarantee card - a small Rest-world frosted hero. The
 * wake window reads as a clean earliest→deadline time pairing in big rounded numerals over a scenic
 * Rest backdrop (it's about waking, so it lives in the indigo world, not the brand-green chrome).
 */
@Composable
private fun WindowCard(enabled: Boolean, targetMinutes: Int, windowMinutes: Int) {
    val deadline = (targetMinutes + windowMinutes) % (24 * 60)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius)),
    ) {
        ScenicHeroBackground(modifier = Modifier.matchParentSize(), domain = DomainTheme.Rest)
        Row(modifier = Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Shield, contentDescription = null, tint = DomainTheme.Rest.color)
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Overline("Guaranteed wake")
                if (enabled) {
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(hhmm(targetMinutes), style = NoopType.number(28f), color = DomainTheme.Rest.color)
                        Text("→", style = NoopType.title2, color = Palette.textTertiary)
                        Text(hhmm(deadline), style = NoopType.number(28f), color = DomainTheme.Rest.bright)
                    }
                    Text(
                        uiString(R.string.l10n_smart_alarm_screen_a_backup_alarm_is_set_for_cf8b94fb, hhmm(deadline)),
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                } else {
                    Text(uiString(R.string.l10n_smart_alarm_screen_off_e3de5ab0), style = NoopType.title2, color = Palette.textSecondary)
                    Text(
                        uiString(R.string.l10n_smart_alarm_screen_turn_on_the_smart_alarm_to_65700430),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
private fun AlarmSettingsCard(content: @Composable () -> Unit) {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Alarm, contentDescription = null, tint = Palette.accent)
                Spacer(Modifier.width(10.dp))
                Text(uiString(R.string.l10n_smart_alarm_screen_wake_alarm_37af3ecf), style = NoopType.headline, color = Palette.textPrimary)
            }
            content()
        }
    }
}

/** Planner inputs plus the cross-platform evening nudge. The plan remains useful with delivery off. */
@Composable
private fun WindDownCard(
    vm: AppViewModel,
    plan: SleepPlan,
    wakeMinutes: Int,
    sleepTargetMinutes: Int,
    leadMinutes: Int,
) {
    val enabled by vm.windDownEnabled.collectAsStateWithLifecycle()
    val goalMode by vm.windDownGoalMode.collectAsStateWithLifecycle()
    NoopCard(padding = 20.dp, tint = if (enabled) DomainTheme.Rest.color else null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline(stringResource(R.string.sleep_planner_evening))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Bedtime, contentDescription = null, tint = DomainTheme.Rest.color)
                    Spacer(Modifier.width(10.dp))
                    Text(uiString(R.string.l10n_smart_alarm_screen_wind_down_nudge_5ca87a0f), style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            ToggleRowLocal(
                label = uiString(R.string.l10n_smart_alarm_screen_remind_me_to_wind_down_4839f0d0),
                help = stringResource(R.string.sleep_planner_nudge_help),
                checked = enabled,
                onChange = { vm.setWindDownEnabled(it) },
            )
            RowDividerLocal()
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    stringResource(R.string.appwide_sleep_tonights_goal),
                    style = NoopType.body,
                    color = Palette.textPrimary,
                )
                SegmentedPillControl(
                    items = SleepGoalMode.entries,
                    selection = goalMode,
                    label = ::sleepGoalLabel,
                    onSelect = vm::setWindDownGoalMode,
                )
                Text(
                    sleepGoalHelp(goalMode),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            RowDividerLocal()
            PlannerSettingRow(
                label = stringResource(R.string.sleep_planner_sleep_target),
                help = stringResource(R.string.sleep_planner_sleep_target_help),
                value = durationLabel(sleepTargetMinutes),
                canDecrease = sleepTargetMinutes > SleepPlanner.MINIMUM_SLEEP_MINUTES,
                canIncrease = sleepTargetMinutes < SleepPlanner.MAXIMUM_SLEEP_MINUTES,
                decreaseLabel = stringResource(R.string.sleep_planner_sleep_target_decrease),
                increaseLabel = stringResource(R.string.sleep_planner_sleep_target_increase),
                onDecrease = { vm.setWindDownSleepNeedMinutes(sleepTargetMinutes - 15) },
                onIncrease = { vm.setWindDownSleepNeedMinutes(sleepTargetMinutes + 15) },
            )
            RowDividerLocal()
            PlannerSettingRow(
                label = stringResource(R.string.sleep_planner_wind_down_buffer),
                help = stringResource(R.string.sleep_planner_wind_down_buffer_help),
                value = durationLabel(leadMinutes),
                canDecrease = leadMinutes > 0,
                canIncrease = leadMinutes < 120,
                decreaseLabel = stringResource(R.string.sleep_planner_wind_down_buffer_decrease),
                increaseLabel = stringResource(R.string.sleep_planner_wind_down_buffer_increase),
                onDecrease = { vm.setWindDownLeadMinutes(leadMinutes - 15) },
                onIncrease = { vm.setWindDownLeadMinutes(leadMinutes + 15) },
            )
            RowDividerLocal()
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.sleep_planner_wake_time), style = NoopType.body, color = Palette.textPrimary)
                    Text(
                        stringResource(R.string.sleep_planner_wake_time_help),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Spacer(Modifier.width(16.dp))
                TimeChip(
                    minutes = wakeMinutes,
                    accessibilityLabel = stringResource(R.string.sleep_planner_wake_time),
                    onPicked = { vm.setPhoneAlarmTargetMinutes(it) },
                )
            }
            Text(
                if (plan.recoveryMinutes > 0)
                    stringResource(R.string.sleep_planner_recovery_added, durationLabel(plan.recoveryMinutes))
                else
                    stringResource(R.string.sleep_planner_recovery_none),
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
            if (enabled) {
                Text(
                    stringResource(R.string.sleep_planner_reminder_around, hhmm(plan.windDownMinute)),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
        }
    }
}

private fun sleepGoalLabel(mode: SleepGoalMode): String = when (mode) {
    SleepGoalMode.TARGET -> "Target"
    SleepGoalMode.BALANCE -> "Balance"
    SleepGoalMode.EXTRA_OPPORTUNITY -> "Extra"
}

private fun sleepGoalHelp(mode: SleepGoalMode): String = when (mode) {
    SleepGoalMode.TARGET ->
        "Keep the sleep target fixed, even when recent history is short."
    SleepGoalMode.BALANCE ->
        "Add a bounded 15-minute-step adjustment when at least 3 recorded nights show a shortfall."
    SleepGoalMode.EXTRA_OPPORTUNITY ->
        "Reserve at least 30 extra minutes tonight. This is added opportunity, not a promise of better recovery."
}

@Composable
private fun PlannerSettingRow(
    label: String,
    help: String,
    value: String,
    canDecrease: Boolean,
    canIncrease: Boolean,
    decreaseLabel: String,
    increaseLabel: String,
    onDecrease: () -> Unit,
    onIncrease: () -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StepperButton(symbol = "−", onClick = onDecrease, label = decreaseLabel, enabled = canDecrease)
            Text(value, style = NoopType.bodyNumber, color = Palette.textPrimary)
            StepperButton(symbol = "+", onClick = onIncrease, label = increaseLabel, enabled = canIncrease)
        }
    }
}

@Composable
private fun ExplanationCard() {
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Palette.accent)
                Spacer(Modifier.width(10.dp))
                Text(uiString(R.string.l10n_smart_alarm_screen_how_the_smart_wake_works_8cf34930), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                uiString(R.string.l10n_smart_alarm_screen_while_you_re_inside_the_window_8700ca3b) +
                    "sleep sits near your nightly low and stays steady; when your heart rate lifts above " +
                    "that (a sign you're sleeping more lightly or starting to stir), NOOP wakes you a " +
                    "little early so you come up from a lighter phase.",
                style = NoopType.footnote, color = Palette.textSecondary,
            )
            Text(
                uiString(R.string.l10n_smart_alarm_screen_this_is_a_coarse_cue_from_d6bbabe7) +
                    "isn't streaming (Bluetooth off, not worn, app killed), no early wake happens and the " +
                    "guaranteed alarm at the window's end still wakes you.",
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun AlarmTapResponsePicker(
    selected: AlarmTapResponse,
    onSelect: (AlarmTapResponse) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.surfaceInset)
            .padding(3.dp),
    ) {
        AlarmTapResponse.entries.forEach { response ->
            val active = response == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(4.dp))
                    .background(if (active) Palette.accent else Palette.surfaceInset)
                    .clickable { onSelect(response) }
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (response == AlarmTapResponse.DISMISS) {
                        stringResource(R.string.l10n_today_screen_dismiss_70afe9ef)
                    } else {
                        stringResource(R.string.smart_alarm_snooze_action)
                    },
                    style = NoopType.body,
                    color = if (active) Palette.surfaceBase else Palette.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun TapMinuteStepper(
    minutes: Int,
    onChange: (Int) -> Unit,
    accessibility: String,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StepperButton(
            symbol = "−",
            onClick = { onChange((minutes - 5).coerceAtLeast(5)) },
            label = stringResource(R.string.smart_alarm_tap_shorten_action, accessibility),
        )
        Text(
            stringResource(R.string.sleep_planner_duration_minutes, minutes),
            style = NoopType.bodyNumber,
            color = Palette.textPrimary,
        )
        StepperButton(
            symbol = "+",
            onClick = { onChange((minutes + 5).coerceAtMost(30)) },
            label = stringResource(R.string.smart_alarm_tap_lengthen_action, accessibility),
        )
    }
}

// MARK: - Window stepper (5–60 min in 5-min steps)

@Composable
private fun WindowStepper(windowMinutes: Int, onChange: (Int) -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        StepperButton(symbol = "−", onClick = { onChange((windowMinutes - 5).coerceAtLeast(5)) }, label = uiString(R.string.l10n_smart_alarm_screen_shorten_window_5bf5b37d))
        Text(uiString(R.string.l10n_smart_alarm_screen_windowminutes_min_bd89fd82, windowMinutes), style = NoopType.bodyNumber, color = Palette.textPrimary)
        StepperButton(symbol = "+", onClick = { onChange((windowMinutes + 5).coerceAtMost(60)) }, label = uiString(R.string.l10n_smart_alarm_screen_lengthen_window_c947ea1d))
    }
}

// MARK: - Local toggle / divider (mirror the AutomationsScreen idiom, kept local to this lane's file)

@Composable
private fun ToggleRowLocal(label: String, help: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.surfaceBase,
                checkedTrackColor = Palette.accent,
                uncheckedThumbColor = Palette.textSecondary,
                uncheckedTrackColor = Palette.surfaceInset,
                uncheckedBorderColor = Palette.hairline,
            ),
        )
    }
}

@Composable
private fun RowDividerLocal() {
    Spacer(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(Palette.hairline),
    )
}

// MARK: - Helpers

private fun hhmm(minutes: Int): String {
    val m = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
    return "%02d:%02d".format(m / 60, m % 60)
}

@Composable
private fun durationLabel(minutes: Int): String {
    val safe = minutes.coerceAtLeast(0)
    val hours = safe / 60
    val remainder = safe % 60
    return when {
        hours == 0 -> stringResource(R.string.sleep_planner_duration_minutes, remainder)
        remainder == 0 -> stringResource(R.string.sleep_planner_duration_hours, hours)
        else -> stringResource(R.string.sleep_planner_duration_hours_minutes, hours, remainder)
    }
}

/** Open the system page where the user grants the exact-alarm special-access permission (API 31+).
 *  There's no runtime dialog for this; the user toggles it in Settings and returns. */
private fun requestExactAlarmAccess(context: android.content.Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
    runCatching {
        context.startActivity(
            Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }.onFailure {
        // Fall back to the app-details page if the OEM lacks the specific action.
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}
