import XCTest
import UserNotifications
@testable import Strand

@MainActor
final class DailyReviewNotificationsTests: XCTestCase {
    private let keys = [
        DailyReviewNotifications.enabledKey,
        DailyReviewNotifications.morningMinutesKey,
        DailyReviewNotifications.eveningMinutesKey,
        NotificationRouteBridge.pendingRouteKey,
        AutoWorkoutNotifications.enabledKey,
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
