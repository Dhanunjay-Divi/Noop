package com.noop.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.noop.R
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.noop.analytics.NapCandidate
import com.noop.calendar.PlannedWorkoutCalendarStore
import com.noop.notif.DailyReviewReminders
import com.noop.notif.AdaptiveDayNotifier
import com.noop.notif.HydrationReminderPrefs
import com.noop.notif.HydrationReminderScheduler
import com.noop.notif.ScheduledReportNotifier
import com.noop.notif.StressBreathingNotifier
import com.noop.notif.WorkoutCautionNotifier
import kotlinx.coroutines.launch

/**
 * Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live
 * biometrics into on-device actions and adaptive coaching. Workout guidance, the smart alarm
 * and the illness watch are real + persisted (ViewModel-backed).
 */
private enum class AutomationReportKind {
    MORNING,
    WORKOUT,
}

private fun automationReportsCanNotify(context: Context): Boolean {
    val runtimePermissionGranted =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
    return runtimePermissionGranted &&
        NotificationManagerCompat.from(context).areNotificationsEnabled()
}

@Composable
fun AutomationsScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val lifecycleOwner = LocalLifecycleOwner.current

    // Double-tap action (parity since 4.2.8) — real + persisted via the ViewModel (NoopPrefs). The
    // dispatch runs in the ViewModel on a fresh strap DOUBLE_TAP event; this card just edits the choice.
    val doubleTapAction by viewModel.doubleTapAction.collectAsStateWithLifecycle()

    // (#766) The strap firmware wake-alarm state used to be read here; it moved to SmartAlarmScreen with
    // the rest of the alarm UI.
    // Illness watch is real + persisted (opt-OUT — the watch has always run on Android).
    val illnessWatch by viewModel.illnessWatchEnabled.collectAsStateWithLifecycle()
    val contextualVitalReview by viewModel.contextualVitalReviewEnabled.collectAsStateWithLifecycle()
    val contextualVo2Review by viewModel.contextualVo2ReviewEnabled.collectAsStateWithLifecycle()
    val adaptiveDayGuidance by viewModel.adaptiveDayGuidanceEnabled.collectAsStateWithLifecycle()
    // Battery alerts are real + persisted (opt-OUT, default ON; #368, thanks @ujix).
    val batteryAlerts by viewModel.batteryAlertsEnabled.collectAsStateWithLifecycle()
    val predictiveBatteryAlerts by viewModel.predictiveBatteryAlertsEnabled.collectAsStateWithLifecycle()
    val ctx = LocalContext.current
    var adaptiveNotificationsUnavailable by remember {
        mutableStateOf(
            adaptiveDayGuidance && !AdaptiveDayNotifier.canNotify(ctx),
        )
    }
    var plannedWorkoutCalendarEnabled by remember {
        mutableStateOf(NoopPrefs.plannedWorkoutCalendar(ctx))
    }
    var plannedWorkoutCalendarPermissionUnavailable by remember {
        mutableStateOf(
            plannedWorkoutCalendarEnabled &&
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_CALENDAR) !=
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var workoutNotificationsUnavailable by remember { mutableStateOf(false) }

    // Workout guidance is persisted; the ViewModel owns sustained sample evaluation and band cues.
    val zoneCoaching by viewModel.zoneCoaching.collectAsStateWithLifecycle()
    val zoneCoachRecovery by viewModel.zoneCoachRecovery.collectAsStateWithLifecycle()

    // Inactivity reminder (#419) — real + persisted via InactivityPrefs (opt-in, default OFF). Seeded
    // once, written through on change (SharedPreferences isn't reactive). The buzz itself fires from the
    // BLE offload path (WhoopBleClient.maybeBuzzInactivity → the shipped SedentaryDetector engine); this
    // screen only edits the prefs the engine reads.
    var inactivityEnabled by remember { mutableStateOf(InactivityPrefs.enabled(ctx)) }
    var inactivityThreshold by remember { mutableStateOf(InactivityPrefs.thresholdMinutes(ctx)) }
    var inactivityReNudge by remember { mutableStateOf(InactivityPrefs.reNudgeMinutes(ctx)) }
    var inactivityBuzzLoops by remember { mutableStateOf(InactivityPrefs.buzzLoops(ctx)) }
    var inactivityActiveHours by remember { mutableStateOf(InactivityPrefs.activeHoursEnabled(ctx)) }
    var inactivityActiveStart by remember { mutableStateOf(InactivityPrefs.activeStartMinutes(ctx)) }
    var inactivityActiveEnd by remember { mutableStateOf(InactivityPrefs.activeEndMinutes(ctx)) }
    // The engine also requires the global notification master (default OFF); surface that dependency so
    // enabling the reminder while master is off isn't silently inert.
    val notifMasterOn = NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false)

    // Automatic stress check-ins are opt-in at every layer. Runtime evidence still has to pass the
    // timestamped motion, fresh HR/R-R, worn/encrypted, no-active-session, quiet-hours, and cooldown gates.
    var stressCheckIn by remember { mutableStateOf(BiofeedbackPrefs.checkInEnabled(ctx)) }
    var stressAutoNudge by remember { mutableStateOf(BiofeedbackPrefs.autoNudge(ctx)) }
    var stressPhoneNudge by remember { mutableStateOf(BiofeedbackPrefs.phoneNudge(ctx)) }
    var stressQuietHours by remember { mutableStateOf(BiofeedbackPrefs.quietHoursEnabled(ctx)) }
    var stressNotificationsUnavailable by remember {
        mutableStateOf(
            stressPhoneNudge &&
                !StressBreathingNotifier.canNotify(ctx),
        )
    }

    // Daily guidance mirrors iOS's explicit opt-in pair: a persisted morning Sleep review and an
    // evening Journal prompt that checks completion at delivery time.
    var dailyReviewEnabled by remember { mutableStateOf(DailyReviewReminders.isEnabled(ctx)) }
    var dailyReviewMorning by remember { mutableStateOf(DailyReviewReminders.morningMinutes(ctx)) }
    var dailyReviewEvening by remember { mutableStateOf(DailyReviewReminders.eveningMinutes(ctx)) }
    var dailyReviewNotificationsUnavailable by remember {
        mutableStateOf(dailyReviewEnabled && !DailyReviewReminders.canNotify(ctx))
    }
    val reportsInitiallyAvailable = automationReportsCanNotify(ctx)
    var morningRecapEnabled by remember {
        mutableStateOf(NoopPrefs.morningReportEnabled(ctx))
    }
    var postWorkoutSummaryEnabled by remember {
        mutableStateOf(NoopPrefs.postWorkoutReportEnabled(ctx))
    }
    var reportNotificationsUnavailable by remember {
        mutableStateOf(
            !reportsInitiallyAvailable &&
                (NoopPrefs.morningReportEnabled(ctx) ||
                    NoopPrefs.postWorkoutReportEnabled(ctx)),
        )
    }
    var pendingReportPermission by remember {
        mutableStateOf<AutomationReportKind?>(null)
    }
    var postWorkoutEnablePending by remember { mutableStateOf(false) }

    // Hydration reminders are independently opt-in and live in their own prefs file, so adding this
    // automation cannot overwrite hydration totals or any existing dashboard preference. Phone delivery
    // is a persisted WorkManager one-shot; the optional strap lane only fires on a fresh encrypted packet.
    val hydrationConfig = remember { HydrationReminderPrefs.config(ctx) }
    var hydrationRemindersEnabled by remember { mutableStateOf(hydrationConfig.enabled) }
    var hydrationInterval by remember { mutableStateOf(hydrationConfig.intervalMinutes) }
    var hydrationStart by remember { mutableStateOf(hydrationConfig.startMinutes) }
    var hydrationEnd by remember { mutableStateOf(hydrationConfig.endMinutes) }
    var hydrationAdaptive by remember { mutableStateOf(hydrationConfig.adaptiveEnabled) }
    var hydrationEffectiveInterval by remember {
        mutableStateOf(hydrationConfig.effectiveIntervalMinutes)
    }
    var hydrationStrapBuzz by remember { mutableStateOf(hydrationConfig.strapBuzzEnabled) }
    var hydrationTapConfirm by remember { mutableStateOf(hydrationConfig.tapConfirmEnabled) }
    var hydrationTapAmountMl by remember { mutableStateOf(hydrationConfig.tapAmountMl) }
    var hydrationTapWindow by remember { mutableStateOf(hydrationConfig.tapWindowMinutes) }
    var hydrationBandFirst by remember { mutableStateOf(hydrationConfig.bandFirst) }
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        hydrationRemindersEnabled = granted
        HydrationReminderPrefs.setEnabled(ctx, granted)
        HydrationReminderScheduler.reconcile(ctx)
    }
    val stressNotificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val available = granted && StressBreathingNotifier.prepareAndCanNotify(ctx)
        stressNotificationsUnavailable = !available
        BiofeedbackPrefs.setPhoneNudge(ctx, available)
        stressPhoneNudge = BiofeedbackPrefs.phoneNudge(ctx)
    }
    val dailyReviewPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        dailyReviewEnabled = granted && DailyReviewReminders.setEnabled(ctx, true)
        dailyReviewNotificationsUnavailable = !dailyReviewEnabled
    }
    val workoutPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        workoutNotificationsUnavailable =
            !granted || !WorkoutCautionNotifier.prepareAndCanNotify(ctx)
    }
    fun applyReportPreference(kind: AutomationReportKind, allowed: Boolean) {
        if (allowed) reportNotificationsUnavailable = false
        when (kind) {
            AutomationReportKind.MORNING -> {
                morningRecapEnabled = allowed
                NoopPrefs.setMorningReportEnabled(ctx, allowed)
                if (!allowed) ScheduledReportNotifier.cancelMorning(ctx)
            }
            AutomationReportKind.WORKOUT -> {
                if (!allowed) {
                    postWorkoutEnablePending = false
                    postWorkoutSummaryEnabled = false
                    viewModel.setPostWorkoutReportEnabled(false)
                } else {
                    postWorkoutEnablePending = true
                    viewModel.setPostWorkoutReportEnabled(true) { enabled ->
                        postWorkoutEnablePending = false
                        postWorkoutSummaryEnabled = enabled
                    }
                }
            }
        }
    }
    val reportPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val kind = pendingReportPermission
        pendingReportPermission = null
        if (kind != null) {
            val allowed = granted && NotificationManagerCompat.from(ctx).areNotificationsEnabled()
            applyReportPreference(kind, allowed)
            reportNotificationsUnavailable = !allowed
        }
    }
    val plannedWorkoutCalendarPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        plannedWorkoutCalendarEnabled = granted
        plannedWorkoutCalendarPermissionUnavailable = !granted
        NoopPrefs.setPlannedWorkoutCalendar(ctx, granted)
        if (granted) {
            viewModel.onPlannedWorkoutCalendarChanged()
        } else {
            PlannedWorkoutCalendarStore.clear()
            viewModel.onPlannedWorkoutCalendarChanged()
        }
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                reportNotificationsUnavailable =
                    !automationReportsCanNotify(ctx) &&
                        (morningRecapEnabled || postWorkoutSummaryEnabled)
                if (plannedWorkoutCalendarEnabled) {
                    val calendarGranted = ContextCompat.checkSelfPermission(
                        ctx,
                        Manifest.permission.READ_CALENDAR,
                    ) == PackageManager.PERMISSION_GRANTED
                    if (calendarGranted) {
                        plannedWorkoutCalendarPermissionUnavailable = false
                        viewModel.onPlannedWorkoutCalendarChanged()
                    } else {
                        plannedWorkoutCalendarEnabled = false
                        plannedWorkoutCalendarPermissionUnavailable = true
                        NoopPrefs.setPlannedWorkoutCalendar(ctx, false)
                        PlannedWorkoutCalendarStore.clear()
                        viewModel.onPlannedWorkoutCalendarChanged()
                    }
                }
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var pendingContextualPermission by remember { mutableStateOf<String?>(null) }
    val contextualPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            when (pendingContextualPermission) {
                "vitals" -> viewModel.setContextualVitalReviewEnabled(true)
                "vo2" -> viewModel.setContextualVo2ReviewEnabled(true)
                "adaptive" -> {
                    val available = AdaptiveDayNotifier.prepareAndCanNotify(ctx)
                    adaptiveNotificationsUnavailable = !available
                    viewModel.setAdaptiveDayGuidanceEnabled(available)
                }
            }
        } else if (pendingContextualPermission == "adaptive") {
            adaptiveNotificationsUnavailable = true
            viewModel.setAdaptiveDayGuidanceEnabled(false)
        }
        pendingContextualPermission = null
    }

    fun setContextualReview(target: String, enabled: Boolean) {
        if (!enabled) {
            if (target == "vitals") viewModel.setContextualVitalReviewEnabled(false)
            else if (target == "vo2") viewModel.setContextualVo2ReviewEnabled(false)
            else {
                adaptiveNotificationsUnavailable = false
                viewModel.setAdaptiveDayGuidanceEnabled(false)
            }
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingContextualPermission = target
            contextualPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        if (target == "vitals") viewModel.setContextualVitalReviewEnabled(true)
        else if (target == "vo2") viewModel.setContextualVo2ReviewEnabled(true)
        else {
            val available = AdaptiveDayNotifier.prepareAndCanNotify(ctx)
            adaptiveNotificationsUnavailable = !available
            viewModel.setAdaptiveDayGuidanceEnabled(available)
        }
    }

    fun setPlannedWorkoutCalendarEnabled(enabled: Boolean) {
        if (!enabled) {
            plannedWorkoutCalendarEnabled = false
            plannedWorkoutCalendarPermissionUnavailable = false
            NoopPrefs.setPlannedWorkoutCalendar(ctx, false)
            PlannedWorkoutCalendarStore.clear()
            viewModel.onPlannedWorkoutCalendarChanged()
            return
        }
        if (
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.READ_CALENDAR) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            plannedWorkoutCalendarPermissionLauncher.launch(Manifest.permission.READ_CALENDAR)
            return
        }
        plannedWorkoutCalendarEnabled = true
        plannedWorkoutCalendarPermissionUnavailable = false
        NoopPrefs.setPlannedWorkoutCalendar(ctx, true)
        viewModel.onPlannedWorkoutCalendarChanged()
    }

    fun setWorkoutGuidanceEnabled(enabled: Boolean) {
        viewModel.setZoneCoaching(enabled)
        if (!enabled) {
            workoutNotificationsUnavailable = false
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            workoutPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        workoutNotificationsUnavailable = !WorkoutCautionNotifier.prepareAndCanNotify(ctx)
    }

    fun setHydrationReminderEnabled(enabled: Boolean) {
        if (!enabled) {
            hydrationRemindersEnabled = false
            HydrationReminderPrefs.setEnabled(ctx, false)
            HydrationReminderScheduler.reconcile(ctx)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        hydrationRemindersEnabled = true
        HydrationReminderPrefs.setEnabled(ctx, true)
        HydrationReminderScheduler.reconcile(ctx)
    }

    fun setDailyReviewEnabled(enabled: Boolean) {
        if (!enabled) {
            dailyReviewEnabled = false
            dailyReviewNotificationsUnavailable = false
            DailyReviewReminders.setEnabled(ctx, false)
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            dailyReviewPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        dailyReviewEnabled = DailyReviewReminders.setEnabled(ctx, true)
        dailyReviewNotificationsUnavailable = !dailyReviewEnabled
    }

    fun setReportPreference(kind: AutomationReportKind, enabled: Boolean) {
        if (!enabled) {
            applyReportPreference(kind, false)
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingReportPermission = kind
            reportPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        val allowed = automationReportsCanNotify(ctx)
        applyReportPreference(kind, allowed)
        reportNotificationsUnavailable = !allowed
    }

    fun setStressCheckInEnabled(enabled: Boolean) {
        BiofeedbackPrefs.setCheckInEnabled(ctx, enabled)
        stressCheckIn = BiofeedbackPrefs.checkInEnabled(ctx)
        if (stressCheckIn) {
            stressAutoNudge = BiofeedbackPrefs.autoNudge(ctx)
            stressPhoneNudge = BiofeedbackPrefs.phoneNudge(ctx)
        }
    }

    fun setStressAutoNudgeEnabled(enabled: Boolean) {
        BiofeedbackPrefs.setAutoNudge(ctx, enabled)
        stressAutoNudge = BiofeedbackPrefs.autoNudge(ctx)
        if (stressAutoNudge) {
            stressPhoneNudge = BiofeedbackPrefs.phoneNudge(ctx)
        }
    }

    fun setStressPhoneNudgeEnabled(enabled: Boolean) {
        if (!enabled) {
            stressPhoneNudge = false
            stressNotificationsUnavailable = false
            BiofeedbackPrefs.setPhoneNudge(ctx, false)
            return
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            stressNotificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        if (!StressBreathingNotifier.prepareAndCanNotify(ctx)) {
            stressPhoneNudge = false
            stressNotificationsUnavailable = true
            BiofeedbackPrefs.setPhoneNudge(ctx, false)
            return
        }
        stressNotificationsUnavailable = false
        BiofeedbackPrefs.setPhoneNudge(ctx, true)
        stressPhoneNudge = BiofeedbackPrefs.phoneNudge(ctx)
    }

    // PERF (#707): lazy scaffold — each settings section is an unconditional top-level child, so each
    // becomes one `item { }` in the same order. No standalone Spacers (the eager `spacedBy(20.dp)` is
    // reproduced by the LazyColumn), so spacing is byte-identical; only on-screen sections compose + get
    // accessibility-walked on scroll.
    LazyScreenScaffold(
        title = uiString(R.string.l10n_automations_screen_automations_82542d6d),
        subtitle = "Make Noop Band work for you: tap to act, walk away to lock, and train by feel.",
    ) {
        // Double-tap (parity since 4.2.8): a real, persisted action picker bound to the ViewModel, with a
        // Test action button. Mirrors AutomationsView.swift's Picker (Apple-applicable subset only; no
        // lockScreen / runShortcut on Android).
        item {
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = uiString(R.string.l10n_automations_screen_double_tap_8d2f1646),
            blurb = "Double-tap Noop Band to trigger an action on this device. The band exposes one double-tap gesture.",
            active = doubleTapAction != DoubleTapAction.NONE,
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(uiString(R.string.l10n_automations_screen_when_i_double_tap_a1f1e04d), style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                DoubleTapActionPicker(
                    selected = doubleTapAction,
                    onSelect = { viewModel.setDoubleTapAction(it) },
                )
            }
            RowDivider()
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(
                    onClick = { viewModel.testDoubleTapAction() },
                    enabled = doubleTapAction != DoubleTapAction.NONE,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(uiString(R.string.l10n_automations_screen_test_action_266df314), style = NoopType.body)
                }
                Spacer(Modifier.weight(1f))
                StatePill(
                    if (live.bonded) "Noop Band paired" else "Not connected",
                    tone = if (live.bonded) StrandTone.Positive else StrandTone.Warning,
                )
            }
            RowDivider()
            Overline(stringResource(R.string.appwide_automations_tap_guide_title))
            TapGuideRow(
                stringResource(R.string.appwide_automations_tap_guide_alarm_title),
                stringResource(R.string.appwide_automations_tap_guide_alarm_body),
            )
            TapGuideRow(
                stringResource(R.string.appwide_automations_tap_guide_hydration_title),
                stringResource(R.string.appwide_automations_tap_guide_hydration_body),
            )
            TapGuideRow(
                stringResource(R.string.appwide_automations_tap_guide_sos_title),
                stringResource(R.string.appwide_automations_tap_guide_sos_body),
            )
            TapGuideRow(
                stringResource(R.string.appwide_automations_tap_guide_otherwise_title),
                stringResource(R.string.appwide_automations_tap_guide_otherwise_body),
            )
        }
        }

        // Adaptive coaching.
        item {
        SettingsSection(
            icon = Icons.Filled.Bolt,
            title = stringResource(R.string.appwide_adaptive_coaching_title),
            blurb = stringResource(R.string.appwide_adaptive_coaching_summary),
            active = adaptiveDayGuidance || zoneCoaching || (stressCheckIn && stressAutoNudge),
        ) {
            ToggleRow(
                label = stringResource(R.string.appwide_adaptive_day_guidance_label),
                help = stringResource(R.string.appwide_adaptive_day_guidance_help),
                checked = adaptiveDayGuidance,
                onChange = { setContextualReview("adaptive", it) },
            )
            if (adaptiveDayGuidance) {
                RowDivider()
                ToggleRow(
                    label = stringResource(
                        R.string.appwide_adaptive_day_guidance_calendar_label,
                    ),
                    help = stringResource(
                        R.string.appwide_adaptive_day_guidance_calendar_help,
                    ),
                    checked = plannedWorkoutCalendarEnabled,
                    onChange = ::setPlannedWorkoutCalendarEnabled,
                )
                if (plannedWorkoutCalendarPermissionUnavailable) {
                    RowDivider()
                    Text(
                        stringResource(
                            R.string
                                .appwide_adaptive_day_guidance_calendar_permission_unavailable,
                        ),
                        style = NoopType.footnote,
                        color = Palette.statusWarning,
                    )
                }
            }
            if (adaptiveNotificationsUnavailable) {
                RowDivider()
                Text(
                    stringResource(
                        R.string.appwide_adaptive_day_guidance_notifications_unavailable,
                    ),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
            RowDivider()
            ToggleRow(
                label = stringResource(R.string.appwide_workout_guidance_label),
                help = stringResource(R.string.appwide_workout_guidance_help),
                checked = zoneCoaching,
                onChange = ::setWorkoutGuidanceEnabled,
            )
            if (zoneCoaching && !notifMasterOn) {
                RowDivider()
                Text(
                    stringResource(R.string.appwide_workout_guidance_wrist_alerts_off),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
            if (zoneCoaching) {
                RowDivider()
                ToggleRow(
                    label = uiString(R.string.l10n_automations_screen_recovery_buzz_1abc9a51),
                    help = stringResource(R.string.appwide_workout_guidance_recovery_help),
                    checked = zoneCoachRecovery,
                    onChange = { viewModel.setZoneCoachRecovery(it) },
                )
            }
            if (workoutNotificationsUnavailable) {
                RowDivider()
                Text(
                    stringResource(R.string.appwide_workout_guidance_phone_unavailable),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
            RowDivider()
            ToggleRow(
                label = stringResource(R.string.appwide_stress_checkin_label),
                help = stringResource(R.string.appwide_stress_checkin_help),
                checked = stressCheckIn,
                onChange = ::setStressCheckInEnabled,
            )
            if (stressCheckIn) {
                RowDivider()
                ToggleRow(
                    label = stringResource(R.string.appwide_stress_checkin_detect_label),
                    help = stringResource(R.string.appwide_stress_checkin_detect_help),
                    checked = stressAutoNudge,
                    onChange = ::setStressAutoNudgeEnabled,
                )
                if (stressAutoNudge) {
                    RowDivider()
                    ToggleRow(
                        label = stringResource(R.string.appwide_stress_checkin_phone_label),
                        help = stringResource(R.string.appwide_stress_checkin_phone_help),
                        checked = stressPhoneNudge,
                        onChange = ::setStressPhoneNudgeEnabled,
                    )
                    RowDivider()
                    ToggleRow(
                        label = stringResource(R.string.appwide_stress_checkin_quiet_label),
                        help = stringResource(R.string.appwide_stress_checkin_quiet_help),
                        checked = stressQuietHours,
                        onChange = {
                            stressQuietHours = it
                            BiofeedbackPrefs.setQuietHoursEnabled(ctx, it)
                        },
                    )
                    if (stressNotificationsUnavailable) {
                        RowDivider()
                        Text(
                            stringResource(R.string.appwide_stress_checkin_notifications_unavailable),
                            style = NoopType.footnote,
                            color = Palette.statusWarning,
                        )
                    }
                    if (!notifMasterOn) {
                        RowDivider()
                        Text(
                            stringResource(R.string.appwide_stress_checkin_wrist_alerts_off),
                            style = NoopType.footnote,
                            color = Palette.statusWarning,
                        )
                    }
                }
            }
            RowDivider()
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    Icons.Filled.Air,
                    contentDescription = null,
                    tint = Palette.restBright,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    stringResource(R.string.appwide_stress_checkin_manual_note),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        }

        // #766: the strap's silent wake-alarm card used to sit here, which let users conflate it with the
        // Wake Window + Wind-Down reminder over on the Alarms screen. It's moved to SmartAlarmScreen so
        // every wake/alarm control lives in one place. Automations is just inputs-to-actions now.

        item {
        SettingsSection(
            icon = Icons.Filled.NotificationsActive,
            title = stringResource(R.string.daily_review_section_title),
            blurb = stringResource(R.string.daily_review_section_body),
            active = (dailyReviewEnabled && !dailyReviewNotificationsUnavailable) ||
                morningRecapEnabled ||
                postWorkoutSummaryEnabled,
        ) {
            ToggleRow(
                label = stringResource(R.string.daily_review_toggle),
                help = stringResource(R.string.daily_review_toggle_help),
                checked = dailyReviewEnabled,
                onChange = ::setDailyReviewEnabled,
            )
            if (dailyReviewEnabled) {
                RowDivider()
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(R.string.daily_review_morning_time),
                        style = NoopType.body,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    TimeChip(
                        minutes = dailyReviewMorning,
                        accessibilityLabel = stringResource(R.string.daily_review_morning_time),
                        onPicked = {
                            dailyReviewMorning = it
                            DailyReviewReminders.setMorningMinutes(ctx, it)
                        },
                    )
                }
                RowDivider()
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        stringResource(R.string.daily_review_evening_time),
                        style = NoopType.body,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    TimeChip(
                        minutes = dailyReviewEvening,
                        accessibilityLabel = stringResource(R.string.daily_review_evening_time),
                        onPicked = {
                            dailyReviewEvening = it
                            DailyReviewReminders.setEveningMinutes(ctx, it)
                        },
                    )
                }
                RowDivider()
                Text(
                    stringResource(R.string.daily_review_privacy_note),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            RowDivider()
            ToggleRow(
                label = uiString(
                    R.string.l10n_notifications_settings_screen_morning_recap_45ec05c5,
                ),
                help = stringResource(R.string.automation_morning_recap_help),
                checked = morningRecapEnabled,
                onChange = {
                    setReportPreference(AutomationReportKind.MORNING, it)
                },
            )
            RowDivider()
            ToggleRow(
                label = uiString(
                    R.string.l10n_notifications_settings_screen_post_workout_summary_13e488f5,
                ),
                help = stringResource(R.string.automation_post_workout_summary_help),
                checked = postWorkoutSummaryEnabled,
                enabled = !postWorkoutEnablePending,
                onChange = {
                    setReportPreference(AutomationReportKind.WORKOUT, it)
                },
            )
            if (dailyReviewNotificationsUnavailable) {
                RowDivider()
                Text(
                    stringResource(R.string.daily_review_notifications_unavailable),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
                OutlinedButton(
                    onClick = {
                        runCatching {
                            ctx.startActivity(
                                android.content.Intent(
                                    android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS,
                                ).putExtra(
                                    android.provider.Settings.EXTRA_APP_PACKAGE,
                                    ctx.packageName,
                                ),
                            )
                        }
                    },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) {
                    Text(
                        stringResource(R.string.daily_review_open_notification_settings),
                        style = NoopType.body,
                    )
                }
            }
            if (reportNotificationsUnavailable) {
                RowDivider()
                Text(
                    stringResource(R.string.appwide_notifications_system_disabled),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
        }
        }

        // Hydration check-ins — opt-in, privacy-safe local notification; optional live WHOOP haptic.
        item {
        SettingsSection(
            icon = Icons.Filled.WaterDrop,
            title = stringResource(R.string.l10n_automations_screen_hydration_reminders_a4e4defb),
            blurb = stringResource(R.string.l10n_automations_screen_a_quiet_check_in_during_hours_9c51ddf5),
            active = hydrationRemindersEnabled,
        ) {
            ToggleRow(
                label = stringResource(R.string.l10n_automations_screen_remind_me_to_hydrate_ddd350c5),
                help = stringResource(R.string.l10n_automations_screen_uses_a_local_android_reminder_it_31de6a42),
                checked = hydrationRemindersEnabled,
                onChange = ::setHydrationReminderEnabled,
            )
            if (hydrationRemindersEnabled) {
                RowDivider()
                ToggleRow(
                    label = stringResource(R.string.hydration_adaptive_timing_label),
                    help = stringResource(R.string.hydration_adaptive_timing_help),
                    checked = hydrationAdaptive,
                    onChange = {
                        hydrationAdaptive = it
                        HydrationReminderPrefs.setAdaptiveEnabled(ctx, it)
                        hydrationEffectiveInterval = hydrationInterval
                        HydrationReminderScheduler.reconcile(ctx)
                    },
                )
                if (hydrationAdaptive) {
                    Text(
                        stringResource(
                            R.string.hydration_adaptive_timing_status,
                            hydrationEffectiveInterval,
                        ),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                RowDivider()
                StepperRow(
                    label = if (hydrationAdaptive) {
                        stringResource(R.string.hydration_base_interval_label)
                    } else {
                        stringResource(R.string.l10n_automations_screen_remind_every_8f5f4f63)
                    },
                    help = stringResource(R.string.l10n_automations_screen_how_often_to_check_in_inside_68e143d2),
                    value = hydrationInterval,
                    suffix = stringResource(R.string.l10n_automations_screen_min_b6c935d4),
                    range = 60..240,
                    step = 30,
                    onChange = {
                        hydrationInterval = it
                        HydrationReminderPrefs.setIntervalMinutes(ctx, it)
                        hydrationEffectiveInterval = it
                        HydrationReminderScheduler.reconcile(ctx)
                    },
                )
                RowDivider()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            stringResource(R.string.l10n_automations_screen_active_hours_7936460b),
                            style = NoopType.body,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.l10n_automations_screen_no_hydration_reminders_outside_this_window_ec3b7dba),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    TimeChip(
                        minutes = hydrationStart,
                        accessibilityLabel = stringResource(R.string.l10n_automations_screen_hydration_reminders_start_6640d85d),
                        onPicked = {
                            hydrationStart = it
                            HydrationReminderPrefs.setStartMinutes(ctx, it)
                            HydrationReminderScheduler.reconcile(ctx)
                        },
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        stringResource(R.string.l10n_automations_screen_to_4374aaee),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                    Spacer(Modifier.width(8.dp))
                    TimeChip(
                        minutes = hydrationEnd,
                        accessibilityLabel = stringResource(R.string.l10n_automations_screen_hydration_reminders_end_1b524ef4),
                        onPicked = {
                            hydrationEnd = it
                            HydrationReminderPrefs.setEndMinutes(ctx, it)
                            HydrationReminderScheduler.reconcile(ctx)
                        },
                    )
                }
                RowDivider()
                ToggleRow(
                    label = "Also buzz Noop Band",
                    help = "Optional and off by default. Buzzes once only when a worn Noop Band is connected, encrypted, and sending a fresh live sample.",
                    checked = hydrationStrapBuzz,
                    onChange = {
                        hydrationStrapBuzz = it
                        HydrationReminderPrefs.setStrapBuzzEnabled(ctx, it)
                        if (!it) {
                            hydrationBandFirst = false
                            HydrationReminderScheduler.reconcile(ctx)
                        }
                    },
                )
                if (hydrationStrapBuzz) {
                    RowDivider()
                    ToggleRow(
                        label = stringResource(R.string.hydration_tap_confirm_label),
                        help = stringResource(R.string.hydration_tap_confirm_help),
                        checked = hydrationTapConfirm,
                        onChange = {
                            hydrationTapConfirm = it
                            HydrationReminderPrefs.setTapConfirmEnabled(ctx, it)
                            if (!it) {
                                hydrationBandFirst = false
                                HydrationReminderPrefs.setBandFirst(ctx, false)
                                HydrationReminderScheduler.reconcile(ctx)
                            }
                        },
                    )
                    if (hydrationTapConfirm) {
                        RowDivider()
                        StepperRow(
                            label = stringResource(R.string.hydration_tap_amount_label),
                            help = stringResource(R.string.hydration_tap_amount_help),
                            value = hydrationTapAmountMl,
                            suffix = "ml",
                            range = 50..1_000,
                            step = 50,
                            onChange = {
                                hydrationTapAmountMl = it
                                HydrationReminderPrefs.setTapAmountMl(ctx, it)
                            },
                        )
                        RowDivider()
                        StepperRow(
                            label = stringResource(R.string.hydration_tap_window_label),
                            help = stringResource(R.string.hydration_tap_window_help),
                            value = hydrationTapWindow,
                            suffix = "min",
                            range = 5..30,
                            step = 5,
                            onChange = {
                                hydrationTapWindow = it
                                HydrationReminderPrefs.setTapWindowMinutes(ctx, it)
                            },
                        )
                        RowDivider()
                        ToggleRow(
                            label = stringResource(R.string.hydration_tap_band_first_label),
                            help = stringResource(R.string.hydration_tap_band_first_help),
                            checked = hydrationBandFirst,
                            onChange = {
                                hydrationBandFirst = it
                                HydrationReminderPrefs.setBandFirst(ctx, it)
                                HydrationReminderScheduler.reconcile(ctx)
                            },
                        )
                    }
                }
                if (hydrationStrapBuzz && !notifMasterOn) {
                    RowDivider()
                    Text(
                        "Wrist alerts are off. Turn on the master switch in Settings, Notifications before Noop Band can buzz.",
                        style = NoopType.footnote,
                        color = Palette.statusWarning,
                    )
                }
                if (hydrationStrapBuzz) {
                    RowDivider()
                    Text(
                        if (live.connected && live.bonded && live.encryptedBond) {
                            "Noop Band is ready. A buzz still needs a fresh live stream at the reminder time."
                        } else {
                            "Noop Band haptics are unavailable until it has a live encrypted bond. The phone reminder remains independent."
                        },
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
        }
        }

        // Inactivity reminder (#419) — real + persisted via InactivityPrefs; opt-in, default OFF.
        item {
        SettingsSection(
            icon = Icons.Filled.Timer,
            title = uiString(R.string.l10n_automations_screen_inactivity_reminder_ca49b1ba),
            blurb = "A gentle wrist vibration when you've been sitting too long, a nudge to get up and move. Inferred from Noop Band motion on each history sync, so it can lag real time by a sync or two.",
            active = inactivityEnabled,
        ) {
            ToggleRow(
                label = uiString(R.string.l10n_automations_screen_enable_inactivity_reminder_468c3017),
                help = "Buzzes after you've been sitting past your threshold.",
                checked = inactivityEnabled,
                onChange = {
                    inactivityEnabled = it
                    InactivityPrefs.setBool(ctx, InactivityPrefs.ENABLED, it)
                },
            )
            if (inactivityEnabled) {
                if (!notifMasterOn) {
                    RowDivider()
                    Text(
                        uiString(R.string.l10n_automations_screen_notifications_are_off_so_this_can_b3dba7ee) +
                            "Settings → Notifications to let it through.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                }
                RowDivider()
                StepperRow(
                    label = uiString(R.string.l10n_automations_screen_sitting_for_e464c472),
                    help = "Minutes seated before the first nudge.",
                    value = inactivityThreshold, suffix = "min", range = 15..120, step = 15,
                    onChange = {
                        inactivityThreshold = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.THRESHOLD_MIN, it)
                    },
                )
                RowDivider()
                StepperRow(
                    label = uiString(R.string.l10n_automations_screen_re_nudge_every_646023cd),
                    help = "If you're still seated, buzz again this often.",
                    value = inactivityReNudge, suffix = "min", range = 15..120, step = 15,
                    onChange = {
                        inactivityReNudge = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.RENUDGE_MIN, it)
                    },
                )
                RowDivider()
                StepperRow(
                    label = uiString(R.string.l10n_automations_screen_buzz_strength_e895f99e),
                    help = "How strong the buzz is.",
                    value = inactivityBuzzLoops, suffix = "×", range = 1..4, step = 1,
                    onChange = {
                        inactivityBuzzLoops = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.BUZZ_LOOPS, it)
                    },
                )
                RowDivider()
                ToggleRow(
                    label = uiString(R.string.l10n_automations_screen_only_during_active_hours_29c53fc9),
                    help = "Only nudge during your active hours.",
                    checked = inactivityActiveHours,
                    onChange = {
                        inactivityActiveHours = it
                        InactivityPrefs.setBool(ctx, InactivityPrefs.ACTIVE_HOURS_ENABLED, it)
                    },
                )
                if (inactivityActiveHours) {
                    RowDivider()
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(uiString(R.string.l10n_automations_screen_from_3f66052a), style = NoopType.body, color = Palette.textPrimary)
                        Spacer(Modifier.weight(1f))
                        TimeChip(
                            minutes = inactivityActiveStart,
                            accessibilityLabel = "Active hours start",
                            onPicked = {
                                inactivityActiveStart = it
                                InactivityPrefs.setInt(ctx, InactivityPrefs.ACTIVE_START_MIN, it)
                            },
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("to", style = NoopType.body, color = Palette.textSecondary)
                        Spacer(Modifier.width(8.dp))
                        TimeChip(
                            minutes = inactivityActiveEnd,
                            accessibilityLabel = "Active hours end",
                            onPicked = {
                                inactivityActiveEnd = it
                                InactivityPrefs.setInt(ctx, InactivityPrefs.ACTIVE_END_MIN, it)
                            },
                        )
                    }
                }
            }
        }
        }

        // On-device short-nap detection (PR #569 reimpl) — opt-in, default OFF. Detected on the offload
        // hook; a confident nap is offered as a review card you accept (it becomes a nap session) or
        // dismiss. NEVER auto-written.
        item { NapDetectionSection(viewModel) }

        // Multi-signal wellness check-in (real + persisted; opt-OUT on Android).
        item {
        SettingsSection(
            icon = Icons.Filled.MonitorHeart,
            title = uiString(R.string.l10n_automations_screen_illness_early_warning_453ab477),
            blurb = "Watches resting HR, HRV, skin temperature and respiration against your own baseline. Many factors can move these signals; this is a wellness check-in, not a diagnosis.",
            active = illnessWatch,
        ) {
            ToggleRow(
                label = uiString(R.string.l10n_automations_screen_watch_for_early_illness_signs_4c22e127),
                help = "Needs at least 14 days of history. When two or more signals move together, NOOP shows a private in-app check-in and a detail-free notification at most once a day.",
                checked = illnessWatch,
                onChange = { viewModel.setIllnessWatchEnabled(it) },
            )
        }
        }

        item {
        SettingsSection(
            icon = Icons.Filled.NotificationsActive,
            title = "Vital trend reviews",
            blurb = "Optional private prompts for meaningful changes in fresh wearable or Health " +
                "Connect data. These are review cues, never a diagnosis, all-clear, severity score, " +
                "or emergency alert.",
            active = contextualVitalReview || contextualVo2Review,
        ) {
            ToggleRow(
                label = "Oxygen and body temperature",
                help = "Blood oxygen needs two distinct fresh low days. Explicit body temperature " +
                    "only prompts a thermometer recheck; wrist skin temperature is never substituted.",
                checked = contextualVitalReview,
                onChange = { setContextualReview("vitals", it) },
            )
            RowDivider()
            ToggleRow(
                label = "Longer-term VO2 max changes",
                help = "Requires two persistent recent changes against a comparison at least three " +
                    "weeks older. One shifted estimate never sends a prompt.",
                checked = contextualVo2Review,
                onChange = { setContextualReview("vo2", it) },
            )
        }
        }

        // Battery alerts (real + persisted; opt-OUT, default ON — #368, thanks @ujix).
        item {
        SettingsSection(
            icon = Icons.Filled.BatteryStd,
            title = uiString(R.string.l10n_automations_screen_battery_alerts_f3679d60),
            blurb = "A heads-up when Noop Band battery gets low so you can recharge before bed, and a note when it is fully charged.",
            active = batteryAlerts,
        ) {
            ToggleRow(
                label = uiString(R.string.l10n_automations_screen_notify_on_low_and_full_battery_d1903bb8),
                help = "Sends a notification when Noop Band drops to 15% or reaches a full charge, at most once per charge cycle.",
                checked = batteryAlerts,
                onChange = { viewModel.setBatteryAlertsEnabled(it) },
            )
            if (batteryAlerts) {
                ToggleRow(
                    label = uiString(R.string.l10n_automations_screen_predictive_runtime_warning_4d85f5a6),
                    help = "An early \"recharge tonight\" heads-up when Noop Band has about a day of estimated runtime left, at most once per discharge cycle. Turn off to keep only the 15% warning.",
                    checked = predictiveBatteryAlerts,
                    onChange = { viewModel.setPredictiveBatteryAlertsEnabled(it) },
                )
            }
        }
        }
    }
}

@Composable
private fun TapGuideRow(context: String, action: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.TouchApp,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier.size(16.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(context, style = NoopType.footnote, color = Palette.textPrimary)
            Text(action, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

// MARK: - On-device nap detection (PR #569 reimpl under NoopApp)

/**
 * The nap-detection automation: a toggle plus the REVIEW queue. Detection runs on the offload hook
 * (WhoopBleClient.maybeDetectNaps → the pure NapDetector); a confident NAP is queued in NapStore and shown
 * here as a card the user ACCEPTS (→ a manual nap session, the #508 path) or DISMISSES. The engine never
 * auto-writes a session, and an INCONCLUSIVE window queues nothing — honest by construction.
 */
@Composable
private fun NapDetectionSection(viewModel: AppViewModel) {
    val scope = rememberCoroutineScope()
    val enabled by viewModel.napDetectionEnabled.collectAsStateWithLifecycle()
    // The queue isn't a reactive flow (it's written from the BLE layer); re-read it on each toggle/action.
    var pending by remember { mutableStateOf(viewModel.pendingNaps()) }

    SettingsSection(
        icon = Icons.Filled.Bedtime,
        title = uiString(R.string.l10n_automations_screen_nap_detection_ca2dedf5),
        blurb = "Spots a likely daytime nap from Noop Band motion and heart rate on each history sync, " +
            "then asks you to confirm it. Inferred and approximate: NOOP never adds a nap to your sleep " +
            "without your OK.",
        active = enabled,
    ) {
        ToggleRow(
            label = uiString(R.string.l10n_automations_screen_detect_short_naps_bbfd136d),
            help = "When a sync shows a quiet, settled stretch in the day, NOOP offers it here for you to keep or skip.",
            checked = enabled,
            onChange = {
                viewModel.setNapDetectionEnabled(it)
                if (it) pending = viewModel.pendingNaps()
            },
        )
        if (enabled) {
            if (pending.isEmpty()) {
                RowDivider()
                Text(
                    uiString(R.string.l10n_automations_screen_no_naps_to_review_detected_naps_2e82e9fc),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            } else {
                pending.forEach { nap ->
                    RowDivider()
                    NapReviewRow(
                        nap = nap,
                        onAccept = { scope.launch { pending = viewModel.acceptDetectedNap(nap) } },
                        onDismiss = { pending = viewModel.dismissDetectedNap(nap) },
                    )
                }
            }
        }
    }
}

/** One pending nap candidate: an honest "HH:mm–HH:mm · ~N min" line (+ mean HR when known) with Keep /
 *  Skip controls. Keep persists it as a nap session; Skip forgets it (and won't re-queue the window). */
@Composable
private fun NapReviewRow(nap: NapCandidate, onAccept: () -> Unit, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(napWindowLabel(nap, ctx), style = NoopType.body, color = Palette.textPrimary)
            Text(napDetailLabel(nap), style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(8.dp))
        NapActionButton(Icons.Filled.Check, "Keep this nap", Palette.statusPositive, onAccept)
        Spacer(Modifier.width(8.dp))
        NapActionButton(Icons.Filled.Close, "Skip this nap", Palette.textTertiary, onDismiss)
    }
}

@Composable
private fun NapActionButton(icon: ImageVector, contentDescription: String, tint: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(18.dp))
    }
}

/** "HH:mm–HH:mm · ~N min", local time. Pure-ish (reads the device clock format only). */
private fun napWindowLabel(nap: NapCandidate, ctx: android.content.Context): String {
    val fmt = android.text.format.DateFormat.getTimeFormat(ctx)
    val start = fmt.format(java.util.Date(nap.start * 1000L))
    val end = fmt.format(java.util.Date(nap.end * 1000L))
    val mins = nap.durationS / 60
    return "$start-$end · ~$mins min"
}

private fun napDetailLabel(nap: NapCandidate): String =
    if (nap.meanHr != null) "Quiet and settled, mean HR ~${nap.meanHr} bpm." else "Quiet and settled."

// MARK: - Per-weekday wake-time overrides (PR #554 reimpl under NoopApp)

/**
 * Per-weekday wake-time OVERRIDES for the smart alarm (#554). For each day the alarm fires on, shows the
 * effective wake time (the day's override, else the default) as a [TimeChip]; picking a time sets that
 * day's override, and a "Reset" affordance clears it back to the default. Days the alarm doesn't fire on
 * aren't shown (no point overriding a day it won't ring). Empty enabledDays = every day, so all seven show.
 */
// internal (not private) so the consolidated Alarms screen (SmartAlarmScreen, #766) can reuse the
// exact same picker. The strap wake-alarm card moved there but its weekday/override UI is unchanged.
@Composable
internal fun AlarmDayOverridePicker(
    defaultMinutes: Int,
    enabledDays: Set<Int>,
    overrides: Map<Int, Int>,
    onSetOverride: (Int, Int?) -> Unit,
) {
    val fireDays = SMART_ALARM_WEEKDAY_ORDER.filter { smartAlarmWeekdayIsSelected(it, enabledDays) }
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(uiString(R.string.l10n_automations_screen_per_day_wake_time_873c81e1), style = NoopType.caption, color = Palette.textTertiary)
        fireDays.forEach { dow ->
            val effective = overrides[dow] ?: defaultMinutes
            val hasOverride = overrides.containsKey(dow)
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(smartAlarmWeekdayName(dow), style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                if (hasOverride) {
                    Text(
                        uiString(R.string.l10n_automations_screen_reset_44c57abd),
                        style = NoopType.caption,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(CircleShape)
                            .clickable { onSetOverride(dow, null) }
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                }
                TimeChip(
                    minutes = effective,
                    accessibilityLabel = "${smartAlarmWeekdayName(dow)} wake time",
                    onPicked = { onSetOverride(dow, it) },
                )
            }
        }
        Text(
            uiString(R.string.l10n_automations_screen_each_day_uses_the_time_above_f9bc9ce3),
            style = NoopType.footnote, color = Palette.textTertiary,
        )
    }
}

// MARK: - Section + rows (mirror the settings idiom from AutomationsView.swift)

@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    active: Boolean = false,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Automation")
                    if (active) Overline("ON", color = Palette.accent)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = if (active) Palette.accent else Palette.textSecondary,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

/** A compact dropdown that mirrors the iOS double-tap Picker: a tappable label + chevron that opens a
 *  menu of [DoubleTapAction]s. Labels come from [DoubleTapAction.label] so both clients read the same. */
@Composable
private fun DoubleTapActionPicker(
    selected: DoubleTapAction,
    onSelect: (DoubleTapAction) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .clickable { expanded = true }
                .background(Palette.surfaceInset)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(selected.label, style = NoopType.body, color = Palette.textPrimary)
            Spacer(Modifier.width(4.dp))
            Icon(
                Icons.Filled.ArrowDropDown,
                contentDescription = uiString(R.string.l10n_automations_screen_choose_double_tap_action_6ac9a313),
                tint = Palette.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (action in DoubleTapAction.entries) {
                DropdownMenuItem(
                    text = {
                        Text(
                            action.label,
                            style = NoopType.body,
                            color = if (action == selected) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = { onSelect(action); expanded = false },
                )
            }
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    help: String,
    checked: Boolean,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        NoopToggleSwitch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
        )
    }
}

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(vertical = 4.dp)
            .background(Palette.hairline),
    )
}

/**
 * Weekday selector for the smart alarm (#539). One tappable circle per weekday, Monday-first. An empty
 * [selected] set means "every day" (all circles read as on). Mirrors the macOS AutomationsView picker.
 */
// internal (not private) so SmartAlarmScreen (the consolidated Alarms surface, #766) can reuse it.
@Composable
internal fun AlarmWeekdayPicker(selected: Set<Int>, onToggle: (Int) -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (dow in SMART_ALARM_WEEKDAY_ORDER) {
                val on = smartAlarmWeekdayIsSelected(dow, selected)
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(if (on) Palette.accent else Palette.surfaceInset)
                        .clickable { onToggle(dow) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        smartAlarmWeekdayInitial(dow),
                        style = NoopType.caption,
                        color = if (on) Palette.surfaceBase else Palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        Text(smartAlarmWeekdaySummary(selected), style = NoopType.caption, color = Palette.textTertiary)
    }
}

/** Calendar.DAY_OF_WEEK numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1). */
private val SMART_ALARM_WEEKDAY_ORDER = intArrayOf(2, 3, 4, 5, 6, 7, 1)

/** A day reads as "on" when the set is empty (= every day) or explicitly contains it. Pure for tests. */
internal fun smartAlarmWeekdayIsSelected(dow: Int, days: Set<Int>): Boolean =
    days.isEmpty() || days.contains(dow)

/**
 * Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
 * Pure + side-effect-free for unit tests. Pulling a day out of the implicit "every day" expands to the
 * explicit other six; selecting the seventh collapses back to the empty "every day" set. Mirrors macOS
 * `AutomationsView.toggledWeekday`.
 */
internal fun toggledSmartAlarmWeekday(dow: Int, days: Set<Int>): Set<Int> {
    val next: MutableSet<Int> = when {
        days.isEmpty() -> (1..7).toMutableSet().also { it.remove(dow) }
        days.contains(dow) -> days.toMutableSet().also { it.remove(dow) }
        else -> days.toMutableSet().also { it.add(dow) }
    }
    return if (next.size == 7) emptySet() else next
}

/** Human-readable summary of the selection. Pure for tests. Mirrors macOS `weekdaySummary`. */
internal fun smartAlarmWeekdaySummary(days: Set<Int>): String = when {
    days.isEmpty() || days.size == 7 -> "Every day"
    days == setOf(2, 3, 4, 5, 6) -> "Weekdays"
    days == setOf(1, 7) -> "Weekends"
    else -> SMART_ALARM_WEEKDAY_ORDER.filter { days.contains(it) }
        .joinToString(", ") { smartAlarmWeekdayName(it) }
}

private fun smartAlarmWeekdayInitial(dow: Int): String = when (dow) {
    1 -> "S"; 2 -> "M"; 3 -> "T"; 4 -> "W"; 5 -> "T"; 6 -> "F"; 7 -> "S"; else -> "?"
}

private fun smartAlarmWeekdayName(dow: Int): String = when (dow) {
    1 -> "Sun"; 2 -> "Mon"; 3 -> "Tue"; 4 -> "Wed"; 5 -> "Thu"; 6 -> "Fri"; 7 -> "Sat"; else -> "?"
}

/** A label/help row with a −[value]+ stepper, clamped to [range] and moved by [step]. */
@Composable
private fun StepperRow(
    label: String,
    help: String,
    value: Int,
    suffix: String,
    range: IntRange,
    step: Int,
    onChange: (Int) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(12.dp))
        StepButton(Icons.Filled.Remove, "Decrease $label", enabled = value > range.first) {
            onChange((value - step).coerceAtLeast(range.first))
        }
        Text(
            uiString(R.string.l10n_automations_screen_value_suffix_26985180, value, suffix),
            style = NoopType.body,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 8.dp).widthIn(min = 56.dp),
        )
        StepButton(Icons.Filled.Add, "Increase $label", enabled = value < range.last) {
            onChange((value + step).coerceAtMost(range.last))
        }
    }
}

@Composable
private fun StepButton(icon: ImageVector, contentDescription: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = if (enabled) Palette.accent else Palette.textTertiary,
        )
    }
}
