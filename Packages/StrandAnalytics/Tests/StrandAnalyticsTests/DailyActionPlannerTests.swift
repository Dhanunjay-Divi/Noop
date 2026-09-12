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
            effortVariety: nil,
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

    private func plannedWorkout(
        day: String = "2026-08-22",
        startSec: Int = 1_003_600,
        endSec: Int = 1_007_200
    ) -> DailyActionPlanner.PlannedWorkout {
        .init(day: day, startSec: startSec, endSec: endSec)
    }

    private func usualSleep(todayMinutes: Double = 360) -> [DailyActionPlanner.SleepDay] {
        (14...20).map {
            .init(day: String(format: "2026-08-%02d", $0), minutes: 450)
        } + [.init(day: today, minutes: todayMinutes)]
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

    func testPlannedWorkoutUsesPersonalUsualSleepWhenHistoryIsSupported() {
        let plan = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(),
            checkIn: .asUsual,
            recentEffort: history(),
            recentSleep: usualSleep(),
            plannedWorkout: plannedWorkout(),
            nowSec: 1_000_000
        )

        XCTAssertEqual(
            plan.workoutAdjustment,
            .init(
                startSec: 1_003_600,
                durationMinutes: 60,
                reason: .sleepDeficit,
                measuredSleepMinutes: 360,
                referenceSleepMinutes: 450,
                sleepDeficitMinutes: 90,
                sleepReference: .personalUsual,
                confidence: .solid
            )
        )
    }

    func testPlannedWorkoutFallsBackToExplicitSleepTargetWhileBaselineBuilds() {
        let plan = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(),
            checkIn: .unanswered,
            recentEffort: [],
            recentSleep: [.init(day: today, minutes: 410)],
            sleepTargetMinutes: 480,
            sleepTargetIsExplicit: true,
            plannedWorkout: plannedWorkout(),
            nowSec: 1_000_000
        )

        XCTAssertEqual(plan.availability, .checkInNeeded)
        XCTAssertEqual(plan.workoutAdjustment?.reason, .sleepDeficit)
        XCTAssertEqual(plan.workoutAdjustment?.sleepDeficitMinutes, 70)
        XCTAssertEqual(plan.workoutAdjustment?.sleepReference, .explicitTarget)
        XCTAssertEqual(plan.workoutAdjustment?.confidence, .building)
    }

    func testImplicitDefaultSleepTargetCannotCreatePersonalizedDeficit() {
        let plan = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(),
            checkIn: .unanswered,
            recentEffort: [],
            recentSleep: [.init(day: today, minutes: 360)],
            sleepTargetMinutes: 480,
            plannedWorkout: plannedWorkout(),
            nowSec: 1_000_000
        )

        XCTAssertNil(plan.workoutAdjustment)
    }

    func testRecoveryShiftCanSupportWorkoutAdjustmentWithoutSleepDuration() {
        let plan = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(level: .strained, confidence: .building),
            checkIn: .asUsual,
            recentEffort: history(),
            plannedWorkout: plannedWorkout(),
            nowSec: 1_000_000
        )

        XCTAssertEqual(plan.workoutAdjustment?.reason, .recoveryShift)
        XCTAssertNil(plan.workoutAdjustment?.measuredSleepMinutes)
        XCTAssertEqual(plan.workoutAdjustment?.confidence, .building)
    }

    func testFallbackDayAllowsElapsedLeadBeyond24HoursButRejectsAnotherCivilDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(
            TimeZone(identifier: "America/New_York")
        )
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1,
            hour: 0
        )))
        let acceptedStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1,
            hour: 23,
            minute: 30
        )))
        let acceptedEnd = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1,
            hour: 23,
            minute: 55
        )))
        let nextDayStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 2,
            hour: 0,
            minute: 10
        )))
        let nextDayEnd = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 2,
            hour: 0,
            minute: 40
        )))
        let nowSec = Int(now.timeIntervalSince1970)
        let acceptedLead = Int(acceptedStart.timeIntervalSince(now))
        XCTAssertGreaterThan(acceptedLead, 24 * 60 * 60)
        XCTAssertLessThan(acceptedLead, 25 * 60 * 60)

        let day = "2026-11-01"
        let accepted = DailyActionPlanner.plan(
            today: day,
            readiness: readiness(level: .strained, day: day),
            checkIn: .asUsual,
            recentEffort: history(),
            plannedWorkout: plannedWorkout(
                day: day,
                startSec: Int(acceptedStart.timeIntervalSince1970),
                endSec: Int(acceptedEnd.timeIntervalSince1970)
            ),
            nowSec: nowSec
        )
        let rejected = DailyActionPlanner.plan(
            today: day,
            readiness: readiness(level: .strained, day: day),
            checkIn: .asUsual,
            recentEffort: history(),
            plannedWorkout: plannedWorkout(
                day: "2026-11-02",
                startSec: Int(nextDayStart.timeIntervalSince1970),
                endSec: Int(nextDayEnd.timeIntervalSince1970)
            ),
            nowSec: nowSec
        )

        XCTAssertEqual(accepted.workoutAdjustment?.reason, .recoveryShift)
        XCTAssertNil(rejected.workoutAdjustment)
    }

    func testThinSleepDifferenceAndInvalidWorkoutTimingFailClosed() {
        let thinDifference = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(),
            checkIn: .asUsual,
            recentEffort: history(),
            recentSleep: usualSleep(todayMinutes: 406),
            plannedWorkout: plannedWorkout(),
            nowSec: 1_000_000
        )
        let alreadyStarted = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(level: .strained),
            checkIn: .asUsual,
            recentEffort: history(),
            plannedWorkout: plannedWorkout(startSec: 999_000, endSec: 1_002_600),
            nowSec: 1_000_000
        )
        let wrongDay = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(level: .strained),
            checkIn: .asUsual,
            recentEffort: history(),
            plannedWorkout: plannedWorkout(day: "2026-08-23"),
            nowSec: 1_000_000
        )

        XCTAssertNil(thinDifference.workoutAdjustment)
        XCTAssertNil(alreadyStarted.workoutAdjustment)
        XCTAssertNil(wrongDay.workoutAdjustment)
    }

    func testPainOrUnwellSuppressesPlannedWorkoutAdjustment() {
        let plan = DailyActionPlanner.plan(
            today: today,
            readiness: readiness(level: .strained),
            checkIn: .painOrUnwell,
            recentEffort: history(),
            recentSleep: usualSleep(),
            plannedWorkout: plannedWorkout(),
            nowSec: 1_000_000
        )

        XCTAssertEqual(plan.availability, .stop)
        XCTAssertNil(plan.workoutAdjustment)
    }
}
