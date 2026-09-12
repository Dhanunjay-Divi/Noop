import XCTest
import UserNotifications
@testable import Strand

@MainActor
final class LocalNotificationLifecycleLedgerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LocalNotificationLifecycleLedgerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLedgerRetainsOnlyNewestBoundedRecords() {
        let ledger = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 3
        )

        for index in 0..<5 {
            ledger.record(
                identifier: "hydration-reminder-\(480 + index)",
                categoryIdentifier: DailyReviewNotifications.privacyCategoryID,
                state: .scheduled,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(
            ledger.records().map(\.identifier),
            ["hydration", "hydration", "hydration"]
        )

        let reloaded = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 3
        )
        XCTAssertEqual(reloaded.records(), ledger.records())
    }

    func testSerializedLedgerContainsOnlyAllowedPrivacySafeFields() throws {
        let ledger = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 8
        )
        ledger.record(
            identifier: "daily-review-morning",
            categoryIdentifier: "noop.daily-review.private",
            state: .suppressed,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ledger.serializedRecords()
            ) as? [[String: Any]]
        )
        let record = try XCTUnwrap(object.first)
        XCTAssertEqual(
            Set(record.keys),
            ["identifier", "categoryIdentifier", "state", "timestamp"]
        )
        let encoded = String(decoding: ledger.serializedRecords(), as: UTF8.self)
        for forbidden in ["title", "body", "userInfo", "route", "health", "error"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
    }

    func testLedgerSanitizesUnstableTokensAndRecordsEveryLifecycleState() {
        let ledger = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 8
        )

        for (index, state) in LocalNotificationLifecycleState.allCases.enumerated() {
            ledger.record(
                identifier: index == 0
                    ? "contains private text"
                    : "metric-review-heart-rate-\(index)",
                categoryIdentifier: index == 0
                    ? "category/unsafe"
                    : DailyReviewNotifications.privacyCategoryID,
                state: state,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(
            ledger.records().map(\.state),
            LocalNotificationLifecycleState.allCases
        )
        XCTAssertEqual(ledger.records().first?.identifier, "unknown")
        XCTAssertEqual(ledger.records().first?.categoryIdentifier, "unknown")
        XCTAssertEqual(
            Set(ledger.records().dropFirst().map(\.identifier)),
            ["metric_review"]
        )
        XCTAssertEqual(
            Set(ledger.records().dropFirst().map(\.categoryIdentifier)),
            ["private"]
        )
    }

    func testConcurrentDelegateWritesRemainBoundedAndDecodable() {
        let ledger = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 64
        )
        let categoryIdentifier = DailyReviewNotifications.privacyCategoryID

        DispatchQueue.concurrentPerform(iterations: 256) { index in
            ledger.record(
                identifier: "hydration-reminder-\(index)",
                categoryIdentifier: categoryIdentifier,
                state: .presented,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(ledger.records().count, 64)
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                [LocalNotificationLifecycleRecord].self,
                from: ledger.serializedRecords()
            )
        )
    }

    func testCancellationUsesKnownCategoryAndDiagnosticsStateEvidenceBoundary() {
        let ledger = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 8
        )
        ledger.record(
            identifier: "daily-review-morning",
            categoryIdentifier: DailyReviewNotifications.privacyCategoryID,
            state: .scheduled,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        ledger.recordCancellation(
            identifier: "daily-review-morning",
            timestamp: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(ledger.records().last?.state, .cancelled)
        XCTAssertEqual(ledger.records().last?.identifier, "daily_review")
        XCTAssertEqual(ledger.records().last?.categoryIdentifier, "private")
        let lines = ledger.diagnosticLines()
        XCTAssertTrue(lines.contains {
            $0.contains("scheduled=OS accepted request")
        })
        XCTAssertTrue(lines.contains {
            $0.contains("state=cancelled id=daily_review category=private")
        })
    }

    func testLegacyDynamicIdentifiersAreScrubbedWhenLedgerLoads() throws {
        let legacy = [
            LocalNotificationLifecycleRecord(
                identifier: "hydration-reminder-765",
                categoryIdentifier: "noop.daily-review.private",
                state: .scheduled,
                timestamp: Date(timeIntervalSince1970: 1)
            ),
            LocalNotificationLifecycleRecord(
                identifier: "contextual-oxygen-low-20260824",
                categoryIdentifier: "private-health-topic",
                state: .presented,
                timestamp: Date(timeIntervalSince1970: 2)
            ),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "ledger")

        let ledger = LocalNotificationLifecycleLedger(
            defaults: defaults,
            storageKey: "ledger",
            capacity: 8
        )

        XCTAssertEqual(
            ledger.records().map(\.identifier),
            ["hydration", "contextual_vital"]
        )
        XCTAssertEqual(
            ledger.records().map(\.categoryIdentifier),
            ["private", "unknown"]
        )
        let encoded = String(decoding: ledger.serializedRecords(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("765"))
        XCTAssertFalse(encoded.contains("oxygen"))
        XCTAssertFalse(encoded.contains("health-topic"))
    }

    func testExistingDiagnosticExportIncludesNotificationLifecycleSection() {
        XCTAssertTrue(
            DebugDataDiagnostics.strapStateLines().contains(
                "Local notification lifecycle"
            )
        )
    }
}

@MainActor
final class LocalNotificationCapacityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_739_200)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testCoordinatorNeverExceedsSystemPendingCap() async {
        let protected = (0..<4).map {
            request(
                identifier: "noop.safety.capacity-\($0)",
                interval: TimeInterval(10_000 + $0)
            )
        }
        let routine = (0..<80).map {
            request(
                identifier: String(format: "daily-review-%03d", $0),
                interval: TimeInterval(60 + $0)
            )
        }
        let center = LocalNotificationCenterCapacitySpy()

        let result = await LocalNotificationCapacityCoordinator().reconcile(
            candidateRequests: protected + routine,
            replacingIdentifiers: [],
            now: now,
            calendar: calendar,
            client: center.client
        )

        XCTAssertEqual(result.acceptedCount, 64)
        XCTAssertEqual(result.capacityLimitedIdentifiers.count, 20)
        XCTAssertLessThanOrEqual(
            center.requests.count,
            LocalNotificationCapacityPolicy.systemCapacity
        )
        XCTAssertEqual(center.requests.count, result.acceptedCount)
        XCTAssertTrue(
            protected.allSatisfy {
                center.requests[$0.identifier] != nil
            }
        )
    }

    func testReservedSlotsRemainAvailableForEveryProtectedPriorityClass() {
        let safety = request(
            identifier: "noop.safety.user-armed",
            interval: 3_600
        )
        let userExplicit = request(
            identifier: "smart-alarm-user-selected",
            interval: 3_600
        )
        let transient = request(
            identifier: "transient-coach-check-in",
            interval: nil
        )
        let routine = (0..<8).map {
            request(
                identifier: String(format: "hydration-reminder-%03d", $0),
                interval: TimeInterval(60 + $0)
            )
        }

        let plan = LocalNotificationCapacityPolicy.plan(
            existingRequests: [],
            candidateRequests: routine + [transient, userExplicit, safety],
            replacingIdentifiers: [],
            capacity: 8,
            reservedPrioritySlots: 3,
            now: now,
            calendar: calendar
        )
        let selected = Set(
            plan.selectedCandidateRequests.map(\.identifier)
        )

        XCTAssertEqual(
            LocalNotificationCapacityPolicy.priority(for: safety),
            .safetyCritical
        )
        XCTAssertEqual(
            LocalNotificationCapacityPolicy.priority(for: userExplicit),
            .userExplicit
        )
        XCTAssertEqual(
            LocalNotificationCapacityPolicy.priority(for: transient),
            .transient
        )
        XCTAssertTrue(selected.isSuperset(of:
            [safety.identifier, userExplicit.identifier, transient.identifier]
        ))
        XCTAssertEqual(selected.count, 8)
        XCTAssertEqual(plan.capacityLimitedCandidateRequests.count, 3)
    }

    func testRoutineHorizonIsTrimmedBeforeProtectedRequests() {
        let routine = (0..<8).map {
            request(
                identifier: String(format: "daily-review-%02d", $0),
                interval: TimeInterval(60 * ($0 + 1))
            )
        }
        let protected = [
            request(
                identifier: "noop.safety.future-check-in",
                interval: 86_400
            ),
            request(
                identifier: "smart-alarm-future",
                interval: 86_400
            ),
            request(
                identifier: "foreground-transient",
                interval: nil
            ),
        ]

        let plan = LocalNotificationCapacityPolicy.plan(
            existingRequests: routine,
            candidateRequests: protected,
            replacingIdentifiers: [],
            capacity: 8,
            reservedPrioritySlots: 3,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(
            Set(plan.selectedCandidateRequests.map(\.identifier)),
            Set(protected.map(\.identifier))
        )
        XCTAssertEqual(
            plan.selectedExistingRequests.map(\.identifier),
            Array(routine.prefix(5)).map(\.identifier)
        )
        XCTAssertEqual(
            plan.existingIdentifiersToRemove,
            Array(routine.suffix(3)).map(\.identifier)
        )
    }

    func testStaleSyncIsMaintenanceAndLosesCapacityBeforeRoutine() {
        let staleSync = request(
            identifier: "noop.band-sync.stale",
            interval: 30
        )
        let routine = request(
            identifier: "daily-review-evening",
            interval: 3_600
        )

        let plan = LocalNotificationCapacityPolicy.plan(
            existingRequests: [],
            candidateRequests: [staleSync, routine],
            replacingIdentifiers: [],
            capacity: 1,
            reservedPrioritySlots: 0,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(
            LocalNotificationCapacityPolicy.priority(for: staleSync),
            .maintenance
        )
        XCTAssertEqual(
            plan.selectedCandidateRequests.map(\.identifier),
            [routine.identifier]
        )
        XCTAssertEqual(
            plan.capacityLimitedCandidateRequests.map(\.identifier),
            [staleSync.identifier]
        )
    }

    func testEqualPriorityAndFireDateUseIdentifierTieOrdering() {
        let candidates = ["c", "a", "b"].map {
            request(
                identifier: "daily-review-\($0)",
                interval: 600
            )
        }

        let plan = LocalNotificationCapacityPolicy.plan(
            existingRequests: [],
            candidateRequests: candidates,
            replacingIdentifiers: [],
            capacity: 2,
            reservedPrioritySlots: 0,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(
            plan.selectedCandidateRequests.map(\.identifier),
            ["daily-review-a", "daily-review-b"]
        )
        XCTAssertEqual(
            plan.capacityLimitedCandidateRequests.map(\.identifier),
            ["daily-review-c"]
        )
    }

    func testReconciliationReplacesSelectedRequestAndRemovesDeselectedExisting() async {
        let replacementID = "daily-review-replacement"
        let original = request(
            identifier: replacementID,
            interval: 120,
            body: "old"
        )
        let obsolete = request(
            identifier: "daily-review-obsolete",
            interval: 180
        )
        let replacement = request(
            identifier: replacementID,
            interval: 60,
            body: "new"
        )
        let safety = request(
            identifier: "noop.safety.user-check",
            interval: 3_600
        )
        let center = LocalNotificationCenterCapacitySpy(
            existing: [original, obsolete]
        )

        let result = await LocalNotificationCapacityCoordinator(
            capacity: 2,
            reservedPrioritySlots: 0
        ).reconcile(
            candidateRequests: [replacement, safety],
            replacingIdentifiers: [replacementID],
            now: now,
            calendar: calendar,
            client: center.client
        )

        XCTAssertEqual(
            Set(result.acceptedIdentifiers),
            [replacementID, safety.identifier]
        )
        XCTAssertEqual(
            result.removedIdentifiers,
            [obsolete.identifier]
        )
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(center.requests[replacementID]?.content.body, "new")
        XCTAssertNil(center.requests[obsolete.identifier])
        XCTAssertFalse(
            center.removalBatches.joined().contains(replacementID)
        )
    }

    func testFailedReplacementKeepsEligibleExistingRequest() async {
        let identifier = "daily-review-replacement"
        let original = request(
            identifier: identifier,
            interval: 120,
            body: "old"
        )
        let replacement = request(
            identifier: identifier,
            interval: 60,
            body: "new"
        )
        let center = LocalNotificationCenterCapacitySpy(
            existing: [original],
            failingIdentifiers: [identifier]
        )

        let result = await LocalNotificationCapacityCoordinator(
            capacity: 1,
            reservedPrioritySlots: 0
        ).reconcile(
            candidateRequests: [replacement],
            replacingIdentifiers: [identifier],
            now: now,
            calendar: calendar,
            client: center.client
        )

        XCTAssertEqual(result.failedIdentifiers, [identifier])
        XCTAssertTrue(result.acceptedIdentifiers.isEmpty)
        XCTAssertEqual(result.retainedIdentifiers, [identifier])
        XCTAssertEqual(result.activeIdentifiers, [identifier])
        XCTAssertTrue(result.capacityLimitedIdentifiers.isEmpty)
        XCTAssertTrue(result.removedIdentifiers.isEmpty)
        XCTAssertEqual(center.requests[identifier]?.content.body, "old")
        XCTAssertFalse(
            center.removalBatches.joined().contains(identifier)
        )
    }

    func testPreservedExistingRequestsRemainPinnedUnderCapacityPressure() async {
        let firstPrior = request(
            identifier: "wind-down-nudge-prior-1",
            interval: 60
        )
        let secondPrior = request(
            identifier: "wind-down-nudge-prior-2",
            interval: 120
        )
        let firstCandidate = request(
            identifier: "wind-down-nudge-next-1",
            interval: 30
        )
        let secondCandidate = request(
            identifier: "wind-down-nudge-next-2",
            interval: 45
        )
        let center = LocalNotificationCenterCapacitySpy(
            existing: [firstPrior, secondPrior]
        )

        let result = await LocalNotificationCapacityCoordinator(
            capacity: 2,
            reservedPrioritySlots: 0
        ).reconcile(
            candidateRequests: [firstCandidate, secondCandidate],
            replacingIdentifiers: [
                firstCandidate.identifier,
                secondCandidate.identifier,
            ],
            preservingExistingIdentifiers: [
                firstPrior.identifier,
                secondPrior.identifier,
            ],
            now: now,
            calendar: calendar,
            client: center.client
        )

        XCTAssertTrue(result.acceptedIdentifiers.isEmpty)
        XCTAssertEqual(
            Set(result.retainedIdentifiers),
            [firstPrior.identifier, secondPrior.identifier]
        )
        XCTAssertEqual(
            Set(result.capacityLimitedIdentifiers),
            [firstCandidate.identifier, secondCandidate.identifier]
        )
        XCTAssertTrue(result.removedIdentifiers.isEmpty)
        XCTAssertTrue(center.removalBatches.isEmpty)
        XCTAssertEqual(
            Set(center.requests.keys),
            [firstPrior.identifier, secondPrior.identifier]
        )
    }

    func testObsoleteGenerationCannotMutateAfterPendingSnapshotReturns() async {
        let existing = request(
            identifier: "daily-review-obsolete",
            interval: 120,
            body: "old"
        )
        let candidate = request(
            identifier: "daily-review-current",
            interval: 60,
            body: "new"
        )
        let pendingPaused = expectation(
            description: "pending request snapshot paused"
        )
        let center = LocalNotificationCenterCapacitySpy(
            existing: [existing],
            pauseFirstPending: true,
            onFirstPendingPaused: { pendingPaused.fulfill() }
        )
        let coordinator = LocalNotificationCapacityCoordinator(
            capacity: 1,
            reservedPrioritySlots: 0
        )
        var isCurrent = true

        let task = Task { @MainActor in
            await coordinator.reconcile(
                candidateRequests: [candidate],
                replacingIdentifiers: [existing.identifier],
                now: now,
                calendar: calendar,
                isStillCurrent: { isCurrent },
                client: center.client
            )
        }
        await fulfillment(of: [pendingPaused], timeout: 1)
        isCurrent = false
        center.resumeFirstPending()

        let result = await task.value
        XCTAssertTrue(result.activeIdentifiers.isEmpty)
        XCTAssertTrue(result.removedIdentifiers.isEmpty)
        XCTAssertTrue(center.removalBatches.isEmpty)
        XCTAssertTrue(center.mutationLog.isEmpty)
        XCTAssertEqual(
            center.requests[existing.identifier]?.content.body,
            "old"
        )
    }

    func testObsoleteGenerationCannotDeleteNewerStableIdentifierSchedule() async {
        let stableID = "daily-review-shared"
        let oldRequest = request(
            identifier: stableID,
            interval: 120,
            body: "old"
        )
        let newRequest = request(
            identifier: stableID,
            interval: 60,
            body: "new"
        )
        let firstAddPaused = expectation(description: "first add paused")
        let center = LocalNotificationCenterCapacitySpy(
            pauseFirstAdd: true,
            onFirstAddPaused: { firstAddPaused.fulfill() }
        )
        let coordinator = LocalNotificationCapacityCoordinator(
            capacity: 1,
            reservedPrioritySlots: 0
        )
        var firstGenerationIsCurrent = true

        let first = Task { @MainActor in
            await coordinator.reconcile(
                candidateRequests: [oldRequest],
                replacingIdentifiers: [stableID],
                now: now,
                calendar: calendar,
                isStillCurrent: { firstGenerationIsCurrent },
                client: center.client
            )
        }
        await fulfillment(of: [firstAddPaused], timeout: 1)

        firstGenerationIsCurrent = false
        let second = Task { @MainActor in
            await coordinator.reconcile(
                candidateRequests: [newRequest],
                replacingIdentifiers: [stableID],
                now: now,
                calendar: calendar,
                client: center.client
            )
        }
        await Task.yield()
        center.resumeFirstAdd()

        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertTrue(firstResult.acceptedIdentifiers.isEmpty)
        XCTAssertEqual(secondResult.acceptedIdentifiers, [stableID])
        XCTAssertEqual(center.requests[stableID]?.content.body, "new")
        XCTAssertEqual(
            center.mutationLog,
            ["add:old", "remove:\(stableID)", "add:new"]
        )
    }

    func testCapacityLimitedLifecycleEvidenceIsPrivacySafe() async throws {
        let candidate = request(
            identifier: "metric-review-sensitive-token",
            interval: 60,
            categoryIdentifier: "sensitive-category",
            body: "private measurement"
        )
        let center = LocalNotificationCenterCapacitySpy()

        let result = await LocalNotificationLifecycle.reconcile(
            candidateRequests: [candidate],
            replacingIdentifiers: [candidate.identifier],
            now: now,
            calendar: calendar,
            coordinator: LocalNotificationCapacityCoordinator(
                capacity: 1,
                reservedPrioritySlots: 1
            ),
            client: center.client
        )

        XCTAssertEqual(
            result.capacityLimitedIdentifiers,
            [candidate.identifier]
        )
        XCTAssertTrue(center.requests.isEmpty)
        let record = try XCTUnwrap(
            LocalNotificationLifecycleLedger.shared.records().last
        )
        XCTAssertEqual(record.state, .capacityLimited)
        XCTAssertEqual(record.identifier, "metric_review")
        XCTAssertEqual(record.categoryIdentifier, "unknown")
        let encoded = String(
            decoding: try JSONEncoder().encode(record),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("sensitive"))
        XCTAssertFalse(encoded.contains("private measurement"))
    }

    private func request(
        identifier: String,
        interval: TimeInterval?,
        categoryIdentifier: String = "noop.daily-review.private",
        body: String = "Private reminder"
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "NOOP"
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        let trigger = interval.map {
            UNTimeIntervalNotificationTrigger(
                timeInterval: $0,
                repeats: false
            )
        }
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
    }
}

@MainActor
private final class LocalNotificationCenterCapacitySpy {
    private enum TestError: Error {
        case rejected
    }

    private(set) var requests: [String: UNNotificationRequest]
    private(set) var removalBatches: [[String]] = []
    private(set) var mutationLog: [String] = []
    private let failingIdentifiers: Set<String>
    private var pauseFirstPending: Bool
    private let onFirstPendingPaused: (() -> Void)?
    private var firstPendingContinuation: CheckedContinuation<Void, Never>?
    private var pauseFirstAdd: Bool
    private let onFirstAddPaused: (() -> Void)?
    private var firstAddContinuation: CheckedContinuation<Void, Never>?

    init(
        existing: [UNNotificationRequest] = [],
        failingIdentifiers: Set<String> = [],
        pauseFirstPending: Bool = false,
        onFirstPendingPaused: (() -> Void)? = nil,
        pauseFirstAdd: Bool = false,
        onFirstAddPaused: (() -> Void)? = nil
    ) {
        requests = Dictionary(
            uniqueKeysWithValues: existing.map {
                ($0.identifier, $0)
            }
        )
        self.failingIdentifiers = failingIdentifiers
        self.pauseFirstPending = pauseFirstPending
        self.onFirstPendingPaused = onFirstPendingPaused
        self.pauseFirstAdd = pauseFirstAdd
        self.onFirstAddPaused = onFirstAddPaused
    }

    func resumeFirstAdd() {
        firstAddContinuation?.resume()
        firstAddContinuation = nil
    }

    func resumeFirstPending() {
        firstPendingContinuation?.resume()
        firstPendingContinuation = nil
    }

    var client: LocalNotificationCenterClient {
        LocalNotificationCenterClient(
            pendingRequests: { [weak self] in
                guard let self else { return [] }
                if self.pauseFirstPending {
                    self.pauseFirstPending = false
                    self.onFirstPendingPaused?()
                    await withCheckedContinuation { continuation in
                        self.firstPendingContinuation = continuation
                    }
                }
                return self.requests.values.sorted {
                    $0.identifier < $1.identifier
                }
            },
            add: { [weak self] request in
                guard let self else { return }
                if self.pauseFirstAdd {
                    self.pauseFirstAdd = false
                    self.onFirstAddPaused?()
                    await withCheckedContinuation { continuation in
                        self.firstAddContinuation = continuation
                    }
                }
                if self.failingIdentifiers.contains(request.identifier) {
                    throw TestError.rejected
                }
                self.requests[request.identifier] = request
                self.mutationLog.append("add:\(request.content.body)")
            },
            removePending: { [weak self] identifiers in
                guard let self else { return }
                self.removalBatches.append(identifiers)
                identifiers.forEach {
                    self.requests.removeValue(forKey: $0)
                    self.mutationLog.append("remove:\($0)")
                }
            }
        )
    }
}

@MainActor
final class DailyReviewNotificationsTests: XCTestCase {
    private let keys = [
        DailyReviewNotifications.enabledKey,
        DailyReviewNotifications.morningMinutesKey,
        DailyReviewNotifications.eveningMinutesKey,
        DailyReviewNotifications.completedJournalDaysKey,
        DailyReviewNotifications.scheduledEveningIDsKey,
        NotificationRouteBridge.pendingRouteKey,
        AutoWorkoutNotifications.enabledKey,
        MorningRecapNotifications.enabledKey,
        MorningRecapNotifications.lastReportDayKey,
        PostWorkoutSummaryNotifications.enabledKey,
        PostWorkoutSummaryNotifications.lastWorkoutStartKey,
        PostWorkoutSummaryNotifications.frontierInitializedKey,
        PuffinExperiment.autoWorkoutModeKey,
        PuffinExperiment.autoDetectWorkoutsKey,
        "autoWorkout.lastNotifiedToken",
        "autoWorkout.notifiedTokenHistory",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaultsAreOffWithUsefulReviewTimes() {
        XCTAssertFalse(DailyReviewNotifications.isEnabled)
        XCTAssertEqual(DailyReviewNotifications.morningMinutes, 8 * 60)
        XCTAssertEqual(DailyReviewNotifications.eveningMinutes, 19 * 60)
    }

    func testMinuteInputsAreClampedBeforePersistence() {
        DailyReviewNotifications.setMorningMinutes(-20)
        DailyReviewNotifications.setEveningMinutes(9_000)

        XCTAssertEqual(DailyReviewNotifications.morningMinutes, 0)
        XCTAssertEqual(DailyReviewNotifications.eveningMinutes, 24 * 60 - 1)
    }

    func testReminderRoutesAndCopyArePrivacySafe() {
        let specs = DailyReviewNotifications.reminderSpecs(morning: 7 * 60, evening: 20 * 60)

        XCTAssertEqual(specs.map(\.route), [.sleep, .journal])
        XCTAssertEqual(specs.map(\.minuteOfDay), [7 * 60, 20 * 60])
        XCTAssertTrue(specs[0].body.contains("Sleep"))
        XCTAssertTrue(specs[0].body.contains("Recovery"))
        XCTAssertTrue(specs[1].body.contains("Effort"))
        XCTAssertTrue(specs[0].body.localizedCaseInsensitiveContains("log"))
        XCTAssertTrue(specs[1].body.localizedCaseInsensitiveContains("log"))
        XCTAssertFalse(specs[0].body.localizedCaseInsensitiveContains("open NOOP"))
        XCTAssertFalse(specs[1].body.localizedCaseInsensitiveContains("open NOOP"))
        for spec in specs {
            XCTAssertNil(
                spec.body.rangeOfCharacter(from: .decimalDigits),
                "Generic repeating reminders must not embed a score or health value."
            )
        }
    }

    func testScheduledContentKeepsHiddenPreviewsGeneric() {
        let category = DailyReviewNotifications.privacyCategory()
        XCTAssertEqual(category.identifier, "noop.daily-review.private")
        XCTAssertEqual(category.hiddenPreviewsBodyPlaceholder, "Private NOOP check-in")
    }

    func testFailedStableReplacementKeepsDailyReviewEnabledAndTracked() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 12,
            hour: 12
        ))!
        let existing = DailyReviewNotifications.notificationRequests(
            now: now,
            calendar: calendar
        )
        let eveningIDs = existing.map(\.identifier).filter {
            $0.hasPrefix("daily-review-evening-")
        }
        UserDefaults.standard.set(true, forKey: DailyReviewNotifications.enabledKey)
        UserDefaults.standard.set(
            eveningIDs,
            forKey: DailyReviewNotifications.scheduledEveningIDsKey
        )
        let center = LocalNotificationCenterCapacitySpy(
            existing: existing,
            failingIdentifiers: Set(existing.map(\.identifier))
        )

        let result = await DailyReviewNotifications.reconcileSchedule(
            now: now,
            calendar: calendar,
            coordinator: LocalNotificationCapacityCoordinator(
                capacity: 32,
                reservedPrioritySlots: 0
            ),
            client: center.client
        )
        DailyReviewNotifications.applyRescheduleResult(result)

        XCTAssertTrue(result?.acceptedIdentifiers.isEmpty ?? false)
        XCTAssertEqual(
            Set(result?.retainedIdentifiers ?? []),
            Set(existing.map(\.identifier))
        )
        XCTAssertTrue(DailyReviewNotifications.isEnabled)
        XCTAssertEqual(
            Set(
                UserDefaults.standard.stringArray(
                    forKey: DailyReviewNotifications.scheduledEveningIDsKey
                ) ?? []
            ),
            Set(eveningIDs)
        )
    }

    func testFailedStableReplacementKeepsHydrationEnabledAndTracked() async {
        let scheduledIDsKey = "hydrationReminders.scheduledRequestIDs"
        let specs = HydrationReminders.reminderSpecs(
            start: 8 * 60,
            end: 20 * 60,
            interval: 120
        )
        let existing = HydrationReminders.notificationRequests(specs: specs)
        let identifiers = existing.map(\.identifier)
        UserDefaults.standard.set(true, forKey: HydrationReminders.enabledKey)
        UserDefaults.standard.set(
            8 * 60,
            forKey: HydrationReminders.activeStartMinutesKey
        )
        UserDefaults.standard.set(
            20 * 60,
            forKey: HydrationReminders.activeEndMinutesKey
        )
        UserDefaults.standard.set(
            120,
            forKey: HydrationReminders.intervalMinutesKey
        )
        UserDefaults.standard.set(identifiers, forKey: scheduledIDsKey)
        let center = LocalNotificationCenterCapacitySpy(
            existing: existing,
            failingIdentifiers: Set(identifiers)
        )

        let result = await HydrationReminders.reconcileSchedule(
            coordinator: LocalNotificationCapacityCoordinator(
                capacity: 32,
                reservedPrioritySlots: 0
            ),
            client: center.client
        )
        HydrationReminders.applyRescheduleResult(result)

        XCTAssertTrue(result?.acceptedIdentifiers.isEmpty ?? false)
        XCTAssertEqual(
            Set(result?.retainedIdentifiers ?? []),
            Set(identifiers)
        )
        XCTAssertTrue(HydrationReminders.isEnabled)
        XCTAssertEqual(
            Set(
                UserDefaults.standard.stringArray(
                    forKey: scheduledIDsKey
                ) ?? []
            ),
            Set(identifiers)
        )
        UserDefaults.standard.removeObject(forKey: HydrationReminders.enabledKey)
        UserDefaults.standard.removeObject(
            forKey: HydrationReminders.activeStartMinutesKey
        )
        UserDefaults.standard.removeObject(
            forKey: HydrationReminders.activeEndMinutesKey
        )
        UserDefaults.standard.removeObject(
            forKey: HydrationReminders.intervalMinutesKey
        )
        UserDefaults.standard.removeObject(forKey: scheduledIDsKey)
    }

    func testPendingNotificationRouteIsConsumedOnce() {
        NotificationRouteBridge.recordPending(.breathe)

        XCTAssertEqual(NotificationRouteBridge.consumePending(), .breathe)
        XCTAssertNil(NotificationRouteBridge.consumePending())
    }

    func testEveningJournalScheduleSkipsCompletedDaysAndPastToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 31,
            hour: 20
        ))!

        let specs = DailyReviewNotifications.eveningReminderSpecs(
            now: now,
            minuteOfDay: 19 * 60,
            completedDays: ["2026-09-01"],
            calendar: calendar
        )

        XCTAssertFalse(specs.map(\.day).contains("2026-08-31"))
        XCTAssertFalse(specs.map(\.day).contains("2026-09-01"))
        XCTAssertEqual(specs.first?.reminder.route, .journal)
        XCTAssertEqual(specs.first?.day, "2026-09-02")
    }

    func testUnknownNotificationRouteIsIgnored() {
        XCTAssertNil(
            NotificationRouteBridge.route(
                from: [NotificationRouteBridge.userInfoKey: "untrusted-destination"]
            )
        )
    }

    func testActivitySuggestionInterruptionsRequestPermissionOnlyOnExplicitEnable() async {
        let notifications = AutoWorkoutNotificationClientSpy(status: .notDetermined)
        notifications.authorizationResult = true

        XCTAssertFalse(AutoWorkoutNotifications.isEnabled)
        let enabled = await withCheckedContinuation {
            (continuation: CheckedContinuation<AutoWorkoutNotifications.EnableOutcome, Never>) in
            AutoWorkoutNotifications.setEnabled(true, client: notifications.client) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(enabled, .enabled)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertTrue(AutoWorkoutNotifications.isEnabled)

        let off = await withCheckedContinuation {
            (continuation: CheckedContinuation<AutoWorkoutNotifications.EnableOutcome, Never>) in
            AutoWorkoutNotifications.setEnabled(false, client: notifications.client) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(off, .off)
        XCTAssertEqual(notifications.authorizationRequestCount, 1,
                       "Turning interruptions off must not request notification permission.")
        XCTAssertFalse(AutoWorkoutNotifications.isEnabled)
    }

    func testDeniedActivitySuggestionPermissionLeavesPreferenceOff() async {
        let notifications = AutoWorkoutNotificationClientSpy(status: .notDetermined)
        notifications.authorizationResult = false

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<AutoWorkoutNotifications.EnableOutcome, Never>) in
            AutoWorkoutNotifications.setEnabled(true, client: notifications.client) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertFalse(AutoWorkoutNotifications.isEnabled,
                       "A denied OS permission must never leave a misleading enabled switch.")
    }

    func testClearWhileAddIsSuspendedRemovesStaleNotificationAndDoesNotDeduplicateRetry() async {
        let notifications = AutoWorkoutNotificationClientSpy(status: .authorized)
        notifications.suspendAdds = true
        PuffinExperiment.setAutoWorkoutMode(.ask)
        UserDefaults.standard.set(true, forKey: AutoWorkoutNotifications.enabledKey)
        let start = 1_700_000_000
        let end = start + 1_200

        let posting = Task {
            await AutoWorkoutNotifications.postIfAuthorized(
                startSec: start,
                endSec: end,
                client: notifications.client
            )
        }
        await notifications.waitUntilAddStarts()

        AutoWorkoutNotifications.clear(client: notifications.client)
        notifications.resumeAdd()
        await posting.value

        XCTAssertTrue(notifications.requests.isEmpty,
                      "A clear that wins during add must remove the daemon-side stale request.")
        XCTAssertGreaterThanOrEqual(notifications.removalCount, 2,
                                    "Cleanup must run once immediately and again after stale add returns.")
        XCTAssertNil(UserDefaults.standard.string(forKey: "autoWorkout.lastNotifiedToken"),
                     "A delivery invalidated by clear must remain retryable.")
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "autoWorkout.notifiedTokenHistory"))
    }

    func testSameCandidateCanRepostAfterClearBeforeStaleAddCompletes() async {
        let notifications = AutoWorkoutNotificationClientSpy(status: .authorized)
        notifications.suspendAdds = true
        PuffinExperiment.setAutoWorkoutMode(.ask)
        UserDefaults.standard.set(true, forKey: AutoWorkoutNotifications.enabledKey)
        let start = 1_700_100_000
        let end = start + 1_200
        let expectedToken = "candidate:" + AutoWorkoutNotifications.token(startSec: start, endSec: end)

        let stalePosting = Task {
            await AutoWorkoutNotifications.postIfAuthorized(
                startSec: start,
                endSec: end,
                client: notifications.client
            )
        }
        await notifications.waitUntilAddStarts()

        AutoWorkoutNotifications.clear(client: notifications.client)
        // This is deliberately the same candidate. The retired active generation must not suppress it.
        await AutoWorkoutNotifications.postIfAuthorized(
            startSec: start,
            endSec: end,
            client: notifications.client
        )
        notifications.resumeAdd()
        await stalePosting.value

        XCTAssertEqual(notifications.addCount, 2,
                       "The current generation must retry after the stale generation is cleared.")
        XCTAssertEqual(notifications.requests.count, 1,
                       "Stale cleanup must run before, not after, the newer stable-id delivery.")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "autoWorkout.lastNotifiedToken"),
                       expectedToken)
    }

    func testClearReleasesQueuedDeliveryBudgetBeforeSuspendedAddCompletes() async {
        let notifications = AutoWorkoutNotificationClientSpy(status: .authorized)
        notifications.suspendAdds = true
        PuffinExperiment.setAutoWorkoutMode(.ask)
        UserDefaults.standard.set(true, forKey: AutoWorkoutNotifications.enabledKey)
        let activeBudget = PostSyncRoutineNotificationBudget()
        let queuedBudget = PostSyncRoutineNotificationBudget()

        let activePosting = Task {
            await AutoWorkoutNotifications.postIfAuthorized(
                startSec: 1_700_150_000,
                endSec: 1_700_151_200,
                client: notifications.client,
                budget: activeBudget
            )
        }
        await notifications.waitUntilAddStarts()

        await AutoWorkoutNotifications.postIfAuthorized(
            startSec: 1_700_160_000,
            endSec: 1_700_161_200,
            client: notifications.client,
            budget: queuedBudget
        )
        AutoWorkoutNotifications.clear(client: notifications.client)

        XCTAssertTrue(queuedBudget.reserve(.morningRecap))
        XCTAssertTrue(queuedBudget.commit(.morningRecap))
        XCTAssertEqual(queuedBudget.claimedLane, .morningRecap)

        notifications.resumeAdd()
        await activePosting.value
        XCTAssertFalse(activeBudget.isClaimed)
    }

    func testActivitySuggestionDedupHonorsBoundedHistoryAndLegacyToken() {
        let suite = "DailyReviewNotificationsTests.autoWorkout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = 1_700_000_000
        let delivery = "candidate:" + AutoWorkoutNotifications.token(startSec: start, endSec: start + 1_200)

        XCTAssertTrue(AutoWorkoutNotifications.shouldDeliver(
            deliveryToken: delivery, kind: .candidate, startSec: start, defaults: defaults
        ))
        defaults.set([delivery], forKey: "autoWorkout.notifiedTokenHistory")
        XCTAssertFalse(AutoWorkoutNotifications.shouldDeliver(
            deliveryToken: delivery, kind: .candidate, startSec: start, defaults: defaults
        ))

        defaults.removeObject(forKey: "autoWorkout.notifiedTokenHistory")
        defaults.set("start:\(start)", forKey: "autoWorkout.lastNotifiedToken")
        XCTAssertFalse(AutoWorkoutNotifications.shouldDeliver(
            deliveryToken: delivery, kind: .candidate, startSec: start, defaults: defaults
        ))
    }

    func testPostSyncBudgetAllowsOnlyOneRoutineNotificationLane() async {
        let budget = PostSyncRoutineNotificationBudget()
        let notifications = AutoWorkoutNotificationClientSpy(status: .authorized)
        PuffinExperiment.setAutoWorkoutMode(.ask)
        UserDefaults.standard.set(true, forKey: AutoWorkoutNotifications.enabledKey)

        await AutoWorkoutNotifications.postIfAuthorized(
            startSec: 1_700_200_000,
            endSec: 1_700_201_200,
            client: notifications.client,
            budget: budget
        )

        XCTAssertEqual(budget.claimedLane, .autoWorkout)
        XCTAssertEqual(notifications.requests.count, 1)
        XCTAssertFalse(budget.claim(.postWorkoutSummary))
        XCTAssertEqual(budget.claimedLane, .autoWorkout)
    }

    func testFailedPostReleasesBudgetForLowerPriorityLane() async {
        let budget = PostSyncRoutineNotificationBudget()
        let notifications = AutoWorkoutNotificationClientSpy(status: .authorized)
        notifications.failAdds = true
        PuffinExperiment.setAutoWorkoutMode(.ask)
        UserDefaults.standard.set(true, forKey: AutoWorkoutNotifications.enabledKey)

        await AutoWorkoutNotifications.postIfAuthorized(
            startSec: 1_700_300_000,
            endSec: 1_700_301_200,
            client: notifications.client,
            budget: budget
        )

        XCTAssertNil(budget.claimedLane)
        XCTAssertFalse(budget.isClaimed)
        XCTAssertTrue(budget.reserve(.morningRecap))
        XCTAssertTrue(budget.commit(.morningRecap))
        XCTAssertEqual(budget.claimedLane, .morningRecap)
        XCTAssertTrue(notifications.requests.isEmpty)
    }

    func testWrongLaneCannotCommitOrReleaseReservation() {
        let budget = PostSyncRoutineNotificationBudget()

        XCTAssertTrue(budget.reserve(.postWorkoutSummary))
        XCTAssertFalse(budget.commit(.morningRecap))
        budget.release(.morningRecap)
        XCTAssertFalse(budget.reserve(.adaptiveDay))
        XCTAssertTrue(budget.commit(.postWorkoutSummary))
    }
}

@MainActor
final class MorningRecapNotificationsTests: XCTestCase {
    private let keys = [
        MorningRecapNotifications.enabledKey,
        MorningRecapNotifications.lastReportDayKey,
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testPolicyRequiresFreshMaterializedScoresAndNewReportDay() {
        XCTAssertTrue(MorningRecapNotifications.shouldNotify(
            enabled: true,
            materializedAfterSync: true,
            chargeOrRestPresent: true,
            reportDay: "2026-08-28",
            lastReportDay: "2026-08-27"
        ))
        XCTAssertFalse(MorningRecapNotifications.shouldNotify(
            enabled: true,
            materializedAfterSync: false,
            chargeOrRestPresent: true,
            reportDay: "2026-08-28",
            lastReportDay: nil
        ))
        XCTAssertFalse(MorningRecapNotifications.shouldNotify(
            enabled: true,
            materializedAfterSync: true,
            chargeOrRestPresent: false,
            reportDay: "2026-08-28",
            lastReportDay: nil
        ))
        XCTAssertFalse(MorningRecapNotifications.shouldNotify(
            enabled: true,
            materializedAfterSync: true,
            chargeOrRestPresent: true,
            reportDay: "2026-08-28",
            lastReportDay: "2026-08-28"
        ))
    }

    func testEnablePostsOnePrivateRecapPerReportDay() async {
        let notifications = MorningRecapNotificationClientSpy(status: .authorized)
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                MorningRecapNotifications.EnableOutcome, Never
            >) in
            MorningRecapNotifications.setEnabled(
                true,
                client: notifications.client
            ) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(outcome, .enabled)

        await MorningRecapNotifications.postIfAuthorized(
            reportDay: "2026-08-28",
            chargeOrRestPresent: true,
            materializedAfterSync: true,
            client: notifications.client
        )
        await MorningRecapNotifications.postIfAuthorized(
            reportDay: "2026-08-28",
            chargeOrRestPresent: true,
            materializedAfterSync: true,
            client: notifications.client
        )

        XCTAssertEqual(notifications.requests.count, 1)
        let request = try? XCTUnwrap(notifications.requests.values.first)
        XCTAssertEqual(
            request.flatMap { NotificationRouteBridge.route(from: $0.content.userInfo) },
            .sleep
        )
        XCTAssertEqual(
            request?.content.categoryIdentifier,
            DailyReviewNotifications.privacyCategoryID
        )
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: MorningRecapNotifications.lastReportDayKey),
            "2026-08-28"
        )
    }

    func testDeniedPermissionLeavesRecapOff() async {
        let notifications = MorningRecapNotificationClientSpy(status: .notDetermined)
        notifications.authorizationResult = false
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                MorningRecapNotifications.EnableOutcome, Never
            >) in
            MorningRecapNotifications.setEnabled(
                true,
                client: notifications.client
            ) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertFalse(MorningRecapNotifications.isEnabled)
    }

    func testExhaustedPostSyncBudgetKeepsRecapEligibleForLaterSync() async {
        let notifications = MorningRecapNotificationClientSpy(status: .authorized)
        UserDefaults.standard.set(true, forKey: MorningRecapNotifications.enabledKey)
        let exhausted = PostSyncRoutineNotificationBudget()
        XCTAssertTrue(exhausted.claim(.autoWorkout))

        await MorningRecapNotifications.postIfAuthorized(
            reportDay: "2026-09-11",
            chargeOrRestPresent: true,
            client: notifications.client,
            budget: exhausted
        )

        XCTAssertTrue(notifications.requests.isEmpty)
        XCTAssertNil(
            UserDefaults.standard.string(forKey: MorningRecapNotifications.lastReportDayKey)
        )

        let laterSync = PostSyncRoutineNotificationBudget()
        await MorningRecapNotifications.postIfAuthorized(
            reportDay: "2026-09-11",
            chargeOrRestPresent: true,
            client: notifications.client,
            budget: laterSync
        )

        XCTAssertEqual(laterSync.claimedLane, .morningRecap)
        XCTAssertEqual(notifications.requests.count, 1)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: MorningRecapNotifications.lastReportDayKey),
            "2026-09-11"
        )
    }
}

@MainActor
final class PostWorkoutSummaryNotificationsTests: XCTestCase {
    private let keys = [
        PostWorkoutSummaryNotifications.enabledKey,
        PostWorkoutSummaryNotifications.lastWorkoutStartKey,
        PostWorkoutSummaryNotifications.frontierInitializedKey,
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testPolicyRequiresOptInInitializedFrontierAndStrictlyNewerWorkout() {
        XCTAssertTrue(PostWorkoutSummaryNotifications.shouldNotify(
            enabled: true,
            frontierInitialized: true,
            newestWorkoutStart: 101,
            lastWorkoutStart: 100
        ))
        XCTAssertFalse(PostWorkoutSummaryNotifications.shouldNotify(
            enabled: false,
            frontierInitialized: true,
            newestWorkoutStart: 101,
            lastWorkoutStart: 100
        ))
        XCTAssertFalse(PostWorkoutSummaryNotifications.shouldNotify(
            enabled: true,
            frontierInitialized: false,
            newestWorkoutStart: 101,
            lastWorkoutStart: 100
        ))
        XCTAssertFalse(PostWorkoutSummaryNotifications.shouldNotify(
            enabled: true,
            frontierInitialized: true,
            newestWorkoutStart: 100,
            lastWorkoutStart: 100
        ))
    }

    func testExplicitEnableSeedsExistingHistoryThenPostsNewWorkoutOnce() async {
        let notifications = PostWorkoutNotificationClientSpy(status: .authorized)
        let enabled = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                PostWorkoutSummaryNotifications.EnableOutcome, Never
            >) in
            PostWorkoutSummaryNotifications.setEnabled(
                true,
                currentNewestWorkoutStart: 100,
                client: notifications.client
            ) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(enabled, .enabled)
        XCTAssertTrue(PostWorkoutSummaryNotifications.isEnabled)
        XCTAssertEqual(
            UserDefaults.standard.integer(
                forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey
            ),
            100
        )

        await PostWorkoutSummaryNotifications.postIfAuthorized(
            newestWorkoutStart: 100,
            client: notifications.client
        )
        XCTAssertTrue(notifications.requests.isEmpty)

        await PostWorkoutSummaryNotifications.postIfAuthorized(
            newestWorkoutStart: 101,
            client: notifications.client
        )
        await PostWorkoutSummaryNotifications.postIfAuthorized(
            newestWorkoutStart: 101,
            client: notifications.client
        )

        XCTAssertEqual(notifications.requests.count, 1)
        let request = try? XCTUnwrap(notifications.requests.values.first)
        XCTAssertEqual(
            request.flatMap { NotificationRouteBridge.route(from: $0.content.userInfo) },
            .workouts
        )
        XCTAssertEqual(request?.content.categoryIdentifier, DailyReviewNotifications.privacyCategoryID)
        XCTAssertFalse(request?.content.body.contains("101") == true)
        XCTAssertEqual(
            UserDefaults.standard.integer(
                forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey
            ),
            101
        )
    }

    func testExplicitReenableReplacesAStaleFutureFrontier() async {
        let notifications = PostWorkoutNotificationClientSpy(status: .authorized)
        UserDefaults.standard.set(500, forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey)
        UserDefaults.standard.set(true, forKey: PostWorkoutSummaryNotifications.frontierInitializedKey)

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                PostWorkoutSummaryNotifications.EnableOutcome, Never
            >) in
            PostWorkoutSummaryNotifications.setEnabled(
                true,
                currentNewestWorkoutStart: 100,
                client: notifications.client
            ) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(outcome, .enabled)
        XCTAssertEqual(
            UserDefaults.standard.integer(
                forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey
            ),
            100
        )

        await PostWorkoutSummaryNotifications.postIfAuthorized(
            newestWorkoutStart: 101,
            client: notifications.client
        )
        XCTAssertEqual(notifications.requests.count, 1)
    }

    func testExplicitReenableClearsAStaleFrontierForEmptyHistory() async {
        let notifications = PostWorkoutNotificationClientSpy(status: .authorized)
        UserDefaults.standard.set(500, forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey)
        UserDefaults.standard.set(true, forKey: PostWorkoutSummaryNotifications.frontierInitializedKey)

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                PostWorkoutSummaryNotifications.EnableOutcome, Never
            >) in
            PostWorkoutSummaryNotifications.setEnabled(
                true,
                currentNewestWorkoutStart: nil,
                client: notifications.client
            ) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(outcome, .enabled)
        XCTAssertNil(
            UserDefaults.standard.object(
                forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey
            )
        )
        XCTAssertTrue(
            UserDefaults.standard.bool(
                forKey: PostWorkoutSummaryNotifications.frontierInitializedKey
            )
        )

        await PostWorkoutSummaryNotifications.postIfAuthorized(
            newestWorkoutStart: 1,
            client: notifications.client
        )
        XCTAssertEqual(notifications.requests.count, 1)
    }

    func testDeniedPermissionLeavesPreferenceOff() async {
        let notifications = PostWorkoutNotificationClientSpy(status: .notDetermined)
        notifications.authorizationResult = false

        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                PostWorkoutSummaryNotifications.EnableOutcome, Never
            >) in
            PostWorkoutSummaryNotifications.setEnabled(
                true,
                currentNewestWorkoutStart: 100,
                client: notifications.client
            ) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertFalse(PostWorkoutSummaryNotifications.isEnabled)
        XCTAssertFalse(
            UserDefaults.standard.bool(
                forKey: PostWorkoutSummaryNotifications.frontierInitializedKey
            )
        )
    }

    func testMissingUpgradeFrontierSeedsSilently() async {
        let notifications = PostWorkoutNotificationClientSpy(status: .authorized)
        UserDefaults.standard.set(true, forKey: PostWorkoutSummaryNotifications.enabledKey)

        await PostWorkoutSummaryNotifications.postIfAuthorized(
            newestWorkoutStart: 200,
            client: notifications.client
        )

        XCTAssertTrue(notifications.requests.isEmpty)
        XCTAssertEqual(
            UserDefaults.standard.integer(
                forKey: PostWorkoutSummaryNotifications.lastWorkoutStartKey
            ),
            200
        )
        XCTAssertTrue(
            UserDefaults.standard.bool(
                forKey: PostWorkoutSummaryNotifications.frontierInitializedKey
            )
        )
    }
}

@MainActor
private final class MorningRecapNotificationClientSpy {
    var status: UNAuthorizationStatus
    var authorizationResult = false
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [String: UNNotificationRequest] = [:]

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    var client: MorningRecapNotifications.NotificationClient {
        MorningRecapNotifications.NotificationClient(
            authorizationStatus: { [weak self] in self?.status ?? .denied },
            requestAuthorization: { [weak self] in
                guard let self else { return false }
                self.authorizationRequestCount += 1
                return self.authorizationResult
            },
            preparePrivateCategory: {},
            add: { [weak self] request in
                self?.requests[request.identifier] = request
            },
            remove: { [weak self] identifiers in
                identifiers.forEach { self?.requests.removeValue(forKey: $0) }
            }
        )
    }
}

@MainActor
private final class PostWorkoutNotificationClientSpy {
    var status: UNAuthorizationStatus
    var authorizationResult = false
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [String: UNNotificationRequest] = [:]

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    var client: PostWorkoutSummaryNotifications.NotificationClient {
        PostWorkoutSummaryNotifications.NotificationClient(
            authorizationStatus: { [weak self] in self?.status ?? .denied },
            requestAuthorization: { [weak self] in
                guard let self else { return false }
                self.authorizationRequestCount += 1
                return self.authorizationResult
            },
            preparePrivateCategory: {},
            add: { [weak self] request in
                self?.requests[request.identifier] = request
            },
            remove: { [weak self] identifiers in
                identifiers.forEach { self?.requests.removeValue(forKey: $0) }
            }
        )
    }
}

/// Deterministic, in-memory stand-in for Notification Center. `suspendAdds` models the real daemon
/// boundary: removal can finish locally before an already-started add reports completion.
@MainActor
private final class AutoWorkoutNotificationClientSpy {
    var status: UNAuthorizationStatus
    var authorizationResult = false
    var authorizationRequestCount = 0
    var suspendAdds = false
    var failAdds = false
    private(set) var requests: [String: UNNotificationRequest] = [:]
    private(set) var removalCount = 0
    private(set) var addCount = 0

    private var addStarted = false
    private var addStartedContinuation: CheckedContinuation<Void, Never>?
    private var addResumeContinuation: CheckedContinuation<Void, Never>?

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    var client: AutoWorkoutNotifications.NotificationClient {
        AutoWorkoutNotifications.NotificationClient(
            authorizationStatus: { [weak self] in self?.status ?? .denied },
            requestAuthorization: { [weak self] in
                guard let self else { return false }
                self.authorizationRequestCount += 1
                return self.authorizationResult
            },
            add: { [weak self] request in
                guard let self else { return }
                try await self.add(request)
            },
            remove: { [weak self] identifiers in
                self?.remove(identifiers)
            }
        )
    }

    private func add(_ request: UNNotificationRequest) async throws {
        addCount += 1
        if failAdds {
            throw TestError.rejected
        }
        if suspendAdds {
            addStarted = true
            addStartedContinuation?.resume()
            addStartedContinuation = nil
            await withCheckedContinuation { addResumeContinuation = $0 }
        }
        requests[request.identifier] = request
    }

    private enum TestError: Error {
        case rejected
    }

    func waitUntilAddStarts() async {
        if addStarted { return }
        await withCheckedContinuation { addStartedContinuation = $0 }
    }

    func resumeAdd() {
        suspendAdds = false
        addResumeContinuation?.resume()
        addResumeContinuation = nil
    }

    private func remove(_ identifiers: [String]) {
        removalCount += 1
        identifiers.forEach { requests.removeValue(forKey: $0) }
    }
}

@MainActor
final class BluetoothAvailabilityNotificationsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: BluetoothAvailabilityNotifications.enabledKey)
        UserDefaults.standard.removeObject(forKey: BluetoothAvailabilityNotifications.monitoringExpectedKey)
    }

    override func tearDown() {
        BluetoothAvailabilityNotifications.clear()
        UserDefaults.standard.removeObject(forKey: BluetoothAvailabilityNotifications.enabledKey)
        UserDefaults.standard.removeObject(forKey: BluetoothAvailabilityNotifications.monitoringExpectedKey)
        super.tearDown()
    }

    func testConnectionAlertDefaultsOnButExplicitOptOutPersists() {
        XCTAssertTrue(BluetoothAvailabilityNotifications.isEnabled)
        BluetoothAvailabilityNotifications.setEnabled(false)
        XCTAssertFalse(BluetoothAvailabilityNotifications.isEnabled)
        BluetoothAvailabilityNotifications.setEnabled(true)
        XCTAssertTrue(BluetoothAvailabilityNotifications.isEnabled)
    }

    func testOutagePolicyRequiresEveryRelevanceAndDedupGate() {
        XCTAssertTrue(BluetoothAvailabilityNotifications.shouldPost(
            enabled: true, radioWasPoweredOn: true, hasPairedDevice: true,
            outageAlreadyHandled: false
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldPost(
            enabled: false, radioWasPoweredOn: true, hasPairedDevice: true,
            outageAlreadyHandled: false
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldPost(
            enabled: true, radioWasPoweredOn: false, hasPairedDevice: true,
            outageAlreadyHandled: false
        ), "The initial CoreBluetooth launch state must stay silent.")
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldPost(
            enabled: true, radioWasPoweredOn: true, hasPairedDevice: false,
            outageAlreadyHandled: false
        ), "An install with no paired wearable has nothing actionable to report.")
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldPost(
            enabled: true, radioWasPoweredOn: true, hasPairedDevice: true,
            outageAlreadyHandled: true
        ), "Repeated callbacks in one radio outage must not spam.")
    }

    func testAsyncEpisodeGateRejectsRecoveryRemovalAndOlderGeneration() {
        XCTAssertTrue(BluetoothAvailabilityNotifications.isCurrentOutageEpisode(
            expectedEpisode: 8,
            currentEpisode: 8,
            outageActive: true,
            radioIsPoweredOff: true,
            hasRelevantWearable: true
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.isCurrentOutageEpisode(
            expectedEpisode: 8,
            currentEpisode: 9,
            outageActive: true,
            radioIsPoweredOff: true,
            hasRelevantWearable: true
        ), "A recovery/new outage generation must invalidate the older async continuation.")
        XCTAssertFalse(BluetoothAvailabilityNotifications.isCurrentOutageEpisode(
            expectedEpisode: 8,
            currentEpisode: 8,
            outageActive: false,
            radioIsPoweredOff: false,
            hasRelevantWearable: true
        ), "Radio recovery must invalidate an in-flight off alert.")
        XCTAssertFalse(BluetoothAvailabilityNotifications.isCurrentOutageEpisode(
            expectedEpisode: 8,
            currentEpisode: 8,
            outageActive: true,
            radioIsPoweredOff: true,
            hasRelevantWearable: false
        ), "Disconnect/removal must invalidate an in-flight off alert.")
    }

    func testAsyncDeliveryRechecksOptOutEpisodeAndTaskCancellation() {
        XCTAssertTrue(BluetoothAvailabilityNotifications.shouldContinueDelivery(
            enabled: true, episodeStillActive: true, taskCancelled: false
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldContinueDelivery(
            enabled: false, episodeStillActive: true, taskCancelled: false
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldContinueDelivery(
            enabled: true, episodeStillActive: false, taskCancelled: false
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.shouldContinueDelivery(
            enabled: true, episodeStillActive: true, taskCancelled: true
        ))
    }

    func testExplicitMonitoringIntentOverridesMigrationPairingEvidence() {
        XCTAssertTrue(BluetoothAvailabilityNotifications.hasRelevantWearable(
            pairedEvidence: true, explicitExpectation: nil
        ))
        XCTAssertFalse(BluetoothAvailabilityNotifications.hasRelevantWearable(
            pairedEvidence: true, explicitExpectation: false
        ), "An explicit Disconnect/Remove must silence a stale paired identifier.")
        XCTAssertTrue(BluetoothAvailabilityNotifications.hasRelevantWearable(
            pairedEvidence: false, explicitExpectation: true
        ), "A previously established monitored wearable survives a normal relaunch.")
    }

    func testSecondaryRemovalKeepsMonitoringWhenAnotherWearableIsStillPaired() {
        BluetoothAvailabilityNotifications.setMonitoringExpected(true)
        BluetoothAvailabilityNotifications.setMonitoringExpected(false, pairedEvidence: true)
        XCTAssertEqual(BluetoothAvailabilityNotifications.monitoringExpected, true)

        BluetoothAvailabilityNotifications.setMonitoringExpected(false, pairedEvidence: false)
        XCTAssertEqual(BluetoothAvailabilityNotifications.monitoringExpected, false)
    }

    func testOnlyAuthorizedNotificationStatesCanPost() {
        XCTAssertTrue(BluetoothAvailabilityNotifications.canPost(using: .authorized))
        XCTAssertTrue(BluetoothAvailabilityNotifications.canPost(using: .provisional))
        XCTAssertFalse(BluetoothAvailabilityNotifications.canPost(using: .notDetermined))
        XCTAssertFalse(BluetoothAvailabilityNotifications.canPost(using: .denied))
    }

    func testBluetoothAlertRoutesToDevices() {
        XCTAssertEqual(
            NotificationRouteBridge.route(
                from: [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.devices.rawValue]
            ),
            .devices
        )
    }

    func testSafetyReminderRoutesOnlyToTrustedSafetyDestination() {
        XCTAssertEqual(
            NotificationRouteBridge.route(
                from: [NotificationRouteBridge.userInfoKey: NoopNotificationRoute.safety.rawValue]
            ),
            .safety
        )
        XCTAssertNil(NotificationRouteBridge.route(
            from: [NotificationRouteBridge.userInfoKey: "https://example.com"]
        ))
    }
}

@MainActor
final class AutoWorkoutNotificationsTests: XCTestCase {
    func testCandidateTokenIsStableAcrossEndpointGrowth() {
        XCTAssertEqual(AutoWorkoutNotifications.token(startSec: 100, endSec: 200), "start:100")
        XCTAssertEqual(
            AutoWorkoutNotifications.token(startSec: 100, endSec: 200),
            AutoWorkoutNotifications.token(startSec: 100, endSec: 201)
        )
        XCTAssertNotEqual(
            AutoWorkoutNotifications.token(startSec: 100, endSec: 200),
            AutoWorkoutNotifications.token(startSec: 101, endSec: 201)
        )
        XCTAssertTrue(AutoWorkoutSuggestionIdentity.matches("100:200", startSec: 100),
                      "legacy dismiss/notification tokens survive migration")
    }
}
