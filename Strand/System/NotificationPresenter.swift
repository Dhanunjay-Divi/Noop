import Foundation
import NoopRemoteSync
import UserNotifications

enum LocalNotificationLifecycleState: String, Codable, CaseIterable, Sendable {
    case scheduled
    case presented
    case cancelled
    case suppressed
    case capacityLimited
    case unknown
}

struct LocalNotificationLifecycleRecord: Codable, Equatable, Sendable {
    let identifier: String
    let categoryIdentifier: String
    let state: LocalNotificationLifecycleState
    let timestamp: Date
}

/// A deliberately narrow, bounded record of app-observable notification lifecycle events.
///
/// It never stores notification copy, userInfo, routes, health values, errors, or delivery claims.
/// `scheduled` means Notification Center accepted a request. `presented` means a delegate callback was
/// observed. Neither state implies that an unobserved background banner, sound, or device alert occurred.
final class LocalNotificationLifecycleLedger: @unchecked Sendable {
    static let shared = LocalNotificationLifecycleLedger()
    static let defaultCapacity = 128

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey: String
    private let capacity: Int
    private var recordsStorage: [LocalNotificationLifecycleRecord]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "diagnostics.localNotificationLifecycle.v1",
        capacity: Int = defaultCapacity
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.capacity = max(1, capacity)
        let decoded = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([LocalNotificationLifecycleRecord].self, from: $0)
        } ?? []
        self.recordsStorage = Array(
            decoded.map(Self.sanitizedRecord).suffix(max(1, capacity))
        )
        if let data = try? JSONEncoder().encode(recordsStorage) {
            defaults.set(data, forKey: storageKey)
        }
    }

    func record(
        identifier: String,
        categoryIdentifier: String,
        state: LocalNotificationLifecycleState,
        timestamp: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(
            LocalNotificationLifecycleRecord(
                identifier: Self.stableIdentifier(identifier),
                categoryIdentifier: Self.stableCategory(categoryIdentifier),
                state: state,
                timestamp: timestamp
            )
        )
    }

    /// Cancellation records an app request to remove a notification. Notification Center does not report
    /// whether a matching pending or presented request existed, so no stronger claim is made.
    func recordCancellation(
        identifier: String,
        categoryIdentifier: String? = nil,
        timestamp: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        let stableIdentifier = Self.stableIdentifier(identifier)
        let category = categoryIdentifier.map {
            Self.stableCategory($0)
        } ?? recordsStorage.last(where: {
            $0.identifier == stableIdentifier
        })?.categoryIdentifier ?? "unknown"
        appendLocked(
            LocalNotificationLifecycleRecord(
                identifier: stableIdentifier,
                categoryIdentifier: category,
                state: .cancelled,
                timestamp: timestamp
            )
        )
    }

    func records() -> [LocalNotificationLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsStorage
    }

    func serializedRecords() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return (try? JSONEncoder().encode(recordsStorage)) ?? Data("[]".utf8)
    }

    func diagnosticLines(limit: Int = 24) -> [String] {
        let snapshot = Array(records().suffix(max(0, limit)))
        var lines = [
            String(repeating: "-", count: 40),
            "Local notification lifecycle",
            "Evidence only: scheduled=OS accepted request; presented=app delegate callback observed.",
        ]
        guard !snapshot.isEmpty else {
            lines.append("(no lifecycle events recorded)")
            return lines
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lines += snapshot.map {
            "\(formatter.string(from: $0.timestamp)) "
                + "state=\($0.state.rawValue) "
                + "id=\($0.identifier) "
                + "category=\($0.categoryIdentifier)"
        }
        return lines
    }

    private func appendLocked(_ record: LocalNotificationLifecycleRecord) {
        recordsStorage.append(record)
        if recordsStorage.count > capacity {
            recordsStorage.removeFirst(recordsStorage.count - capacity)
        }
        if let data = try? JSONEncoder().encode(recordsStorage) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func sanitizedRecord(
        _ record: LocalNotificationLifecycleRecord
    ) -> LocalNotificationLifecycleRecord {
        LocalNotificationLifecycleRecord(
            identifier: stableIdentifier(record.identifier),
            categoryIdentifier: stableCategory(record.categoryIdentifier),
            state: record.state,
            timestamp: record.timestamp
        )
    }

    /// Maps producer-owned request identifiers to a fixed diagnostic vocabulary.
    /// Prefixes intentionally discard dates, reminder slots, metric names, and other suffixes.
    static func stableIdentifier(_ raw: String) -> String {
        let canonical = Set([
            "coach_check_in", "connection", "auto_workout", "strain_target",
            "morning_recap",
            "safety_check_in", "safety_contact_setup", "safety_sos_result",
            "illness_check_in", "daily_review", "inactivity", "smart_alarm",
            "battery", "wind_down", "hydration", "metric_review",
            "contextual_vital", "adaptive_day", "caffeine_cutoff", "stale_sync",
            "managed_poke", "unknown",
        ])
        if canonical.contains(raw) {
            return raw
        }
        let exact: [String: String] = [
            "noop.coach.local-check-in": "coach_check_in",
            "bluetooth-powered-off": "connection",
            "auto-workout-candidate": "auto_workout",
            "strain-target": "strain_target",
            "morning-recap": "morning_recap",
            "noop.safety.personal-check-in": "safety_check_in",
            "noop.safety.contacts.setup": "safety_contact_setup",
            "safety-gesture-result": "safety_sos_result",
            "wellness-check-in": "illness_check_in",
            "noop.band-sync.stale": "stale_sync",
            "managed-poke": "managed_poke",
            "contextual-adaptivePlannedWorkout": "adaptive_day",
            "contextual-adaptivePlannedWorkout-boundary": "adaptive_day",
        ]
        if let mapped = exact[raw] {
            return mapped
        }
        let prefixes: [(String, String)] = [
            ("daily-review-", "daily_review"),
            ("inactivity-", "inactivity"),
            ("smart-alarm-", "smart_alarm"),
            ("battery-", "battery"),
            ("wind-down-nudge", "wind_down"),
            ("hydration-reminder", "hydration"),
            ("metric-review-", "metric_review"),
            ("contextual-", "contextual_vital"),
            ("vital-", "contextual_vital"),
            ("caffeine-cutoff-", "caffeine_cutoff"),
            ("illness-", "illness_check_in"),
            ("managed-poke-", "managed_poke"),
        ]
        return prefixes.first(where: { raw.hasPrefix($0.0) })?.1 ?? "unknown"
    }

    static func stableCategory(_ raw: String) -> String {
        switch raw {
        case "":
            return "none"
        case DailyReviewNotifications.privacyCategoryID, "private":
            return "private"
        case "none", "unknown":
            return raw
        default:
            return "unknown"
        }
    }
}

struct LocalNotificationReconciliationResult: Equatable, Sendable {
    let acceptedIdentifiers: [String]
    let retainedIdentifiers: [String]
    let capacityLimitedIdentifiers: [String]
    let failedIdentifiers: [String]
    let removedIdentifiers: [String]

    var acceptedCount: Int { acceptedIdentifiers.count }
    var activeIdentifiers: [String] {
        Array(Set(acceptedIdentifiers + retainedIdentifiers)).sorted()
    }
    var activeCount: Int { activeIdentifiers.count }

    func accepted(_ identifier: String) -> Bool {
        acceptedIdentifiers.contains(identifier)
    }

    init(
        acceptedIdentifiers: [String],
        retainedIdentifiers: [String] = [],
        capacityLimitedIdentifiers: [String],
        failedIdentifiers: [String],
        removedIdentifiers: [String]
    ) {
        self.acceptedIdentifiers = acceptedIdentifiers
        self.retainedIdentifiers = retainedIdentifiers
        self.capacityLimitedIdentifiers = capacityLimitedIdentifiers
        self.failedIdentifiers = failedIdentifiers
        self.removedIdentifiers = removedIdentifiers
    }
}

@MainActor
struct LocalNotificationCenterClient {
    let pendingRequests: () async -> [UNNotificationRequest]
    let add: (UNNotificationRequest) async throws -> Void
    let removePending: ([String]) -> Void

    static func system(
        center: UNUserNotificationCenter = .current()
    ) -> LocalNotificationCenterClient {
        LocalNotificationCenterClient(
            pendingRequests: {
                await withCheckedContinuation { continuation in
                    center.getPendingNotificationRequests {
                        continuation.resume(returning: $0)
                    }
                }
            },
            add: { request in
                try await center.add(request)
            },
            removePending: { identifiers in
                center.removePendingNotificationRequests(
                    withIdentifiers: identifiers
                )
            }
        )
    }
}

enum LocalNotificationCapacityPolicy {
    static let systemCapacity = 64
    static let reservedPrioritySlots = 4
    private static let staleSyncRequestIdentifier = "noop.band-sync.stale"

    enum Priority: Int, Comparable {
        case safetyCritical
        case userExplicit
        case transient
        case routine
        case maintenance

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var isPriorityProtected: Bool {
            self <= .transient
        }
    }

    struct Plan {
        let selectedCandidateRequests: [UNNotificationRequest]
        let selectedExistingRequests: [UNNotificationRequest]
        let capacityLimitedCandidateRequests: [UNNotificationRequest]
        let existingIdentifiersToRemove: [String]
    }

    private struct RankedRequest {
        let request: UNNotificationRequest
        let priority: Priority
        let nextFireDate: Date
        let isCandidate: Bool
    }

    static func plan(
        existingRequests: [UNNotificationRequest],
        candidateRequests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingExistingIdentifiers: Set<String> = [],
        capacity: Int = systemCapacity,
        reservedPrioritySlots: Int = reservedPrioritySlots,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Plan {
        let boundedCapacity = max(1, capacity)
        let boundedReserve = min(
            max(0, reservedPrioritySlots),
            boundedCapacity
        )
        let candidatesByID = requestsByIdentifier(candidateRequests)
        let replacementIDs = replacingIdentifiers
            .union(candidatesByID.keys)

        let existingByID = requestsByIdentifier(existingRequests)
        let retainedExisting = existingByID.values.filter {
            !replacementIDs.contains($0.identifier)
        }
        let preservedExisting = retainedExisting.filter {
            preservingExistingIdentifiers.contains($0.identifier)
        }
        let preservedExistingIDs = Set(
            preservedExisting.map(\.identifier)
        )
        let preservedRanked = preservedExisting.map {
            rankedRequest(
                $0,
                isCandidate: false,
                now: now,
                calendar: calendar
            )
        }.sorted(by: rankedBefore)
        let ranked = (
            retainedExisting.filter {
                !preservedExistingIDs.contains($0.identifier)
            }.map {
                rankedRequest(
                    $0,
                    isCandidate: false,
                    now: now,
                    calendar: calendar
                )
            }
            + candidatesByID.values.map {
                rankedRequest(
                    $0,
                    isCandidate: true,
                    now: now,
                    calendar: calendar
                )
            }
        ).sorted(by: rankedBefore)

        let selectedPreserved = Array(
            preservedRanked.prefix(boundedCapacity)
        )
        let remainingCapacity = max(
            0,
            boundedCapacity - selectedPreserved.count
        )
        let preservedPriorityCount = selectedPreserved.filter {
            $0.priority.isPriorityProtected
        }.count
        let remainingReserve = max(
            0,
            boundedReserve - preservedPriorityCount
        )
        let protected = ranked.filter(\.priority.isPriorityProtected)
        let unprotected = ranked.filter {
            !$0.priority.isPriorityProtected
        }
        let selectedRemaining: [RankedRequest]
        if protected.count >= remainingCapacity {
            selectedRemaining = Array(
                protected.prefix(remainingCapacity)
            )
        } else {
            let unprotectedAllowance = max(
                0,
                remainingCapacity - max(
                    remainingReserve,
                    protected.count
                )
            )
            selectedRemaining = protected
                + Array(unprotected.prefix(unprotectedAllowance))
        }
        let selected = selectedPreserved + selectedRemaining

        let selectedIDs = Set(selected.map(\.request.identifier))
        let selectedCandidates = selected
            .filter(\.isCandidate)
            .map(\.request)
        let selectedExisting = selected
            .filter { !$0.isCandidate }
            .map(\.request)
        let limitedCandidates = candidatesByID.values
            .filter { !selectedIDs.contains($0.identifier) }
            .sorted {
                rankedBefore(
                    rankedRequest(
                        $0,
                        isCandidate: true,
                        now: now,
                        calendar: calendar
                    ),
                    rankedRequest(
                        $1,
                        isCandidate: true,
                        now: now,
                        calendar: calendar
                    )
                )
            }
        let removals = existingByID.keys
            .filter { !selectedIDs.contains($0) }
            .sorted()

        return Plan(
            selectedCandidateRequests: selectedCandidates,
            selectedExistingRequests: selectedExisting,
            capacityLimitedCandidateRequests: limitedCandidates,
            existingIdentifiersToRemove: removals
        )
    }

    static func priority(
        for request: UNNotificationRequest
    ) -> Priority {
        let identifier = request.identifier
        if request.content.interruptionLevel == .timeSensitive
            || identifier == SafetyCheckInNotifications.requestIdentifier
            || identifier == "safety-gesture-result"
            || identifier.hasPrefix("noop.safety.")
            || identifier.hasPrefix("workout-caution-") {
            return .safetyCritical
        }
        if identifier.hasPrefix("smart-alarm-")
            || identifier == "strain-target"
            || identifier == "hydration-reminder-missed-response" {
            return .userExplicit
        }
        if request.trigger == nil {
            return .transient
        }
        if identifier == staleSyncRequestIdentifier
            || identifier.hasPrefix("battery-") {
            return .maintenance
        }
        if identifier.hasPrefix("wind-down-nudge")
            || identifier.hasPrefix("daily-review-")
            || identifier.hasPrefix("hydration-reminder-")
            || identifier.hasPrefix("metric-review-")
            || identifier.hasPrefix("contextual-")
            || identifier.hasPrefix("caffeine-cutoff-")
            || identifier.hasPrefix("inactivity-")
            || identifier == "wellness-check-in" {
            return .routine
        }
        // Preserve an unknown request as user-explicit until its ownership is
        // classified. This avoids deleting a legacy alarm merely to make room
        // for a new routine horizon.
        return .userExplicit
    }

    private static func requestsByIdentifier(
        _ requests: [UNNotificationRequest]
    ) -> [String: UNNotificationRequest] {
        requests.reduce(into: [:]) { result, request in
            result[request.identifier] = request
        }
    }

    private static func rankedRequest(
        _ request: UNNotificationRequest,
        isCandidate: Bool,
        now: Date,
        calendar: Calendar
    ) -> RankedRequest {
        RankedRequest(
            request: request,
            priority: priority(for: request),
            nextFireDate: nextFireDate(
                for: request,
                now: now,
                calendar: calendar
            ),
            isCandidate: isCandidate
        )
    }

    private static func rankedBefore(
        _ lhs: RankedRequest,
        _ rhs: RankedRequest
    ) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        if lhs.nextFireDate != rhs.nextFireDate {
            return lhs.nextFireDate < rhs.nextFireDate
        }
        return lhs.request.identifier < rhs.request.identifier
    }

    private static func nextFireDate(
        for request: UNNotificationRequest,
        now: Date,
        calendar: Calendar
    ) -> Date {
        guard let trigger = request.trigger else { return now }
        if let interval = trigger as? UNTimeIntervalNotificationTrigger {
            return now.addingTimeInterval(interval.timeInterval)
        }
        guard let calendarTrigger = trigger
            as? UNCalendarNotificationTrigger else {
            return .distantFuture
        }

        var resolvedCalendar = calendar
        let components = calendarTrigger.dateComponents
        if let timeZone = components.timeZone {
            resolvedCalendar.timeZone = timeZone
        }
        if !calendarTrigger.repeats,
           let absoluteDate = resolvedCalendar.date(from: components) {
            return absoluteDate
        }
        return resolvedCalendar.nextDate(
            after: now.addingTimeInterval(-1),
            matching: components,
            matchingPolicy: .nextTimePreservingSmallerComponents,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? .distantFuture
    }
}

/// Serializes every pending-request mutation against one observed Notification Center snapshot.
/// The coordinator never persists producer state; it returns the exact identifiers the OS accepted.
@MainActor
final class LocalNotificationCapacityCoordinator {
    static let shared = LocalNotificationCapacityCoordinator()

    private let capacity: Int
    private let reservedPrioritySlots: Int
    private var isReconciling = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        capacity: Int = LocalNotificationCapacityPolicy.systemCapacity,
        reservedPrioritySlots: Int =
            LocalNotificationCapacityPolicy.reservedPrioritySlots
    ) {
        self.capacity = max(1, capacity)
        self.reservedPrioritySlots = min(
            max(0, reservedPrioritySlots),
            self.capacity
        )
    }

    func reconcile(
        candidateRequests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingExistingIdentifiers: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        isStillCurrent: @MainActor () -> Bool = { true },
        client: LocalNotificationCenterClient
    ) async -> LocalNotificationReconciliationResult {
        await acquire()
        defer { release() }

        guard isStillCurrent() else {
            return LocalNotificationReconciliationResult(
                acceptedIdentifiers: [],
                retainedIdentifiers: [],
                capacityLimitedIdentifiers: [],
                failedIdentifiers: [],
                removedIdentifiers: []
            )
        }
        let existingRequests = await client.pendingRequests()
        guard isStillCurrent() else {
            return LocalNotificationReconciliationResult(
                acceptedIdentifiers: [],
                retainedIdentifiers: [],
                capacityLimitedIdentifiers: [],
                failedIdentifiers: [],
                removedIdentifiers: []
            )
        }
        let candidatesByID = candidateRequests.reduce(into: [
            String: UNNotificationRequest
        ]()) { result, request in
            result[request.identifier] = request
        }
        var failedIDs = Set<String>()
        var attemptedIDs = Set<String>()
        var acceptedByID: [String: UNNotificationRequest] = [:]
        var removedExistingIDs = Set<String>()
        var finalPlan = LocalNotificationCapacityPolicy.plan(
            existingRequests: existingRequests,
            candidateRequests: Array(candidatesByID.values),
            replacingIdentifiers: replacingIdentifiers,
            preservingExistingIdentifiers: preservingExistingIdentifiers,
            capacity: capacity,
            reservedPrioritySlots: reservedPrioritySlots,
            now: now,
            calendar: calendar
        )

        while true {
            let eligibleCandidates = candidatesByID.values.filter {
                !failedIDs.contains($0.identifier)
            }
            let effectiveReplacementIDs = replacingIdentifiers
                .subtracting(failedIDs)
            let plan = LocalNotificationCapacityPolicy.plan(
                existingRequests: existingRequests,
                candidateRequests: eligibleCandidates,
                replacingIdentifiers: effectiveReplacementIDs,
                preservingExistingIdentifiers: preservingExistingIdentifiers,
                capacity: capacity,
                reservedPrioritySlots: reservedPrioritySlots,
                now: now,
                calendar: calendar
            )
            finalPlan = plan

            let newRemovals = plan.existingIdentifiersToRemove.filter {
                removedExistingIDs.insert($0).inserted
            }
            if !newRemovals.isEmpty {
                client.removePending(newRemovals)
            }

            let requestsToAttempt = plan.selectedCandidateRequests.filter {
                !attemptedIDs.contains($0.identifier)
            }
            guard !requestsToAttempt.isEmpty else { break }

            for request in requestsToAttempt {
                guard isStillCurrent() else { break }
                attemptedIDs.insert(request.identifier)
                do {
                    try await client.add(request)
                    acceptedByID[request.identifier] = request
                } catch {
                    failedIDs.insert(request.identifier)
                    acceptedByID.removeValue(forKey: request.identifier)
                }
            }
            guard isStillCurrent() else { break }
        }

        let finalSelectedCandidateIDs = Set(
            finalPlan.selectedCandidateRequests.map(\.identifier)
        )
        let acceptedButDeselectedIDs = Set(acceptedByID.keys)
            .subtracting(finalSelectedCandidateIDs)
        if !acceptedButDeselectedIDs.isEmpty {
            client.removePending(acceptedButDeselectedIDs.sorted())
        }
        let acceptedIDs = finalPlan.selectedCandidateRequests.compactMap {
            acceptedByID[$0.identifier] == nil ? nil : $0.identifier
        }
        let selectedExistingIDs = Set(
            finalPlan.selectedExistingRequests.map(\.identifier)
        )
        var restoredExistingIDs = Set<String>()
        for request in finalPlan.selectedExistingRequests
        where removedExistingIDs.contains(request.identifier) {
            do {
                try await client.add(request)
                restoredExistingIDs.insert(request.identifier)
            } catch {
                // Existing request restoration is best-effort. The producer's
                // accepted set remains truthful and the queue stays bounded.
            }
        }

        let capacityLimitedIDs = candidatesByID.keys
            .filter {
                !finalSelectedCandidateIDs.contains($0)
                    && !failedIDs.contains($0)
            }
            .sorted()
        let finalRemovedIDs = removedExistingIDs
            .subtracting(restoredExistingIDs)
            .subtracting(Set(acceptedIDs))
            .filter { !selectedExistingIDs.contains($0) }
            .sorted()
        let retainedExistingIDs = selectedExistingIDs
            .subtracting(removedExistingIDs)
            .union(restoredExistingIDs)
            .intersection(
                replacingIdentifiers.union(
                    preservingExistingIdentifiers
                )
            )
            .sorted()

        let result = LocalNotificationReconciliationResult(
            acceptedIdentifiers: acceptedIDs,
            retainedIdentifiers: retainedExistingIDs,
            capacityLimitedIdentifiers: capacityLimitedIDs,
            failedIdentifiers: failedIDs.sorted(),
            removedIdentifiers: finalRemovedIDs
        )
        guard isStillCurrent() else {
            if !result.acceptedIdentifiers.isEmpty {
                client.removePending(result.acceptedIdentifiers)
            }
            return LocalNotificationReconciliationResult(
                acceptedIdentifiers: [],
                retainedIdentifiers: [],
                capacityLimitedIdentifiers: [],
                failedIdentifiers: [],
                removedIdentifiers: result.removedIdentifiers
            )
        }
        return result
    }

    private func acquire() async {
        guard isReconciling else {
            isReconciling = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isReconciling = false
            return
        }
        waiters.removeFirst().resume()
    }
}

enum LocalNotificationSchedulingError: Error {
    case capacityLimited
    case notificationCenterRejected
}

/// Central boundary for local notification adds and removals. Callers still own authorization and policy;
/// this boundary records only the observable result of their interaction with Notification Center.
enum LocalNotificationLifecycle {
    @MainActor
    static func reconcile(
        candidateRequests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingExistingIdentifiers: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        coordinator: LocalNotificationCapacityCoordinator? = nil,
        isStillCurrent: @MainActor () -> Bool = { true },
        client: LocalNotificationCenterClient
    ) async -> LocalNotificationReconciliationResult {
        let requestsByID = candidateRequests.reduce(into: [
            String: UNNotificationRequest
        ]()) { result, request in
            result[request.identifier] = request
        }
        let result = await (coordinator ?? .shared).reconcile(
            candidateRequests: Array(requestsByID.values),
            replacingIdentifiers: replacingIdentifiers,
            preservingExistingIdentifiers: preservingExistingIdentifiers,
            now: now,
            calendar: calendar,
            isStillCurrent: isStillCurrent,
            client: client
        )

        for identifier in result.removedIdentifiers {
            LocalNotificationLifecycleLedger.shared.recordCancellation(
                identifier: identifier
            )
        }
        for identifier in result.acceptedIdentifiers {
            guard let request = requestsByID[identifier] else { continue }
            record(request, state: .scheduled)
        }
        for identifier in result.capacityLimitedIdentifiers {
            guard let request = requestsByID[identifier] else { continue }
            record(request, state: .capacityLimited)
        }
        for identifier in result.failedIdentifiers {
            guard let request = requestsByID[identifier] else { continue }
            record(request, state: .unknown)
        }
        return result
    }

    @MainActor
    static func reconcile(
        candidateRequests: [UNNotificationRequest],
        replacingIdentifiers: Set<String>,
        preservingExistingIdentifiers: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        coordinator: LocalNotificationCapacityCoordinator? = nil,
        isStillCurrent: @MainActor () -> Bool = { true },
        on center: UNUserNotificationCenter = .current()
    ) async -> LocalNotificationReconciliationResult {
        await reconcile(
            candidateRequests: candidateRequests,
            replacingIdentifiers: replacingIdentifiers,
            preservingExistingIdentifiers: preservingExistingIdentifiers,
            now: now,
            calendar: calendar,
            coordinator: coordinator,
            isStillCurrent: isStillCurrent,
            client: .system(center: center)
        )
    }

    @MainActor
    static func schedule(
        _ request: UNNotificationRequest,
        on center: UNUserNotificationCenter = .current()
    ) async throws {
        let result = await reconcile(
            candidateRequests: [request],
            replacingIdentifiers: [request.identifier],
            on: center
        )
        if result.accepted(request.identifier) {
            return
        }
        if result.capacityLimitedIdentifiers.contains(request.identifier) {
            throw LocalNotificationSchedulingError.capacityLimited
        }
        throw LocalNotificationSchedulingError.notificationCenterRejected
    }

    @MainActor
    static func schedule(
        _ request: UNNotificationRequest,
        on center: UNUserNotificationCenter = .current()
    ) {
        Task { @MainActor in
            _ = try? await schedule(request, on: center)
        }
    }

    static func cancel(
        identifiers: [String],
        pending: Bool = true,
        presented: Bool = false,
        on center: UNUserNotificationCenter = .current()
    ) {
        guard !identifiers.isEmpty else { return }
        if pending {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        if presented {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        for identifier in identifiers {
            LocalNotificationLifecycleLedger.shared.recordCancellation(
                identifier: identifier
            )
        }
    }

    static func suppressed(
        identifier: String,
        categoryIdentifier: String = "none"
    ) {
        LocalNotificationLifecycleLedger.shared.record(
            identifier: identifier,
            categoryIdentifier: categoryIdentifier,
            state: .suppressed
        )
    }

    static func presented(_ request: UNNotificationRequest) {
        record(request, state: .presented)
    }

    private static func record(
        _ request: UNNotificationRequest,
        state: LocalNotificationLifecycleState
    ) {
        LocalNotificationLifecycleLedger.shared.record(
            identifier: request.identifier,
            categoryIdentifier: request.content.categoryIdentifier,
            state: state
        )
    }
}

/// Foreground presentation delegate for the app's local notifications (wind-down nudge, smart-alarm
/// backup, battery/illness alerts).
///
/// Without a `UNUserNotificationCenterDelegate`, iOS/macOS suppress a notification's banner while the
/// app is in the FOREGROUND (the default). A user testing a reminder with the app open would see
/// nothing and conclude notifications are broken. Returning banner + sound + list here makes them
/// visible whether the app is open or not — matching what the user expects from a reminder.
///
/// Cross-platform (iOS + macOS). Register once at launch:
/// `UNUserNotificationCenter.current().delegate = NotificationPresenter.shared`.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    private override init() { super.init() }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
#if os(iOS)
        if ManagedSafetyPushPayload.incidentID(
            from: notification.request.content.userInfo
        ) != nil {
            Task { @MainActor in
                guard ManagedRuntimeAuthorization.isAllowed else {
                    AppDiagnosticsRecorder.shared.record(
                        "managed_safety.push_presented",
                        fields: [
                            "outcome": "deferred",
                            "failure_kind": "terms_required",
                        ]
                    )
                    completionHandler([])
                    return
                }
                LocalNotificationLifecycle.presented(notification.request)
                AppDiagnosticsRecorder.shared.record(
                    "managed_safety.push_presented",
                    fields: ["outcome": "foreground"]
                )
                ContextualActionCenter.shared.capture(notification.request)
                completionHandler([.banner, .sound, .list])
            }
            return
        }
#endif
        LocalNotificationLifecycle.presented(notification.request)
        Task { @MainActor in
            ContextualActionCenter.shared.capture(notification.request)
        }
        completionHandler([.banner, .sound, .list])
    }

    /// Route a tapped review reminder into the relevant top-level screen. The bridge persists first,
    /// which is essential during a cold launch: SwiftUI may not have mounted RootView/RootTabView yet.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // A response is direct evidence that Notification Center surfaced this request to the user. It
        // does not retroactively make any claim about other scheduled notifications.
        LocalNotificationLifecycle.presented(response.notification.request)
        Task { @MainActor in
            ContextualActionCenter.shared.capture(response.notification.request)
        }
        #if os(iOS)
        if let incidentID = ManagedSafetyPushPayload.incidentIDForUserResponse(
            from: response.notification.request.content.userInfo
        ) {
            NotificationRouteBridge.recordPending(.safety)
            Task { @MainActor in
                guard ManagedRuntimeAuthorization.isAllowed else {
                    AppDiagnosticsRecorder.shared.record(
                        "managed_safety.push_opened",
                        fields: [
                            "outcome": "deferred",
                            "failure_kind": "terms_required",
                        ]
                    )
                    return
                }
                AppDiagnosticsRecorder.shared.record(
                    "managed_safety.push_opened",
                    fields: ["outcome": "accepted"]
                )
                _ = await ManagedCloudService.shared
                    .handleManagedSafetyPush(incidentID: incidentID)
            }
        } else if let route = NotificationRouteBridge.route(
            from: response.notification.request.content.userInfo
        ) {
            NotificationRouteBridge.recordPending(route)
        }
        #else
        if let route = NotificationRouteBridge.route(
            from: response.notification.request.content.userInfo
        ) {
            NotificationRouteBridge.recordPending(route)
        }
        #endif
        completionHandler()
    }
}

// MARK: - Prominence policy

/// How loudly a notification is allowed to arrive.
///
/// iOS silences the default `.active` level under Focus and Do Not Disturb. Before this existed every
/// NOOP notification used that default, which produced two opposite defects at once: a safety check-in
/// the user had explicitly armed could be silenced by a Focus mode, while a strap-battery nudge arrived
/// with exactly the same prominence as that safety message.
///
/// The vocabulary is deliberately three-valued. Adding a fourth tier invites per-notification tuning,
/// and prominence creep is how apps train users to swipe everything away.
///
/// `.timeSensitive` requires the `com.apple.developer.usernotifications.time-sensitive` entitlement.
/// Without it iOS silently downgrades the request to `.active`, so the entitlement and this policy have
/// to travel together. It does NOT require, and NOOP does not request, the critical-alert entitlement:
/// that one pierces silent mode and is reserved for medical devices, which NOOP explicitly is not.
enum NotificationProminence {
    /// A safety flow the user armed themselves: check-ins and SOS results. Allowed to pierce Focus,
    /// because a safety feature that Do Not Disturb can mute is not a safety feature.
    case safetyCritical
    /// Everything score- or coaching-related. Keeps the ordinary `.active` behaviour.
    case standard
    /// Housekeeping the user never needs woken for: battery, review reminders, digests.
    case ambient

    var level: UNNotificationInterruptionLevel {
        switch self {
        case .safetyCritical: return .timeSensitive
        case .standard:       return .active
        case .ambient:        return .passive
        }
    }
}

extension UNMutableNotificationContent {
    /// Applies the prominence tier. Call this on every content object so the choice is explicit at the
    /// producer rather than inherited from an iOS default nobody chose.
    func applyProminence(_ prominence: NotificationProminence) {
        interruptionLevel = prominence.level
    }
}
