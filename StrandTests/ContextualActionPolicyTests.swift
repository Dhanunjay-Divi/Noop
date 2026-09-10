import XCTest
import UserNotifications
@testable import Strand

final class ContextualActionPolicyTests: XCTestCase {
    private func action(
        _ kind: ContextualActionKind,
        id: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        route: NoopNotificationRoute? = nil
    ) -> ContextualAction {
        ContextualAction(
            id: id ?? kind.rawValue,
            kind: kind,
            title: id ?? kind.rawValue,
            detail: "",
            evidence: [],
            createdAt: createdAt,
            expiresAt: expiresAt,
            amountML: nil,
            route: route
        )
    }

    func testVisibleActionsExpireDeduplicateAndRespectPriorityLimit() {
        let now = Date(timeIntervalSince1970: 5_000)
        let future = Date(timeIntervalSince1970: 10_000)
        let actions = [
            action(.hydration, id: "old-water", createdAt: Date(timeIntervalSince1970: 1_000), expiresAt: future),
            action(.hydration, id: "new-water", createdAt: Date(timeIntervalSince1970: 2_000), expiresAt: future),
            action(.journal, createdAt: Date(timeIntervalSince1970: 1_000), expiresAt: future),
            action(.windDown, createdAt: Date(timeIntervalSince1970: 1_000), expiresAt: future),
            action(.recovery, createdAt: Date(timeIntervalSince1970: 1_000), expiresAt: future),
            action(
                .breathe,
                createdAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: Date(timeIntervalSince1970: 4_000)
            ),
        ]

        let visible = ContextualActionPolicy.visible(actions, now: now)

        XCTAssertEqual(visible.map(\.kind), [.recovery, .windDown, .hydration])
        XCTAssertEqual(visible.last?.id, "new-water")
    }

    func testZeroLimitReturnsNoActions() {
        let visible = ContextualActionPolicy.visible(
            [
                action(
                    .hydration,
                    createdAt: Date(timeIntervalSince1970: 1_000),
                    expiresAt: Date(timeIntervalSince1970: 10_000)
                ),
            ],
            now: Date(timeIntervalSince1970: 2_000),
            limit: 0
        )

        XCTAssertTrue(visible.isEmpty)
    }

    func testRecoveryRouteDefaultsToSleepAndPreservesWorkoutDestination() {
        let now = Date()
        let future = now.addingTimeInterval(60)

        XCTAssertEqual(
            action(.recovery, createdAt: now, expiresAt: future).resolvedRecoveryRoute,
            .sleep
        )
        XCTAssertEqual(
            action(
                .recovery,
                createdAt: now,
                expiresAt: future,
                route: .workouts
            ).resolvedRecoveryRoute,
            .workouts
        )
    }

    func testLegacyPersistedActionWithoutRouteStillDecodes() throws {
        let now = Date()
        let encoded = try JSONEncoder().encode(
            action(
                .recovery,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60),
                route: .workouts
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "route")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ContextualAction.self, from: legacy)

        XCTAssertNil(decoded.route)
        XCTAssertEqual(decoded.resolvedRecoveryRoute, .sleep)
    }

    @MainActor
    func testRecoveryRoutePersistsAcrossActionCenterReload() {
        let suiteName = "ContextualActionPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "state"
        let now = Date()
        let center = ContextualActionCenter(defaults: defaults, storageKey: storageKey)
        center.presentRecovery(
            title: "Keep it lighter",
            detail: "Your planned workout is later today.",
            fingerprint: "planned-workout",
            evidence: [],
            observedAt: now,
            maximumAge: 60 * 60,
            route: .workouts
        )

        let restored = ContextualActionCenter(defaults: defaults, storageKey: storageKey)

        XCTAssertEqual(restored.visibleActions.first?.route, .workouts)
        XCTAssertEqual(restored.visibleActions.first?.resolvedRecoveryRoute, .workouts)
    }

    @MainActor
    func testStaleDeliveredNotificationDoesNotBecomeCurrentAction() {
        let suiteName = "ContextualActionPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = ContextualActionCenter(
            defaults: defaults,
            storageKey: "state"
        )
        let request = UNNotificationRequest(
            identifier: "hydration-reminder",
            content: UNMutableNotificationContent(),
            trigger: nil
        )

        center.capture(
            request,
            observedAt: Date().addingTimeInterval(-3 * 60 * 60)
        )

        XCTAssertTrue(center.visibleActions.isEmpty)
    }
}
