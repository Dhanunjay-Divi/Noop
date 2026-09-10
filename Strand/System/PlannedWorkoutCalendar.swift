import Combine
import Foundation
import StrandAnalytics
#if os(iOS)
import EventKit
#endif

enum PlannedWorkoutCalendarSettings {
    static let enabledKey = "contextualInterventions.plannedWorkoutCalendarEnabled"

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}

struct PlannedWorkoutCalendarSnapshot: Equatable, Sendable {
    let day: String
    let startSec: Int
    let endSec: Int
    let observedAtSec: Int
    let revision: Int

    /// Today uses a 04:00 logical-day boundary while EventKit queries the civil calendar day.
    /// The store has already proved this is a future event on the current civil day; re-key only at
    /// the planning boundary so a 01:00 refresh can still advise about that afternoon's workout.
    func plannedWorkout(forPlanningDay planningDay: String) -> DailyActionPlanner.PlannedWorkout {
        .init(day: planningDay, startSec: startSec, endSec: endSec)
    }
}

#if os(iOS)
private func plannedWorkoutWasDeclinedByCurrentUser(_ event: EKEvent) -> Bool {
    event.attendees?.contains { participant in
        participant.isCurrentUser && participant.participantStatus == .declined
    } == true
}
#endif

/// Ephemeral calendar boundary for planned-workout guidance.
///
/// Event content is classified inside the query and discarded there. The only published state is a
/// generic same-day time window; nothing is written to UserDefaults, SQLite, diagnostics, or a network.
@MainActor
final class PlannedWorkoutCalendarStore: ObservableObject {
    static let shared = PlannedWorkoutCalendarStore()
    static let providerDidChange = Notification.Name(
        "noop.calendar.plannedWorkoutProviderDidChange"
    )

    enum AccessOutcome: Equatable, Sendable {
        case enabled
        case denied
        case unavailable
    }

    @Published private(set) var snapshot: PlannedWorkoutCalendarSnapshot?

    private var revision = 0
    private var requestGeneration = 0
    private var lastRefreshAt: Date?
    private var lastRefreshDay: String?
    private let cacheLifetime: TimeInterval = 5 * 60
    #if os(iOS)
    private let permissionStore = EKEventStore()
    private var eventStoreObserver: NSObjectProtocol?
    #endif

    private init() {
        #if os(iOS)
        eventStoreObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleProviderChange()
            }
        }
        #endif
    }

    deinit {
        #if os(iOS)
        if let eventStoreObserver {
            NotificationCenter.default.removeObserver(eventStoreObserver)
        }
        #endif
    }

    func requestAccess(
        completion: (@MainActor @Sendable (AccessOutcome) -> Void)? = nil
    ) {
        #if os(iOS)
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            completion?(.enabled)
            Task { @MainActor in _ = await refresh(force: true) }
        case .notDetermined:
            Task { @MainActor in
                do {
                    let granted = try await permissionStore.requestFullAccessToEvents()
                    if granted {
                        _ = await refresh(force: true)
                    } else {
                        clear()
                    }
                    completion?(granted ? .enabled : .denied)
                } catch {
                    clear()
                    completion?(.denied)
                }
            }
        case .denied, .restricted, .writeOnly:
            clear()
            completion?(.denied)
        @unknown default:
            clear()
            completion?(.unavailable)
        }
        #else
        completion?(.unavailable)
        #endif
    }

    func clear() {
        requestGeneration &+= 1
        snapshot = nil
        lastRefreshAt = nil
        lastRefreshDay = nil
        ContextualInterventionCenter.invalidatePlannedWorkoutCandidate()
    }

    func handleProviderChange() async {
        clear()
        _ = await refresh(force: true)
        guard ContextualInterventionSettings.adaptiveDayGuidanceEnabled,
              PlannedWorkoutCalendarSettings.enabled else { return }
        NotificationCenter.default.post(name: Self.providerDidChange, object: nil)
    }

    @discardableResult
    func refresh(now: Date = Date(), force: Bool = false) async
        -> PlannedWorkoutCalendarSnapshot? {
        guard ContextualInterventionSettings.adaptiveDayGuidanceEnabled,
              PlannedWorkoutCalendarSettings.enabled else {
            clear()
            return nil
        }

        let day = Self.dayKey(now)
        let authorization = Self.authorizationCategory()
        #if os(iOS)
        guard authorization == "full_access" else {
            clear()
            lastRefreshAt = now
            lastRefreshDay = day
            let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
                "calendar.workout_plan_refresh",
                fields: ["permission_state": authorization]
            )
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "permission_unavailable",
                fields: ["candidate_bucket": "zero"]
            )
            return nil
        }
        #endif
        if !force,
           lastRefreshDay == day,
           let lastRefreshAt,
           now.timeIntervalSince(lastRefreshAt) >= 0,
           now.timeIntervalSince(lastRefreshAt) < cacheLifetime {
            return snapshot
        }

        requestGeneration &+= 1
        let request = requestGeneration
        let diagnostic = AppDiagnosticsRecorder.shared.beginOperation(
            "calendar.workout_plan_refresh",
            fields: ["permission_state": authorization]
        )

        #if os(iOS)
        let result = await Self.query(now: now)
        guard request == requestGeneration else {
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "superseded",
                fields: ["candidate_bucket": "zero"]
            )
            return nil
        }
        guard ContextualInterventionSettings.adaptiveDayGuidanceEnabled,
              PlannedWorkoutCalendarSettings.enabled,
              Self.authorizationCategory() == "full_access" else {
            clear()
            AppDiagnosticsRecorder.shared.endOperation(
                diagnostic,
                outcome: "access_changed",
                fields: ["candidate_bucket": "zero"]
            )
            return nil
        }
        revision &+= 1
        snapshot = result.window.map {
            PlannedWorkoutCalendarSnapshot(
                day: day,
                startSec: $0.startSec,
                endSec: $0.endSec,
                observedAtSec: Int(now.timeIntervalSince1970),
                revision: revision
            )
        }
        lastRefreshAt = now
        lastRefreshDay = day
        AppDiagnosticsRecorder.shared.endOperation(
            diagnostic,
            outcome: result.window == nil ? "empty" : "matched",
            fields: ["candidate_bucket": result.candidateBucket]
        )
        return snapshot
        #else
        snapshot = nil
        lastRefreshAt = now
        lastRefreshDay = day
        AppDiagnosticsRecorder.shared.endOperation(
            diagnostic,
            outcome: "platform_unavailable",
            fields: ["candidate_bucket": "zero"]
        )
        return nil
        #endif
    }

    static func hasCurrentReadAccess() -> Bool {
        authorizationCategory() == "full_access"
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    private static func authorizationCategory() -> String {
        #if os(iOS)
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return "full_access"
        case .writeOnly: return "write_only"
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
        #else
        return "platform_unavailable"
        #endif
    }

    #if os(iOS)
    private struct QueryResult: Sendable {
        let window: (startSec: Int, endSec: Int)?
        let candidateBucket: String
    }

    private static func query(now: Date) async -> QueryResult {
        await Task.detached(priority: .utility) {
            let store = EKEventStore()
            let calendar = Calendar.autoupdatingCurrent
            let startOfDay = calendar.startOfDay(for: now)
            guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
                return QueryResult(window: nil, candidateBucket: "zero")
            }
            let events = store.events(
                matching: store.predicateForEvents(
                    withStart: startOfDay,
                    end: endOfDay,
                    calendars: nil
                )
            )
            var candidates: [(startSec: Int, endSec: Int)] = []
            candidates.reserveCapacity(min(events.count, 8))
            for event in events {
                guard !event.isAllDay,
                      event.status != .canceled,
                      !plannedWorkoutWasDeclinedByCurrentUser(event),
                      event.startDate > now,
                      event.endDate > event.startDate,
                      PlannedWorkoutTitleClassifier.isWorkoutTitle(event.title)
                else { continue }
                let startSec = Int(event.startDate.timeIntervalSince1970)
                let endSec = Int(event.endDate.timeIntervalSince1970)
                let durationMinutes = (endSec - startSec) / 60
                guard durationMinutes >= DailyActionPlanner.minimumPlannedWorkoutMinutes,
                      durationMinutes <= DailyActionPlanner.maximumPlannedWorkoutMinutes
                else { continue }
                candidates.append((startSec, endSec))
            }
            candidates.sort {
                $0.startSec == $1.startSec
                    ? $0.endSec < $1.endSec
                    : $0.startSec < $1.startSec
            }
            let bucket = switch candidates.count {
            case 0: "zero"
            case 1: "one"
            default: "multiple"
            }
            return QueryResult(window: candidates.first, candidateBucket: bucket)
        }.value
    }
    #endif
}
