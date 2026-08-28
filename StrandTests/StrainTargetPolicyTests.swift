import XCTest
import UserNotifications
import StrandAnalytics
@testable import Strand

/// `StrainTargetNotifier.StrainTargetPolicy` — the pure once-per-day crossing gate + copy behind the
/// #593 evidence-gated Effort-marker nudge. Mirrors the Android `StrainTargetPolicyTest` byte-for-byte (same
/// fixtures, same expectations). No notification/UserDefaults runtime needed here. Contract: fire at
/// most once per day, only when strain has genuinely reached a KNOWN target, never on a guessed one.
@MainActor
final class StrainTargetPolicyTests: XCTestCase {
    private typealias Policy = StrainTargetNotifier.StrainTargetPolicy
    private let range = DailyActionPlanner.EffortRange(lower: 40, upper: 60)

    private func guidance(_ effort: Double?) -> DailyEffortGuidance.Result {
        DailyEffortGuidance.evaluate(currentEffort: effort, range: range)
    }

    func testFiresWhenEnabledStrainReachedTargetAndNotYetToday() {
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, guidance: guidance(40), dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18", lastNotifiedDay: "2026-07-17"))
        // Overshooting the target still fires (>= gate), once.
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, guidance: guidance(72), dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18", lastNotifiedDay: nil))
    }

    func testSuppressedWhenDisabled() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: false, guidance: guidance(50), dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18", lastNotifiedDay: nil))
    }

    func testSuppressedBeforeTargetIsReached() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, guidance: guidance(39.9), dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18", lastNotifiedDay: nil))
    }

    func testSuppressedWhenAlreadyFiredToday() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, guidance: guidance(50), dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18", lastNotifiedDay: "2026-07-18"))
    }

    func testSuppressedForHistoricalOrFutureDataDays() {
        for dataDay in ["2026-07-17", "2026-07-19"] {
            XCTAssertFalse(Policy.shouldNotify(
                enabled: true, guidance: guidance(50), dataDay: dataDay,
                currentLocalDay: "2026-07-18", lastNotifiedDay: nil
            ), "only the current local calendar day's row may notify")
        }
    }

    func testSuppressedWhenTargetUnknownCalibrating() {
        // Planner withheld the range ⇒ nil target ⇒ never fire (never guess a target).
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true,
            guidance: DailyEffortGuidance.evaluate(currentEffort: 50, range: nil),
            dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18",
            lastNotifiedDay: nil))
    }

    func testSuppressedWhenNoStrainYet() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, guidance: guidance(nil), dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18", lastNotifiedDay: nil))
    }

    func testStaleReadinessCannotProduceNotifiableGuidance() {
        let staleReadiness = ReadinessEngine.Readiness(
            level: .balanced,
            headline: "Readiness",
            summary: "Stale fixture",
            signals: [],
            effortVariety: nil,
            asOfDay: "2026-07-17",
            confidence: .solid,
            baselineDays: 14
        )
        let plan = DailyActionPlanner.plan(
            today: "2026-07-18",
            readiness: staleReadiness,
            checkIn: .asUsual,
            recentEffort: []
        )
        XCTAssertNil(plan.target, "a prior-day readiness read must withhold today's range")
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true,
            guidance: DailyEffortGuidance.evaluate(currentEffort: 50, range: plan.target),
            dataDay: "2026-07-18",
            currentLocalDay: "2026-07-18",
            lastNotifiedDay: nil
        ))
    }

    func testDailyActionCheckInIsStrictlyDayScopedAndFailClosed() {
        XCTAssertEqual(
            BehaviorStore.decodeDailyActionCheckIn(
                today: "2026-08-22", storedDay: "2026-08-22", storedValue: "asUsual"
            ),
            .asUsual
        )
        XCTAssertEqual(
            BehaviorStore.decodeDailyActionCheckIn(
                today: "2026-08-22", storedDay: "2026-08-21", storedValue: "asUsual"
            ),
            .unanswered
        )
        XCTAssertEqual(
            BehaviorStore.decodeDailyActionCheckIn(
                today: "2026-08-22", storedDay: "2026-08-22", storedValue: "unexpected"
            ),
            .unanswered
        )
    }

    func testDeniedPermissionDoesNotEnableEffortMarker() async {
        let notifications = StrainTargetNotificationClientSpy(status: .notDetermined)
        notifications.authorizationResult = false
        let outcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<
                StrainTargetNotifier.EnableOutcome, Never
            >) in
            StrainTargetNotifier.setEnabled(true, client: notifications.client) {
                continuation.resume(returning: $0)
            }
        }

        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(notifications.authorizationRequestCount, 1)
        XCTAssertTrue(notifications.requests.isEmpty)
    }
}

@MainActor
private final class StrainTargetNotificationClientSpy {
    var status: UNAuthorizationStatus
    var authorizationResult = false
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [String: UNNotificationRequest] = [:]

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    var client: StrainTargetNotifier.NotificationClient {
        StrainTargetNotifier.NotificationClient(
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
