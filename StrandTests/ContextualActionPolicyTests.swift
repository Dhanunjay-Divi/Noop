import XCTest
import UserNotifications
@testable import Strand

final class ContextualActionPolicyTests: XCTestCase {
    private func action(
        _ kind: ContextualActionKind,
        id: String? = nil,
        createdAt: Date,
        expiresAt: Date
    ) -> ContextualAction {
        ContextualAction(
            id: id ?? kind.rawValue,
            kind: kind,
            title: id ?? kind.rawValue,
            detail: "",
            evidence: [],
            createdAt: createdAt,
            expiresAt: expiresAt,
            amountML: nil
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
