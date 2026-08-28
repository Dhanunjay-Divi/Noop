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
final class DailyReviewNotificationsTests: XCTestCase {
    private let keys = [
        DailyReviewNotifications.enabledKey,
        DailyReviewNotifications.morningMinutesKey,
        DailyReviewNotifications.eveningMinutesKey,
        NotificationRouteBridge.pendingRouteKey,
        AutoWorkoutNotifications.enabledKey,
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

        XCTAssertEqual(specs.map(\.route), [.sleep, .today])
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

    func testPendingNotificationRouteIsConsumedOnce() {
        NotificationRouteBridge.recordPending(.sleep)

        XCTAssertEqual(NotificationRouteBridge.consumePending(), .sleep)
        XCTAssertNil(NotificationRouteBridge.consumePending())
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
                await self.add(request)
            },
            remove: { [weak self] identifiers in
                self?.remove(identifiers)
            }
        )
    }

    private func add(_ request: UNNotificationRequest) async {
        addCount += 1
        if suspendAdds {
            addStarted = true
            addStartedContinuation?.resume()
            addStartedContinuation = nil
            await withCheckedContinuation { addResumeContinuation = $0 }
        }
        requests[request.identifier] = request
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
