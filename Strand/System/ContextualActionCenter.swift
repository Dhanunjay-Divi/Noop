import Combine
import Foundation
import UserNotifications

enum ContextualActionKind: String, Codable, CaseIterable, Sendable {
    case hydration
    case breathe
    case journal
    case windDown
    case recovery

    var priority: Int {
        switch self {
        case .breathe: return 100
        case .recovery: return 85
        case .windDown: return 70
        case .hydration: return 60
        case .journal: return 45
        }
    }
}

struct ContextualAction: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: ContextualActionKind
    let title: String
    let detail: String
    let evidence: [String]
    let createdAt: Date
    let expiresAt: Date
    let amountML: Int?
}

enum ContextualActionPolicy {
    static let visibleLimit = 3

    static func visible(
        _ actions: [ContextualAction],
        now: Date,
        limit: Int = visibleLimit
    ) -> [ContextualAction] {
        let current = actions.filter { $0.expiresAt > now }
        let newestByKind = Dictionary(grouping: current, by: \.kind).compactMap { _, values in
            values.max { $0.createdAt < $1.createdAt }
        }
        return newestByKind.sorted {
            if $0.kind.priority != $1.kind.priority {
                return $0.kind.priority > $1.kind.priority
            }
            return $0.createdAt > $1.createdAt
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

/// Persistent in-app companion to accepted wellness notifications.
///
/// Signal engines and notification policies remain authoritative. This center only keeps a compact,
/// expiring action available after an accepted event, deduplicates it across relaunches, and protects
/// one-tap actions from repeated UI delivery. It never derives a diagnosis or invents a metric.
@MainActor
final class ContextualActionCenter: ObservableObject {
    static let shared = ContextualActionCenter()

    @Published private(set) var actions: [ContextualAction] = []
    @Published private(set) var processingIDs = Set<String>()

    private struct PersistedState: Codable {
        var actions: [ContextualAction]
        var dismissedIDs: [String]
        var completedIDs: [String]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var dismissedIDs = Set<String>()
    private var completedIDs = Set<String>()
    private var expiryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "contextualActions.state.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            actions = state.actions
            dismissedIDs = Set(state.dismissedIDs)
            completedIDs = Set(state.completedIDs)
        }
        removeExpired(now: Date())
    }

    var visibleActions: [ContextualAction] {
        ContextualActionPolicy.visible(actions, now: Date())
    }

    func presentHydration(
        fingerprint: String,
        amountML: Int? = nil,
        evidence: [String]? = nil,
        now: Date = Date()
    ) {
        let resolvedAmountML = amountML ?? HydrationReminders.doubleTapAmountML
        let resolvedEvidence = evidence ?? HydrationReminders.contextualActionEvidence
        present(
            kind: .hydration,
            fingerprint: fingerprint,
            title: String(localized: "Hydration check-in"),
            detail: String(localized: "Log one glass only after you drink it."),
            evidence: resolvedEvidence,
            observedAt: now,
            expiresAfter: 2 * 60 * 60,
            amountML: min(max(resolvedAmountML, 50), 1_000)
        )
    }

    func presentStress(
        fastRMSSD: Double?,
        baselineRMSSD: Double?,
        fingerprint: String,
        now: Date = Date()
    ) {
        var evidence = [String(localized: "Fresh wrist motion and heart rhythm data")]
        if let fastRMSSD, let baselineRMSSD,
           fastRMSSD.isFinite, baselineRMSSD.isFinite, baselineRMSSD > 0 {
            evidence.append(
                String(
                    format: String(localized: "Short-window HRV %.0f ms vs recent %.0f ms baseline"),
                    fastRMSSD,
                    baselineRMSSD
                )
            )
        }
        present(
            kind: .breathe,
            fingerprint: fingerprint,
            title: String(localized: "Stress check-in"),
            detail: String(localized: "A one-minute breathing cue is ready if it would help."),
            evidence: evidence,
            observedAt: now,
            expiresAfter: 45 * 60
        )
    }

    func presentRecovery(
        title: String,
        detail: String,
        fingerprint: String,
        evidence: [String],
        observedAt: Date,
        maximumAge: TimeInterval
    ) {
        present(
            kind: .recovery,
            fingerprint: fingerprint,
            title: title,
            detail: detail,
            evidence: Self.readableEvidence(evidence),
            observedAt: observedAt,
            expiresAfter: min(maximumAge, 18 * 60 * 60)
        )
    }

    func capture(
        _ request: UNNotificationRequest,
        observedAt: Date = Date()
    ) {
        let identifier = request.identifier
        let content = request.content
        let route = NotificationRouteBridge.route(from: content.userInfo)
        let fingerprint = "\(identifier):\(Self.localDayToken(observedAt))"

        if identifier.hasPrefix("hydration-reminder") || route == .hydration {
            presentHydration(fingerprint: fingerprint, now: observedAt)
        } else if identifier.hasPrefix("daily-review-evening") || route == .journal {
            present(
                kind: .journal,
                fingerprint: fingerprint,
                title: content.title.isEmpty ? String(localized: "Journal check-in") : content.title,
                detail: content.body.isEmpty
                    ? String(localized: "Add context for today while it is still fresh.")
                    : content.body,
                evidence: [String(localized: "No journal answer was recorded for this review")],
                observedAt: observedAt,
                expiresAfter: 8 * 60 * 60
            )
        } else if identifier.hasPrefix("wind-down-nudge") {
            present(
                kind: .windDown,
                fingerprint: fingerprint,
                title: content.title.isEmpty ? String(localized: "Wind down") : content.title,
                detail: content.body,
                evidence: [content.subtitle].filter { !$0.isEmpty },
                observedAt: observedAt,
                expiresAfter: 6 * 60 * 60
            )
        } else if identifier.hasPrefix("contextual-stressBreathing") || route == .breathe {
            presentStress(
                fastRMSSD: nil,
                baselineRMSSD: nil,
                fingerprint: fingerprint,
                now: observedAt
            )
        } else if identifier.hasPrefix("contextual-")
                    || identifier.hasPrefix("daily-review-morning") {
            present(
                kind: .recovery,
                fingerprint: fingerprint,
                title: content.title.isEmpty ? String(localized: "Recovery check-in") : content.title,
                detail: content.body,
                evidence: [String(localized: "Recent measured sleep and recovery context")],
                observedAt: observedAt,
                expiresAfter: 12 * 60 * 60
            )
        }
    }

    func importDeliveredNotifications(
        center: UNUserNotificationCenter = .current(),
        now: Date = Date()
    ) async {
        let delivered = await center.deliveredNotifications()
        for notification in delivered {
            capture(
                notification.request,
                observedAt: min(notification.date, now)
            )
        }
    }

    #if DEBUG
    func applyDemoActionsIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--demo-context-actions") else { return }
        let now = Date()
        presentHydration(
            fingerprint: "demo-hydration",
            amountML: 250,
            evidence: [
                String(localized: "Scheduled hydration check-in"),
                String(localized: "Higher Effort today")
            ],
            now: now
        )
        presentRecovery(
            title: String(localized: "Protect tonight’s recovery"),
            detail: String(localized: "A lighter evening can help preserve your planned sleep window."),
            fingerprint: "demo-recovery",
            evidence: ["current-sleep", "below-explicit-target"],
            observedAt: now,
            maximumAge: 12 * 60 * 60
        )
        presentStress(
            fastRMSSD: 31,
            baselineRMSSD: 48,
            fingerprint: "demo-stress",
            now: now
        )
    }
    #endif

    func dismiss(_ action: ContextualAction) {
        dismissedIDs.insert(action.id)
        actions.removeAll { $0.id == action.id }
        processingIDs.remove(action.id)
        persist()
    }

    func begin(_ action: ContextualAction) -> Bool {
        guard actions.contains(where: { $0.id == action.id }),
              !processingIDs.contains(action.id),
              !completedIDs.contains(action.id) else { return false }
        processingIDs.insert(action.id)
        return true
    }

    func finish(_ action: ContextualAction, succeeded: Bool) {
        processingIDs.remove(action.id)
        guard succeeded else { return }
        completedIDs.insert(action.id)
        actions.removeAll { $0.id == action.id }
        persist()
    }

    func complete(_ action: ContextualAction) {
        finish(action, succeeded: begin(action))
    }

    func removeExpired(now: Date = Date()) {
        let priorCount = actions.count
        actions.removeAll { $0.expiresAt <= now }
        processingIDs = processingIDs.intersection(Set(actions.map(\.id)))
        if actions.count != priorCount { persist() } else { scheduleExpiry() }
    }

    private func present(
        kind: ContextualActionKind,
        fingerprint: String,
        title: String,
        detail: String,
        evidence: [String],
        observedAt: Date,
        expiresAfter: TimeInterval,
        amountML: Int? = nil
    ) {
        let id = "\(kind.rawValue):\(fingerprint)"
        let expiresAt = observedAt.addingTimeInterval(max(60, expiresAfter))
        let now = Date()
        guard expiresAt > now,
              !dismissedIDs.contains(id),
              !completedIDs.contains(id) else { return }

        if actions.contains(where: { $0.id == id }) {
            removeExpired(now: now)
            return
        }

        // A foreground delegate callback can arrive immediately after the richer signal-specific action.
        // Preserve that version instead of replacing its measured evidence with generic notification copy.
        if let existing = actions.first(where: { $0.kind == kind }),
           now.timeIntervalSince(existing.createdAt) < 5 * 60,
           existing.evidence.count > evidence.count {
            return
        }

        actions.removeAll { $0.kind == kind }
        actions.append(
            ContextualAction(
                id: id,
                kind: kind,
                title: title,
                detail: detail,
                evidence: Array(evidence.filter { !$0.isEmpty }.prefix(3)),
                createdAt: observedAt,
                expiresAt: expiresAt,
                amountML: amountML
            )
        )
        persist()
    }

    private func persist() {
        actions = Array(actions.sorted { $0.createdAt > $1.createdAt }.prefix(12))
        dismissedIDs = Set(dismissedIDs.sorted().suffix(64))
        completedIDs = Set(completedIDs.sorted().suffix(64))
        let state = PersistedState(
            actions: actions,
            dismissedIDs: Array(dismissedIDs),
            completedIDs: Array(completedIDs)
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: storageKey)
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = actions.map(\.expiresAt).min() else {
            expiryTask = nil
            return
        }
        let delay = max(0, next.timeIntervalSinceNow)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.removeExpired()
        }
    }

    private static func localDayToken(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private static func readableEvidence(_ tokens: [String]) -> [String] {
        tokens.compactMap { token in
            switch token {
            case "current-sleep": return String(localized: "Today’s measured sleep")
            case "recent-sleep-window": return String(localized: "Latest measured sleep window")
            case "below-explicit-target": return String(localized: "Below your chosen sleep target")
            case "personal-sleep-timing": return String(localized: "Compared with your own recent timing")
            case "later-onset": return String(localized: "Sleep began later than your recent pattern")
            case "shorter-sleep": return String(localized: "Sleep duration was shorter than your recent pattern")
            case "timezone-east", "timezone-west": return String(localized: "Device time zone changed")
            case "offset-change": return String(localized: "A multi-hour local-time shift was observed")
            default: return token.isEmpty ? nil : token
            }
        }
    }
}
