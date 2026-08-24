import XCTest
import StrandAnalytics
@testable import Strand

/// `StrainTargetNotifier.StrainTargetPolicy` — the pure once-per-day crossing gate + copy behind the
/// #593 evidence-gated Effort-marker nudge. Mirrors the Android `StrainTargetPolicyTest` byte-for-byte (same
/// fixtures, same expectations). No notification/UserDefaults runtime needed here. Contract: fire at
/// most once per day, only when strain has genuinely reached a KNOWN target, never on a guessed one.
final class StrainTargetPolicyTests: XCTestCase {
    private typealias Policy = StrainTargetNotifier.StrainTargetPolicy
    private let range = DailyActionPlanner.EffortRange(lower: 40, upper: 60)

    private func guidance(_ effort: Double?) -> DailyEffortGuidance.Result {
        DailyEffortGuidance.evaluate(currentEffort: effort, range: range)
    }

    func testFiresWhenEnabledStrainReachedTargetAndNotYetToday() {
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, guidance: guidance(40), lastNotifiedDay: "2026-07-17",
            today: "2026-07-18"))
        // Overshooting the target still fires (>= gate), once.
        XCTAssertTrue(Policy.shouldNotify(
            enabled: true, guidance: guidance(72), lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenDisabled() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: false, guidance: guidance(50), lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedBeforeTargetIsReached() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, guidance: guidance(39.9), lastNotifiedDay: nil, today: "2026-07-18"))
    }

    func testSuppressedWhenAlreadyFiredToday() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, guidance: guidance(50), lastNotifiedDay: "2026-07-18",
            today: "2026-07-18"))
    }

    func testSuppressedWhenTargetUnknownCalibrating() {
        // Planner withheld the range ⇒ nil target ⇒ never fire (never guess a target).
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true,
            guidance: DailyEffortGuidance.evaluate(currentEffort: 50, range: nil),
            lastNotifiedDay: nil,
            today: "2026-07-18"))
    }

    func testSuppressedWhenNoStrainYet() {
        XCTAssertFalse(Policy.shouldNotify(
            enabled: true, guidance: guidance(nil), lastNotifiedDay: nil, today: "2026-07-18"))
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
}
