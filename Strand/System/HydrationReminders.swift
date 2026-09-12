import Foundation
import UserNotifications

/// Opt-in, privacy-safe water reminders.
///
/// The OS notification schedule is the durable lane: it can present while NOOP is suspended and may
/// mirror to Apple Watch according to the user's iPhone/Watch notification settings. A WHOOP buzz is a
/// separate best-effort lane. `AppModel` claims a due slot only while fresh live packets prove that the
/// encrypted strap connection is active; this file deliberately makes no background-delivery promise.
@MainActor
enum HydrationReminders {
    static let enabledKey = "hydrationReminders.enabled"
    static let intervalMinutesKey = "hydrationReminders.intervalMinutes"
    static let activeStartMinutesKey = "hydrationReminders.activeStartMinutes"
    static let activeEndMinutesKey = "hydrationReminders.activeEndMinutes"
    static let strapBuzzEnabledKey = "hydrationReminders.strapBuzzEnabled"
    static let adaptiveEnabledKey = "hydrationReminders.adaptiveEnabled"
    static let doubleTapConfirmEnabledKey = "hydrationReminders.doubleTapConfirmEnabled"
    static let doubleTapAmountMLKey = "hydrationReminders.doubleTapAmountML"
    static let doubleTapWindowMinutesKey = "hydrationReminders.doubleTapWindowMinutes"
    static let bandFirstEnabledKey = "hydrationReminders.bandFirstEnabled"
    /// One-time boundary between the legacy combined reminder switch and the independent phone/wrist
    /// channels. An old hidden wrist flag must never become active merely because the app was updated.
    static let independentChannelsMigrationKey = "hydrationReminders.independentChannels.v1"

    private static let scheduledRequestIDsKey = "hydrationReminders.scheduledRequestIDs"
    private static let lastClaimedStrapSlotKey = "hydrationReminders.lastClaimedStrapSlot"
    private static let lastConfirmedStrapSlotKey = "hydrationReminders.lastConfirmedStrapSlot"
    private static let pendingEscalationSlotKey = "hydrationReminders.pendingEscalationSlot"
    private static let requestIDPrefix = "hydration-reminder-"
    private static let missedResponseRequestID = "hydration-reminder-missed-response"
    private static let adaptiveIntervalKey = "hydrationReminders.adaptiveIntervalMinutes"
    private static let adaptiveReasonKey = "hydrationReminders.adaptiveReason"
    private static let adaptiveDayKey = "hydrationReminders.adaptiveDay"
    private static let masterWristAlertsKey = "notif.masterEnabled"
    private static let quietHoursEnabledKey = "notif.quietHoursEnabled"
    private static let quietStartMinutesKey = "notif.quietStartMinutes"
    private static let quietEndMinutesKey = "notif.quietEndMinutes"
    private static let minimumIntervalMinutes = 60
    private static let maximumIntervalMinutes = 240
    private static var scheduleGeneration: UInt64 = 0
    private static var missedResponseGeneration: UInt64 = 0

    enum EnableOutcome: Equatable, Sendable {
        case scheduled
        case denied
        case off
    }

    struct ReminderSpec: Equatable, Sendable {
        let identifier: String
        let minuteOfDay: Int
        let title: String
        let body: String
        let route: NoopNotificationRoute
    }

    struct DueSlot: Equatable, Sendable {
        let minuteOfDay: Int
        /// Local calendar day on which this exact occurrence began (`yyyy-MM-dd`).
        let localDay: String

        var token: String { "\(localDay)-\(minuteOfDay)" }
    }

    struct AdaptiveContext: Equatable, Sendable {
        let temperatureC: Double?
        let effort: Double?
        let consumedML: Double?
        let goalML: Int?
        let minuteOfDay: Int
    }

    struct AdaptivePlan: Equatable, Sendable {
        let intervalMinutes: Int
        let reasons: [String]
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var intervalMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: intervalMinutesKey) as? Int ?? 120
        return clampedInterval(raw)
    }

    static var activeStartMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: activeStartMinutesKey) as? Int ?? 8 * 60
        return DailyReviewNotifications.clampMinute(raw)
    }

    static var activeEndMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: activeEndMinutesKey) as? Int ?? 21 * 60
        return DailyReviewNotifications.clampMinute(raw)
    }

    static var strapBuzzEnabled: Bool {
        UserDefaults.standard.bool(forKey: strapBuzzEnabledKey)
    }

    static var adaptiveEnabled: Bool {
        UserDefaults.standard.object(forKey: adaptiveEnabledKey) as? Bool ?? true
    }

    static var doubleTapConfirmEnabled: Bool {
        UserDefaults.standard.bool(forKey: doubleTapConfirmEnabledKey)
    }

    static var doubleTapAmountML: Int {
        let raw = UserDefaults.standard.object(forKey: doubleTapAmountMLKey) as? Int ?? 250
        return min(max(raw, 50), 1_000)
    }

    static var doubleTapWindowMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: doubleTapWindowMinutesKey) as? Int ?? 10
        return min(max(raw, 5), 30)
    }

    static var bandFirstEnabled: Bool {
        UserDefaults.standard.bool(forKey: bandFirstEnabledKey)
            && strapBuzzEnabled
            && doubleTapConfirmEnabled
    }

    /// Opens an explicit confirmation window only after NOOP issued a band-cue command. No tap means
    /// no intake is written; a later HealthKit import remains the other source of confirmed water. The
    /// optional phone escalation is tied to this exact occurrence and is cancelled only after its log.
    static func armDoubleTapConfirmation(for slot: DueSlot, now: Date = Date()) {
        guard doubleTapConfirmEnabled else { return }
        TapAutomationStore.arm(
            PendingTapAutomation(
                kind: .hydrationConfirm,
                value: doubleTapAmountML,
                contextKey: slot.token,
                now: now,
                windowMinutes: doubleTapWindowMinutes
            ),
            now: now
        )
        if bandFirstEnabled, isEnabled {
            scheduleMissedResponse(for: slot)
        }
    }

    static func markDoubleTapConfirmed(contextKey: String?) {
        guard let contextKey, !contextKey.isEmpty else { return }
        let defaults = UserDefaults.standard
        defaults.set(contextKey, forKey: lastConfirmedStrapSlotKey)
        guard defaults.string(forKey: pendingEscalationSlotKey) == contextKey else { return }
        cancelMissedResponse()
    }

    static var effectiveIntervalMinutes: Int {
        guard adaptiveEnabled,
              UserDefaults.standard.string(forKey: adaptiveDayKey) == Repository.localDayKey(Date())
        else { return intervalMinutes }
        let stored = UserDefaults.standard.object(forKey: adaptiveIntervalKey) as? Int ?? intervalMinutes
        return clampedInterval(stored)
    }

    static var adaptiveSummary: String {
        guard adaptiveEnabled else { return String(localized: "Uses your fixed base interval.") }
        let reason = UserDefaults.standard.string(forKey: adaptiveReasonKey) ?? ""
        if reason.isEmpty || effectiveIntervalMinutes == intervalMinutes {
            return String(localized: "Using your \(intervalMinutes)-minute base interval today.")
        }
        return String(localized: "Every \(effectiveIntervalMinutes) minutes today · \(reason)")
    }

    static var contextualActionEvidence: [String] {
        var evidence = [String(localized: "Scheduled hydration check-in")]
        let reason = UserDefaults.standard.string(forKey: adaptiveReasonKey) ?? ""
        if !reason.isEmpty {
            evidence.append(reason)
        }
        return evidence
    }

    /// Preserve an explicitly active legacy pair, but clear a dormant hidden wrist flag when the old
    /// master reminder was OFF. From this build onward each channel persists independently.
    static func migrateIndependentChannelsIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: independentChannelsMigrationKey) else { return }
        if !defaults.bool(forKey: enabledKey) {
            defaults.set(false, forKey: strapBuzzEnabledKey)
            defaults.removeObject(forKey: lastClaimedStrapSlotKey)
        }
        defaults.set(true, forKey: independentChannelsMigrationKey)
    }

    static func setEnabled(
        _ on: Bool,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        guard on else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            removeScheduledRequests()
            cancelMissedResponse()
            completion?(.off)
            return
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                await enableAndSchedule(
                    generation: generation,
                    center: center,
                    completion: completion
                )
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                if granted {
                    await enableAndSchedule(
                        generation: generation,
                        center: center,
                        completion: completion
                    )
                } else {
                    guard generation == scheduleGeneration else { return }
                    UserDefaults.standard.set(false, forKey: enabledKey)
                    recordSuppressedRequests()
                    completion?(.denied)
                }
            default:
                guard generation == scheduleGeneration else { return }
                UserDefaults.standard.set(false, forKey: enabledKey)
                recordSuppressedRequests()
                completion?(.denied)
            }
        }
    }

    static func setIntervalMinutes(_ minutes: Int) {
        UserDefaults.standard.set(clampedInterval(minutes), forKey: intervalMinutesKey)
        if adaptiveEnabled {
            UserDefaults.standard.set(clampedInterval(minutes), forKey: adaptiveIntervalKey)
            UserDefaults.standard.removeObject(forKey: adaptiveReasonKey)
        }
        if isEnabled { requestReschedule() }
    }

    static func setAdaptiveEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: adaptiveEnabledKey)
        if !on {
            UserDefaults.standard.removeObject(forKey: adaptiveIntervalKey)
            UserDefaults.standard.removeObject(forKey: adaptiveReasonKey)
            UserDefaults.standard.removeObject(forKey: adaptiveDayKey)
        }
        if isEnabled { requestReschedule() }
    }

    static func updateAdaptiveContext(
        temperatureC: Double?,
        effort: Double?,
        consumedML: Double?,
        goalML: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard adaptiveEnabled else { return }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let context = AdaptiveContext(
            temperatureC: temperatureC,
            effort: effort,
            consumedML: consumedML,
            goalML: goalML,
            minuteOfDay: (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        )
        let plan = adaptivePlan(
            baseInterval: intervalMinutes,
            start: activeStartMinutes,
            end: activeEndMinutes,
            context: context
        )
        let defaults = UserDefaults.standard
        let dayKey = Repository.localDayKey(now)
        let previousDay = defaults.string(forKey: adaptiveDayKey)
        let previous = effectiveIntervalMinutes
        defaults.set(plan.intervalMinutes, forKey: adaptiveIntervalKey)
        defaults.set(plan.reasons.joined(separator: " + "), forKey: adaptiveReasonKey)
        defaults.set(dayKey, forKey: adaptiveDayKey)
        if isEnabled, previousDay != dayKey || previous != plan.intervalMinutes {
            requestReschedule()
        }
    }

    static func adaptivePlan(
        baseInterval: Int,
        start: Int,
        end: Int,
        context: AdaptiveContext
    ) -> AdaptivePlan {
        var adjustment = 0
        var reasons: [String] = []

        if let temperature = context.temperatureC, temperature.isFinite {
            if temperature >= 30 {
                adjustment -= 30
                reasons.append(String(localized: "hot weather"))
            } else if temperature >= 24 {
                adjustment -= 15
                reasons.append(String(localized: "warm weather"))
            }
        }
        if let effort = context.effort, effort.isFinite {
            if effort >= 70 {
                adjustment -= 30
                reasons.append(String(localized: "higher Effort"))
            } else if effort >= 40 {
                adjustment -= 15
                reasons.append(String(localized: "active day"))
            }
        }

        let start = DailyReviewNotifications.clampMinute(start)
        let end = DailyReviewNotifications.clampMinute(end)
        let span = (end - start + 24 * 60) % (24 * 60)
        let duration = span == 0 ? 24 * 60 : span
        let elapsed = (context.minuteOfDay - start + 24 * 60) % (24 * 60)
        if elapsed < duration,
           let consumed = context.consumedML,
           let goal = context.goalML,
           consumed.isFinite,
           goal > 0 {
            let expected = Double(elapsed) / Double(duration)
            let actual = max(0, consumed) / Double(goal)
            if expected >= 0.25, actual < expected - 0.20 {
                adjustment -= 15
                reasons.append(String(localized: "behind goal"))
            } else if actual > expected + 0.25 {
                adjustment += 15
                reasons.append(String(localized: "ahead of goal"))
            }
        }

        adjustment = min(30, max(-60, adjustment))
        let stepped = Int((Double(clampedInterval(baseInterval) + adjustment) / 15.0).rounded()) * 15
        return AdaptivePlan(intervalMinutes: clampedInterval(stepped), reasons: reasons)
    }

    static func setActiveStartMinutes(_ minutes: Int) {
        UserDefaults.standard.set(DailyReviewNotifications.clampMinute(minutes), forKey: activeStartMinutesKey)
        if isEnabled { requestReschedule() }
    }

    static func setActiveEndMinutes(_ minutes: Int) {
        UserDefaults.standard.set(DailyReviewNotifications.clampMinute(minutes), forKey: activeEndMinutesKey)
        if isEnabled { requestReschedule() }
    }

    static func setStrapBuzzEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: strapBuzzEnabledKey)
        if !on {
            UserDefaults.standard.removeObject(forKey: lastClaimedStrapSlotKey)
            UserDefaults.standard.set(false, forKey: bandFirstEnabledKey)
            TapAutomationStore.clear(kind: .hydrationConfirm)
            cancelMissedResponse()
            if isEnabled { requestReschedule() }
        }
    }

    static func setDoubleTapConfirmEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: doubleTapConfirmEnabledKey)
        if !on {
            UserDefaults.standard.set(false, forKey: bandFirstEnabledKey)
            TapAutomationStore.clear(kind: .hydrationConfirm)
            cancelMissedResponse()
            if isEnabled { requestReschedule() }
        }
    }

    static func setDoubleTapAmountML(_ amountML: Int) {
        UserDefaults.standard.set(min(max(amountML, 50), 1_000), forKey: doubleTapAmountMLKey)
    }

    static func setDoubleTapWindowMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 5), 30), forKey: doubleTapWindowMinutesKey)
    }

    static func setBandFirstEnabled(_ on: Bool) {
        let enabled = on && strapBuzzEnabled && doubleTapConfirmEnabled
        UserDefaults.standard.set(enabled, forKey: bandFirstEnabledKey)
        if !enabled { cancelMissedResponse() }
        if isEnabled { requestReschedule() }
    }

    /// Rebuild pending requests after an upgrade without ever prompting for permission on launch.
    static func restoreScheduleIfAuthorized() {
        guard isEnabled else {
            removeScheduledRequests()
            return
        }
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                requestReschedule()
            default:
                recordSuppressedRequests()
                break
            }
        }
    }

    /// Daily reminder slots in a start-inclusive/end-exclusive window, including overnight windows.
    /// Equal start/end means all day, matching the Android policy and common quiet-hours semantics.
    static func reminderMinutes(start: Int, end: Int, interval: Int) -> [Int] {
        let start = DailyReviewNotifications.clampMinute(start)
        let end = DailyReviewNotifications.clampMinute(end)
        let step = clampedInterval(interval)
        let wrappedDuration = (end - start + 24 * 60) % (24 * 60)
        let duration = wrappedDuration == 0 ? 24 * 60 : wrappedDuration
        return stride(from: 0, to: duration, by: step).map { (start + $0) % (24 * 60) }
    }

    static func reminderSpecs(start: Int, end: Int, interval: Int) -> [ReminderSpec] {
        reminderMinutes(start: start, end: end, interval: interval).map { minute in
            ReminderSpec(
                identifier: requestIDPrefix + String(minute),
                minuteOfDay: minute,
                title: String(localized: "Hydration check-in"),
                body: String(localized: "Take a moment to drink some water if you need it."),
                route: .hydration
            )
        }
    }

    static func clampedInterval(_ minutes: Int) -> Int {
        min(max(minutes, minimumIntervalMinutes), maximumIntervalMinutes)
    }

    /// Shared quiet-hours semantics: inclusive start, exclusive end, with midnight wrapping. Matching
    /// start/end is an empty quiet window, consistent with Android `NotifPrefs.inQuietHours` and the
    /// existing Apple inactivity-alert policy (hydration's own matching active times still mean all day).
    static func windowContains(_ minuteOfDay: Int, start: Int, end: Int) -> Bool {
        let minute = DailyReviewNotifications.clampMinute(minuteOfDay)
        let start = DailyReviewNotifications.clampMinute(start)
        let end = DailyReviewNotifications.clampMinute(end)
        if start <= end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    /// The most recent due occurrence inside a small grace window. Kept pure for deterministic tests.
    static func dueSlot(
        now: Date,
        calendar: Calendar = .current,
        slots: [Int],
        graceMinutes: Int = 5
    ) -> DueSlot? {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let grace = max(0, graceMinutes)

        let candidates: [(slot: Int, elapsed: Int)] = slots.map { raw in
            let slot = DailyReviewNotifications.clampMinute(raw)
            return (slot, (nowMinute - slot + 24 * 60) % (24 * 60))
        }.filter { $0.elapsed <= grace }

        guard let candidate = candidates.min(by: { $0.elapsed < $1.elapsed }),
              let occurrence = calendar.date(byAdding: .minute, value: -candidate.elapsed, to: now)
        else { return nil }

        let day = calendar.dateComponents([.year, .month, .day], from: occurrence)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
        return DueSlot(
            minuteOfDay: candidate.slot,
            localDay: String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        )
    }

    /// Adaptive intervals can realign wall-clock slots. Preserve each lane's own de-duplication while
    /// preventing two strap cues inside the minimum supported interval after such a realignment.
    static func strapOccurrenceIsSeparated(
        previousToken: String?,
        due: DueSlot,
        calendar: Calendar = .current
    ) -> Bool {
        guard let previousToken else { return true }
        guard previousToken != due.token else { return false }

        func occurrence(from token: String) -> Date? {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]),
                  let minute = Int(parts[3]),
                  (0..<(24 * 60)).contains(minute)
            else { return nil }
            return calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: minute / 60,
                minute: minute % 60
            ))
        }

        guard let previous = occurrence(from: previousToken),
              let current = occurrence(from: due.token)
        else {
            return true
        }
        return current.timeIntervalSince(previous) >= TimeInterval(minimumIntervalMinutes * 60)
    }

    /// Atomically claims one live WHOOP-buzz occurrence. `AppModel` still gates the actual command on
    /// bonded + encrypted live state. This preference gate keeps the automation opt-in and de-duplicated.
    static func claimDueStrapBuzz(now: Date = Date(), calendar: Calendar = .current) -> DueSlot? {
        let defaults = UserDefaults.standard
        guard strapBuzzEnabled,
              defaults.bool(forKey: masterWristAlertsKey)
        else { return nil }

        if defaults.bool(forKey: quietHoursEnabledKey) {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            let quietStart = defaults.object(forKey: quietStartMinutesKey) as? Int ?? 22 * 60
            let quietEnd = defaults.object(forKey: quietEndMinutesKey) as? Int ?? 7 * 60
            if windowContains(nowMinute, start: quietStart, end: quietEnd) { return nil }
        }

        let slots = reminderMinutes(
            start: activeStartMinutes,
            end: activeEndMinutes,
            interval: effectiveIntervalMinutes
        )
        guard let due = dueSlot(now: now, calendar: calendar, slots: slots),
              strapOccurrenceIsSeparated(
                  previousToken: defaults.string(forKey: lastClaimedStrapSlotKey),
                  due: due,
                  calendar: calendar
              )
        else { return nil }

        defaults.set(due.token, forKey: lastClaimedStrapSlotKey)
        return due
    }

    private static var storedRequestIDs: [String] {
        UserDefaults.standard.stringArray(forKey: scheduledRequestIDsKey) ?? []
    }

    private static func removeScheduledRequests() {
        let ids = storedRequestIDs
        if !ids.isEmpty {
            LocalNotificationLifecycle.cancel(identifiers: ids)
        }
        UserDefaults.standard.removeObject(forKey: scheduledRequestIDsKey)
    }

    private static func enableAndSchedule(
        generation: UInt64,
        center: UNUserNotificationCenter,
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)?
    ) async {
        guard generation == scheduleGeneration else { return }
        DailyReviewNotifications.registerPrivacyCategory(on: center)
        let result = await reconcileSchedule(
            expectedGeneration: generation,
            client: .system(center: center)
        )
        guard generation == scheduleGeneration else { return }
        if bandFirstEnabled || (result?.activeCount ?? 0) > 0 {
            UserDefaults.standard.set(true, forKey: enabledKey)
            completion?(.scheduled)
        } else {
            UserDefaults.standard.set(false, forKey: enabledKey)
            completion?(.off)
        }
    }

    private static func requestReschedule(now: Date = Date()) {
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            DailyReviewNotifications.registerPrivacyCategory(on: center)
            let result = await reconcileSchedule(
                now: now,
                expectedGeneration: generation,
                client: .system(center: center)
            )
            guard generation == scheduleGeneration else { return }
            applyRescheduleResult(result)
        }
    }

    static func applyRescheduleResult(
        _ result: LocalNotificationReconciliationResult?
    ) {
        guard !bandFirstEnabled,
              let result,
              result.activeCount == 0 else { return }
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    @discardableResult
    static func reconcileSchedule(
        now: Date = Date(),
        calendar: Calendar = .current,
        expectedGeneration: UInt64? = nil,
        coordinator: LocalNotificationCapacityCoordinator? = nil,
        client: LocalNotificationCenterClient
    ) async -> LocalNotificationReconciliationResult? {
        let oldIDs = storedRequestIDs
        let specs = reminderSpecs(
            start: activeStartMinutes,
            end: activeEndMinutes,
            interval: effectiveIntervalMinutes
        )
        // In band-first mode the phone lane is occurrence-driven: an issued band cue schedules one delayed
        // alert, and a confirmed tap cancels it. Keeping the repeating requests here would notify even
        // after confirmation, which iOS cannot suppress per occurrence.
        guard !bandFirstEnabled else {
            for spec in specs {
                LocalNotificationLifecycle.suppressed(
                    identifier: spec.identifier,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
            }
            let result = await LocalNotificationLifecycle.reconcile(
                candidateRequests: [],
                replacingIdentifiers: Set(oldIDs),
                now: now,
                calendar: calendar,
                coordinator: coordinator,
                isStillCurrent: {
                    expectedGeneration.map { $0 == scheduleGeneration } ?? true
                },
                client: client
            )
            if let expectedGeneration,
               expectedGeneration != scheduleGeneration {
                return nil
            }
            UserDefaults.standard.removeObject(forKey: scheduledRequestIDsKey)
            return result
        }

        let requests = notificationRequests(specs: specs)
        let result = await LocalNotificationLifecycle.reconcile(
            candidateRequests: requests,
            replacingIdentifiers: Set(
                oldIDs + requests.map(\.identifier)
            ),
            now: now,
            calendar: calendar,
            coordinator: coordinator,
            isStillCurrent: {
                expectedGeneration.map { $0 == scheduleGeneration } ?? true
            },
            client: client
        )
        if let expectedGeneration,
           expectedGeneration != scheduleGeneration {
            return nil
        }
        if result.activeIdentifiers.isEmpty {
            UserDefaults.standard.removeObject(forKey: scheduledRequestIDsKey)
        } else {
            UserDefaults.standard.set(
                result.activeIdentifiers,
                forKey: scheduledRequestIDsKey
            )
        }
        return result
    }

    static func notificationRequests(
        specs: [ReminderSpec]
    ) -> [UNNotificationRequest] {
        specs.map { spec -> UNNotificationRequest in
            let content = UNMutableNotificationContent()
            content.applyProminence(.ambient)
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.hydration"
            content.userInfo = [NotificationRouteBridge.userInfoKey: spec.route.rawValue]

            var components = DateComponents()
            components.hour = spec.minuteOfDay / 60
            components.minute = spec.minuteOfDay % 60
            return UNNotificationRequest(
                identifier: spec.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: true
                )
            )
        }
    }

    private static func scheduleMissedResponse(for slot: DueSlot) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: lastConfirmedStrapSlotKey) != slot.token else { return }
        missedResponseGeneration &+= 1
        let generation = missedResponseGeneration

        let center = UNUserNotificationCenter.current()
        LocalNotificationLifecycle.cancel(
            identifiers: [missedResponseRequestID],
            on: center
        )
        DailyReviewNotifications.registerPrivacyCategory(on: center)

        let content = UNMutableNotificationContent()
        content.applyProminence(.standard)
        content.title = String(localized: "Hydration check-in")
        content.body = String(localized: "No water was logged from the band cue. Open Hydration if you drank.")
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.hydration"
        content.userInfo = [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.hydration.rawValue]

        let request = UNNotificationRequest(
                identifier: missedResponseRequestID,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(
                    timeInterval: TimeInterval(doubleTapWindowMinutes * 60),
                    repeats: false
                )
            )
        Task { @MainActor in
            let result = await LocalNotificationLifecycle.reconcile(
                candidateRequests: [request],
                replacingIdentifiers: [missedResponseRequestID],
                on: center
            )
            guard generation == missedResponseGeneration,
                  defaults.string(forKey: lastConfirmedStrapSlotKey)
                    != slot.token,
                  result.accepted(missedResponseRequestID) else {
                if result.accepted(missedResponseRequestID) {
                    LocalNotificationLifecycle.cancel(
                        identifiers: [missedResponseRequestID],
                        on: center
                    )
                }
                return
            }
            defaults.set(slot.token, forKey: pendingEscalationSlotKey)
        }
    }

    private static func cancelMissedResponse() {
        missedResponseGeneration &+= 1
        LocalNotificationLifecycle.cancel(
            identifiers: [missedResponseRequestID]
        )
        UserDefaults.standard.removeObject(forKey: pendingEscalationSlotKey)
    }

    private static func recordSuppressedRequests() {
        let identifiers = storedRequestIDs.isEmpty
            ? reminderSpecs(
                start: activeStartMinutes,
                end: activeEndMinutes,
                interval: effectiveIntervalMinutes
            ).map(\.identifier)
            : storedRequestIDs
        for identifier in identifiers {
            LocalNotificationLifecycle.suppressed(
                identifier: identifier,
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
        }
    }
}
