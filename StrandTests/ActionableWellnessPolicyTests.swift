import UserNotifications
import XCTest
@testable import Strand

@MainActor
final class ActionableWellnessPolicyTests: XCTestCase {
    private func sourceText(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

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

    func testInactivityEnableRequestsAuthorizationWhenNotDetermined() async {
        let notifications = InactivityNotificationClientSpy(
            status: .notDetermined,
            authorizationResult: true
        )

        let outcome = await InactivityNotificationPermission
            .resolveExplicitPreferenceChange(
                enabled: true,
                client: notifications.client
            )

        XCTAssertEqual(outcome, .permissionAvailable)
        XCTAssertEqual(notifications.authorizationStatusReadCount, 1)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
    }

    func testInactivityPermissionRemainsPreferenceOnlyWhenNoPromptIsNeeded() async {
        for status in [
            UNAuthorizationStatus.authorized,
            .provisional,
            .denied,
        ] {
            let notifications = InactivityNotificationClientSpy(status: status)
            let outcome = await InactivityNotificationPermission
                .resolveExplicitPreferenceChange(
                    enabled: true,
                    client: notifications.client
                )

            XCTAssertEqual(
                outcome,
                status == .denied ? .permissionDenied : .permissionAvailable
            )
            XCTAssertEqual(notifications.authorizationStatusReadCount, 1)
            XCTAssertEqual(notifications.authorizationRequestCount, 0)
        }

        let disabledNotifications = InactivityNotificationClientSpy(
            status: .notDetermined
        )
        let disabledOutcome = await InactivityNotificationPermission
            .resolveExplicitPreferenceChange(
                enabled: false,
                client: disabledNotifications.client
            )

        XCTAssertEqual(disabledOutcome, .preferenceOnly)
        XCTAssertEqual(disabledNotifications.authorizationStatusReadCount, 0)
        XCTAssertEqual(disabledNotifications.authorizationRequestCount, 0)
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

    func testMacHydrationNotificationPresentsConfirmedFlowWithoutAutomaticIntake() throws {
        let root = try sourceText("Strand/App/RootView.swift")
        let hydration = try sourceText("Strand/Screens/HydrationView.swift")
        let routeStart = try XCTUnwrap(
            root.range(of: "private func consumePendingNotificationRoute()")
        )
        let routeTail = root[routeStart.lowerBound...]
        let routeEnd = try XCTUnwrap(
            routeTail.range(of: "\n    private func select")
        )
        let routeHandler = String(routeTail[..<routeEnd.lowerBound])
        let sheetStart = try XCTUnwrap(
            root.range(of: ".sheet(isPresented: $showHydrationLog)")
        )
        let sheetTail = root[sheetStart.lowerBound...]
        let sheetEnd = try XCTUnwrap(
            sheetTail.range(of: ".sheet(isPresented: $showMovementBreak)")
        )
        let sheet = String(sheetTail[..<sheetEnd.lowerBound])

        XCTAssertTrue(routeHandler.contains("case .hydration: showHydrationLog = true"))
        XCTAssertTrue(routeHandler.contains("case .logHydration:"))
        XCTAssertTrue(
            routeHandler.contains("\"wellness_notification.action_started\"")
        )
        XCTAssertFalse(routeHandler.contains("repo.logHydration"))
        XCTAssertTrue(sheet.contains("HydrationView()"))
        XCTAssertTrue(sheet.contains("Button(\"Done\")"))
        XCTAssertTrue(
            hydration.contains("NoopButton(title, systemImage: systemImage")
        )
        XCTAssertTrue(hydration.contains("Task { await add(ml: ml) }"))
    }

    func testMacHydrationNotificationRequestIsConsumedOnce() throws {
        _ = NotificationRouteBridge.consumePendingRequest()
        NotificationRouteBridge.recordPending(
            .hydration,
            presentation: .logHydration
        )

        let request = try XCTUnwrap(
            NotificationRouteBridge.consumePendingRequest()
        )

        XCTAssertEqual(request.route, .hydration)
        XCTAssertEqual(request.presentation, .logHydration)
        XCTAssertNil(NotificationRouteBridge.consumePendingRequest())
    }
}

@MainActor
private final class InactivityNotificationClientSpy {
    var status: UNAuthorizationStatus
    var authorizationResult: Bool
    private(set) var authorizationStatusReadCount = 0
    private(set) var authorizationRequestCount = 0

    init(
        status: UNAuthorizationStatus,
        authorizationResult: Bool = false
    ) {
        self.status = status
        self.authorizationResult = authorizationResult
    }

    var client: InactivityNotificationPermission.NotificationClient {
        InactivityNotificationPermission.NotificationClient(
            authorizationStatus: { [weak self] in
                guard let self else { return .denied }
                self.authorizationStatusReadCount += 1
                return self.status
            },
            requestAuthorization: { [weak self] in
                guard let self else { return false }
                self.authorizationRequestCount += 1
                return self.authorizationResult
            }
        )
    }
}
