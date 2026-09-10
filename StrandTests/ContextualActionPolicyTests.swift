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
    func testPlannedWorkoutReconciliationKeepsCurrentAndRemovesOnlyStaleWorkoutAction() {
        let suiteName = "ContextualActionPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = ContextualActionCenter(defaults: defaults, storageKey: "state")
        let now = Date()
        center.presentRecovery(
            title: "Sleep recovery",
            detail: "Review sleep.",
            fingerprint: "sleep-a",
            evidence: [],
            observedAt: now,
            maximumAge: 60 * 60,
            route: .sleep
        )
        center.presentRecovery(
            title: "Planned workout",
            detail: "Keep it lighter.",
            fingerprint: "planned-a",
            evidence: [],
            observedAt: now.addingTimeInterval(1),
            maximumAge: 60 * 60,
            route: .workouts
        )

        center.reconcileRecoveryActions(
            route: .workouts,
            keepingFingerprint: "planned-a"
        )
        XCTAssertEqual(center.visibleActions.first?.route, .workouts)

        center.reconcileRecoveryActions(
            route: .workouts,
            keepingFingerprint: nil
        )
        XCTAssertTrue(center.visibleActions.allSatisfy { $0.route != .workouts })
    }

    @MainActor
    func testEquivalentLegacyActionMigratesAfterDeliveryStateIsCanonical() throws {
        let suiteName = "ContextualActionPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "state"
        let center = ContextualActionCenter(defaults: defaults, storageKey: storageKey)
        let legacy = "planned-workout|2026-08-22|1700000123|SLEEP_DEFICIT"
        let current = "planned-workout|2026-08-22|1700000123"
        center.presentRecovery(
            title: "Planned workout",
            detail: "Keep it lighter.",
            fingerprint: legacy,
            evidence: ["Measured sleep"],
            observedAt: Date(),
            maximumAge: 60 * 60,
            route: .workouts
        )

        center.migrateRecoveryAction(
            route: .workouts,
            toFingerprint: current
        ) {
            ContextualInterventionCenter.plannedWorkoutFingerprintsMatch($0, current)
        }
        center.reconcileRecoveryActions(
            route: .workouts,
            keepingFingerprint: current
        )

        let migrated = try XCTUnwrap(center.visibleActions.first)
        XCTAssertEqual(migrated.id, "recovery:\(current)")
        XCTAssertEqual(migrated.route, .workouts)
        XCTAssertEqual(migrated.evidence, ["Measured sleep"])
        XCTAssertEqual(
            ContextualActionCenter(defaults: defaults, storageKey: storageKey)
                .visibleActions.first?.id,
            migrated.id
        )
    }

    @MainActor
    func testPlannedWorkoutActionFingerprintMigrationPreservesDismissal() throws {
        let suiteName = "ContextualActionPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "state"
        let center = ContextualActionCenter(defaults: defaults, storageKey: storageKey)
        let legacy = "planned-workout|2026-08-22|1700000123|SLEEP_DEFICIT"
        let current = "planned-workout|2026-08-22|1700000123"
        center.presentRecovery(
            title: "Planned workout",
            detail: "Keep it lighter.",
            fingerprint: legacy,
            evidence: ["Measured sleep"],
            observedAt: Date(),
            maximumAge: 60 * 60,
            route: .workouts
        )
        center.dismiss(try XCTUnwrap(center.visibleActions.first))

        center.migrateRecoveryAction(
            route: .workouts,
            toFingerprint: current
        ) {
            ContextualInterventionCenter.plannedWorkoutFingerprintsMatch($0, current)
        }
        center.presentRecovery(
            title: "Planned workout",
            detail: "Keep it lighter.",
            fingerprint: current,
            evidence: ["Measured sleep"],
            observedAt: Date(),
            maximumAge: 60 * 60,
            route: .workouts
        )

        XCTAssertTrue(center.visibleActions.isEmpty)
        XCTAssertTrue(
            ContextualActionCenter(defaults: defaults, storageKey: storageKey)
                .visibleActions.isEmpty
        )
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

    @MainActor
    func testScheduledPlannedWorkoutPreservesSupportingEvidenceAndExactExpiry() throws {
        let suiteName = "ContextualActionPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = ContextualActionCenter(
            defaults: defaults,
            storageKey: "state"
        )
        let observedAt = Date()
        let start = observedAt.addingTimeInterval(15 * 60)
        let evidence = [String(localized: "daily_plan.evidence.readiness")]
        let content = UNMutableNotificationContent()
        content.userInfo = [
            AdaptivePlannedWorkoutScheduler.startSecUserInfoKey:
                NSNumber(value: start.timeIntervalSince1970),
            AdaptivePlannedWorkoutScheduler.fingerprintUserInfoKey:
                "recovery-only",
            AdaptivePlannedWorkoutScheduler.evidenceUserInfoKey:
                evidence,
        ]
        let request = UNNotificationRequest(
            identifier: AdaptivePlannedWorkoutScheduler.requestID,
            content: content,
            trigger: nil
        )

        center.capture(request, observedAt: observedAt)

        let action = try XCTUnwrap(center.visibleActions.first)
        XCTAssertEqual(action.evidence, evidence)
        XCTAssertEqual(action.route, .workouts)
        XCTAssertEqual(
            action.expiresAt.timeIntervalSince1970,
            start.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
