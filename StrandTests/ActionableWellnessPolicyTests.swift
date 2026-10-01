import UserNotifications
import XCTest
@testable import Strand

@MainActor
final class ActionableWellnessPolicyTests: XCTestCase {
    func testBreathingSessionCompletesOnlyAtBoundedMinute() {
        XCTAssertEqual(
            ActionableWellnessPolicy.elapsedSeconds(
                startedAtUptime: 100,
                nowUptime: 99
            ),
            0
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.elapsedSeconds(
                startedAtUptime: 100,
                nowUptime: 159.99
            ),
            59
        )
        XCTAssertFalse(
            ActionableWellnessPolicy.shouldCompleteBreathingSession(
                isOneMinuteSession: false,
                elapsedSeconds: 60
            )
        )
        XCTAssertFalse(
            ActionableWellnessPolicy.shouldCompleteBreathingSession(
                isOneMinuteSession: true,
                elapsedSeconds: 59
            )
        )
        XCTAssertTrue(
            ActionableWellnessPolicy.shouldCompleteBreathingSession(
                isOneMinuteSession: true,
                elapsedSeconds: 60
            )
        )
    }

    func testMovementBreakCountdownAndProgressAreBounded() {
        XCTAssertEqual(
            ActionableWellnessPolicy.movementRemainingSeconds(afterTick: 120),
            119
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementRemainingSeconds(afterTick: 0),
            0
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtUptime: 100,
                nowUptime: 100.99
            ),
            120
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtUptime: 100,
                nowUptime: 101
            ),
            119
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementRemainingSeconds(
                startedAtUptime: 100,
                nowUptime: 220
            ),
            0
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementProgress(remainingSeconds: 120),
            0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementProgress(remainingSeconds: 60),
            0.5,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementProgress(remainingSeconds: 0),
            1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ActionableWellnessPolicy.movementProgress(remainingSeconds: -20),
            1,
            accuracy: 0.000_1
        )
    }

    func testWellnessPresentationsRoundTripOnlyTrustedValues() {
        for presentation in [
            NotificationRoutePresentation.startBreathing,
            .logHydration,
            .movementBreak,
        ] {
            XCTAssertEqual(
                NotificationRouteBridge.presentation(
                    from: [
                        NotificationRouteBridge.presentationUserInfoKey:
                            presentation.rawValue
                    ]
                ),
                presentation
            )
        }
        XCTAssertNil(
            NotificationRouteBridge.presentation(
                from: [
                    NotificationRouteBridge.presentationUserInfoKey:
                        "https://example.com"
                ]
            )
        )
    }

    func testStressNotificationPreferenceIsRecheckedAtDelivery() {
        XCTAssertFalse(
            ContextualInterventionPolicy.preferenceAllowsDelivery(
                kind: .stressBreathing,
                stressPhoneNudgeEnabled: false
            )
        )
        XCTAssertTrue(
            ContextualInterventionPolicy.preferenceAllowsDelivery(
                kind: .stressBreathing,
                stressPhoneNudgeEnabled: true
            )
        )
        XCTAssertTrue(
            ContextualInterventionPolicy.preferenceAllowsDelivery(
                kind: .adaptiveRoutineRecovery,
                stressPhoneNudgeEnabled: false
            )
        )
    }

    func testWellnessCategoriesExposeOnePrivateForegroundAction() {
        let categories: [
            (
                category: UNNotificationCategory,
                identifier: String,
                actionIdentifier: String
            )
        ] = [
            (
                DailyReviewNotifications.hydrationActionCategory(),
                DailyReviewNotifications.hydrationCategoryID,
                DailyReviewNotifications.logWaterActionID
            ),
            (
                DailyReviewNotifications.stressBreathingActionCategory(),
                DailyReviewNotifications.stressBreathingCategoryID,
                DailyReviewNotifications.startBreathingActionID
            ),
            (
                DailyReviewNotifications.inactivityActionCategory(),
                DailyReviewNotifications.inactivityCategoryID,
                DailyReviewNotifications.startMovementBreakActionID
            ),
        ]

        for expected in categories {
            XCTAssertEqual(expected.category.identifier, expected.identifier)
            XCTAssertEqual(
                expected.category.actions.map(\.identifier),
                [expected.actionIdentifier]
            )
            XCTAssertEqual(
                expected.category.hiddenPreviewsBodyPlaceholder,
                String(localized: "Private NOOP check-in")
            )
            let options = expected.category.actions[0].options
            XCTAssertTrue(options.contains(.authenticationRequired))
            XCTAssertTrue(options.contains(.foreground))
        }
    }

    func testHydrationRequestsCarryActionablePrivateRoute() throws {
        let spec = try XCTUnwrap(
            HydrationReminders.reminderSpecs(
                start: 8 * 60,
                end: 9 * 60,
                interval: 60
            ).first
        )
        let request = try XCTUnwrap(
            HydrationReminders.notificationRequests(specs: [spec]).first
        )

        XCTAssertEqual(
            request.content.categoryIdentifier,
            DailyReviewNotifications.hydrationCategoryID
        )
        XCTAssertEqual(
            NotificationRouteBridge.route(from: request.content.userInfo),
            .hydration
        )
        XCTAssertEqual(
            NotificationRouteBridge.presentation(
                from: request.content.userInfo
            ),
            .logHydration
        )
    }
}
