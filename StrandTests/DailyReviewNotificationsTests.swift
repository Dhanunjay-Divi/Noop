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
