import XCTest
@testable import Strand

final class TapAutomationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        TapAutomationStore.clear()
        UserDefaults.standard.removeObject(forKey: TapAutomationPreferences.alarmDoubleTapEnabledKey)
        UserDefaults.standard.removeObject(forKey: TapAutomationPreferences.alarmWindowMinutesKey)
        super.tearDown()
    }

    func testAlarmDisplacesReminderAndReminderCannotDisplaceAlarm() {
        var state = PendingTapAutomationState()
        let hydration = PendingTapAutomation(
            token: "water",
            kind: .hydrationConfirm,
            value: 250,
            contextKey: "2026-08-23-480",
            now: now,
            windowMinutes: 10
        )
        let alarm = PendingTapAutomation(
            token: "alarm",
            kind: .alarmDismiss,
            now: now,
            windowMinutes: 15
        )

        XCTAssertTrue(state.arm(hydration, now: now))
        XCTAssertTrue(state.arm(alarm, now: now))
        XCTAssertFalse(state.arm(hydration, now: now))
        XCTAssertEqual(state.consume(now: now)?.token, "alarm")
    }

    func testConsumptionIsOneShotAndReplayReturnsNothing() {
        var state = PendingTapAutomationState()
        state.arm(
            PendingTapAutomation(
                token: "one-shot",
                kind: .hydrationConfirm,
                value: 300,
                now: now,
                windowMinutes: 5
            ),
            now: now
        )

        XCTAssertEqual(state.consume(now: now)?.value, 300)
        XCTAssertNil(state.consume(now: now))
    }

    func testHydrationOccurrenceIdentitySurvivesPersistence() {
        let action = PendingTapAutomation(
            token: "slot-scoped",
            kind: .hydrationConfirm,
            value: 250,
            contextKey: "2026-08-23-480",
            now: now,
            windowMinutes: 10
        )

        TapAutomationStore.arm(action, now: now)

        XCTAssertEqual(TapAutomationStore.consume(now: now)?.contextKey, "2026-08-23-480")
    }

    func testClearingHydrationDoesNotClearHigherPriorityAlarm() {
        var state = PendingTapAutomationState(
            pending: PendingTapAutomation(
                token: "alarm",
                kind: .alarmDismiss,
                now: now,
                windowMinutes: 15
            )
        )

        state.clear(kind: .hydrationConfirm)

        XCTAssertEqual(state.consume(now: now)?.kind, .alarmDismiss)
    }

    func testExpiredAndNotYetActiveTokensAreNeverConsumed() {
        let action = PendingTapAutomation(
            token: "expiring",
            kind: .hydrationConfirm,
            value: 250,
            now: now,
            windowMinutes: 5
        )
        var expired = PendingTapAutomationState(pending: action)
        XCTAssertNil(expired.consume(now: now.addingTimeInterval(5 * 60)))

        var early = PendingTapAutomationState(pending: action)
        XCTAssertNil(early.consume(now: now.addingTimeInterval(-1)))
    }

    func testDurableStoreRemovesTokenBeforeASecondConsume() {
        TapAutomationStore.clear()
        let action = PendingTapAutomation(
            token: "durable",
            kind: .hydrationConfirm,
            value: 200,
            now: now,
            windowMinutes: 10
        )
        TapAutomationStore.arm(action, now: now)

        XCTAssertEqual(TapAutomationStore.consume(now: now), action)
        XCTAssertNil(TapAutomationStore.consume(now: now))
        XCTAssertNil(UserDefaults.standard.data(forKey: TapAutomationStore.storageKey))
    }

    func testNoPendingTapDoesNotInventAnAction() {
        var state = PendingTapAutomationState()
        XCTAssertNil(state.consume(now: now))
    }
}
