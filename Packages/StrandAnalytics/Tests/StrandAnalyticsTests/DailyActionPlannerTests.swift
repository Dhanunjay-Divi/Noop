import XCTest
@testable import StrandAnalytics

final class DailyActionPlannerTests: XCTestCase {
    private let today = "2026-08-22"

    private func readiness(
        level: ReadinessEngine.Level = .balanced,
        confidence: ScoreConfidence = .solid,
        day: String? = "2026-08-22"
    ) -> ReadinessEngine.Readiness {
        ReadinessEngine.Readiness(
            level: level,
            headline: "Within range",
            summary: "Available measured signals are close to your recent baseline.",
            signals: [
                .init(key: "hrv", label: "HRV", detail: "in your normal range", flag: .neutral),
                .init(key: "rhr", label: "Resting HR", detail: "in your normal range", flag: .neutral),
            ],
            acwr: nil,
            monotony: nil,
            asOfDay: day,
            confidence: confidence,
            baselineDays: 20
        )
    }

    private func history(count: Int = 14, value: (Int) -> Double = { $0.isMultiple(of: 2) ? 40 : 60 })
        -> [DailyActionPlanner.EffortDay] {
        (1...count).map {
            .init(day: String(format: "2026-08-%02d", $0), effort: value($0))
        }
    }

    func testReadyRangeUsesPersonalHistoryAndNeverRisesForPrimed() {
        let balanced = DailyActionPlanner.plan(
            today: today, readiness: readiness(), checkIn: .asUsual, recentEffort: history()
        )
        let primed = DailyActionPlanner.plan(
            today: today, readiness: readiness(level: .primed),
            checkIn: .asUsual, recentEffort: history()
        )

        XCTAssertEqual(balanced.availability, .ready)
        XCTAssertEqual(balanced.target, .init(lower: 40, upper: 60))
        XCTAssertEqual(balanced.confidence, .solid)
        XCTAssertEqual(primed.target, balanced.target)
        XCTAssertTrue(primed.limitations.contains { $0.contains("never raises") })
    }

    func testSameDaySelfCheckIsRequired() {
        let plan = DailyActionPlanner.plan(
            today: today, readiness: readiness(), checkIn: .unanswered, recentEffort: history()
        )
        XCTAssertEqual(plan.availability, .checkInNeeded)
        XCTAssertNil(plan.target)
        XCTAssertEqual(plan.action, .completeCheckIn)
    }

    func testHowUserFeelsOverridesWearableRead() {
        let below = DailyActionPlanner.plan(
            today: today, readiness: readiness(level: .primed),
            checkIn: .belowUsual, recentEffort: history()
        )
        let unwell = DailyActionPlanner.plan(
            today: today, readiness: readiness(level: .primed),
            checkIn: .painOrUnwell, recentEffort: history()
        )
        XCTAssertEqual(below.availability, .recoveryShift)
        XCTAssertEqual(below.action, .chooseEasyDay)
        XCTAssertNil(below.target)
        XCTAssertEqual(unwell.availability, .stop)
        XCTAssertEqual(unwell.action, .stopAndAssess)
        XCTAssertNil(unwell.target)
    }

    func testMeasuredRecoveryShiftWithholdsInsteadOfLoweringTarget() {
        for level in [ReadinessEngine.Level.strained, .rundown] {
            let plan = DailyActionPlanner.plan(
                today: today, readiness: readiness(level: level),
                checkIn: .asUsual, recentEffort: history()
            )
            XCTAssertEqual(plan.availability, .recoveryShift)
            XCTAssertNil(plan.target)
            XCTAssertEqual(plan.action, .chooseEasyDay)
        }
    }

    func testStaleOrThinEvidenceNeverProducesRange() {
        let stale = DailyActionPlanner.plan(
            today: today, readiness: readiness(day: "2026-08-21"),
            checkIn: .asUsual, recentEffort: history()
        )
        let oneSignal = DailyActionPlanner.plan(
            today: today, readiness: readiness(confidence: .building),
            checkIn: .asUsual, recentEffort: history()
        )
        let thinHistory = DailyActionPlanner.plan(
            today: today, readiness: readiness(), checkIn: .asUsual, recentEffort: history(count: 6)
        )
        XCTAssertNil(stale.target)
        XCTAssertNil(oneSignal.target)
        XCTAssertNil(thinHistory.target)
        XCTAssertEqual(thinHistory.availability, .calibrating)
    }

    func testHistoryWindowExcludesTodayFutureInvalidAndAveragesDuplicates() {
        var rows = history(count: 7, value: { _ in 50 })
        rows += [
            .init(day: "2026-08-01", effort: 70),
            .init(day: today, effort: 100),
            .init(day: "2026-08-23", effort: 100),
            .init(day: "2026-07-20", effort: 100),
            .init(day: "not-a-day", effort: 100),
            .init(day: "2026-08-08", effort: 101),
        ]
        let values = DailyActionPlanner.effortValues(in: rows, before: today)
        XCTAssertEqual(values.count, 7)
        XCTAssertEqual(values.first, 60)
        XCTAssertFalse(values.contains(100))
    }

    func testStableHistoryGetsUsefulBoundedRange() {
        XCTAssertEqual(DailyActionPlanner.planningRange(Array(repeating: 0, count: 7)),
                       .init(lower: 0, upper: 10))
        XCTAssertEqual(DailyActionPlanner.planningRange(Array(repeating: 100, count: 7)),
                       .init(lower: 90, upper: 100))
    }

    func testOneSleepActionUsesSupportedPlannerRecovery() {
        let normal = DailyActionPlanner.plan(
            today: today, readiness: readiness(), checkIn: .asUsual, recentEffort: history(),
            sleepRecoveryMinutes: 15, sleepConfidence: .solid
        )
        let recovery = DailyActionPlanner.plan(
            today: today, readiness: readiness(), checkIn: .asUsual, recentEffort: history(),
            sleepRecoveryMinutes: 30, sleepConfidence: .building
        )
        XCTAssertEqual(normal.action, .keepSleepWindow)
        XCTAssertEqual(recovery.action, .protectExtraSleep)
        XCTAssertEqual(recovery.evidence.last?.source, .sleepPlan)
    }
}
