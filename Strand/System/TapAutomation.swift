import Foundation

/// One explicit action that a fresh band double-tap may consume.
///
/// Safety, medication, and emergency actions are deliberately absent. A gesture without screen
/// context is not strong enough evidence to confirm or cancel any of them.
struct PendingTapAutomation: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case alarmDismiss
        case hydrationConfirm
        case reminderAcknowledge

        fileprivate var priority: Int {
            switch self {
            case .alarmDismiss: return 300
            case .hydrationConfirm: return 200
            case .reminderAcknowledge: return 100
            }
        }
    }

    let token: String
    let kind: Kind
    /// An action-specific, already-validated integer. Hydration stores millilitres here.
    let value: Int
    /// Identity of the reminder occurrence this action answers, such as a hydration slot token.
    let contextKey: String?
    let createdAt: Date
    let expiresAt: Date

    init(
        token: String = UUID().uuidString,
        kind: Kind,
        value: Int = 0,
        contextKey: String? = nil,
        now: Date = Date(),
        windowMinutes: Int
    ) {
        self.token = token
        self.kind = kind
        self.value = value
        self.contextKey = contextKey
        createdAt = now
        expiresAt = now.addingTimeInterval(TimeInterval(min(max(windowMinutes, 1), 30) * 60))
    }

    func isActive(at date: Date) -> Bool {
        date >= createdAt && date < expiresAt
    }
}

/// Pure single-slot state machine. A wake alarm outranks any reminder already waiting; lower-priority
/// reminders cannot displace it. Consumption clears the token before its caller performs side effects,
/// making a repeated callback or gesture an exact no-op.
struct PendingTapAutomationState: Equatable, Sendable {
    private(set) var pending: PendingTapAutomation?

    @discardableResult
    mutating func arm(_ action: PendingTapAutomation, now: Date = Date()) -> Bool {
        discardExpired(at: now)
        if let pending, pending.kind.priority > action.kind.priority { return false }
        pending = action
        return true
    }

    mutating func consume(now: Date = Date()) -> PendingTapAutomation? {
        discardExpired(at: now)
        guard let action = pending else { return nil }
        pending = nil
        return action
    }

    mutating func discardExpired(at date: Date = Date()) {
        if let pending, !pending.isActive(at: date) { self.pending = nil }
    }

    mutating func clear(kind: PendingTapAutomation.Kind) {
        if pending?.kind == kind { pending = nil }
    }
}

/// Small durable wrapper used by the app-level model. Persistence keeps a reminder window alive across
/// an ordinary view rebuild, while the expiring token prevents a stale launch from logging anything.
enum TapAutomationStore {
    static let storageKey = "tapAutomation.pending.v1"

    static func arm(_ action: PendingTapAutomation, now: Date = Date()) {
        var state = load()
        guard state.arm(action, now: now) else { return }
        save(state)
    }

    static func consume(now: Date = Date()) -> PendingTapAutomation? {
        var state = load()
        let action = state.consume(now: now)
        save(state)
        return action
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static func clear(kind: PendingTapAutomation.Kind) {
        var state = load()
        state.clear(kind: kind)
        save(state)
    }

    private static func load() -> PendingTapAutomationState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let action = try? JSONDecoder().decode(PendingTapAutomation.self, from: data)
        else { return PendingTapAutomationState() }
        return PendingTapAutomationState(pending: action)
    }

    private static func save(_ state: PendingTapAutomationState) {
        guard let pending = state.pending,
              let data = try? JSONEncoder().encode(pending)
        else {
            clear()
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum TapAutomationPreferences {
    static let alarmDoubleTapEnabledKey = "tapAutomation.alarm.enabled"
    static let alarmWindowMinutesKey = "tapAutomation.alarm.windowMinutes"

    static var alarmDoubleTapEnabled: Bool {
        UserDefaults.standard.bool(forKey: alarmDoubleTapEnabledKey)
    }

    static var alarmWindowMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: alarmWindowMinutesKey) as? Int ?? 15
        return min(max(raw, 5), 30)
    }

    static func armAlarmDismiss(now: Date = Date()) {
        guard alarmDoubleTapEnabled else { return }
        TapAutomationStore.arm(
            PendingTapAutomation(
                kind: .alarmDismiss,
                now: now,
                windowMinutes: alarmWindowMinutes
            ),
            now: now
        )
    }
}
