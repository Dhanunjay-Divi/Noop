import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Smart alarm (#207) — the iOS/macOS surface.
///
/// HONEST by design: a sideloaded, backgrounded app on iOS can't fire a dependable LOUD wake alarm
/// (that needs the critical-alert entitlement, which a non-App-Store build doesn't have), so this
/// platform deliberately does NOT offer a wake alarm. The dependable phone wake lives on Android,
/// which has the exact-alarm primitive. Here we offer the cross-platform WIND-DOWN nudge — a gentle
/// evening reminder — and we say plainly why there's no wake alarm, rather than promising one we
/// can't keep.
struct SmartAlarmView: View {
    // #766: this is now the ONE alarm surface. The strap's silent firmware wake-alarm used to live in a
    // separate card over in Automations, which let users conflate it with the wind-down reminder; it's
    // moved here so every wake/wind-down control sits together. Needs the model (to arm/disarm the strap
    // alarm over BLE) and the behavior store (the alarm's persisted on/time/weekdays).
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var repo: Repository

    @State private var windDownOn = WindDownNudge.isEnabled
    /// Shown when the user flips the nudge on but notifications are denied at the OS level — the reminder
    /// can never fire, so we revert the switch and point them to Settings instead of failing silently.
    @State private var showNotifDeniedAlert = false
    /// Earliest wake time the nudge is derived from (minutes since midnight). Seeded from the store.
    @State private var wakeMinutes = WindDownNudge.wakeMinutes
    @State private var sleepTargetMinutes = WindDownNudge.sleepNeedMinutes
    @State private var sleepGoalMode = WindDownNudge.goalMode
    @State private var windDownLeadMinutes = WindDownNudge.leadMinutes
    @State private var allSleepSessions: [CachedSleepSession] = []
    @State private var habitualMidsleepSec: Int?

    // PR#554 (MumiZed) — per-day wake overrides. `perDayOn` reflects whether ANY override is set; the
    // `overrides` map mirrors the store so the pickers stay in sync. Additive: with none set, the nudge
    // behaves exactly as before (one wake time for every evening).
    @State private var perDayOn = WindDownNudge.hasPerDayOverrides
    @State private var overrides: [Int: Int] = WindDownNudge.perDayWakeOverrides

    // #34: consecutive times the strap reported back a DIFFERENT alarm time than we sent (set in
    // FrameRouter). ≥2 = the strap is persistently refusing the alarm (a corrupted clock/alarm register),
    // which the strapRejectedCard surfaces with reset guidance. @AppStorage so it updates live.
    @AppStorage("alarm.rejectStreak") private var alarmRejectStreak = 0
    @AppStorage(TapAutomationPreferences.alarmDoubleTapEnabledKey) private var alarmDoubleTapEnabled = false
    @AppStorage(TapAutomationPreferences.alarmWindowMinutesKey) private var alarmTapWindowMinutes = 15
    /// Calendar weekday numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1), matching AutomationsView.
    nonisolated private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        ScreenScaffold(title: "Sleep Planner",
                       subtitle: "Tonight's plan, wind-down reminder, and wake alarms in one place.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                windowHero
                strapAlarmCard
                strapRejectedCard   // #34: only shows when the strap keeps refusing the alarm
                honestyCard
                windDownCard
            }
        }
        .task(id: repo.refreshSeq) {
            allSleepSessions = await repo.allSleepSessions()
            habitualMidsleepSec = await repo.habitualMidsleepSec()
        }
        .onChangeCompat(of: sleepPlan.recoveryMinutes) { _ in
            if behavior.smartAlarmMode == .adaptiveSleep { model.applySmartAlarm() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: WindDownNudge.stateDidChange
            )
        ) { _ in
            windDownOn = WindDownNudge.isEnabled
            wakeMinutes = WindDownNudge.wakeMinutes
            overrides = WindDownNudge.perDayWakeOverrides
            perDayOn = WindDownNudge.hasPerDayOverrides
        }
        .alert(String(localized: "Notifications are off"), isPresented: $showNotifDeniedAlert) {
            Button(String(localized: "Open Settings")) { Self.openNotificationSettings() }
            Button(String(localized: "Not now"), role: .cancel) {}
        } message: {
            Text("Turn on notifications for NOOP in Settings to get your wind-down reminder.")
        }
    }

    /// Deep-link to the OS notification settings so a user who denied can flip it back on — the system
    /// permission dialog only appears once, so Settings is the only recovery path.
    private static func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// One plan, derived from the same explicit target and recent arithmetic balance used by the card.
    /// Naps contribute only when they have recorded sleep stages; missing nights remain skipped.
    private var sleepPlan: SleepPlan {
        SleepPlanner.plan(
            wakeMinute: nextPlannerWakeMinutes,
            sleepTargetMinutes: sleepTargetMinutes,
            windDownLeadMinutes: windDownLeadMinutes,
            debtBalanceMinutes: plannerLedger.nightCount == 0 ? nil : plannerLedger.balanceMin,
            historyNights: plannerLedger.nightCount,
            goalMode: sleepGoalMode
        )
    }

    private var provisionalSleepPlan: SleepPlan {
        SleepPlanner.plan(
            wakeMinute: wakeMinutes,
            sleepTargetMinutes: sleepTargetMinutes,
            windDownLeadMinutes: windDownLeadMinutes,
            debtBalanceMinutes: plannerLedger.nightCount == 0 ? nil : plannerLedger.balanceMin,
            historyNights: plannerLedger.nightCount,
            goalMode: sleepGoalMode
        )
    }

    private var nextPlannerWakeMinutes: Int {
        guard let plan = WindDownNudge.nextDatedPlan(
            defaultWakeMinutes: wakeMinutes,
            wakeOverrides: overrides,
            targetSleepMinutes: provisionalSleepPlan.sleepOpportunityMinutes,
            leadMinutes: windDownLeadMinutes
        ) else {
            return wakeMinutes
        }
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: plan.wakeDate
        )
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private var plannerLedger: SleepDebtLedger {
        SleepDebt.ledger(
            series: repo.days.map { day in
                (
                    day: day.day,
                    totalSleepMin: SleepDebt.creditedSleepMin(
                        mainSleepMin: day.totalSleepMin,
                        napSleepMin: plannerNapMinutesByDay[day.day] ?? 0
                    )
                )
            },
            needHours: Double(sleepTargetMinutes) / 60.0
        )
    }

    private var plannerNapMinutesByDay: [String: Double] {
        SleepView.napSleepMinutesByWakeDay(
            allSleepSessions,
            habitualMidsleepSec: habitualMidsleepSec)
    }

    // A Rest-tinted plan hero. It is useful even with reminders off: reminder state changes delivery,
    // not the underlying bedtime math.
    private var windowHero: some View {
        let plan = sleepPlan
        return ZStack {
            ScenicHeroBackground(domain: .rest)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tonight's plan").strandOverline()
                    Spacer()
                    Text(planConfidenceLabel(plan.confidence))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    heroTime(label: "Wind down",
                             time: timeLabel(plan.windDownMinute),
                             tint: StrandPalette.restColor)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    heroTime(label: "Bedtime",
                             time: timeLabel(plan.bedtimeMinute),
                             tint: StrandPalette.restBright)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    heroTime(label: "Wake",
                             time: timeLabel(plan.wakeMinute),
                             tint: StrandPalette.restBright)
                    Spacer(minLength: 0)
                }
                Text(planSummary(plan))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let timing = observedTimingSummary(plan) {
                    Label(timing, systemImage: "clock.arrow.circlepath")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(windDownOn
                     ? String(
                        format: String(localized: "appwide.sleep.reminder.scheduled_format"),
                        timeLabel(plan.windDownMinute)
                     )
                     : String(localized: "appwide.sleep.reminder.off"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .accessibilityElement(children: .combine)
    }

    private func heroTime(label: LocalizedStringKey, time: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(time)
                .font(StrandFont.number(24))
                .foregroundStyle(tint)
        }
    }

    private func planSummary(_ plan: SleepPlan) -> String {
        let opportunity = durationLabel(plan.sleepOpportunityMinutes)
        switch plan.goalMode {
        case .target:
            if let balance = plan.debtBalanceMinutes, balance < -SleepDebt.onTargetBandMin {
                return String(localized: "\(opportunity) fixed sleep opportunity. Recent history is \(durationLabel(Int(abs(balance)))) short, but Target mode does not change the amount you set.")
            }
            return String(localized: "\(opportunity) fixed sleep opportunity from the target you set.")
        case .extraOpportunity:
            return String(localized: "\(opportunity) sleep opportunity. Extra mode reserves at least 30 minutes beyond your target; a supported recent shortfall can raise that addition, capped at 1 hour.")
        case .balance:
            break
        }
        if plan.historyNights < SleepPlanner.minimumDebtNights {
            return String(localized: "\(opportunity) sleep opportunity from your target. Add at least 3 recorded nights to calibrate a recent-balance adjustment.")
        }
        if plan.recoveryMinutes > 0 {
            return String(localized: "\(opportunity) sleep opportunity: your \(durationLabel(plan.baseSleepMinutes)) target plus \(durationLabel(plan.recoveryMinutes)) to ease a recent \(durationLabel(Int(abs(plan.debtBalanceMinutes ?? 0)))) shortfall. The addition is capped at 1 hour.")
        }
        if let balance = plan.debtBalanceMinutes, balance > SleepDebt.onTargetBandMin {
            return String(localized: "\(opportunity) sleep opportunity. Your recent balance is \(durationLabel(Int(balance))) ahead, but NOOP never trims your target because of a surplus.")
        }
        return String(localized: "\(opportunity) sleep opportunity. Your recent sleep balance is on target, so no recovery time was added.")
    }

    private func observedTimingSummary(_ plan: SleepPlan) -> String? {
        guard let shift = SleepPlanner.observedTimingShiftMinutes(
            plan: plan,
            habitualMidsleepSeconds: habitualMidsleepSec
        ) else { return nil }
        if abs(shift) <= 30 {
            return String(localized: "Tonight is within 30 minutes of your observed sleep timing.")
        }
        let direction = shift < 0 ? String(localized: "earlier") : String(localized: "later")
        return String(localized: "Tonight is \(durationLabel(abs(shift))) \(direction) than your observed sleep timing. This describes your recent behavior, not a biological chronotype.")
    }

    private func sleepGoalLabel(_ mode: SleepGoalMode) -> String {
        switch mode {
        case .target: return String(localized: "Target")
        case .balance: return String(localized: "Adaptive")
        case .extraOpportunity: return String(localized: "Extra")
        }
    }

    private func sleepGoalHelp(_ mode: SleepGoalMode) -> String {
        switch mode {
        case .target:
            return String(localized: "Keep the sleep target fixed, even when recent history is short.")
        case .balance:
            return String(localized: "Move bedtime earlier in bounded 15-minute steps when at least 3 recorded nights show a shortfall.")
        case .extraOpportunity:
            return String(localized: "Reserve at least 30 extra minutes tonight. This is added opportunity, not a promise of better recovery.")
        }
    }

    private func planConfidenceLabel(_ confidence: ScoreConfidence) -> String {
        switch confidence {
        case .calibrating: return String(localized: "Calibrating")
        case .building: return String(localized: "Building")
        case .solid: return String(localized: "Solid basis")
        }
    }

    // #34: shown ONLY when the strap has repeatedly reported back a different alarm time than we sent —
    // i.e. its firmware is refusing the write (a reset/corrupted clock/alarm register). Gated on the alarm
    // being on and a rejection STREAK (≥2) so a one-off readback quirk never nags. Actionable: a strap
    // reset via the official app clears it; the phone Clock alarm covers the gap meanwhile.
    @ViewBuilder private var strapRejectedCard: some View {
        if behavior.smartAlarmEnabled && alarmRejectStreak >= 2 {
            StrandCard(padding: 20) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Noop Band isn't accepting the alarm")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Noop Band keeps reporting a different time than NOOP sends, so its alarm may not fire at your wake time. Restart the band from Devices, or fully charge it and reconnect. Keep your phone's Clock alarm as your wake until the band accepts the time.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // The up-front, honest note about the difference between the strap's silent buzz (above) and a loud
    // phone wake. The strap alarm is real, but it's a gentle wrist buzz, not a sound, so we say plainly
    // to keep a backup, and that the louder smart wake lives on Android.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Noop Band alarm is a silent vibration, not a sound")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Noop Band provides a silent wrist vibration. Fixed-time alarms stay on the band once armed. Detected-sleep alarms are revised when fresh sleep data reaches NOOP, so background timing depends on Bluetooth sync and iOS scheduling. The phone backup is a normal notification, not a guaranteed loud alarm; Focus or silent mode can suppress it. Keep a Clock alarm for anything you cannot miss.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Strap silent wake-alarm (#766, moved here from Automations)

    // The strap's own firmware alarm: a silent wrist buzz at the chosen time, armed over BLE so it fires
    // even if the phone is asleep or NOOP is closed. Lifted verbatim (behaviour intact) out of
    // AutomationsView.alarmCard so users stop conflating it with the wind-down reminder below.
    private var strapAlarmCard: some View {
        StrandCard(padding: 20, tint: behavior.smartAlarmEnabled ? StrandPalette.chargeColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "alarm.fill")
                            .foregroundStyle(StrandPalette.chargeColor)
                            .accessibilityHidden(true)
                        Text("Noop Band wake alarm")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake me with a band vibration")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("The band can vibrate at your wake time after NOOP arms it. Keep a phone alarm for anything you cannot miss.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $behavior.smartAlarmEnabled)
                        .labelsHidden().toggleStyle(.noopSwitch)
                        .accessibilityLabel("Wake me with a band vibration")
                }
                .frame(minHeight: 42)

                if behavior.smartAlarmEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    Picker("Wake rule", selection: $behavior.smartAlarmMode) {
                        Text("At a time").tag(SmartAlarmMode.wakeTime)
                        Text("After sleep").tag(SmartAlarmMode.sleepDuration)
                        Text("Adaptive").tag(SmartAlarmMode.adaptiveSleep)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Wake alarm mode")

                    Divider().overlay(StrandPalette.hairline)
                    Toggle(isOn: $alarmDoubleTapEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Double-tap to stop vibration")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Consumes the first live double-tap after the band alarm; it does not silence Apple Clock alarms.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .toggleStyle(.noopSwitch)
                    if alarmDoubleTapEnabled {
                        Stepper(value: $alarmTapWindowMinutes, in: 5...30, step: 5) {
                            HStack {
                                Text("Active tap window")
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text("\(alarmTapWindowMinutes) min")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    if behavior.smartAlarmMode == .wakeTime {
                        HStack {
                            Label("Wake at", systemImage: "clock")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            DatePicker("", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Wake time")
                        }
                        .frame(minHeight: 44)
                    } else if behavior.smartAlarmMode == .sleepDuration {
                        Stepper(
                            value: $behavior.smartAlarmDurationMinutes,
                            in: SleepDurationAlarmPolicy.minimumTargetMinutes...SleepDurationAlarmPolicy.maximumTargetMinutes,
                            step: 15
                        ) {
                            HStack {
                                Label("Detected sleep", systemImage: "moon.zzz.fill")
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text(durationLabel(behavior.smartAlarmDurationMinutes))
                                    .font(StrandFont.number(18))
                                    .foregroundStyle(StrandPalette.restBright)
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityLabel("Detected sleep target")
                        .accessibilityValue(durationLabel(behavior.smartAlarmDurationMinutes))
                    } else {
                        HStack {
                            Label("Tonight's plan", systemImage: "moon.stars.fill")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(durationLabel(sleepPlan.sleepOpportunityMinutes))
                                .font(StrandFont.number(18))
                                .foregroundStyle(StrandPalette.restBright)
                                .monospacedDigit()
                        }
                        Text("Updates from your sleep target and the planner's bounded recent-balance adjustment.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Divider().overlay(StrandPalette.hairline)
                    alarmWeekdayPicker
                    alarmRuntimeStatus
                    if model.whoop5Detected && !PuffinExperiment.isEnabled {
                        Text("This Noop Band firmware needs Experimental mode before wrist wake can be armed. Your time is saved, but the band is not armed yet. Keep a backup alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if model.whoop5Detected {
                        Text("Armed using the experimental band command. Wrist wake is still under validation for this firmware, so keep a backup alarm.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if behavior.smartAlarmMode.usesDetectedSleep {
                        Text("Once NOOP has a fresh detected sleep session, it arms Noop Band for the projected target and revises that time as awake minutes accumulate. The band can still vibrate with NOOP closed after it has been armed; detecting and revising the target remains best-effort in the background.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Armed on Noop Band, so it can vibrate even if the phone is asleep or NOOP is closed. Keep a backup alarm for anything you cannot miss.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmMode) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmDurationMinutes) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmWeekdays) { _ in model.applySmartAlarm() }
        }
    }

    @ViewBuilder private var alarmRuntimeStatus: some View {
        switch model.smartAlarmRuntimeState {
        case .off:
            EmptyView()
        case .fixed(let date):
            Label(
                String(localized: "Next wrist buzz \(date.formatted(date: .omitted, time: .shortened))"),
                systemImage: "checkmark.circle.fill"
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.statusPositive)
        case .waitingForSleep:
            Label("Waiting for fresh detected sleep", systemImage: "moon.zzz")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        case .durationScheduled(let fireDate, let asleepMinutes, let targetMinutes):
            Label(
                String(localized: "\(durationLabel(asleepMinutes)) of \(durationLabel(targetMinutes)) detected · projected \(fireDate.formatted(date: .omitted, time: .shortened))"),
                systemImage: "waveform.path.ecg"
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.restBright)
        case .durationReached(let asleepMinutes, let targetMinutes):
            Label(
                String(localized: "Sleep target reached · \(durationLabel(min(asleepMinutes, targetMinutes)))"),
                systemImage: "checkmark.circle.fill"
            )
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.statusPositive)
        }
    }

    private var windDownCard: some View {
        // Rest-tinted when armed so the active state reads in the sleep world; neutral when off.
        StrandCard(padding: 20, tint: windDownOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Evening").strandOverline()
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(StrandPalette.restColor)
                            .accessibilityHidden(true)
                        Text("Wind-down nudge")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me to wind down")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("A gentle notification at your planned wind-down time.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $windDownOn)
                        .labelsHidden().toggleStyle(.noopSwitch)
                        .accessibilityLabel("Remind me to wind down")
                        .onChangeCompat(of: windDownOn) { on in
                            WindDownNudge.setEnabled(on) { outcome in
                                switch outcome {
                                case .scheduled:
                                    windDownOn = true
                                case .denied:
                                    windDownOn = false
                                    showNotifDeniedAlert = true
                                case .failed, .off:
                                    windDownOn = false
                                }
                            }
                        }
                }
                .frame(minHeight: 42)

                Divider().overlay(StrandPalette.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    Text("appwide.sleep.tonights_goal")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    SegmentedPillControl(
                        SleepGoalMode.allCases,
                        selection: $sleepGoalMode,
                        label: sleepGoalLabel
                    )
                    Text(sleepGoalHelp(sleepGoalMode))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChangeCompat(of: sleepGoalMode) { mode in
                    WindDownNudge.setGoalMode(mode)
                }

                Divider().overlay(StrandPalette.hairline)
                plannerValueRow(
                    title: "Sleep target",
                    help: "Your baseline opportunity before any small recent-balance addition.",
                    value: durationLabel(sleepTargetMinutes),
                    decrementEnabled: sleepTargetMinutes > SleepPlanner.minimumSleepMinutes,
                    incrementEnabled: sleepTargetMinutes < SleepPlanner.maximumSleepMinutes,
                    decrementLabel: "Reduce sleep target by 15 minutes",
                    incrementLabel: "Increase sleep target by 15 minutes",
                    onDecrement: {
                        sleepTargetMinutes = max(
                            SleepPlanner.minimumSleepMinutes,
                            sleepTargetMinutes - 15
                        )
                        WindDownNudge.setSleepNeedMinutes(sleepTargetMinutes)
                        if behavior.smartAlarmMode == .adaptiveSleep { model.applySmartAlarm() }
                    },
                    onIncrement: {
                        sleepTargetMinutes = min(
                            SleepPlanner.maximumSleepMinutes,
                            sleepTargetMinutes + 15
                        )
                        WindDownNudge.setSleepNeedMinutes(sleepTargetMinutes)
                        if behavior.smartAlarmMode == .adaptiveSleep { model.applySmartAlarm() }
                    }
                )

                Divider().overlay(StrandPalette.hairline)
                plannerValueRow(
                    title: "Wind-down buffer",
                    help: "Time to settle before the suggested bedtime.",
                    value: durationLabel(windDownLeadMinutes),
                    decrementEnabled: windDownLeadMinutes > 0,
                    incrementEnabled: windDownLeadMinutes < 120,
                    decrementLabel: "Reduce wind-down buffer by 15 minutes",
                    incrementLabel: "Increase wind-down buffer by 15 minutes",
                    onDecrement: {
                        windDownLeadMinutes = max(0, windDownLeadMinutes - 15)
                        WindDownNudge.setLeadMinutes(windDownLeadMinutes)
                    },
                    onIncrement: {
                        windDownLeadMinutes = min(120, windDownLeadMinutes + 15)
                        WindDownNudge.setLeadMinutes(windDownLeadMinutes)
                    }
                )

                Divider().overlay(StrandPalette.hairline)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Planner wake time")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Bedtime and wind-down count backward from this time.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    DatePicker("", selection: wakeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityLabel("Planner wake time")
                }
                if behavior.smartAlarmEnabled && behavior.smartAlarmMinutes != wakeMinutes {
                    Button("Use Noop Band alarm time") {
                        wakeMinutes = behavior.smartAlarmMinutes
                        WindDownNudge.setWakeMinutes(wakeMinutes)
                    }
                    .font(StrandFont.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHint("Aligns the sleep plan with the separate Noop Band wake alarm")
                }

                Text(sleepPlan.recoveryMinutes > 0
                     ? String(
                        format: String(localized: "appwide.sleep.recovery.added_format"),
                        durationLabel(sleepPlan.recoveryMinutes)
                     )
                     : String(localized: "appwide.sleep.recovery.none"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if windDownOn {
                    Text(
                        String(
                            format: String(localized: "appwide.sleep.reminder.around_format"),
                            timeLabel(sleepPlan.windDownMinute)
                        )
                    )
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                Divider().overlay(StrandPalette.hairline)
                perDaySection
            }
        }
    }

    // PR#554 — per-day wake overrides. A toggle reveals a per-weekday wake-time editor; with it off (or no
    // override set) every evening uses the single wake time above. Each weekday row shows the effective wake
    // (override or the default) and lets the user set or clear that day's time.
    @ViewBuilder private var perDaySection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Different wake time per day")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Override only the days you choose.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $perDayOn)
                .labelsHidden().toggleStyle(.noopSwitch)
                .accessibilityLabel("Different wake time per day")
                .accessibilityIdentifier("noop.sleep-planner.per-day")
                .onChangeCompat(of: perDayOn) { on in
                    // Turning the section OFF clears every override (so the nudge reverts to the single time);
                    // turning it ON just reveals the editor — no override is created until the user sets one.
                    if !on {
                        for weekday in 1...7 { WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil) }
                        overrides = [:]
                    }
                }
        }
        .frame(minHeight: 42)

        if perDayOn {
            VStack(spacing: 8) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    weekdayOverrideRow(weekday)
                }
            }
            .padding(.top, 4)
        }
    }

    /// One weekday's override row: the day name, the effective wake time (override or default), a picker to
    /// set it, and a clear control shown only when an override exists for that day.
    private func weekdayOverrideRow(_ weekday: Int) -> some View {
        let effective = overrides[weekday] ?? wakeMinutes
        let hasOverride = overrides[weekday] != nil
        return HStack(spacing: 12) {
            Text(Self.weekdayName(weekday))
                .font(StrandFont.subhead)
                .foregroundStyle(hasOverride ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(width: 96, alignment: .leading)
            Spacer(minLength: 0)
            if hasOverride {
                Button {
                    WindDownNudge.setWakeOverride(weekday: weekday, minutes: nil)
                    overrides[weekday] = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(Self.weekdayName(weekday)) override, use the default wake time")
            }
            DatePicker("", selection: overrideBinding(weekday, effective: effective),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .accessibilityLabel("\(Self.weekdayName(weekday)) wake time")
                .accessibilityIdentifier("noop.sleep-planner.wake.\(weekday)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noop.sleep-planner.wake-row.\(weekday)")
    }

    /// A binding for one weekday's wake override — reads the effective minute, writes a NEW override (a pick
    /// always sets that day's override) into both the store and the local mirror, rescheduling via the store.
    private func overrideBinding(_ weekday: Int, effective: Int) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = effective / 60
                c.minute = effective % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                WindDownNudge.setWakeOverride(weekday: weekday, minutes: m)
                overrides[weekday] = m
            }
        )
    }

    /// Full weekday name for a Calendar weekday number (1=Sun…7=Sat).
    private static func weekdayName(_ dow: Int) -> String {
        let names = [String(localized: "Sunday"), String(localized: "Monday"), String(localized: "Tuesday"),
                     String(localized: "Wednesday"), String(localized: "Thursday"), String(localized: "Friday"),
                     String(localized: "Saturday")]
        return (1...7).contains(dow) ? names[dow - 1] : String(localized: "Day \(dow)")
    }

    // Bridges the minutes-since-midnight store to a DatePicker's Date, persisting + rescheduling.
    private var wakeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = wakeMinutes / 60
                c.minute = wakeMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                wakeMinutes = m
                WindDownNudge.setWakeMinutes(m)
            }
        )
    }

    private func plannerValueRow(
        title: LocalizedStringKey,
        help: LocalizedStringKey,
        value: String,
        decrementEnabled: Bool,
        incrementEnabled: Bool,
        decrementLabel: String,
        incrementLabel: String,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    plannerStepButton(
                        systemName: "minus",
                        enabled: decrementEnabled,
                        accessibilityLabel: decrementLabel,
                        action: onDecrement
                    )
                    Text(value)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 58)
                        .accessibilityLabel(value)
                    plannerStepButton(
                        systemName: "plus",
                        enabled: incrementEnabled,
                        accessibilityLabel: incrementLabel,
                        action: onIncrement
                    )
                }
            }
            Text(help)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44)
    }

    private func plannerStepButton(
        systemName: String,
        enabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: 32, height: 32)
                .background(StrandPalette.surfaceInset, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func timeLabel(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func durationLabel(_ minutes: Int) -> String {
        let safe = max(minutes, 0)
        let hours = safe / 60
        let remainder = safe % 60
        if hours == 0 { return String(localized: "\(remainder)m") }
        if remainder == 0 { return String(localized: "\(hours)h") }
        return String(localized: "\(hours)h \(remainder)m")
    }

    // MARK: - Strap alarm weekday picker (#766, moved here from Automations, behaviour intact)

    private var alarmWeekdayPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { dow in
                    let selected = Self.alarmWeekdayIsSelected(dow, in: behavior.smartAlarmWeekdays)
                    Text(Self.alarmWeekdayInitial(dow))
                        .font(StrandFont.caption)
                        .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Circle())
                        .contentShape(Circle())
                        .onTapGesture { behavior.smartAlarmWeekdays = Self.alarmToggledWeekday(dow, in: behavior.smartAlarmWeekdays) }
                        .accessibilityLabel(Self.weekdayName(dow))
                        .accessibilityIdentifier("noop.sleep-planner.weekday.\(dow)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text(Self.alarmWeekdaySummary(behavior.smartAlarmWeekdays))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityIdentifier("noop.sleep-planner.weekday-summary")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Bridges the strap alarm's minutes-since-midnight store to a DatePicker's Date.
    private var alarmTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = behavior.smartAlarmMinutes / 60
                c.minute = behavior.smartAlarmMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                behavior.smartAlarmMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            }
        )
    }

    // The strap-alarm weekday rules: pure + nonisolated so they stay unit-testable. Kept byte-identical
    // to the originals in AutomationsView (only renamed with an `alarm` prefix to avoid colliding with
    // this view's full-name `weekdayName`).

    /// A day reads as "on" when the set is empty (= every day) or explicitly contains it.
    nonisolated static func alarmWeekdayIsSelected(_ dow: Int, in days: Set<Int>) -> Bool {
        days.isEmpty || days.contains(dow)
    }

    /// Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
    nonisolated static func alarmToggledWeekday(_ dow: Int, in days: Set<Int>) -> Set<Int> {
        var next: Set<Int>
        if days.isEmpty {
            next = Set(1...7)
            next.remove(dow)
        } else if days.contains(dow) {
            next = days
            next.remove(dow)
        } else {
            next = days
            next.insert(dow)
        }
        return next.count == 7 ? [] : next
    }

    /// Human-readable summary of the selection.
    nonisolated static func alarmWeekdaySummary(_ days: Set<Int>) -> String {
        if days.isEmpty || days.count == 7 { return String(localized: "Every day") }
        if days == Set(2...6) { return String(localized: "Weekdays") }
        if days == Set([1, 7]) { return String(localized: "Weekends") }
        return weekdayOrder.filter { days.contains($0) }.map { alarmWeekdayShort($0) }.joined(separator: ", ")
    }

    /// One-letter day chip. Derived from the localized short name so the initials follow the
    /// language (and Tue/Thu or Sat/Sun never share a single collision-prone key). English output
    /// is byte-identical to the old hardcoded initials.
    private static func alarmWeekdayInitial(_ dow: Int) -> String {
        let short = alarmWeekdayShort(dow)
        return short == "?" ? "?" : String(short.prefix(1))
    }

    nonisolated private static func alarmWeekdayShort(_ dow: Int) -> String {
        switch dow {
        case 1: return String(localized: "Sun")
        case 2: return String(localized: "Mon")
        case 3: return String(localized: "Tue")
        case 4: return String(localized: "Wed")
        case 5: return String(localized: "Thu")
        case 6: return String(localized: "Fri")
        case 7: return String(localized: "Sat")
        default: return "?"
        }
    }
}
