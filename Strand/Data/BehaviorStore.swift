import Foundation
import Combine
import StrandAnalytics

enum SmartAlarmMode: String, CaseIterable, Identifiable, Sendable {
    case wakeTime
    case sleepDuration
    case adaptiveSleep

    var id: String { rawValue }
    var usesDetectedSleep: Bool { self != .wakeTime }
}

/// Settings for the strap's physical inputs and the Mac/coaching automations built on top of the
/// live event + biometric stream. UserDefaults-backed (single-user, on-device).
@MainActor
final class BehaviorStore: ObservableObject {
    nonisolated static let zoneCoachingKey = "behavior.zoneCoaching"

    // MARK: Double-tap → Mac action
    @Published var doubleTapAction: MacActionKind { didSet { d.set(doubleTapAction.rawValue, forKey: K.dtAction) } }
    @Published var doubleTapShortcut: String { didSet { d.set(doubleTapShortcut, forKey: K.dtShortcut) } }

    // MARK: Wear automation
    /// Lock the Mac when the strap comes off the wrist.
    @Published var autoLockOnWristOff: Bool { didSet { d.set(autoLockOnWristOff, forKey: K.autoLock) } }
    /// Run a Shortcut when the strap comes off (presence automation: Focus, pause media, set away…).
    @Published var wristOffShortcut: String { didSet { d.set(wristOffShortcut, forKey: K.wristOffShortcut) } }
    /// Run a Shortcut when the strap goes back on the wrist.
    @Published var wristOnShortcut: String { didSet { d.set(wristOnShortcut, forKey: K.wristOnShortcut) } }

    // MARK: Sustained workout-exertion guidance
    @Published var zoneCoaching: Bool { didSet { d.set(zoneCoaching, forKey: K.zoneCoaching) } }

    // MARK: Haptic biofeedback — Stress check-ins (L3)
    //
    // Defaults remain OFF (opt-in, manual-first). These MIRROR the keys `BiofeedbackPrefs` reads/writes.
    // The detector still fails closed unless the current event has fresh R-R, HR, worn/encrypted state,
    // and dense timestamp-matched wrist motion from the wearable.
    @Published var stressCheckIn: Bool { didSet { d.set(stressCheckIn, forKey: K.stressCheckIn) } }
    @Published var stressAutoNudge: Bool { didSet { d.set(stressAutoNudge, forKey: K.stressAutoNudge) } }
    @Published var stressPhoneNudge: Bool { didSet { d.set(stressPhoneNudge, forKey: K.stressPhoneNudge) } }
    @Published var stressQuietHours: Bool { didSet { d.set(stressQuietHours, forKey: K.stressQuietHours) } }
    @Published var stressUseResonancePace: Bool { didSet { d.set(stressUseResonancePace, forKey: K.stressUseResonance) } }

    /// Presentation helper only. The persisted preference never counts as active unless the live source
    /// can provide the wrist-motion evidence required by `BiofeedbackPrefs`.
    var automaticStressNudgeEffective: Bool {
        BiofeedbackPrefs.automaticStressNudgesAvailable && stressCheckIn && stressAutoNudge
    }

    // MARK: Smart alarm
    @Published var smartAlarmEnabled: Bool { didSet { d.set(smartAlarmEnabled, forKey: K.alarmOn) } }
    /// Target wake time, minutes since local midnight.
    @Published var smartAlarmMinutes: Int { didSet { d.set(smartAlarmMinutes, forKey: K.alarmTime) } }
    /// Weekdays the alarm fires on (Calendar weekday numbers: 1 = Sun … 7 = Sat). An empty set means
    /// "every day" - the backward-compatible default for anyone upgrading from before per-day scheduling.
    @Published var smartAlarmWeekdays: Set<Int> { didSet { d.set(Array(smartAlarmWeekdays).sorted(), forKey: K.alarmWeekdays) } }
    /// Fixed local wake time or a target amount of detected sleep. Existing installs default to the
    /// fixed-time behavior they already configured.
    @Published var smartAlarmMode: SmartAlarmMode {
        didSet { d.set(smartAlarmMode.rawValue, forKey: K.alarmMode) }
    }
    /// Target detected asleep time for duration mode. The UI and runtime clamp this to 4...12 hours.
    @Published var smartAlarmDurationMinutes: Int {
        didSet { d.set(smartAlarmDurationMinutes, forKey: K.alarmDuration) }
    }
    /// Durable one-fire guard for duration mode. A fresh detected session has a new onset and can fire;
    /// repeated sync/analysis passes for the same session cannot buzz again.
    @Published var smartAlarmLastFiredSessionStart: Int {
        didSet { d.set(smartAlarmLastFiredSessionStart, forKey: K.alarmLastFiredSession) }
    }
    /// Session currently represented by the firmware's one-shot duration alarm. Persisting the onset
    /// lets a later strap-fired callback close the same session without scheduling a second wake.
    var smartAlarmArmedSessionStart: Int {
        didSet { d.set(smartAlarmArmedSessionStart, forKey: K.alarmArmedSession) }
    }

    // MARK: Illness early-warning
    @Published var illnessWatch: Bool { didSet { d.set(illnessWatch, forKey: K.illness) } }

    // MARK: Strap battery alerts
    /// Notify on low strap battery (≤15%) and full charge (100%). Default ON (#368).
    @Published var batteryAlerts: Bool { didSet { d.set(batteryAlerts, forKey: K.batteryAlerts) } }
    /// Predictive "recharge tonight" warning at ~24h of estimated runtime left. Sub-gate under
    /// batteryAlerts (both must be on). Default ON so pre-toggle behavior is unchanged.
    @Published var batteryPredictiveAlerts: Bool { didSet { d.set(batteryPredictiveAlerts, forKey: K.batteryPredictiveAlerts) } }

    // MARK: Strain target nudge (#593)
    /// Once-a-day informational nudge when the day's Effort reaches the evidence-gated personal marker.
    /// It is not presented as an optimum, a limit, or permission to keep pushing. Default OFF.
    @Published var strainTargetNudge: Bool { didSet { d.set(strainTargetNudge, forKey: K.strainTargetNudge) } }

    private let d = UserDefaults.standard
    /// Stable cross-platform keys/read vocabulary for the same-day Daily Action self-check. The answer
    /// is intentionally day-scoped: a prior day's response never unlocks a new day's planning range.
    static let dailyActionCheckInDayKey = "behavior.dailyActionCheckIn.day"
    static let dailyActionCheckInValueKey = "behavior.dailyActionCheckIn.value"

    private enum K {
        static let dtAction = "behavior.doubleTapAction"
        static let dtShortcut = "behavior.doubleTapShortcut"
        static let autoLock = "behavior.autoLockOnWristOff"
        static let wristOffShortcut = "behavior.wristOffShortcut"
        static let wristOnShortcut = "behavior.wristOnShortcut"
        static let zoneCoaching = BehaviorStore.zoneCoachingKey
        // Haptic biofeedback L3 — keys MATCH BiofeedbackPrefs (one source of truth, two readers).
        static let stressCheckIn = "biofeedback.stressCheckIn"
        static let stressAutoNudge = "biofeedback.stressAutoNudge"
        static let stressPhoneNudge = "biofeedback.stressPhoneNudge"
        static let stressQuietHours = "biofeedback.stressQuietHours"
        static let stressUseResonance = "biofeedback.stressUseResonancePace"
        static let alarmOn = "behavior.smartAlarmEnabled"
        static let alarmTime = "behavior.smartAlarmMinutes"
        static let alarmWeekdays = "behavior.smartAlarmWeekdays"
        static let alarmMode = "behavior.smartAlarmMode"
        static let alarmDuration = "behavior.smartAlarmDurationMinutes"
        static let alarmLastFiredSession = "behavior.smartAlarmLastFiredSessionStart"
        static let alarmArmedSession = "behavior.smartAlarmArmedSessionStart"
        // "behavior.smartAlarmWindow" retired: it was stored but never read (no wake-window
        // watcher ever shipped). The defaults key is left orphaned on purpose — harmless, and
        // preserved should a real light-sleep watcher ever land.
        static let illness = "behavior.illnessWatch"
        static let batteryAlerts = "behavior.batteryAlerts"
        static let batteryPredictiveAlerts = "behavior.batteryPredictiveAlerts"
        static let strainTargetNudge = "behavior.strainTargetNudge"
    }

    init() {
        doubleTapAction = MacActionKind(rawValue: d.string(forKey: K.dtAction) ?? "") ?? .none
        doubleTapShortcut = d.string(forKey: K.dtShortcut) ?? ""
        autoLockOnWristOff = d.object(forKey: K.autoLock) as? Bool ?? false
        wristOffShortcut = d.string(forKey: K.wristOffShortcut) ?? ""
        wristOnShortcut = d.string(forKey: K.wristOnShortcut) ?? ""
        zoneCoaching = d.object(forKey: K.zoneCoaching) as? Bool ?? false
        stressCheckIn = d.object(forKey: K.stressCheckIn) as? Bool ?? false
        stressAutoNudge = d.object(forKey: K.stressAutoNudge) as? Bool ?? false
        stressPhoneNudge = d.object(forKey: K.stressPhoneNudge) as? Bool ?? false
        stressQuietHours = d.object(forKey: K.stressQuietHours) as? Bool ?? true
        stressUseResonancePace = d.object(forKey: K.stressUseResonance) as? Bool ?? true
        smartAlarmEnabled = d.object(forKey: K.alarmOn) as? Bool ?? false
        smartAlarmMinutes = d.object(forKey: K.alarmTime) as? Int ?? 7 * 60       // 07:00
        // Stored as a plain [Int]; only valid weekday numbers (1…7) are kept so a corrupted defaults
        // entry can never schedule against a bogus day. Empty (or all 7) = every day.
        smartAlarmWeekdays = Set((d.array(forKey: K.alarmWeekdays) as? [Int] ?? []).filter { (1...7).contains($0) })
        smartAlarmMode = SmartAlarmMode(rawValue: d.string(forKey: K.alarmMode) ?? "") ?? .wakeTime
        smartAlarmDurationMinutes = min(
            max(d.object(forKey: K.alarmDuration) as? Int ?? 8 * 60, 4 * 60),
            12 * 60
        )
        smartAlarmLastFiredSessionStart = max(
            d.object(forKey: K.alarmLastFiredSession) as? Int ?? 0,
            0
        )
        smartAlarmArmedSessionStart = max(
            d.object(forKey: K.alarmArmedSession) as? Int ?? 0,
            0
        )
        illnessWatch = d.object(forKey: K.illness) as? Bool ?? false
        batteryAlerts = d.object(forKey: K.batteryAlerts) as? Bool ?? true
        batteryPredictiveAlerts = d.object(forKey: K.batteryPredictiveAlerts) as? Bool ?? true
        strainTargetNudge = d.object(forKey: K.strainTargetNudge) as? Bool ?? false
    }

    // MARK: Daily Action self-check

    nonisolated static func decodeDailyActionCheckIn(
        today: String,
        storedDay: String?,
        storedValue: String?
    ) -> DailyActionPlanner.CheckIn {
        guard storedDay == today,
              let storedValue,
              let value = DailyActionPlanner.CheckIn(rawValue: storedValue) else {
            return .unanswered
        }
        return value
    }

    func dailyActionCheckIn(for day: String) -> DailyActionPlanner.CheckIn {
        Self.decodeDailyActionCheckIn(
            today: day,
            storedDay: d.string(forKey: Self.dailyActionCheckInDayKey),
            storedValue: d.string(forKey: Self.dailyActionCheckInValueKey)
        )
    }

    func setDailyActionCheckIn(_ value: DailyActionPlanner.CheckIn, for day: String) {
        d.set(day, forKey: Self.dailyActionCheckInDayKey)
        d.set(value.rawValue, forKey: Self.dailyActionCheckInValueKey)
        ContextualInterventionInputs.notifyChanged()
    }

    // MARK: Charge baseline recalibration

    /// Epoch SECONDS the Charge build-up was last manually reset from, or 0 if never. Reads the SAME
    /// canonical key the analytics engine folds against (`Baselines.recoveryBaselineEpochKey`) — no
    /// second source of truth. The "Recalibrate Charge baseline" Settings button writes it (and the
    /// sibling HRV epoch) via `recalibrateChargeBaseline()`.
    var chargeBaselineEpoch: Double { Baselines.recoveryBaselineEpoch(d) }

    /// True once the user has manually recalibrated their Charge baseline. Lets a surface (e.g. the
    /// Today "building" hint) explain WHY the score is calibrating again - an honest "you reset it",
    /// not a silent cold-start.
    var didRecalibrateCharge: Bool { chargeBaselineEpoch > 0 }

    /// Restart the ~4-night Charge build-up from `now`: re-anchor every baseline that feeds Charge
    /// (HRV plus resting HR / respiration / skin temp) WITHOUT deleting any stored day. Delegates to
    /// the single cross-platform source of truth so iOS, macOS and the Android twin stay in lockstep.
    /// After calling this the next baseline computation re-seeds from tonight, so Today honestly shows
    /// the calibrating/building state again. The caller is responsible for kicking a recompute + refresh.
    func recalibrateChargeBaseline(now: Double = Date().timeIntervalSince1970) {
        Baselines.recalibrateRecoveryBaselines(now: now, defaults: d)
    }
}
