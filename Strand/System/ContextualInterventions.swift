import Foundation
import UserNotifications
import StrandAnalytics
import WhoopProtocol

// MARK: - Shared delivery gate

/// Restart-safe policy shared by event-driven wellness prompts.
///
/// Signal-specific engines decide whether an observation is meaningful. This layer only decides whether
/// a prompt may be delivered now: the evidence must still be fresh, the exact observation must be new,
/// its topic cooldown must have elapsed, the global anti-pileup window must be clear, and routine prompts
/// must be outside quiet hours. It never turns a wellness signal into a diagnosis or emergency.
enum ContextualInterventionKind: String, Codable, CaseIterable, Sendable {
    case stressBreathing
    case adaptiveSleepRecovery
    case adaptiveRoutineRecovery
    case adaptivePlannedWorkout
    case adaptiveTravel
    case caffeineCutoff
    case oxygenTrend
    case bodyTemperatureReview
    case vo2Trend

    var cooldown: TimeInterval {
        switch self {
        case .stressBreathing: return 4 * 60 * 60
        case .adaptiveSleepRecovery, .adaptiveRoutineRecovery, .adaptivePlannedWorkout:
            return 20 * 60 * 60
        case .adaptiveTravel: return 24 * 60 * 60
        case .caffeineCutoff: return 6 * 60 * 60
        case .oxygenTrend, .bodyTemperatureReview: return 24 * 60 * 60
        case .vo2Trend: return 21 * 24 * 60 * 60
        }
    }

    var isAdaptiveDayGuidance: Bool {
        switch self {
        case .adaptiveSleepRecovery, .adaptiveRoutineRecovery,
             .adaptivePlannedWorkout, .adaptiveTravel:
            return true
        default:
            return false
        }
    }
}

struct ContextualInterventionCandidate: Equatable, Sendable {
    let kind: ContextualInterventionKind
    let observedAt: Date
    let maximumAge: TimeInterval
    let fingerprint: String
    let title: String
    let body: String
    let route: NoopNotificationRoute
    var evidence: [String] = []
    var respectsQuietHours = true
}

struct ContextualInterventionState: Codable, Equatable, Sendable {
    struct Delivery: Codable, Equatable, Sendable {
        let at: Date
        let fingerprint: String
    }

    var lastGlobalDelivery: Date?
    var deliveries: [String: Delivery]

    static let empty = ContextualInterventionState(lastGlobalDelivery: nil, deliveries: [:])
}

enum ContextualInterventionDecisionReason: Equatable, Sendable {
    case deliver
    case stale
    case duplicate
    case topicCooldown
    case globalCooldown
    case quietHours
}

struct ContextualInterventionDecision: Equatable, Sendable {
    let shouldDeliver: Bool
    let reason: ContextualInterventionDecisionReason
    let nextState: ContextualInterventionState
}

enum ContextualInterventionPolicy {
    static let globalCooldown: TimeInterval = 30 * 60

    static func evaluate(
        _ candidate: ContextualInterventionCandidate,
        state: ContextualInterventionState,
        now: Date,
        quietHoursEnabled: Bool,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
        calendar: Calendar = .current
    ) -> ContextualInterventionDecision {
        let age = now.timeIntervalSince(candidate.observedAt)
        guard age >= -5 * 60, age <= candidate.maximumAge else {
            return .init(shouldDeliver: false, reason: .stale, nextState: state)
        }

        let key = candidate.kind.rawValue
        if let prior = state.deliveries[key] {
            guard prior.fingerprint != candidate.fingerprint else {
                return .init(shouldDeliver: false, reason: .duplicate, nextState: state)
            }
            guard now.timeIntervalSince(prior.at) >= candidate.kind.cooldown else {
                return .init(shouldDeliver: false, reason: .topicCooldown, nextState: state)
            }
        }

        // A stronger adaptive prompt already covers the weaker same-day guidance. Travel blocks
        // routine and short-sleep follow-ups; a routine-recovery prompt also blocks a later generic
        // short-sleep prompt. A new travel observation can still supersede either lower-priority topic.
        for blocker in adaptivePriorityBlockers(for: candidate.kind) {
            if let prior = state.deliveries[blocker.rawValue],
               now.timeIntervalSince(prior.at) < 20 * 60 * 60 {
                return .init(shouldDeliver: false, reason: .topicCooldown, nextState: state)
            }
        }

        if let last = state.lastGlobalDelivery,
           now.timeIntervalSince(last) < globalCooldown {
            return .init(shouldDeliver: false, reason: .globalCooldown, nextState: state)
        }

        if candidate.respectsQuietHours, quietHoursEnabled {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if windowContains(
                minute,
                start: quietStartMinutes,
                end: quietEndMinutes
            ) {
                return .init(shouldDeliver: false, reason: .quietHours, nextState: state)
            }
        }

        var next = state
        next.lastGlobalDelivery = now
        next.deliveries[key] = .init(at: now, fingerprint: candidate.fingerprint)
        return .init(shouldDeliver: true, reason: .deliver, nextState: next)
    }

    static func nextEligibleDate(
        for candidate: ContextualInterventionCandidate,
        state: ContextualInterventionState,
        notBefore: Date,
        quietHoursEnabled: Bool,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let expiresAt = candidate.observedAt.addingTimeInterval(candidate.maximumAge)
        var probe = notBefore

        for _ in 0..<8 {
            guard probe < expiresAt else { return nil }
            let decision = evaluate(
                candidate,
                state: state,
                now: probe,
                quietHoursEnabled: quietHoursEnabled,
                quietStartMinutes: quietStartMinutes,
                quietEndMinutes: quietEndMinutes,
                calendar: calendar
            )
            if decision.shouldDeliver { return probe }

            let next: Date?
            switch decision.reason {
            case .globalCooldown:
                next = state.lastGlobalDelivery?.addingTimeInterval(globalCooldown)
            case .topicCooldown:
                next = topicCooldownEnd(for: candidate.kind, state: state)
            case .quietHours:
                next = nextQuietHoursEnd(
                    after: probe,
                    endMinutes: quietEndMinutes,
                    calendar: calendar
                )
            case .stale, .duplicate:
                return nil
            case .deliver:
                return probe
            }

            guard let next else { return nil }
            probe = next > probe ? next : probe.addingTimeInterval(1)
        }
        return nil
    }

    static func windowContains(_ minute: Int, start: Int, end: Int) -> Bool {
        let day = 24 * 60
        let value = ((minute % day) + day) % day
        let lo = ((start % day) + day) % day
        let hi = ((end % day) + day) % day
        guard lo != hi else { return false }
        return lo < hi ? (value >= lo && value < hi) : (value >= lo || value < hi)
    }

    private static func adaptivePriorityBlockers(
        for kind: ContextualInterventionKind
    ) -> [ContextualInterventionKind] {
        switch kind {
        case .adaptiveSleepRecovery:
            return [.adaptiveTravel, .adaptivePlannedWorkout, .adaptiveRoutineRecovery]
        case .adaptiveRoutineRecovery:
            return [.adaptiveTravel, .adaptivePlannedWorkout]
        case .adaptivePlannedWorkout:
            return [.adaptiveTravel]
        default:
            return []
        }
    }

    private static func topicCooldownEnd(
        for kind: ContextualInterventionKind,
        state: ContextualInterventionState
    ) -> Date? {
        var dates: [Date] = []
        if let prior = state.deliveries[kind.rawValue] {
            dates.append(prior.at.addingTimeInterval(kind.cooldown))
        }
        for blocker in adaptivePriorityBlockers(for: kind) {
            if let prior = state.deliveries[blocker.rawValue] {
                dates.append(prior.at.addingTimeInterval(20 * 60 * 60))
            }
        }
        return dates.max()
    }

    private static func nextQuietHoursEnd(
        after date: Date,
        endMinutes: Int,
        calendar: Calendar
    ) -> Date? {
        let normalized = ((endMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        return calendar.nextDate(
            after: date,
            matching: DateComponents(
                hour: normalized / 60,
                minute: normalized % 60,
                second: 0
            ),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

/// Notification side effect for immediate contextual prompts. Authorization is requested only from an
/// explicit settings toggle; event handlers merely inspect the current status. State is persisted only
/// after the OS accepted the request, so a denied permission cannot silently consume a fresh observation.
@MainActor
enum ContextualInterventionCenter {
    static let stateKey = "contextualInterventions.deliveryState.v1"
    static let plannedWorkoutRequestID = "contextual-adaptivePlannedWorkout"
    private static let quietHoursEnabledKey = "notif.quietHoursEnabled"
    private static let quietStartMinutesKey = "notif.quietStartMinutes"
    private static let quietEndMinutesKey = "notif.quietEndMinutes"
    private struct PendingDelivery {
        let candidate: ContextualInterventionCandidate
        let onRetry: (@MainActor @Sendable (Date) -> Void)?
    }

    private static var deliveriesInFlight = Set<ContextualInterventionKind>()
    private static var pendingDeliveries: [PendingDelivery] = []
    private static var deliveryLoopRunning = false
    private static var currentPlannedWorkoutFingerprint: String?

    enum EnableOutcome: Equatable, Sendable {
        case enabled
        case denied
        case off
    }

    static func requestAuthorization(
        completion: (@MainActor @Sendable (EnableOutcome) -> Void)? = nil
    ) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion?(.enabled)
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                let final = await center.notificationSettings()
                completion?(granted && Self.isAuthorized(final.authorizationStatus) ? .enabled : .denied)
            default:
                completion?(.denied)
            }
        }
    }

    static func post(
        _ candidate: ContextualInterventionCandidate,
        onRetry: (@MainActor @Sendable (Date) -> Void)? = nil
    ) {
        guard deliveryConsentCurrent(for: candidate) else { return }
        if deliveriesInFlight.contains(candidate.kind) {
            guard candidate.kind == .adaptivePlannedWorkout else { return }
            pendingDeliveries.removeAll { $0.candidate.kind == candidate.kind }
            pendingDeliveries.append(.init(
                candidate: candidate,
                onRetry: onRetry
            ))
            return
        }
        deliveriesInFlight.insert(candidate.kind)
        pendingDeliveries.append(.init(
            candidate: candidate,
            onRetry: onRetry
        ))
        guard !deliveryLoopRunning else { return }
        deliveryLoopRunning = true
        Task { @MainActor in
            await drainPendingDeliveries()
        }
    }

    private static func drainPendingDeliveries() async {
        while !pendingDeliveries.isEmpty {
            let pending = pendingDeliveries.removeFirst()
            await deliver(
                pending.candidate,
                onRetry: pending.onRetry
            )
            if !pendingDeliveries.contains(where: {
                $0.candidate.kind == pending.candidate.kind
            }) {
                deliveriesInFlight.remove(pending.candidate.kind)
            }
        }
        deliveryLoopRunning = false
    }

    private static func deliver(
        _ candidate: ContextualInterventionCandidate,
        onRetry: (@MainActor @Sendable (Date) -> Void)?
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard deliveryConsentCurrent(for: candidate),
              isAuthorized(settings.authorizationStatus) else {
            rejectDelivery(candidate, on: center)
            return
        }

        await DailyReviewNotifications.ensurePrivacyCategory(on: center)
        guard deliveryConsentCurrent(for: candidate) else {
            rejectDelivery(candidate, on: center)
            return
        }

        let defaults = UserDefaults.standard
        let current = loadState(defaults: defaults)
        let quietHoursEnabled = defaults.bool(forKey: quietHoursEnabledKey)
        let quietStartMinutes =
            defaults.object(forKey: quietStartMinutesKey) as? Int ?? 22 * 60
        let quietEndMinutes =
            defaults.object(forKey: quietEndMinutesKey) as? Int ?? 7 * 60
        let deliveryNow = Date()
        let decision = ContextualInterventionPolicy.evaluate(
            candidate,
            state: current,
            now: deliveryNow,
            quietHoursEnabled: quietHoursEnabled,
            quietStartMinutes: quietStartMinutes,
            quietEndMinutes: quietEndMinutes
        )
        guard decision.shouldDeliver else {
            if candidate.kind == .adaptiveTravel, decision.reason == .duplicate {
                AdaptiveDayTimeZoneStore.discardPending()
            }
            if candidate.kind == .adaptivePlannedWorkout,
               let retryAt = ContextualInterventionPolicy.nextEligibleDate(
                   for: candidate,
                   state: current,
                   notBefore: deliveryNow,
                   quietHoursEnabled: quietHoursEnabled,
                   quietStartMinutes: quietStartMinutes,
                   quietEndMinutes: quietEndMinutes
               ) {
                onRetry?(retryAt)
            }
            LocalNotificationLifecycle.suppressed(
                identifier: "contextual-\(candidate.kind.rawValue)",
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID
            )
            return
        }

        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.body
        content.sound = .default
        content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
        content.threadIdentifier = "noop.contextual.\(candidate.kind.rawValue)"
        var userInfo: [AnyHashable: Any] = [
            NotificationRouteBridge.userInfoKey: candidate.route.rawValue
        ]
        if candidate.kind == .adaptivePlannedWorkout {
            userInfo[AdaptivePlannedWorkoutScheduler.startSecUserInfoKey] = Int(
                candidate.observedAt.addingTimeInterval(
                    candidate.maximumAge
                ).timeIntervalSince1970
            )
            userInfo[AdaptivePlannedWorkoutScheduler.fingerprintUserInfoKey] =
                candidate.fingerprint
            userInfo[AdaptivePlannedWorkoutScheduler.evidenceUserInfoKey] =
                candidate.evidence
        }
        content.userInfo = userInfo
        do {
            guard deliveryConsentCurrent(for: candidate) else {
                rejectDelivery(candidate, on: center)
                return
            }
            try await LocalNotificationLifecycle.schedule(
                UNNotificationRequest(
                    identifier: candidate.kind == .adaptivePlannedWorkout
                        ? plannedWorkoutRequestID
                        : "contextual-\(candidate.kind.rawValue)",
                    content: content,
                    trigger: nil
                ),
                on: center
            )
            guard deliveryConsentCurrent(for: candidate) else {
                rejectDelivery(candidate, on: center)
                return
            }
            if candidate.kind == .adaptivePlannedWorkout {
                guard AdaptivePlannedWorkoutScheduler.scheduleDeliveryExpiry(
                    start: candidate.observedAt.addingTimeInterval(candidate.maximumAge),
                    fingerprint: candidate.fingerprint,
                    now: Date(),
                    center: center
                ) else {
                    rejectDelivery(candidate, on: center)
                    return
                }
            }
            if candidate.kind.isAdaptiveDayGuidance {
                ContextualActionCenter.shared.presentRecovery(
                    title: candidate.title,
                    detail: candidate.body,
                    fingerprint: candidate.fingerprint,
                    evidence: candidate.evidence,
                    observedAt: candidate.observedAt,
                    maximumAge: candidate.maximumAge,
                    route: candidate.route
                )
            } else if candidate.kind == .stressBreathing {
                ContextualActionCenter.shared.presentStress(
                    fastRMSSD: nil,
                    baselineRMSSD: nil,
                    fingerprint: candidate.fingerprint,
                    now: candidate.observedAt
                )
            }
            saveState(decision.nextState, defaults: defaults)
            await AdaptivePlannedWorkoutScheduler.reconcilePending(
                after: decision.nextState,
                acceptedAt: deliveryNow,
                center: center
            )
            if candidate.kind == .adaptiveTravel {
                AdaptiveDayTimeZoneStore.discardPending()
            }
        } catch {
            // A rejected request remains eligible while its evidence is fresh.
        }
    }

    private static func deliveryConsentCurrent(
        for candidate: ContextualInterventionCandidate
    ) -> Bool {
        guard !candidate.kind.isAdaptiveDayGuidance ||
                ContextualInterventionSettings.adaptiveDayGuidanceEnabled else {
            return false
        }
        guard candidate.kind == .adaptivePlannedWorkout else { return true }
        return PlannedWorkoutCalendarSettings.enabled &&
            PlannedWorkoutCalendarStore.hasCurrentReadAccess() &&
            plannedWorkoutFingerprintsMatch(
                currentPlannedWorkoutFingerprint,
                candidate.fingerprint
            )
    }

    static func invalidatePlannedWorkoutCandidate() {
        currentPlannedWorkoutFingerprint = nil
    }

    fileprivate static func plannedWorkoutCandidateIsCurrent(
        _ fingerprint: String
    ) -> Bool {
        plannedWorkoutFingerprintsMatch(
            currentPlannedWorkoutFingerprint,
            fingerprint
        )
    }

    private static func rejectDelivery(
        _ candidate: ContextualInterventionCandidate,
        on center: UNUserNotificationCenter
    ) {
        if candidate.kind == .adaptivePlannedWorkout,
           plannedWorkoutCandidateIsCurrent(candidate.fingerprint) {
            AdaptivePlannedWorkoutScheduler.cancelPending(on: center)
            reconcilePlannedWorkoutArtifacts(
                keepingFingerprint: nil,
                center: center
            )
        }
        LocalNotificationLifecycle.suppressed(
            identifier: "contextual-\(candidate.kind.rawValue)",
            categoryIdentifier: DailyReviewNotifications.privacyCategoryID
        )
    }

    static func loadState(defaults: UserDefaults = .standard) -> ContextualInterventionState {
        guard let data = defaults.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode(ContextualInterventionState.self, from: data)
        else { return .empty }
        return decoded
    }

    static func saveState(
        _ state: ContextualInterventionState,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    static func reconciledPlannedWorkoutState(
        _ state: ContextualInterventionState,
        keepingFingerprint: String?
    ) -> ContextualInterventionState {
        let key = ContextualInterventionKind.adaptivePlannedWorkout.rawValue
        guard let prior = state.deliveries[key] else { return state }
        if let keepingFingerprint,
           plannedWorkoutFingerprintsMatch(
               prior.fingerprint,
               keepingFingerprint
           ) {
            guard prior.fingerprint != keepingFingerprint else { return state }
            var migrated = state
            migrated.deliveries[key] = .init(
                at: prior.at,
                fingerprint: keepingFingerprint
            )
            return migrated
        }
        var next = state
        next.deliveries.removeValue(forKey: key)
        next.lastGlobalDelivery = next.deliveries.values.map(\.at).max()
        return next
    }

    static func reconcilePlannedWorkoutArtifacts(
        keepingFingerprint: String?,
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        currentPlannedWorkoutFingerprint = keepingFingerprint
        let state = loadState(defaults: defaults)
        let key = ContextualInterventionKind.adaptivePlannedWorkout.rawValue
        let prior = state.deliveries[key]
        let remainsCurrent =
            keepingFingerprint != nil &&
            plannedWorkoutFingerprintsMatch(
                prior?.fingerprint,
                keepingFingerprint
            )
        let artifactFingerprint = remainsCurrent
            ? prior?.fingerprint
            : keepingFingerprint
        if let keepingFingerprint {
            ContextualActionCenter.shared.migrateRecoveryAction(
                route: .workouts,
                toFingerprint: keepingFingerprint
            ) { candidateFingerprint in
                plannedWorkoutFingerprintsMatch(
                    candidateFingerprint,
                    keepingFingerprint
                )
            }
        }
        ContextualActionCenter.shared.reconcileRecoveryActions(
            route: .workouts,
            keepingFingerprint: keepingFingerprint
        )
        AdaptivePlannedWorkoutScheduler.reconcileDeliveryExpiry(
            keepingFingerprint: artifactFingerprint,
            center: center,
            defaults: defaults
        )

        let next = reconciledPlannedWorkoutState(
            state,
            keepingFingerprint: keepingFingerprint
        )
        if next != state {
            saveState(next, defaults: defaults)
        }
        guard !remainsCurrent else { return }
        LocalNotificationLifecycle.cancel(
            identifiers: [plannedWorkoutRequestID, AdaptivePlannedWorkoutScheduler.requestID],
            presented: true,
            on: center
        )
    }

    static func expirePlannedWorkoutArtifacts(
        fingerprint: String,
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        guard currentPlannedWorkoutFingerprint == nil ||
                plannedWorkoutFingerprintsMatch(
                    currentPlannedWorkoutFingerprint,
                    fingerprint
                ) else {
            return
        }
        currentPlannedWorkoutFingerprint = nil
        ContextualActionCenter.shared.reconcileRecoveryActions(
            route: .workouts,
            keepingFingerprint: nil
        )
        AdaptivePlannedWorkoutScheduler.reconcileDeliveryExpiry(
            keepingFingerprint: nil,
            center: center,
            defaults: defaults
        )
        LocalNotificationLifecycle.cancel(
            identifiers: [plannedWorkoutRequestID, AdaptivePlannedWorkoutScheduler.requestID],
            presented: true,
            on: center
        )
    }

    static func reconcileMissingPlannedWorkoutArtifacts(
        now: Date,
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        let key = ContextualInterventionKind.adaptivePlannedWorkout.rawValue
        if let prior = loadState(defaults: defaults).deliveries[key],
           let start = plannedWorkoutStartDate(from: prior.fingerprint),
           start <= now {
            expirePlannedWorkoutArtifacts(
                fingerprint: prior.fingerprint,
                center: center,
                defaults: defaults
            )
            return
        }
        reconcilePlannedWorkoutArtifacts(
            keepingFingerprint: nil,
            center: center,
            defaults: defaults
        )
    }

    static func plannedWorkoutStartDate(from fingerprint: String) -> Date? {
        guard let identity = plannedWorkoutIdentity(from: fingerprint) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(identity.startSec))
    }

    static func plannedWorkoutFingerprintsMatch(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        if lhs == rhs { return true }
        guard let lhsIdentity = plannedWorkoutIdentity(from: lhs),
              let rhsIdentity = plannedWorkoutIdentity(from: rhs) else {
            return false
        }
        return lhsIdentity.day == rhsIdentity.day &&
            lhsIdentity.startSec == rhsIdentity.startSec
    }

    private static func plannedWorkoutIdentity(
        from fingerprint: String
    ) -> (day: String, startSec: Int)? {
        let fields = fingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard (fields.count == 3 || fields.count == 4),
              fields[0] == "planned-workout",
              !fields[1].isEmpty,
              let startSec = Int(fields[2]) else {
            return nil
        }
        return (String(fields[1]), startSec)
    }

    private static func canonicalPlannedWorkoutFingerprint(
        from fingerprint: String
    ) -> String? {
        guard let identity = plannedWorkoutIdentity(from: fingerprint) else {
            return nil
        }
        return [
            "planned-workout",
            identity.day,
            String(identity.startSec)
        ].joined(separator: "|")
    }

    static func recordScheduledPlannedWorkoutDelivery(
        fingerprint: String,
        deliveredAt: Date,
        defaults: UserDefaults = .standard
    ) {
        var state = loadState(defaults: defaults)
        let key = ContextualInterventionKind.adaptivePlannedWorkout.rawValue
        let storedFingerprint =
            canonicalPlannedWorkoutFingerprint(from: fingerprint) ?? fingerprint
        if let prior = state.deliveries[key],
           plannedWorkoutFingerprintsMatch(prior.fingerprint, storedFingerprint) {
            if prior.fingerprint != storedFingerprint {
                state.deliveries[key] = .init(
                    at: prior.at,
                    fingerprint: storedFingerprint
                )
                saveState(state, defaults: defaults)
            }
            return
        }
        if state.lastGlobalDelivery.map({ $0 < deliveredAt }) ?? true {
            state.lastGlobalDelivery = deliveredAt
        }
        state.deliveries[key] = .init(
            at: deliveredAt,
            fingerprint: storedFingerprint
        )
        saveState(state, defaults: defaults)
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

enum ContextualInterventionSettings {
    static let vitalReviewEnabledKey = "contextualInterventions.vitalReviewEnabled"
    static let vo2ReviewEnabledKey = "contextualInterventions.vo2ReviewEnabled"
    static let adaptiveDayGuidanceEnabledKey =
        "contextualInterventions.adaptiveDayGuidanceEnabled"

    static var vitalReviewEnabled: Bool {
        UserDefaults.standard.bool(forKey: vitalReviewEnabledKey)
    }

    static var vo2ReviewEnabled: Bool {
        UserDefaults.standard.bool(forKey: vo2ReviewEnabledKey)
    }

    static var adaptiveDayGuidanceEnabled: Bool {
        UserDefaults.standard.bool(forKey: adaptiveDayGuidanceEnabledKey)
    }
}

/// Low-frequency user inputs that can invalidate an already delivered adaptive-day recommendation.
/// Publishers persist their value first; AppModel coalesces the resulting evaluation.
@MainActor
enum ContextualInterventionInputs {
    static let didChange = Notification.Name("noop.contextualInterventionInputs.didChange")

    static func notifyChanged() {
        ContextualInterventionCenter.invalidatePlannedWorkoutCandidate()
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - Adaptive day guidance

/// Restart-safe timezone observation. A qualified transition remains available for 36 hours so a prompt
/// suppressed by quiet hours or missing notification permission can retry without treating the same zone
/// as a fresh change. One-hour DST transitions advance the baseline but never create travel guidance.
enum AdaptiveDayTimeZoneStore {
    private static let currentOffsetKey = "adaptiveDay.timeZone.currentOffsetSec"
    private static let changeFromKey = "adaptiveDay.timeZone.changeFromSec"
    private static let changeToKey = "adaptiveDay.timeZone.changeToSec"
    private static let changeAtKey = "adaptiveDay.timeZone.changeAtSec"

    static func observe(
        offsetSec: Int,
        nowSec: Int,
        defaults: UserDefaults = .standard
    ) -> AdaptiveDayGuidance.TimeZoneChange? {
        if let prior = defaults.object(forKey: currentOffsetKey) as? Int,
           prior != offsetSec {
            let shift = AdaptiveDayGuidance.normalizedTravelDeltaSeconds(
                previousOffsetSec: prior,
                currentOffsetSec: offsetSec
            )
            if abs(shift) >= AdaptiveDayGuidance.travelThresholdSeconds {
                defaults.set(prior, forKey: changeFromKey)
                defaults.set(offsetSec, forKey: changeToKey)
                defaults.set(nowSec, forKey: changeAtKey)
            }
            defaults.set(offsetSec, forKey: currentOffsetKey)
        } else if defaults.object(forKey: currentOffsetKey) == nil {
            defaults.set(offsetSec, forKey: currentOffsetKey)
        }
        return pending(defaults: defaults)
    }

    static func pending(
        defaults: UserDefaults = .standard
    ) -> AdaptiveDayGuidance.TimeZoneChange? {
        guard let from = defaults.object(forKey: changeFromKey) as? Int,
              let to = defaults.object(forKey: changeToKey) as? Int,
              let at = defaults.object(forKey: changeAtKey) as? Int else { return nil }
        return .init(
            previousOffsetSec: from,
            currentOffsetSec: to,
            observedAtSec: at
        )
    }

    static func discardPending(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: changeFromKey)
        defaults.removeObject(forKey: changeToKey)
        defaults.removeObject(forKey: changeAtKey)
    }
}

enum AdaptiveDayInterventionFactory {
    static func candidate(
        from recommendation: AdaptiveDayGuidance.Recommendation
    ) -> ContextualInterventionCandidate {
        let copy: (ContextualInterventionKind, String, String)
        switch recommendation.kind {
        case .travelAdjustment:
            copy = (
                .adaptiveTravel,
                String(localized: "appwide.adaptive_day_guidance.travel.title"),
                String(localized: "appwide.adaptive_day_guidance.travel.body")
            )
        case .routineRecovery:
            copy = (
                .adaptiveRoutineRecovery,
                String(localized: "appwide.adaptive_day_guidance.routine.title"),
                String(localized: "appwide.adaptive_day_guidance.routine.body")
            )
        case .sleepRecovery:
            copy = (
                .adaptiveSleepRecovery,
                String(localized: "appwide.adaptive_day_guidance.sleep.title"),
                String(localized: "appwide.adaptive_day_guidance.sleep.body")
            )
        }
        return ContextualInterventionCandidate(
            kind: copy.0,
            observedAt: Date(timeIntervalSince1970: TimeInterval(recommendation.observedAtSec)),
            maximumAge: TimeInterval(recommendation.maximumAgeSeconds),
            fingerprint: recommendation.fingerprint,
            title: copy.1,
            body: copy.2,
            route: .sleep,
            evidence: recommendation.evidence
        )
    }

    static func plannedWorkoutCandidate(
        from adjustment: DailyActionPlanner.WorkoutAdjustment,
        day: String,
        observedAt: Date
    ) -> ContextualInterventionCandidate {
        let maximumAge = max(
            0,
            TimeInterval(adjustment.startSec) - observedAt.timeIntervalSince1970
        )
        let evidence = switch adjustment.reason {
        case .sleepDeficit:
            [
                String(localized: "daily_plan.workout_adjustment.title"),
                String(localized: "daily_plan.workout_adjustment.sleep_label")
            ]
        case .recoveryShift:
            [
                String(localized: "daily_plan.workout_adjustment.title"),
                String(localized: "daily_plan.evidence.readiness")
            ]
        case .sleepAndRecovery:
            [
                String(localized: "daily_plan.workout_adjustment.title"),
                String(localized: "daily_plan.workout_adjustment.sleep_label"),
                String(localized: "daily_plan.evidence.readiness")
            ]
        }
        return ContextualInterventionCandidate(
            kind: .adaptivePlannedWorkout,
            observedAt: observedAt,
            maximumAge: maximumAge,
            fingerprint: [
                "planned-workout",
                day,
                String(adjustment.startSec)
            ].joined(separator: "|"),
            title: String(localized: "appwide.adaptive_day_guidance.planned_workout.title"),
            body: String(localized: "appwide.adaptive_day_guidance.planned_workout.body"),
            route: .workouts,
            evidence: evidence
        )
    }
}

/// Best-effort pre-workout reevaluation at the two-hour boundary.
///
/// Calendar-derived notification copy is never materialized ahead of time. A process-local task handles
/// the boundary while NOOP is alive, and iOS receives a one-shot app-refresh hint for process-death
/// recovery. Both paths re-read current consent and evidence before any notification can be posted.
@MainActor
enum AdaptivePlannedWorkoutScheduler {
    static let requestID = "contextual-adaptivePlannedWorkout-boundary"
    static let startSecUserInfoKey = "noop.plannedWorkout.startSec"
    static let evaluationSecUserInfoKey = "noop.plannedWorkout.evaluationSec"
    static let fingerprintUserInfoKey = "noop.plannedWorkout.fingerprint"
    static let evidenceUserInfoKey = "noop.plannedWorkout.evidence"
    static let deliveredStartSecKey = "noop.plannedWorkout.deliveredStartSec"
    static let deliveredFingerprintKey = "noop.plannedWorkout.deliveredFingerprint"
    static let leadTime: TimeInterval = 2 * 60 * 60
    private static var boundaryTask: Task<Void, Never>?
    private static var deliveryExpiryTask: Task<Void, Never>?

    @discardableResult
    static func schedule(
        adjustment: DailyActionPlanner.WorkoutAdjustment,
        day: String,
        now: Date = Date(),
        center: UNUserNotificationCenter = .current(),
        onBoundary: @escaping @MainActor @Sendable () async -> Void
    ) async -> Bool {
        let start = Date(timeIntervalSince1970: TimeInterval(adjustment.startSec))
        let boundary = start.addingTimeInterval(-leadTime)
        guard boundary > now else {
            cancelPending(on: center)
            return false
        }

        let candidate = AdaptiveDayInterventionFactory.plannedWorkoutCandidate(
            from: adjustment,
            day: day,
            observedAt: boundary
        )
        let settings = await center.notificationSettings()
        guard !Task.isCancelled,
              ContextualInterventionCenter.plannedWorkoutCandidateIsCurrent(
                candidate.fingerprint
              ) else {
            return false
        }
        guard isAuthorized(settings.authorizationStatus),
              ContextualInterventionSettings.adaptiveDayGuidanceEnabled,
              PlannedWorkoutCalendarSettings.enabled,
              PlannedWorkoutCalendarStore.hasCurrentReadAccess() else {
            cancelPending(on: center)
            return false
        }

        return armEvaluation(
            startSec: adjustment.startSec,
            evaluationAt: boundary,
            fingerprint: candidate.fingerprint,
            now: now,
            center: center,
            defaults: .standard,
            outcome: "armed",
            onBoundary: onBoundary
        )
    }

    @discardableResult
    static func scheduleRetry(
        start: Date,
        fingerprint: String,
        retryAt: Date,
        now: Date = Date(),
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        onBoundary: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard ContextualInterventionCenter.plannedWorkoutCandidateIsCurrent(fingerprint),
              ContextualInterventionSettings.adaptiveDayGuidanceEnabled,
              PlannedWorkoutCalendarSettings.enabled,
              PlannedWorkoutCalendarStore.hasCurrentReadAccess() else {
            return false
        }
        return armEvaluation(
            startSec: Int(start.timeIntervalSince1970),
            evaluationAt: retryAt,
            fingerprint: fingerprint,
            now: now,
            center: center,
            defaults: defaults,
            outcome: "retry_armed",
            onBoundary: onBoundary
        )
    }

    static func reconcilePending(
        after state: ContextualInterventionState,
        acceptedAt: Date,
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) async {
        guard let startSec = pendingStartSec(defaults: defaults),
              let fingerprint = defaults.string(forKey: fingerprintUserInfoKey) else {
            removeLegacyNotification(on: center)
            return
        }
        guard PlannedWorkoutCalendarSettings.enabled,
              PlannedWorkoutCalendarStore.hasCurrentReadAccess()
        else {
            cancelPending(on: center, defaults: defaults)
            return
        }

        let start = Date(timeIntervalSince1970: TimeInterval(startSec))
        guard start > acceptedAt else {
            cancelPending(on: center, defaults: defaults)
            return
        }
        let boundary = start.addingTimeInterval(-leadTime)
        let scheduledEvaluation = pendingEvaluationSec(defaults: defaults).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        } ?? boundary

        let shouldKeep = shouldKeepPending(
            startSec: startSec,
            fingerprint: fingerprint,
            state: state,
            notBefore: max(scheduledEvaluation, acceptedAt),
            quietHoursEnabled: defaults.bool(forKey: "notif.quietHoursEnabled"),
            quietStartMinutes: defaults.object(forKey: "notif.quietStartMinutes") as? Int
                ?? 22 * 60,
            quietEndMinutes: defaults.object(forKey: "notif.quietEndMinutes") as? Int
                ?? 7 * 60
        )
        if !shouldKeep {
            cancelPending(on: center, defaults: defaults)
        }
    }

    static func shouldKeepPending(
        startSec: Int,
        fingerprint: String,
        state: ContextualInterventionState,
        notBefore: Date? = nil,
        quietHoursEnabled: Bool,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let start = Date(timeIntervalSince1970: TimeInterval(startSec))
        let boundary = start.addingTimeInterval(-leadTime)
        let candidate = ContextualInterventionCandidate(
            kind: .adaptivePlannedWorkout,
            observedAt: boundary,
            maximumAge: leadTime,
            fingerprint: fingerprint,
            title: "",
            body: "",
            route: .workouts
        )
        return ContextualInterventionPolicy.nextEligibleDate(
            for: candidate,
            state: state,
            notBefore: max(boundary, notBefore ?? boundary),
            quietHoursEnabled: quietHoursEnabled,
            quietStartMinutes: quietStartMinutes,
            quietEndMinutes: quietEndMinutes,
            calendar: calendar
        ) != nil
    }

    @discardableResult
    static func scheduleDeliveryExpiry(
        start: Date,
        fingerprint: String,
        now: Date = Date(),
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard start > now else {
            ContextualInterventionCenter.expirePlannedWorkoutArtifacts(
                fingerprint: fingerprint,
                center: center,
                defaults: defaults
            )
            return false
        }

        let startSec = Int(start.timeIntervalSince1970)
        defaults.set(startSec, forKey: deliveredStartSecKey)
        defaults.set(fingerprint, forKey: deliveredFingerprintKey)
        deliveryExpiryTask?.cancel()
        let delay = max(1, start.timeIntervalSince(now))
        deliveryExpiryTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  deliveredStartSec(defaults: defaults) == startSec,
                  defaults.string(forKey: deliveredFingerprintKey) == fingerprint else {
                return
            }
            deliveryExpiryTask = nil
            clearDeliveryExpiryMetadata(defaults: defaults)
#if os(iOS)
            rescheduleRequestedWake(now: Date(), defaults: defaults)
#endif
            AppDiagnosticsRecorder.shared.record(
                "adaptive_day.planned_workout_boundary",
                fields: ["outcome": "expired"]
            )
            ContextualInterventionCenter.expirePlannedWorkoutArtifacts(
                fingerprint: fingerprint,
                center: center,
                defaults: defaults
            )
        }
#if os(iOS)
        rescheduleRequestedWake(now: now, defaults: defaults)
#endif
        AppDiagnosticsRecorder.shared.record(
            "adaptive_day.planned_workout_boundary",
            fields: ["outcome": "expiry_armed"]
        )
        return true
    }

    static func reconcileDeliveryExpiry(
        keepingFingerprint: String?,
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        let priorFingerprint = defaults.string(forKey: deliveredFingerprintKey)
        let hadExpiry = deliveryExpiryTask != nil ||
            deliveredStartSec(defaults: defaults) != nil ||
            priorFingerprint != nil
        if let keepingFingerprint,
           ContextualInterventionCenter.plannedWorkoutFingerprintsMatch(
               priorFingerprint,
               keepingFingerprint
           ) {
            if deliveryExpiryTask == nil,
               let startSec = deliveredStartSec(defaults: defaults) {
                let start = Date(timeIntervalSince1970: TimeInterval(startSec))
                if start > Date() {
                    scheduleDeliveryExpiry(
                        start: start,
                        fingerprint: keepingFingerprint,
                        center: center,
                        defaults: defaults
                    )
                }
            }
            return
        }
        deliveryExpiryTask?.cancel()
        deliveryExpiryTask = nil
        clearDeliveryExpiryMetadata(defaults: defaults)
#if os(iOS)
        rescheduleRequestedWake(now: Date(), defaults: defaults)
#endif
        if hadExpiry {
            AppDiagnosticsRecorder.shared.record(
                "adaptive_day.planned_workout_boundary",
                fields: ["outcome": "expiry_cancelled"]
            )
        }
    }

    static func cancelPending(
        on center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        let hadPending =
            boundaryTask != nil ||
            pendingStartSec(defaults: defaults) != nil ||
            defaults.string(forKey: fingerprintUserInfoKey) != nil
        boundaryTask?.cancel()
        boundaryTask = nil
        clearPendingMetadata(defaults: defaults)
#if os(iOS)
        rescheduleRequestedWake(now: Date(), defaults: defaults)
#endif
        removeLegacyNotification(on: center)
        if hadPending {
            AppDiagnosticsRecorder.shared.record(
                "adaptive_day.planned_workout_boundary",
                fields: ["outcome": "cancelled"]
            )
        }
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private static func pendingStartSec(defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: startSecUserInfoKey) != nil else { return nil }
        return defaults.integer(forKey: startSecUserInfoKey)
    }

    private static func deliveredStartSec(defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: deliveredStartSecKey) != nil else { return nil }
        return defaults.integer(forKey: deliveredStartSecKey)
    }

    private static func pendingEvaluationSec(defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: evaluationSecUserInfoKey) != nil else { return nil }
        return defaults.integer(forKey: evaluationSecUserInfoKey)
    }

    private static func clearPendingMetadata(defaults: UserDefaults) {
        defaults.removeObject(forKey: startSecUserInfoKey)
        defaults.removeObject(forKey: evaluationSecUserInfoKey)
        defaults.removeObject(forKey: fingerprintUserInfoKey)
        defaults.removeObject(forKey: evidenceUserInfoKey)
    }

    private static func clearDeliveryExpiryMetadata(defaults: UserDefaults) {
        defaults.removeObject(forKey: deliveredStartSecKey)
        defaults.removeObject(forKey: deliveredFingerprintKey)
    }

#if os(iOS)
    private static func rescheduleRequestedWake(
        now: Date,
        defaults: UserDefaults
    ) {
        BackgroundSyncScheduler.clearRequestedWake()
        let evaluation = pendingEvaluationSec(defaults: defaults).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        } ?? pendingStartSec(defaults: defaults).map {
            Date(timeIntervalSince1970: TimeInterval($0))
                .addingTimeInterval(-leadTime)
        }
        let expiry = deliveredStartSec(defaults: defaults).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let next = [evaluation, expiry]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
        if let next {
            BackgroundSyncScheduler.requestWake(noLaterThan: next, now: now)
        }
    }
#endif

    private static func armEvaluation(
        startSec: Int,
        evaluationAt: Date,
        fingerprint: String,
        now: Date,
        center: UNUserNotificationCenter,
        defaults: UserDefaults,
        outcome: String,
        onBoundary: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        let start = Date(timeIntervalSince1970: TimeInterval(startSec))
        guard evaluationAt > now, evaluationAt < start else { return false }

        removeLegacyNotification(on: center)
        let evaluationSec = Int(evaluationAt.timeIntervalSince1970)
        defaults.set(startSec, forKey: startSecUserInfoKey)
        defaults.set(evaluationSec, forKey: evaluationSecUserInfoKey)
        defaults.set(fingerprint, forKey: fingerprintUserInfoKey)
        defaults.removeObject(forKey: evidenceUserInfoKey)
        boundaryTask?.cancel()
        let delay = max(1, evaluationAt.timeIntervalSince(now))
        boundaryTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  pendingStartSec(defaults: defaults) == startSec,
                  pendingEvaluationSec(defaults: defaults) == evaluationSec,
                  defaults.string(forKey: fingerprintUserInfoKey) == fingerprint,
                  ContextualInterventionCenter.plannedWorkoutCandidateIsCurrent(fingerprint),
                  ContextualInterventionSettings.adaptiveDayGuidanceEnabled,
                  PlannedWorkoutCalendarSettings.enabled,
                  PlannedWorkoutCalendarStore.hasCurrentReadAccess() else {
                cancelPending(on: center, defaults: defaults)
                return
            }
            boundaryTask = nil
            clearPendingMetadata(defaults: defaults)
#if os(iOS)
            rescheduleRequestedWake(now: Date(), defaults: defaults)
#endif
            AppDiagnosticsRecorder.shared.record(
                "adaptive_day.planned_workout_boundary",
                fields: ["outcome": "reevaluation_requested"]
            )
            await onBoundary()
        }
#if os(iOS)
        rescheduleRequestedWake(now: now, defaults: defaults)
#endif
        AppDiagnosticsRecorder.shared.record(
            "adaptive_day.planned_workout_boundary",
            fields: ["outcome": outcome]
        )
        return true
    }

    private static func removeLegacyNotification(
        on center: UNUserNotificationCenter
    ) {
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }
}

/// The strongest workout cue bypasses routine quiet hours and the wellness anti-pileup window. It still
/// requires notification authorization and has its own restart-safe cooldown. The policy that calls this
/// has already required a fresh, plausible, sustained HR trace.
struct WorkoutCautionNotificationState: Equatable, Sendable {
    let lastPostedAt: Date?
}

enum WorkoutCautionNotificationPolicy {
    static let cooldown: TimeInterval = 10 * 60

    static func shouldDeliver(
        state: WorkoutCautionNotificationState,
        now: Date
    ) -> Bool {
        guard let prior = state.lastPostedAt else { return true }
        return now.timeIntervalSince(prior) >= cooldown
    }
}

@MainActor
enum WorkoutCautionNotifier {
    private static let requestID = "workout-caution-pause"
    private static let lastPostedKey = "workoutCaution.lastPauseNotificationAt"
    private static var inFlight = false

    static func post(now: Date = Date()) {
        guard !inFlight,
              UserDefaults.standard.bool(forKey: BehaviorStore.zoneCoachingKey)
        else { return }
        let defaults = UserDefaults.standard
        let state = WorkoutCautionNotificationState(
            lastPostedAt: defaults.object(forKey: lastPostedKey) as? Date
        )
        guard WorkoutCautionNotificationPolicy.shouldDeliver(state: state, now: now) else {
            return
        }
        inFlight = true
        Task { @MainActor in
            defer { inFlight = false }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard UserDefaults.standard.bool(forKey: BehaviorStore.zoneCoachingKey),
                  isAuthorized(settings.authorizationStatus) else {
                LocalNotificationLifecycle.suppressed(
                    identifier: requestID,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
                return
            }

            await DailyReviewNotifications.ensurePrivacyCategory(on: center)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "appwide.workout_guidance.notification_title")
            content.body = String(localized: "appwide.workout_guidance.notification_body")
            content.sound = .default
            content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
            content.threadIdentifier = "noop.workout.caution"
            content.userInfo = [
                NotificationRouteBridge.userInfoKey: NoopNotificationRoute.workouts.rawValue
            ]
            do {
                try await LocalNotificationLifecycle.schedule(
                    UNNotificationRequest(
                        identifier: requestID,
                        content: content,
                        trigger: nil
                    ),
                    on: center
                )
                defaults.set(now, forKey: lastPostedKey)
            } catch {
                // Keep the cue eligible if the OS rejected the request.
            }
        }
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

// MARK: - Fresh vital policies

enum ContextualVitalPolicy {
    static let oxygenReviewThresholdPct = 95.0
    static let oxygenLookbackDays = 3
    static let oxygenSameDayConflictPct = 3.0

    struct OxygenObservation: Equatable, Sendable {
        let day: String
        let value: Double
    }

    /// A single wearable oxygen estimate is too placement-sensitive to interrupt the user. Require two
    /// distinct recent days below the same typical-range boundary already shown by the Health vital tile.
    /// Raw optical ADC values can never enter this path because they are stored separately from `spo2Pct`.
    static func oxygenCandidate(
        sourceRows: [SourcedDailyMetric],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ContextualInterventionCandidate? {
        let today = calendar.startOfDay(for: now)
        var candidatesByDay: [String: [(value: Double, priority: Int)]] = [:]
        for row in sourceRows {
            guard let value = row.metric.spo2Pct,
                  value.isFinite,
                  (70.0...100.0).contains(value),
                  let date = dayDate(row.metric.day, calendar: calendar) else { continue }
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: today
            ).day ?? Int.max
            guard (0...oxygenLookbackDays).contains(age) else { continue }
            candidatesByDay[row.metric.day, default: []].append(
                (value, row.source.vitalPriority)
            )
        }

        var byDay: [String: Double] = [:]
        for (day, candidates) in candidatesByDay {
            guard let low = candidates.map(\.value).min(),
                  let high = candidates.map(\.value).max(),
                  high - low < oxygenSameDayConflictPct,
                  let preferred = candidates.min(by: { $0.priority < $1.priority })
            else { continue }
            byDay[day] = preferred.value
        }

        let observations = byDay
            .map { OxygenObservation(day: $0.key, value: $0.value) }
            .sorted { $0.day < $1.day }
        guard observations.count >= 2 else { return nil }
        let pair = Array(observations.suffix(2))
        guard pair.allSatisfy({ $0.value < oxygenReviewThresholdPct }),
              let firstDate = dayDate(pair[0].day, calendar: calendar),
              let latestDate = dayDate(pair[1].day, calendar: calendar) else { return nil }
        let separation = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: firstDate),
            to: calendar.startOfDay(for: latestDate)
        ).day ?? Int.max
        let latestAge = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latestDate),
            to: today
        ).day ?? Int.max
        guard (1...2).contains(separation), (0...1).contains(latestAge) else { return nil }

        let fingerprint = pair
            .map { "\($0.day):\(Int(($0.value * 10).rounded()))" }
            .joined(separator: "|")
        return ContextualInterventionCandidate(
            kind: .oxygenTrend,
            observedAt: latestDate,
            maximumAge: 3 * 24 * 60 * 60,
            fingerprint: fingerprint,
            title: String(localized: "Wellness readings to review"),
            body: String(localized: "Two recent blood oxygen readings were outside the usual wearable range. Open NOOP to review their source and context."),
            route: .trends
        )
    }

    struct BodyTemperaturePoint: Equatable, Sendable {
        let day: String
        let valueC: Double
        let source: String
        let sourcePriority: Int
    }

    static let bodyTemperaturePlausibleRangeC = 30.0...45.0
    static let bodyTemperatureReviewRangeC = 35.0...38.0
    static let bodyTemperatureSameDayConflictC = 0.8

    /// Explicit absolute body-temperature samples only. Wrist/skin temperature is intentionally absent:
    /// it has different physiology and remains in the corroborated personal-baseline engine.
    static func bodyTemperatureCandidate(
        points: [BodyTemperaturePoint],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ContextualInterventionCandidate? {
        let today = calendar.startOfDay(for: now)
        var candidatesByDay: [String: [BodyTemperaturePoint]] = [:]
        for point in points {
            guard point.valueC.isFinite,
                  bodyTemperaturePlausibleRangeC.contains(point.valueC),
                  let date = dayDate(point.day, calendar: calendar) else { continue }
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: today
            ).day ?? Int.max
            guard (0...1).contains(age) else { continue }
            candidatesByDay[point.day, default: []].append(point)
        }

        let resolved = candidatesByDay.compactMap { day, candidates -> BodyTemperaturePoint? in
            guard let low = candidates.map(\.valueC).min(),
                  let high = candidates.map(\.valueC).max(),
                  high - low < bodyTemperatureSameDayConflictC
            else { return nil }
            return candidates.min { lhs, rhs in
                if lhs.sourcePriority == rhs.sourcePriority {
                    return lhs.source < rhs.source
                }
                return lhs.sourcePriority < rhs.sourcePriority
            }
        }
        guard let latest = resolved.max(by: { $0.day < $1.day }),
              !bodyTemperatureReviewRangeC.contains(latest.valueC),
              let observedAt = dayDate(latest.day, calendar: calendar)
        else { return nil }

        return ContextualInterventionCandidate(
            kind: .bodyTemperatureReview,
            observedAt: observedAt,
            maximumAge: 2 * 24 * 60 * 60,
            fingerprint: "\(latest.day):\(Int((latest.valueC * 10).rounded()))",
            title: String(localized: "Body temperature reading to review"),
            body: String(localized: "A fresh explicit body temperature reading was outside the broad review range. Recheck with a thermometer and consider how you feel; NOOP cannot assess severity."),
            route: .trends
        )
    }

    struct VO2Point: Equatable, Sendable {
        let day: String
        let value: Double
    }

    /// VO2 max is a slow fitness trend, not a real-time alarm. Notify only when a genuinely new point is
    /// fresh and two recent points persist in the same direction against a comparison at least three weeks
    /// older than the first point. One shifted estimate is never enough.
    static func vo2Candidate(
        measured: [VO2Point],
        estimated: [VO2Point],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ContextualInterventionCandidate? {
        let measuredClean = cleanVO2(measured, now: now, calendar: calendar)
        let estimatedClean = cleanVO2(estimated, now: now, calendar: calendar)
        let selected: [VO2Point]
        let sourceToken: String
        if measuredClean.count >= 3 {
            selected = measuredClean
            sourceToken = "measured"
        } else {
            selected = estimatedClean
            sourceToken = "estimated"
        }
        guard selected.count >= 3,
              let latest = selected.last,
              let latestDate = dayDate(latest.day, calendar: calendar) else { return nil }
        let shifted = Array(selected.suffix(2))
        guard let firstShiftDate = dayDate(shifted[0].day, calendar: calendar) else { return nil }
        let persistenceGap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: firstShiftDate),
            to: calendar.startOfDay(for: latestDate)
        ).day ?? Int.max
        guard (1...14).contains(persistenceGap) else { return nil }

        let reference = selected.last { point in
            guard point.day < shifted[0].day,
                  let date = dayDate(point.day, calendar: calendar) else { return false }
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: firstShiftDate)
            ).day ?? 0
            return days >= 21
        }
        guard let reference, reference.value > 0 else { return nil }
        let changes = shifted.map { $0.value - reference.value }
        guard changes.allSatisfy({
            abs($0) >= 3.0 && abs($0) / reference.value >= 0.08
        }), changes[0].sign == changes[1].sign else { return nil }

        return ContextualInterventionCandidate(
            kind: .vo2Trend,
            observedAt: latestDate,
            maximumAge: 8 * 24 * 60 * 60,
            fingerprint: "\(sourceToken):\(latest.day):\(Int((latest.value * 10).rounded()))",
            title: String(localized: "Cardio fitness trend updated"),
            body: String(localized: "A meaningful longer-term VO₂ max change is ready to review. Check the source and trend in NOOP."),
            route: .trends
        )
    }

    private static func cleanVO2(
        _ points: [VO2Point],
        now: Date,
        calendar: Calendar
    ) -> [VO2Point] {
        let today = calendar.startOfDay(for: now)
        var byDay: [String: VO2Point] = [:]
        for point in points {
            guard point.value.isFinite,
                  (10.0...90.0).contains(point.value),
                  let date = dayDate(point.day, calendar: calendar) else { continue }
            let age = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: date),
                to: today
            ).day ?? Int.max
            guard age >= 0, age <= 400 else { continue }
            byDay[point.day] = point
        }
        guard let latest = byDay.values.max(by: { $0.day < $1.day }),
              let latestDate = dayDate(latest.day, calendar: calendar) else { return [] }
        let latestAge = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latestDate),
            to: today
        ).day ?? Int.max
        guard latestAge <= 7 else { return [] }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func dayDate(_ day: String, calendar: Calendar) -> Date? {
        let fields = day.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: fields[0],
            month: fields[1],
            day: fields[2]
        ))
    }
}

// MARK: - Caffeine cutoff

enum CaffeineReminderPolicy {
    enum Plan: Equatable, Sendable {
        case none
        case schedule(at: Date)
        case notifyNow(ContextualInterventionCandidate)
    }

    static func plan(
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Plan {
        guard let bedtime = nextBedtime(
            after: now,
            bedtimeMinutes: bedtimeMinutes,
            calendar: calendar
        ) else { return .none }
        let cutoff = bedtime.addingTimeInterval(
            -CaffeineDecay.cutoffLeadHours() * 60 * 60
        )
        let recent = intakes
            .filter { $0.at <= now && $0.at >= now.addingTimeInterval(-24 * 60 * 60) }
            .sorted { $0.at < $1.at }
        guard let latest = recent.last else { return .none }

        if cutoff > now {
            return .schedule(at: cutoff)
        }
        guard latest.at > cutoff else { return .none }
        return .notifyNow(
            ContextualInterventionCandidate(
                kind: .caffeineCutoff,
                observedAt: latest.at,
                maximumAge: 6 * 60 * 60,
                fingerprint: latest.id.uuidString,
                title: String(localized: "Caffeine cutoff"),
                body: String(localized: "A logged intake falls inside your sleep cutoff window. Consider decaf or water from here."),
                route: .sleep
            )
        )
    }

    static func nextBedtime(
        after date: Date,
        bedtimeMinutes: Int,
        calendar: Calendar = .current
    ) -> Date? {
        let minute = DailyReviewNotifications.clampMinute(bedtimeMinutes)
        var components = DateComponents()
        components.hour = minute / 60
        components.minute = minute % 60
        components.second = 0
        return calendar.nextDate(
            after: date.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}

@MainActor
enum CaffeineCutoffReminders {
    static let cutoffEnabledKey = "noop.caffeine.cutoffNudge"
    static let bedtimeMinutesKey = "noop.caffeine.bedtimeMinutes"
    static let notificationsEnabledKey = "noop.caffeine.cutoffNotification"
    private static let requestID = "caffeine-cutoff-reminder"

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationsEnabledKey)
    }

    static func setNotificationsEnabled(
        _ on: Bool,
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int,
        completion: (@MainActor @Sendable (ContextualInterventionCenter.EnableOutcome) -> Void)? = nil
    ) {
        guard on else {
            UserDefaults.standard.set(false, forKey: notificationsEnabledKey)
            removeScheduled()
            completion?(.off)
            return
        }
        ContextualInterventionCenter.requestAuthorization { outcome in
            guard outcome == .enabled else {
                UserDefaults.standard.set(false, forKey: notificationsEnabledKey)
                LocalNotificationLifecycle.suppressed(
                    identifier: requestID,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
                completion?(outcome)
                return
            }
            UserDefaults.standard.set(true, forKey: notificationsEnabledKey)
            reconcile(intakes: intakes, bedtimeMinutes: bedtimeMinutes)
            completion?(.enabled)
        }
    }

    static func reconcile(
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        removeScheduled()
        guard notificationsEnabled,
              UserDefaults.standard.bool(forKey: cutoffEnabledKey) else { return }
        switch CaffeineReminderPolicy.plan(
            intakes: intakes,
            bedtimeMinutes: bedtimeMinutes,
            now: now,
            calendar: calendar
        ) {
        case .none:
            break
        case .notifyNow(let candidate):
            ContextualInterventionCenter.post(candidate)
        case .schedule(let fireDate):
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                let status = await center.notificationSettings().authorizationStatus
                guard isAuthorized(status), fireDate.timeIntervalSince(now) > 1 else {
                    LocalNotificationLifecycle.suppressed(
                        identifier: requestID,
                        categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                    )
                    return
                }
                DailyReviewNotifications.registerPrivacyCategory(on: center)
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Caffeine cutoff")
                content.body = String(localized: "Your caffeine cutoff window starts now. Consider switching to decaf or water for tonight’s sleep.")
                content.sound = .default
                content.categoryIdentifier = DailyReviewNotifications.privacyCategoryID
                content.threadIdentifier = "noop.contextual.caffeine"
                content.userInfo = [
                    NotificationRouteBridge.userInfoKey: NoopNotificationRoute.sleep.rawValue
                ]
                let delay = max(1, fireDate.timeIntervalSince(now))
                try? await LocalNotificationLifecycle.schedule(
                    UNNotificationRequest(
                        identifier: requestID,
                        content: content,
                        trigger: UNTimeIntervalNotificationTrigger(
                            timeInterval: delay,
                            repeats: false
                        )
                    ),
                    on: center
                )
            }
        }
    }

    static func restoreIfAuthorized(
        intakes: [CaffeineIntake],
        bedtimeMinutes: Int
    ) {
        guard notificationsEnabled else {
            removeScheduled()
            return
        }
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            guard isAuthorized(status) else {
                LocalNotificationLifecycle.suppressed(
                    identifier: requestID,
                    categoryIdentifier: DailyReviewNotifications.privacyCategoryID
                )
                return
            }
            reconcile(intakes: intakes, bedtimeMinutes: bedtimeMinutes)
        }
    }

    static func removeScheduled() {
        LocalNotificationLifecycle.cancel(identifiers: [requestID])
    }

    private static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

// MARK: - Timestamp-matched wrist motion

struct TimestampedWristMotionEvidence: Equatable, Sendable {
    let movementG: Double
    let observedAt: Date
    let sampleCount: Int

    func value(relativeTo eventDate: Date, maximumSkew: TimeInterval = 90) -> Double? {
        guard movementG.isFinite,
              abs(eventDate.timeIntervalSince(observedAt)) <= maximumSkew else { return nil }
        return movementG
    }
}

enum StressEvidencePolicy {
    static let maximumPhysiologyAge: TimeInterval = 15
    static let maximumRRBufferGap: TimeInterval = 30

    /// A rolling HRV window may span adjacent live packets, but never a transport gap or a clock jump.
    /// The first packet has no previous receipt and starts a new buffer naturally.
    static func shouldResetRRBuffer(
        previousReceivedAt: Date?,
        currentReceivedAt: Date
    ) -> Bool {
        guard let previousReceivedAt else { return false }
        let gap = currentReceivedAt.timeIntervalSince(previousReceivedAt)
        return gap < 0 || gap > maximumRRBufferGap
    }

    /// Return the contemporaneous wrist movement only when every source-level credibility gate passes.
    /// This runs before `StressOnsetDetector`, so an unencrypted/off-wrist/stale window cannot train its
    /// personal baseline, present an in-app check-in, post a notification, or request a band haptic.
    static func qualifiedMotion(
        now: Date,
        rrReceivedAt: Date?,
        heartRateReceivedAt: Date?,
        motion: TimestampedWristMotionEvidence?,
        connected: Bool,
        bonded: Bool,
        encryptedBond: Bool,
        worn: Bool
    ) -> Double? {
        guard connected, bonded, encryptedBond, worn,
              let rrReceivedAt,
              let heartRateReceivedAt,
              isFresh(rrReceivedAt, now: now),
              isFresh(heartRateReceivedAt, now: now)
        else { return nil }
        return motion?.value(relativeTo: rrReceivedAt)
    }

    private static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age <= maximumPhysiologyAge
    }
}

enum WristMotionEvidencePolicy {
    static let lookbackSeconds = 120
    static let maximumLatestAgeSeconds = 90
    static let maximumSampleGapSeconds = 10
    static let minimumSamples = 8
    static let minimumSpanSeconds = 10
    static let averagingWindowSeconds = 60

    /// Convert persisted gravity into a short movement estimate only when density and timestamps prove it
    /// overlaps the current physiological window. Sparse historical motion fails closed.
    static func derive(
        gravity: [GravitySample],
        nowSec: Int
    ) -> TimestampedWristMotionEvidence? {
        let rows = gravity
            .filter {
                $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                    && $0.ts <= nowSec + 5
                    && $0.ts >= nowSec - lookbackSeconds
            }
            .sorted { $0.ts < $1.ts }
        guard rows.count >= minimumSamples,
              let first = rows.first,
              let latest = rows.last,
              (0...maximumLatestAgeSeconds).contains(nowSec - latest.ts),
              latest.ts - first.ts >= minimumSpanSeconds else { return nil }
        guard !zip(rows, rows.dropFirst()).contains(where: {
            $1.ts - $0.ts > maximumSampleGapSeconds
        }) else { return nil }

        let recentStart = latest.ts - averagingWindowSeconds
        let recentRows = rows.filter { $0.ts >= recentStart }
        let intensities = WorkoutDetector.activitySeries(recentRows).dropFirst().map(\.intensity)
        guard !intensities.isEmpty else { return nil }
        let movement = intensities.reduce(0, +) / Double(intensities.count)
        guard movement.isFinite else { return nil }
        return TimestampedWristMotionEvidence(
            movementG: movement,
            observedAt: Date(timeIntervalSince1970: TimeInterval(latest.ts)),
            sampleCount: recentRows.count
        )
    }
}
