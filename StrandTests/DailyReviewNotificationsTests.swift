import XCTest
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
        for spec in specs {
            XCTAssertNil(
                spec.body.rangeOfCharacter(from: .decimalDigits),
                "Generic repeating reminders must not embed a score or health value."
            )
        }
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
