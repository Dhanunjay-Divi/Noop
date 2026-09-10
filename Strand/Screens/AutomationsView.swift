import SwiftUI
import StrandDesign
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live biometrics
/// into actions (Shortcuts, and Mac-only screen lock) and haptic coaching. All on-device.
struct AutomationsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    #endif
    @Environment(\.openURL) private var openURL
    // PERF: this screen does NOT observe `LiveState`. Its only live-dependent pixel is the "Strap
    // bonded / not connected" pill inside the double-tap card, which is now the `BondStatePill` leaf
    // that owns its own `@EnvironmentObject live`. Observing `live` at this level would re-render the
    // whole 8-9 card automations column on every ~1 Hz strap tick (bond state changes only rarely);
    // scoping it means a tick re-renders just the one pill.
    /// Deep-link into the experimental Rhythm visualization (it self-gates on its own consent).
    @EnvironmentObject var router: NavRouter
    @Environment(\.scenePhase) private var scenePhase

    /// v5 cycle-awareness opt-in (default OFF — the most sensitive health category, manual-first).
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleAwareness = false

    /// Whether the cycle-awareness opt-in is offered for this profile (#801). Delegates to the shared
    /// ``ProfileStore/cycleAwarenessApplies`` gate (mirrors HealthView's opt-in gate) so a male profile
    /// can't enable the feature here when it can't see the Health card either.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies }
    /// v5 Rhythm experimental gate (the screen still shows its own consent clickwrap when opened).
    @AppStorage(RhythmConsent.enabledKey) private var rhythmEnabled = false
    /// Daily phone reminders are separate from wrist alerts and default OFF. State is mirrored only
    /// after the authorization outcome so a denied system permission never leaves an inert ON switch.
    @State private var dailyReviewEnabled = DailyReviewNotifications.isEnabled
    @State private var morningRecapEnabled = MorningRecapNotifications.isEnabled
    @AppStorage(DailyReviewNotifications.morningMinutesKey) private var morningReviewMinutes = 8 * 60
    @AppStorage(DailyReviewNotifications.eveningMinutesKey) private var eveningReviewMinutes = 19 * 60
    /// A separate post-sync report opt-in. It shares notification permission with the scheduled review
    /// reminders but has its own preference and workout frontier.
    @State private var postWorkoutSummaryEnabled = PostWorkoutSummaryNotifications.isEnabled
    /// Hydration reminders are independent from manual water logging. Both remain opt-in, and changing
    /// this schedule never rewrites an existing hydration total or the dashboard-card preference.
    @State private var hydrationReminderEnabled = HydrationReminders.isEnabled
    @AppStorage(HydrationReminders.intervalMinutesKey) private var hydrationIntervalMinutes = 120
    @AppStorage(HydrationReminders.activeStartMinutesKey) private var hydrationStartMinutes = 8 * 60
    @AppStorage(HydrationReminders.activeEndMinutesKey) private var hydrationEndMinutes = 21 * 60
    @AppStorage(HydrationReminders.strapBuzzEnabledKey) private var hydrationStrapBuzzEnabled = false
    @AppStorage(HydrationReminders.adaptiveEnabledKey) private var hydrationAdaptiveEnabled = true
    @AppStorage(HydrationReminders.doubleTapConfirmEnabledKey) private var hydrationTapConfirm = false
    @AppStorage(HydrationReminders.doubleTapAmountMLKey) private var hydrationTapAmountML = 250
    @AppStorage(HydrationReminders.doubleTapWindowMinutesKey) private var hydrationTapWindowMinutes = 10
    @AppStorage(HydrationReminders.bandFirstEnabledKey) private var hydrationBandFirstEnabled = false
    @AppStorage(ContextualInterventionSettings.vitalReviewEnabledKey)
    private var contextualVitalReviews = false
    @AppStorage(ContextualInterventionSettings.vo2ReviewEnabledKey)
    private var contextualVO2Reviews = false
    @AppStorage(ContextualInterventionSettings.adaptiveDayGuidanceEnabledKey)
    private var adaptiveDayGuidance = false
    #if os(iOS)
    @AppStorage(PlannedWorkoutCalendarSettings.enabledKey)
    private var plannedWorkoutCalendarEnabled = false
    @State private var plannedWorkoutCalendarPermissionUnavailable = false
    #endif
    @State private var notificationPermissionDenied = false
    @State private var notificationsAuthorized = false
    @State private var showNotificationPermissionAlert = false
    /// Operational connection alert: default ON, but never requests notification authorization itself.
    @AppStorage(BluetoothAvailabilityNotifications.enabledKey)
    private var bluetoothAvailabilityAlerts = BluetoothAvailabilityNotifications.isEnabled
    /// Inactivity reminder (#419) — UI-local store, persisted in UserDefaults. The buzz itself fires
    /// from the BLE offload path (BLEManager.maybeBuzzInactivity → the shipped SedentaryDetector); this
    /// screen only edits the prefs the engine reads.
    @StateObject private var inactivity = InactivityPrefs()
    #if os(iOS)
    /// Wrist-alerts master gate (PR #572). On iOS the NotificationSettingsView (and its store) are
    /// excluded by project.yml, so `notif.masterEnabled` — the key SedentaryDetector + the wrist-buzz
    /// posting read — has no UI to flip and is stuck at its default OFF. Bind the SAME raw key here so
    /// iPhone users can actually turn wrist alerts on. Default OFF, matching the store's default.
    @AppStorage("notif.masterEnabled") private var wristAlertsMaster = false
    #endif

    var body: some View {
        ScreenScaffold(title: "Automations",
                       subtitle: "Make Noop Band work for you: tap to act, walk away to lock, and train by feel.",
                       // PERF: the cards are direct children of the scaffold column, so the LazyVStack
                       // path (byte-identical layout) genuinely builds the off-screen cards on demand
                       // instead of constructing all eight/nine + their toggle subtrees up-front.
                       lazy: true) {
            dailyReviewCard
            hydrationReminderCard
            connectionHealthCard
            #if os(iOS)
            wristAlertsCard
            #endif
            doubleTapCard
            wearCard
            coachingCard
            // #766: the strap's silent wake-alarm card used to sit here, which let users conflate it with
            // the wind-down reminder. It's moved to the dedicated Alarms screen (SmartAlarmView) so every
            // wake/wind-down control lives in one place. Automations is just inputs-to-actions now.
            inactivityCard
            illnessCard
            contextualReviewCard
            healthInsightsCard
            batteryCard
            strainTargetCard
        }
        .onAppear {
            dailyReviewEnabled = DailyReviewNotifications.isEnabled
            morningRecapEnabled = MorningRecapNotifications.isEnabled
            postWorkoutSummaryEnabled = PostWorkoutSummaryNotifications.isEnabled
            hydrationReminderEnabled = HydrationReminders.isEnabled
            refreshNotificationPermissionState()
            #if os(iOS)
            refreshPlannedWorkoutCalendarState()
            #endif
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            refreshNotificationPermissionState()
            #if os(iOS)
            refreshPlannedWorkoutCalendarState()
            #endif
        }
        .alert("Notifications are off", isPresented: $showNotificationPermissionAlert) {
            Button("Open Settings") { openNotificationSettings() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Allow notifications in Settings to use optional review and water reminders. NOOP still works normally without them.")
        }
    }

    // MARK: - Connection health

    private var connectionHealthCard: some View {
        Section2(
            icon: "antenna.radiowaves.left.and.right.slash",
            title: String(localized: "Connection health"),
            blurb: String(localized: "A single useful heads-up when Bluetooth is turned off and an already-paired wearable can no longer sync."),
            active: bluetoothAvailabilityAlerts && notificationsAuthorized
        ) {
            VStack(spacing: 0) {
                ToggleRow(
                    label: String(localized: "Bluetooth-off alert"),
                    help: String(localized: "On by default. It never asks for notification access, never alerts during first launch, and clears itself when Bluetooth returns."),
                    isOn: bluetoothAvailabilityToggle
                )
                rowDivider
                Text(notificationsAuthorized
                     ? "One notification per outage, only after NOOP has seen Bluetooth working with a paired wearable. No repeated connection warnings."
                     : "This alert uses notification access you already granted to NOOP. Enable a reminder below or allow notifications in Settings; this switch never prompts by itself.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(notificationsAuthorized
                                     ? StrandPalette.textTertiary : StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    private var bluetoothAvailabilityToggle: Binding<Bool> {
        Binding(
            get: { bluetoothAvailabilityAlerts },
            set: { enabled in
                bluetoothAvailabilityAlerts = enabled
                BluetoothAvailabilityNotifications.setEnabled(enabled)
                refreshNotificationPermissionState()
            }
        )
    }

    // MARK: - Daily review reminders

    private var dailyReviewCard: some View {
        Section2(
            icon: "sun.horizon.fill",
            title: String(localized: "Daily review"),
            blurb: String(localized: "Optional phone reminders for daily review and newly synced workouts. Post-sync timing depends on when your wearable reaches NOOP."),
            active: dailyReviewEnabled || morningRecapEnabled || postWorkoutSummaryEnabled
        ) {
            VStack(spacing: 0) {
                ToggleRow(
                    label: String(localized: "Morning & evening reminders"),
                    help: String(localized: "Off by default. Turning this on asks for notification access once; declining never blocks NOOP."),
                    isOn: dailyReviewToggle
                )

                if dailyReviewEnabled {
                    rowDivider
                    reviewTimeRow(
                        label: String(localized: "Morning · opens Sleep"),
                        minutes: morningTimeBinding
                    )
                    rowDivider
                    reviewTimeRow(
                        label: String(localized: "Evening · opens Journal"),
                        minutes: eveningTimeBinding
                    )
                    rowDivider
                    Text("Reminder banners never include scores or health values. Morning invites a Sleep and Recovery review; evening invites an Effort comparison and journal check-in.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                rowDivider
                ToggleRow(
                    label: String(localized: "Morning recap after sync"),
                    help: String(localized: "Off by default. Notifies once when a newly synced night has a Recovery or Sleep Score; delayed wearable sync means delayed delivery."),
                    isOn: morningRecapToggle
                )
                if morningRecapEnabled {
                    rowDivider
                    Text("appwide.notifications.recap_privacy")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                rowDivider
                ToggleRow(
                    label: String(localized: "Post-workout summary"),
                    help: String(localized: "Off by default. Notifies once when a newer workout arrives after sync; existing history is never announced when you turn it on."),
                    isOn: postWorkoutSummaryToggle
                )
                if postWorkoutSummaryEnabled {
                    rowDivider
                    Text("The Lock Screen shows only that a summary is ready. Effort, duration and heart-rate details stay inside NOOP.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                #if os(iOS)
                rowDivider
                HStack(alignment: .top, spacing: 12) {
                    Text(backgroundRefreshSummary)
                        .font(StrandFont.footnote)
                        .foregroundStyle(
                            backgroundRefreshNeedsSettings
                                ? StrandPalette.statusWarning
                                : StrandPalette.textTertiary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if backgroundRefreshNeedsSettings {
                        Button("Open Settings") { openNotificationSettings() }
                            .buttonStyle(.bordered)
                            .tint(StrandPalette.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                #endif

                if notificationPermissionDenied {
                    rowDivider
                    HStack(alignment: .center, spacing: 12) {
                        Text("Notifications are disabled in Settings.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                        Spacer()
                        Button("Open Settings") { openNotificationSettings() }
                            .buttonStyle(.bordered)
                            .tint(StrandPalette.accent)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var dailyReviewToggle: Binding<Bool> {
        Binding(
            get: { dailyReviewEnabled },
            set: { on in
                if !on {
                    dailyReviewEnabled = false
                    notificationPermissionDenied = false
                    DailyReviewNotifications.setEnabled(false)
                    return
                }

                // The explanatory row is visible before this call, so the OS prompt happens only at
                // the predictable moment the user explicitly turns the feature on.
                dailyReviewEnabled = true
                DailyReviewNotifications.setEnabled(true) { outcome in
                    switch outcome {
                    case .scheduled:
                        dailyReviewEnabled = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                    case .denied:
                        dailyReviewEnabled = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        dailyReviewEnabled = false
                    }
                }
            }
        )
    }

    private var postWorkoutSummaryToggle: Binding<Bool> {
        Binding(
            get: { postWorkoutSummaryEnabled },
            set: { on in
                postWorkoutSummaryEnabled = on
                model.setPostWorkoutSummaryNotificationsEnabled(on) { outcome in
                    switch outcome {
                    case .enabled:
                        postWorkoutSummaryEnabled = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                    case .denied:
                        postWorkoutSummaryEnabled = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        postWorkoutSummaryEnabled = false
                    }
                }
            }
        )
    }

    private var morningRecapToggle: Binding<Bool> {
        Binding(
            get: { morningRecapEnabled },
            set: { on in
                morningRecapEnabled = on
                MorningRecapNotifications.setEnabled(on) { outcome in
                    switch outcome {
                    case .enabled:
                        morningRecapEnabled = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                    case .denied:
                        morningRecapEnabled = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        morningRecapEnabled = false
                    }
                }
            }
        )
    }

    private var morningTimeBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: morningReviewMinutes) },
            set: { date in
                let minutes = Self.minutes(from: date)
                morningReviewMinutes = minutes
                DailyReviewNotifications.setMorningMinutes(minutes)
            }
        )
    }

    private var eveningTimeBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: eveningReviewMinutes) },
            set: { date in
                let minutes = Self.minutes(from: date)
                eveningReviewMinutes = minutes
                DailyReviewNotifications.setEveningMinutes(minutes)
            }
        )
    }

    private func reviewTimeRow(label: String, minutes: Binding<Date>) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            DatePicker("", selection: minutes, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42)
        .padding(.vertical, 4)
    }

    #if os(iOS)
    private var backgroundRefreshSummary: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .denied:
            return String(localized: "Background App Refresh is off. Turn it on for best-effort maintenance, and avoid force-quitting NOOP if you want iOS to deliver Bluetooth and Apple Health background events. Opening NOOP always requests a fresh catch-up.")
        case .restricted:
            return String(localized: "Background App Refresh is restricted on this iPhone. Avoid force-quitting NOOP; Bluetooth and Apple Health may still deliver separately when iOS permits, and opening NOOP requests a catch-up.")
        case .available:
            break
        @unknown default:
            return String(localized: "Background refresh availability is unknown. NOOP requests a catch-up when opened.")
        }
        if let completed = BackgroundSyncScheduler.lastCompletedAt {
            return String(localized: "Last background maintenance: \(relativeAgo(completed.timeIntervalSince1970)) ago. iOS controls future timing; you do not need to keep NOOP on screen, but force-quitting prevents background delivery until you reopen it.")
        }
        return String(localized: "Background refresh is best-effort and scheduled by iOS. You do not need to keep NOOP on screen, but avoid force-quitting it if you want background delivery. Opening NOOP requests a fresh catch-up.")
    }

    private var backgroundRefreshNeedsSettings: Bool {
        UIApplication.shared.backgroundRefreshStatus != .available
    }
    #endif

    // MARK: - Hydration reminders

    private var hydrationReminderCard: some View {
        Section2(
            icon: "drop.fill",
            title: String(localized: "Water reminders"),
            blurb: String(localized: "Gentle, optional prompts during your chosen hours. iOS schedules the phone reminders; a band cue needs a fresh, worn and encrypted live connection."),
            active: hydrationReminderEnabled || hydrationStrapBuzzEnabled
        ) {
            VStack(spacing: 0) {
                ToggleRow(
                    label: String(localized: "Phone notification"),
                    help: String(localized: "Shows a private reminder through iOS. Off by default; turning this on asks for notification access."),
                    isOn: hydrationReminderToggle
                )

                if hydrationReminderEnabled || hydrationStrapBuzzEnabled {
                    rowDivider
                    stepperRow(
                        label: String(localized: "Base interval"),
                        help: String(localized: "Adaptive timing starts here and only moves in bounded 15-minute steps."),
                        value: hydrationIntervalBinding,
                        suffix: String(localized: "min"),
                        range: 60...240,
                        step: 30
                    )
                    rowDivider
                    ToggleRow(
                        label: String(localized: "Adaptive timing"),
                        help: String(localized: "Uses current weather, today's Effort, and logged progress. Never more often than hourly or outside your active hours."),
                        isOn: hydrationAdaptiveToggle
                    )
                    if hydrationAdaptiveEnabled {
                        Text(HydrationReminders.adaptiveSummary)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.chargeColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    rowDivider
                    reviewTimeRow(
                        label: String(localized: "Active from"),
                        minutes: hydrationStartBinding
                    )
                    rowDivider
                    reviewTimeRow(
                        label: String(localized: "Active until"),
                        minutes: hydrationEndBinding
                    )
                    if !hydrationReminderEnabled {
                        rowDivider
                        Text("Noop Band reminders use the schedule below. They do not need notification permission, but iOS cannot guarantee a Bluetooth vibration while NOOP is suspended or terminated.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    rowDivider
                    #if os(iOS)
                    Text("The phone notification may tap a paired Apple Watch according to your iPhone and Watch notification settings. NOOP does not bypass those controls.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    #else
                    Text("Reminder delivery follows your system notification settings. The band cue is available only while NOOP is actively connected.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    #endif
                    Text("The active start is included and the end is excluded. Choose matching times for an all-day schedule.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                rowDivider
                ToggleRow(
                    label: String(localized: "Buzz Noop Band"),
                    help: String(localized: "A separate best-effort channel while NOOP has a fresh, worn, bonded and encrypted connection. One short buzz."),
                    isOn: hydrationStrapBuzzToggle
                )
                if hydrationStrapBuzzEnabled {
                    rowDivider
                    ToggleRow(
                        label: String(localized: "Double-tap to confirm"),
                        help: String(localized: "After NOOP issues the band cue, a timely double-tap logs the configured amount. No tap logs nothing."),
                        isOn: hydrationTapConfirmToggle
                    )
                    if hydrationTapConfirm {
                        rowDivider
                        stepperRow(
                            label: String(localized: "Confirmed amount"),
                            help: String(localized: "The exact amount one valid tap records."),
                            value: hydrationTapAmountBinding,
                            suffix: String(localized: "ml"),
                            range: 50...1_000,
                            step: 50
                        )
                        rowDivider
                        stepperRow(
                            label: String(localized: "Tap window"),
                            help: String(localized: "After this time the tap returns to its normal configured action."),
                            value: hydrationTapWindowBinding,
                            suffix: String(localized: "min"),
                            range: 5...30,
                            step: 5
                        )
                        rowDivider
                        ToggleRow(
                            label: String(localized: "Notify only after a missed tap"),
                            help: String(localized: "After NOOP issues a band cue, wait for the tap window. If you do not confirm, send one phone notification. Alarms and safety alerts never wait."),
                            isOn: hydrationBandFirstToggle
                        )
                        .disabled(!hydrationReminderEnabled)
                    }
                }
                if hydrationStrapBuzzEnabled && !notifMasterOn {
                    rowDivider
                    Text("Wrist alerts are off. Turn on the master switch below before the band can buzz; phone reminders remain independent.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private var hydrationReminderToggle: Binding<Bool> {
        Binding(
            get: { hydrationReminderEnabled },
            set: { on in
                if !on {
                    hydrationReminderEnabled = false
                    HydrationReminders.setEnabled(false)
                    return
                }

                hydrationReminderEnabled = true
                HydrationReminders.setEnabled(true) { outcome in
                    switch outcome {
                    case .scheduled:
                        hydrationReminderEnabled = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                    case .denied:
                        hydrationReminderEnabled = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        hydrationReminderEnabled = false
                    }
                }
            }
        )
    }

    private var hydrationIntervalBinding: Binding<Int> {
        Binding(
            get: { hydrationIntervalMinutes },
            set: { value in
                let clamped = HydrationReminders.clampedInterval(value)
                hydrationIntervalMinutes = clamped
                HydrationReminders.setIntervalMinutes(clamped)
            }
        )
    }

    private var hydrationStartBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: hydrationStartMinutes) },
            set: { date in
                let minutes = Self.minutes(from: date)
                hydrationStartMinutes = minutes
                HydrationReminders.setActiveStartMinutes(minutes)
            }
        )
    }

    private var hydrationEndBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromMinutes: hydrationEndMinutes) },
            set: { date in
                let minutes = Self.minutes(from: date)
                hydrationEndMinutes = minutes
                HydrationReminders.setActiveEndMinutes(minutes)
            }
        )
    }

    private var hydrationStrapBuzzToggle: Binding<Bool> {
        Binding(
            get: { hydrationStrapBuzzEnabled },
            set: { on in
                hydrationStrapBuzzEnabled = on
                HydrationReminders.setStrapBuzzEnabled(on)
            }
        )
    }

    private var hydrationTapConfirmToggle: Binding<Bool> {
        Binding(
            get: { hydrationTapConfirm },
            set: { on in
                hydrationTapConfirm = on
                HydrationReminders.setDoubleTapConfirmEnabled(on)
            }
        )
    }

    private var hydrationTapAmountBinding: Binding<Int> {
        Binding(
            get: { hydrationTapAmountML },
            set: { value in
                let clamped = min(max(value, 50), 1_000)
                hydrationTapAmountML = clamped
                HydrationReminders.setDoubleTapAmountML(clamped)
            }
        )
    }

    private var hydrationTapWindowBinding: Binding<Int> {
        Binding(
            get: { hydrationTapWindowMinutes },
            set: { value in
                let clamped = min(max(value, 5), 30)
                hydrationTapWindowMinutes = clamped
                HydrationReminders.setDoubleTapWindowMinutes(clamped)
            }
        )
    }

    private var hydrationBandFirstToggle: Binding<Bool> {
        Binding(
            get: { hydrationBandFirstEnabled },
            set: { on in
                let enabled = on && hydrationReminderEnabled
                hydrationBandFirstEnabled = enabled
                HydrationReminders.setBandFirstEnabled(enabled)
            }
        )
    }

    private var hydrationAdaptiveToggle: Binding<Bool> {
        Binding(
            get: { hydrationAdaptiveEnabled },
            set: { on in
                hydrationAdaptiveEnabled = on
                HydrationReminders.setAdaptiveEnabled(on)
            }
        )
    }

    private func refreshNotificationPermissionState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notificationPermissionDenied = settings.authorizationStatus == .denied
                if settings.authorizationStatus == .denied {
                    if dailyReviewEnabled {
                        dailyReviewEnabled = false
                        DailyReviewNotifications.setEnabled(false)
                    }
                    if morningRecapEnabled {
                        morningRecapEnabled = false
                        MorningRecapNotifications.setEnabled(false)
                    }
                    if postWorkoutSummaryEnabled {
                        postWorkoutSummaryEnabled = false
                        model.setPostWorkoutSummaryNotificationsEnabled(false)
                    }
                    if behavior.strainTargetNudge {
                        behavior.strainTargetNudge = false
                        StrainTargetNotifier.setEnabled(false)
                    }
                }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    notificationsAuthorized = true
                #if os(iOS)
                case .ephemeral:
                    notificationsAuthorized = true
                #endif
                default:
                    notificationsAuthorized = false
                }
            }
        }
    }

    private func openNotificationSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        #else
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        #endif
        openURL(url)
    }

    // MARK: - Wrist alerts master (iOS only — PR #572)

    #if os(iOS)
    /// The master switch for wrist-buzz notifications. On macOS this lives in its own Notifications
    /// screen; that screen is excluded from the iOS target, so without this the gate is unreachable on
    /// iPhone and every wrist alert (inactivity, app notifications) stays silently off. Binds the same
    /// `notif.masterEnabled` key the SedentaryDetector and the notification posting read.
    private var wristAlertsCard: some View {
        Section2(icon: "bell.badge.fill", title: String(localized: "Wrist alerts"),
                 blurb: String(localized: "Let NOOP tap your wrist for the things you turn on below, so you can leave your phone and still feel what matters."),
                 active: wristAlertsMaster) {
            VStack(spacing: 0) {
                ToggleRow(label: String(localized: "Enable wrist alerts"),
                          help: String(localized: "The master switch for every wrist vibration (inactivity, stress, alerts). Off keeps Noop Band quiet no matter what else is on."),
                          isOn: $wristAlertsMaster)
            }
        }
    }
    #endif

    // MARK: - Double tap

    private var doubleTapCard: some View {
        Section2(icon: "hand.tap.fill", title: String(localized: "Double-tap"),
                 blurb: String(localized: "Double-tap Noop Band to trigger an action on \(Platform.deviceNounPhrase). The band exposes one double-tap gesture."),
                 active: behavior.doubleTapAction != .none) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("When I double-tap").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Picker("", selection: $behavior.doubleTapAction) {
                        ForEach(doubleTapOptions) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if behavior.doubleTapAction == .runShortcut {
                    shortcutField(String(localized: "Shortcut name"), text: $behavior.doubleTapShortcut)
                }
                HStack {
                    Button {
                        model.runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
                    } label: { Label("Test action", systemImage: "play.fill") }
                    .buttonStyle(.bordered).tint(StrandPalette.accent)
                    .disabled(behavior.doubleTapAction == .none)
                    Spacer()
                    // Live-observing leaf: re-renders on its own when the strap's bond state flips, so a
                    // ~1 Hz strap tick doesn't re-render the whole automations column (scroll-stutter
                    // isolation). Renders byte-for-byte the previous inline pill.
                    BondStatePill()
                }
                rowDivider
                tapPriorityGuide
                if !model.moments.isEmpty {
                    rowDivider
                    momentsView
                }
            }
        }
    }

    private var tapPriorityGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("appwide.automations.tap_guide.title").strandOverline()
            tapGuideRow(
                "appwide.automations.tap_guide.alarm_title",
                "appwide.automations.tap_guide.alarm_body"
            )
            tapGuideRow(
                "appwide.automations.tap_guide.hydration_title",
                "appwide.automations.tap_guide.hydration_body"
            )
            tapGuideRow(
                "appwide.automations.tap_guide.sos_title",
                "appwide.automations.tap_guide.sos_body"
            )
            tapGuideRow(
                "appwide.automations.tap_guide.otherwise_title",
                "appwide.automations.tap_guide.otherwise_body"
            )
        }
    }

    private func tapGuideRow(_ context: LocalizedStringKey, _ action: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.tap")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(context).font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(action).font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var momentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent moments").strandOverline()
                Spacer()
                Button("Clear") {
                    model.moments.removeAll()
                    UserDefaults.standard.removeObject(forKey: "moments")
                }
                .buttonStyle(.plain).font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
            }
            ForEach(Array(model.moments.suffix(5).reversed().enumerated()), id: \.offset) { _, d in
                Text(Self.momentFormatter.string(from: d))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
    private static let momentFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        // Keep the "EEE d MMM ·" layout but honor the device's 12-/24-hour clock (#337): the "j"
        // template resolves to a 12-hour pattern (contains "a") only where the user prefers it.
        let uses24h = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H").contains("a")
        f.dateFormat = "EEE d MMM · " + (uses24h ? "HH:mm" : "h:mm a")
        return f
    }()

    // MARK: - Wear & presence

    private var wearCard: some View {
        Section2(icon: "figure.walk.motion", title: String(localized: "Wear & presence"),
                 blurb: wearBlurb,
                 active: wearActive) {
            VStack(spacing: 0) {
                #if os(macOS)
                ToggleRow(label: String(localized: "Lock the Mac when I take Noop Band off"),
                          help: String(localized: "Fires the moment Noop Band leaves your wrist."),
                          isOn: $behavior.autoLockOnWristOff)
                rowDivider
                #endif
                shortcutFieldRow(String(localized: "Run a Shortcut when taken off"),
                                 help: String(localized: "Presence automation: set a Focus, pause media, set away…"),
                                 text: $behavior.wristOffShortcut)
                rowDivider
                shortcutFieldRow(String(localized: "Run a Shortcut when put back on"),
                                 help: String(localized: "Reverse the above when you return."),
                                 text: $behavior.wristOnShortcut)
            }
        }
    }

    // MARK: - Coaching

    private var coachingCard: some View {
        Section2(icon: "bolt.heart.fill",
                 title: String(localized: "appwide.adaptive_coaching.title"),
                 blurb: String(localized: "appwide.adaptive_coaching.summary"),
                 active: adaptiveDayGuidance || behavior.zoneCoaching
                    || behavior.automaticStressNudgeEffective) {
            VStack(spacing: 0) {
                ToggleRow(
                    label: String(localized: "appwide.adaptive_day_guidance.label"),
                    help: String(localized: "appwide.adaptive_day_guidance.help"),
                    isOn: adaptiveDayGuidanceToggle
                )
                #if os(iOS)
                if adaptiveDayGuidance {
                    rowDivider
                    ToggleRow(
                        label: String(localized: "appwide.adaptive_day_guidance.calendar.label"),
                        help: String(localized: "appwide.adaptive_day_guidance.calendar.help"),
                        isOn: plannedWorkoutCalendarToggle
                    )
                    if plannedWorkoutCalendarPermissionUnavailable {
                        rowDivider
                        Text("appwide.adaptive_day_guidance.calendar.permission_unavailable")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
                #endif
                rowDivider
                ToggleRow(label: String(localized: "appwide.workout_guidance.label"),
                          help: String(localized: "appwide.workout_guidance.help"),
                          isOn: workoutGuidanceToggle)
                #if os(iOS)
                if behavior.zoneCoaching && !wristAlertsMaster {
                    rowDivider
                    Text("appwide.workout_guidance.wrist_alerts_off")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                #endif
                rowDivider
                ToggleRow(
                    label: String(localized: "appwide.stress_checkin.label"),
                    help: String(localized: "appwide.stress_checkin.help"),
                    isOn: $behavior.stressCheckIn
                )
                if behavior.stressCheckIn {
                    rowDivider
                    ToggleRow(
                        label: String(localized: "appwide.stress_checkin.detect_label"),
                        help: String(localized: "appwide.stress_checkin.detect_help"),
                        isOn: $behavior.stressAutoNudge
                    )
                    if behavior.stressAutoNudge {
                        rowDivider
                        ToggleRow(
                            label: String(localized: "appwide.stress_checkin.phone_label"),
                            help: String(localized: "appwide.stress_checkin.phone_help"),
                            isOn: stressPhoneNudgeToggle
                        )
                        rowDivider
                        ToggleRow(
                            label: String(localized: "appwide.stress_checkin.quiet_label"),
                            help: String(localized: "appwide.stress_checkin.quiet_help"),
                            isOn: $behavior.stressQuietHours
                        )
                        if !notifMasterOn {
                            rowDivider
                            Text("appwide.stress_checkin.wrist_alerts_off")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                        }
                    }
                }
                rowDivider
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wind")
                        .foregroundStyle(StrandPalette.restBright)
                        .accessibilityHidden(true)
                    Text("appwide.stress_checkin.manual_note")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    private var adaptiveDayGuidanceToggle: Binding<Bool> {
        Binding(
            get: { adaptiveDayGuidance },
            set: { on in
                guard on else {
                    adaptiveDayGuidance = false
                    #if os(iOS)
                    PlannedWorkoutCalendarStore.shared.clear()
                    AdaptivePlannedWorkoutScheduler.cancelPending()
                    ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                        keepingFingerprint: nil
                    )
                    #endif
                    model.reevaluateContextualInterventions()
                    return
                }
                ContextualInterventionCenter.requestAuthorization { outcome in
                    switch outcome {
                    case .enabled:
                        adaptiveDayGuidance = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                        model.reevaluateContextualInterventions()
                    case .denied:
                        adaptiveDayGuidance = false
                        AdaptivePlannedWorkoutScheduler.cancelPending()
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        adaptiveDayGuidance = false
                        AdaptivePlannedWorkoutScheduler.cancelPending()
                    }
                }
            }
        )
    }

    #if os(iOS)
    private var plannedWorkoutCalendarToggle: Binding<Bool> {
        Binding(
            get: { plannedWorkoutCalendarEnabled },
            set: { on in
                guard on else {
                    plannedWorkoutCalendarEnabled = false
                    plannedWorkoutCalendarPermissionUnavailable = false
                    PlannedWorkoutCalendarStore.shared.clear()
                    AdaptivePlannedWorkoutScheduler.cancelPending()
                    ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                        keepingFingerprint: nil
                    )
                    model.reevaluateContextualInterventions()
                    return
                }
                PlannedWorkoutCalendarStore.shared.requestAccess { outcome in
                    switch outcome {
                    case .enabled:
                        plannedWorkoutCalendarEnabled = true
                        plannedWorkoutCalendarPermissionUnavailable = false
                        Task { @MainActor in
                            _ = await PlannedWorkoutCalendarStore.shared.refresh(force: true)
                            model.reevaluateContextualInterventions()
                        }
                    case .denied, .unavailable:
                        plannedWorkoutCalendarEnabled = false
                        plannedWorkoutCalendarPermissionUnavailable = true
                        PlannedWorkoutCalendarStore.shared.clear()
                        AdaptivePlannedWorkoutScheduler.cancelPending()
                        ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                            keepingFingerprint: nil
                        )
                    }
                }
            }
        )
    }

    private func refreshPlannedWorkoutCalendarState() {
        guard plannedWorkoutCalendarEnabled else {
            plannedWorkoutCalendarPermissionUnavailable = false
            PlannedWorkoutCalendarStore.shared.clear()
            AdaptivePlannedWorkoutScheduler.cancelPending()
            ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                keepingFingerprint: nil
            )
            return
        }
        PlannedWorkoutCalendarStore.shared.requestAccess { outcome in
            switch outcome {
            case .enabled:
                plannedWorkoutCalendarPermissionUnavailable = false
                Task { @MainActor in
                    _ = await PlannedWorkoutCalendarStore.shared.refresh(force: true)
                }
            case .denied, .unavailable:
                plannedWorkoutCalendarEnabled = false
                plannedWorkoutCalendarPermissionUnavailable = true
                PlannedWorkoutCalendarStore.shared.clear()
                AdaptivePlannedWorkoutScheduler.cancelPending()
                ContextualInterventionCenter.reconcilePlannedWorkoutArtifacts(
                    keepingFingerprint: nil
                )
            }
        }
    }
    #endif

    private var workoutGuidanceToggle: Binding<Bool> {
        Binding(
            get: { behavior.zoneCoaching },
            set: { on in
                behavior.zoneCoaching = on
                guard on else { return }
                // Wrist guidance remains useful if permission is declined. Authorization only adds the
                // strongest "pause and assess" phone prompt.
                ContextualInterventionCenter.requestAuthorization { outcome in
                    if outcome == .denied {
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    } else if outcome == .enabled {
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                    }
                }
            }
        )
    }

    private var stressPhoneNudgeToggle: Binding<Bool> {
        Binding(
            get: { behavior.stressPhoneNudge },
            set: { on in
                guard on else {
                    behavior.stressPhoneNudge = false
                    return
                }
                behavior.stressPhoneNudge = true
                ContextualInterventionCenter.requestAuthorization { outcome in
                    switch outcome {
                    case .enabled:
                        behavior.stressPhoneNudge = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                    case .denied:
                        behavior.stressPhoneNudge = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        behavior.stressPhoneNudge = false
                    }
                }
            }
        )
    }

    // MARK: - Inactivity reminder (#419)

    private var inactivityCard: some View {
        Section2(icon: "timer", title: String(localized: "Inactivity reminder"),
                 blurb: String(localized: "A gentle wrist vibration when you've been sitting too long, a nudge to get up and move. Inferred from Noop Band motion on each history sync, so it can lag real time by a sync or two."),
                 active: inactivity.enabled) {
            VStack(spacing: 0) {
                ToggleRow(label: String(localized: "Enable inactivity reminder"),
                          help: String(localized: "Buzzes after you've been sitting past your threshold."),
                          isOn: $inactivity.enabled)
                if inactivity.enabled {
                    if !notifMasterOn {
                        Text("Notifications are off, so this can't buzz yet. Turn on the master switch in Notifications to let it through.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    rowDivider
                    stepperRow(label: String(localized: "Sitting for"), help: String(localized: "Minutes seated before the first nudge."),
                               value: $inactivity.thresholdMinutes, suffix: String(localized: "min"), range: 15...120, step: 15)
                    rowDivider
                    stepperRow(label: String(localized: "Re-nudge every"), help: String(localized: "If you're still seated, buzz again this often."),
                               value: $inactivity.reNudgeMinutes, suffix: String(localized: "min"), range: 15...120, step: 15)
                    rowDivider
                    stepperRow(label: String(localized: "Buzz strength"), help: String(localized: "How strong the buzz is."),
                               value: $inactivity.buzzLoops, suffix: "×", range: 1...4, step: 1)
                    rowDivider
                    ToggleRow(label: String(localized: "Only during active hours"),
                              help: String(localized: "Only nudge during your active hours."),
                              isOn: $inactivity.activeHoursEnabled)
                    if inactivity.activeHoursEnabled {
                        rowDivider
                        HStack(spacing: 12) {
                            Text("From").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            DatePicker("", selection: activeStartBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Active hours start")
                            Text("to").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                            DatePicker("", selection: activeEndBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Active hours end")
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 42).padding(.vertical, 4)
                    }
                }
            }
        }
    }

    /// The reused global notification master (notif.masterEnabled, default OFF) — drives the inert-feature
    /// warning so enabling the reminder while master is off isn't silently a no-op.
    private var notifMasterOn: Bool {
        UserDefaults.standard.object(forKey: "notif.masterEnabled") as? Bool ?? false
    }
    private var activeStartBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeStartMinutes) },
                set: { inactivity.activeStartMinutes = Self.minutes(from: $0) })
    }
    private var activeEndBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeEndMinutes) },
                set: { inactivity.activeEndMinutes = Self.minutes(from: $0) })
    }

    /// A label/help row with a native −[value]+ stepper, clamped to `range` and moved by `step`.
    private func stepperRow(label: String, help: String, value: Binding<Int>,
                            suffix: String, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            Stepper("", value: value, in: range, step: step).labelsHidden()
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }

    // MARK: - Multi-signal wellness check-in

    private var illnessCard: some View {
        Section2(icon: "waveform.path.ecg", title: String(localized: "Multi-signal change"),
                 blurb: String(localized: "Watches resting HR, HRV, skin temperature and respiration against your own baseline. Many factors can move these signals; this is a wellness check-in, not a diagnosis."),
                 active: behavior.illnessWatch) {
            ToggleRow(label: String(localized: "Watch for baseline shifts"),
                      help: String(localized: "Needs at least 14 days of history. When two or more signals move together, NOOP shows a private in-app check-in and a detail-free notification at most once a day."),
                      isOn: $behavior.illnessWatch)
                .onChangeCompat(of: behavior.illnessWatch) { _ in
                    model.reevaluateIllness()
                    if behavior.illnessWatch { IllnessNotifier.requestAuthorization() }
                }
        }
    }

    // MARK: - Contextual vital reviews

    private var contextualReviewCard: some View {
        Section2(
            icon: "waveform.path.ecg.rectangle",
            title: String(localized: "Vital trend reviews"),
            blurb: String(localized: "Optional, private prompts for meaningful changes in data already synced from your wearable or Apple Health. Never a diagnosis or an emergency alert."),
            active: contextualVitalReviews || contextualVO2Reviews
        ) {
            VStack(spacing: 0) {
                ToggleRow(
                    label: String(localized: "Oxygen & body temperature"),
                    help: String(localized: "Blood oxygen needs two agreeing recent low days. A fresh explicit body-temperature reading can prompt a recheck. Conflicts, stale data, wrist temperature and skin temperature never trigger this review."),
                    isOn: contextualVitalReviewToggle
                )
                rowDivider
                ToggleRow(
                    label: String(localized: "VO₂ max trend"),
                    help: String(localized: "Prompts only when two recent points persist in the same direction against a point at least three weeks earlier. One estimate never triggers it; this is not a live alert."),
                    isOn: contextualVO2ReviewToggle
                )
                rowDivider
                Text("Skin temperature stays inside the multi-signal check above and is never substituted for body temperature. These reviews are not diagnoses, severity assessments, or emergency alerts; notification text contains no values.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        }
    }

    private var contextualVitalReviewToggle: Binding<Bool> {
        Binding(
            get: { contextualVitalReviews },
            set: { on in
                guard on else {
                    contextualVitalReviews = false
                    return
                }
                contextualVitalReviews = true
                ContextualInterventionCenter.requestAuthorization { outcome in
                    switch outcome {
                    case .enabled:
                        contextualVitalReviews = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                        model.reevaluateContextualInterventions()
                    case .denied:
                        contextualVitalReviews = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        contextualVitalReviews = false
                    }
                }
            }
        )
    }

    private var contextualVO2ReviewToggle: Binding<Bool> {
        Binding(
            get: { contextualVO2Reviews },
            set: { on in
                guard on else {
                    contextualVO2Reviews = false
                    return
                }
                contextualVO2Reviews = true
                ContextualInterventionCenter.requestAuthorization { outcome in
                    switch outcome {
                    case .enabled:
                        contextualVO2Reviews = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                        model.reevaluateContextualInterventions()
                    case .denied:
                        contextualVO2Reviews = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        contextualVO2Reviews = false
                    }
                }
            }
        )
    }

    // MARK: - Health insights (v5: cycle awareness opt-in · experimental Rhythm)

    private var healthInsightsCard: some View {
        Section2(icon: "thermometer.medium", title: String(localized: "Health insights"),
                 blurb: String(localized: "Optional, on-device reads from your nightly signals. Each is off by default: for awareness only, never a diagnosis."),
                 active: cycleAwareness || rhythmEnabled) {
            VStack(spacing: 0) {
                // #801: cycle awareness reads the MENSTRUAL temperature shift, so the toggle is only
                // offered to profiles it applies to (gated the same way as the Health opt-in card,
                // not shown for male profiles). Keeps the two surfaces consistent: a profile that can't
                // see the Health card can't enable the feature from here either.
                if cycleOptInApplies {
                    ToggleRow(label: String(localized: "Cycle awareness"),
                              help: String(localized: "Reads a coarse menstrual-cycle phase from your nightly skin temperature, entirely on \(Platform.deviceNounPhrase). On iPhone, turning this on can ask to import cycle-start dates from Apple Health; you can decline and log dates manually. Awareness only: not contraception, not a fertility predictor, not a medical service. The card appears in Health."),
                              isOn: $cycleAwareness)
                        .onChangeCompat(of: cycleAwareness) { on in
                            model.cycleAwarenessEnabled = on
                            Task {
                                #if os(iOS)
                                if on {
                                    await health.requestCycleDataAccessAndImport()
                                } else {
                                    await health.disableCycleDataImport()
                                }
                                #endif
                                await model.refreshV5Signals()
                            }
                        }
                    rowDivider
                }
                ToggleRow(label: String(localized: "Rhythm visualization (experimental)"),
                          help: String(localized: "An experimental picture of your beat-to-beat heart timing. Not an ECG and not a diagnosis. You'll read and accept an experimental note before it shows anything."),
                          isOn: $rhythmEnabled)
                if rhythmEnabled {
                    rowDivider
                    HStack {
                        Text("Open Rhythm").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button {
                            router.openRhythm()
                        } label: { Label("Open", systemImage: "waveform.path") }
                        .buttonStyle(.bordered).tint(StrandPalette.accent)
                    }
                    .frame(minHeight: 42).padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Strap battery alerts

    private var batteryCard: some View {
        Section2(icon: "battery.25", title: String(localized: "Battery alerts"),
                 blurb: String(localized: "Get a notification when Noop Band battery runs low (15%) so you can top it up before tonight, and when it finishes charging."),
                 active: behavior.batteryAlerts) {
            ToggleRow(label: String(localized: "Notify on low and full battery"),
                      help: String(localized: "A reminder to recharge before bed when Noop Band drops to 15%, and a heads-up when it reaches 100%, each at most once per charge cycle."),
                      isOn: $behavior.batteryAlerts)
                .onChangeCompat(of: behavior.batteryAlerts) { on in
                    if on { BatteryNotifier.requestAuthorization() }
                }
            if behavior.batteryAlerts {
                ToggleRow(label: String(localized: "Predictive runtime warning"),
                          help: String(localized: "An early \"recharge tonight\" heads-up when Noop Band has about a day of estimated runtime left, at most once per discharge cycle. Turn off to keep only the 15% warning."),
                          isOn: $behavior.batteryPredictiveAlerts)
            }
        }
    }

    // MARK: - Effort marker nudge (#593)

    private var strainTargetCard: some View {
        Section2(icon: "flame", title: String(localized: "Effort marker"),
                 blurb: String(localized: "A once-a-day nudge at a recovery-based Effort marker. It is a planning cue, not a limit or permission to keep pushing."),
                 active: behavior.strainTargetNudge) {
            ToggleRow(label: String(localized: "Notify when the Effort marker is reached"),
                      help: String(localized: "Posts after Noop Band syncs and NOOP scores the day, not the exact second you cross it. At most once per day."),
                      isOn: strainTargetToggle)
        }
    }

    private var strainTargetToggle: Binding<Bool> {
        Binding(
            get: { behavior.strainTargetNudge },
            set: { enabled in
                guard enabled else {
                    behavior.strainTargetNudge = false
                    StrainTargetNotifier.setEnabled(false)
                    return
                }

                behavior.strainTargetNudge = false
                StrainTargetNotifier.setEnabled(true) { outcome in
                    switch outcome {
                    case .enabled:
                        behavior.strainTargetNudge = true
                        notificationPermissionDenied = false
                        refreshNotificationPermissionState()
                        model.evaluateStrainTarget()
                    case .denied:
                        behavior.strainTargetNudge = false
                        notificationPermissionDenied = true
                        showNotificationPermissionAlert = true
                    case .off:
                        behavior.strainTargetNudge = false
                    }
                }
            }
        )
    }

    // MARK: - Helpers

    /// Double-tap actions offered in the picker. The "Lock the Mac" action can't work on iPhone
    /// (a third-party app can't lock iOS), so it's dropped there.
    private var doubleTapOptions: [MacActionKind] {
        #if os(iOS)
        MacActionKind.allCases.filter { $0 != .lockScreen }
        #else
        MacActionKind.allCases
        #endif
    }

    /// Wear & presence blurb. macOS mentions the auto-lock affordance (and the Apple-Watch unlock
    /// caveat); iOS, where that toggle is hidden, describes the Shortcut-driven presence reactions.
    /// Wear & presence is "active" when any of its reactions are configured: a wrist-on/off Shortcut,
    /// or (macOS) the auto-lock toggle. Presentation-only — drives the card's accent state.
    private var wearActive: Bool {
        let shortcuts = !behavior.wristOffShortcut.isEmpty || !behavior.wristOnShortcut.isEmpty
        #if os(macOS)
        return shortcuts || behavior.autoLockOnWristOff
        #else
        return shortcuts
        #endif
    }

    private var wearBlurb: String {
        #if os(macOS)
        String(localized: "React when the strap comes off or goes on. Note: macOS reserves true auto-UNLOCK for Apple Watch, so this can lock, not unlock.")
        #else
        String(localized: "React when Noop Band comes off or goes on. Run a Shortcut to set a Focus, pause media, or mark yourself away.")
        #endif
    }

    // `date(fromMinutes:)` / `minutes(from:)` stay: the inactivity active-hours pickers above use them.
    // (The strap-alarm time binding moved to SmartAlarmView with the rest of the alarm UI, #766.)
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func shortcutField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(StrandFont.body)
            .frame(maxWidth: 320)
    }

    private func shortcutFieldRow(_ label: String, help: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            shortcutField(String(localized: "Shortcut name"), text: text)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }

    private var rowDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.vertical, 4)
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// The strap bond-status pill in the double-tap card ("Strap bonded" / "Strap not connected"). It owns
/// its OWN `@EnvironmentObject live` so a ~1 Hz strap publish re-renders only this pill, not the whole
/// automations column (the parent `AutomationsView` no longer observes `LiveState`). Renders
/// byte-for-byte the previous inline `StatePill(live.bonded ? …)`.
private struct BondStatePill: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        StatePill(live.bonded ? "Noop Band paired" : "Noop Band not connected",
                  tone: live.bonded ? .positive : .warning, showsDot: true)
    }
}

// MARK: - Local section + row (mirrors the settings idiom)

private struct Section2<Content: View>: View {
    let icon: String; let title: String; var blurb: String? = nil
    /// When this automation is enabled the card carries a brighter brand-green wash; otherwise a
    /// faint one — so an active automation reads at a glance. Presentation-only.
    var active: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        StrandCard(padding: 20, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Automation").strandOverline()
                        if active {
                            Text("ON").font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundStyle(active ? StrandPalette.accent : StrandPalette.textSecondary)
                            .accessibilityHidden(true)
                        Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                if let blurb {
                    Text(blurb).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }
}

private struct ToggleRow: View {
    let label: String; let help: String; @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.noopSwitch)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }
}
