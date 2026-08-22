import XCTest
@testable import StrandAnalytics

final class SleepPlannerTests: XCTestCase {
    func testBasicPlanWrapsAcrossMidnight() {
        let plan = SleepPlanner.plan(
            wakeMinute: 7 * 60,
            sleepTargetMinutes: 8 * 60,
            windDownLeadMinutes: 30,
            debtBalanceMinutes: 0,
            historyNights: 7
        )
        XCTAssertEqual(plan.bedtimeMinute, 23 * 60)
        XCTAssertEqual(plan.windDownMinute, 22 * 60 + 30)
        XCTAssertEqual(plan.sleepOpportunityMinutes, 8 * 60)
        XCTAssertEqual(plan.confidence, .solid)
    }

    func testDebtAddsRoundedBoundedRecovery() {
        let plan = SleepPlanner.plan(
            wakeMinute: 6 * 60 + 30,
            sleepTargetMinutes: 8 * 60,
            windDownLeadMinutes: 45,
            debtBalanceMinutes: -210,
            historyNights: 7
        )
        XCTAssertEqual(plan.recoveryMinutes, 30)
        XCTAssertEqual(plan.sleepOpportunityMinutes, 8 * 60 + 30)
        XCTAssertEqual(plan.bedtimeMinute, 22 * 60)
        XCTAssertEqual(plan.windDownMinute, 21 * 60 + 15)
    }

    func testLargeDebtCannotAddMoreThanOneHour() {
        XCTAssertEqual(
            SleepPlanner.recoveryMinutes(debtBalanceMinutes: -2_000, historyNights: 7),
            60
        )
    }

    func testSurplusAndBalancedHistoryNeverReduceTarget() {
        for balance in [480.0, 0.0, -30.0] {
            let plan = SleepPlanner.plan(
                wakeMinute: 420,
                sleepTargetMinutes: 480,
                windDownLeadMinutes: 30,
                debtBalanceMinutes: balance,
                historyNights: 14
            )
            XCTAssertEqual(plan.recoveryMinutes, 0)
            XCTAssertEqual(plan.sleepOpportunityMinutes, 480)
        }
    }

    func testThinHistoryCalibratesWithoutDebtAdjustment() {
        let plan = SleepPlanner.plan(
            wakeMinute: 420,
            sleepTargetMinutes: 480,
            windDownLeadMinutes: 30,
            debtBalanceMinutes: -500,
            historyNights: 2
        )
        XCTAssertEqual(plan.recoveryMinutes, 0)
        XCTAssertEqual(plan.confidence, .calibrating)
    }

    func testGoalModesAreExplicitAndBounded() {
        let target = SleepPlanner.plan(
            wakeMinute: 420,
            sleepTargetMinutes: 480,
            windDownLeadMinutes: 30,
            debtBalanceMinutes: -420,
            historyNights: 7,
            goalMode: .target
        )
        XCTAssertEqual(target.recoveryMinutes, 0)
        XCTAssertEqual(target.sleepOpportunityMinutes, 480)

        let balance = SleepPlanner.plan(
            wakeMinute: 420,
            sleepTargetMinutes: 480,
            windDownLeadMinutes: 30,
            debtBalanceMinutes: -420,
            historyNights: 7,
            goalMode: .balance
        )
        XCTAssertEqual(balance.recoveryMinutes, 60)

        let extra = SleepPlanner.plan(
            wakeMinute: 420,
            sleepTargetMinutes: 480,
            windDownLeadMinutes: 30,
            debtBalanceMinutes: 120,
            historyNights: 7,
            goalMode: .extraOpportunity
        )
        XCTAssertEqual(extra.recoveryMinutes, 30)
        XCTAssertEqual(extra.sleepOpportunityMinutes, 510)
    }

    func testObservedTimingUsesShortestCircularShift() {
        let plan = SleepPlanner.plan(
            wakeMinute: 7 * 60,
            sleepTargetMinutes: 8 * 60,
            windDownLeadMinutes: 30,
            debtBalanceMinutes: nil,
            historyNights: 7,
            goalMode: .target
        )
        XCTAssertEqual(
            SleepPlanner.observedTimingShiftMinutes(
                plan: plan,
                habitualMidsleepSeconds: 3 * 60 * 60
            ),
            0
        )
        XCTAssertEqual(
            SleepPlanner.observedTimingShiftMinutes(
                plan: plan,
                habitualMidsleepSeconds: 23 * 60 * 60
            ),
            240
        )
        XCTAssertNil(
            SleepPlanner.observedTimingShiftMinutes(
                plan: plan,
                habitualMidsleepSeconds: nil
            )
        )
    }

    func testInputsClampToSafeBounds() {
        let short = SleepPlanner.plan(
            wakeMinute: -1,
            sleepTargetMinutes: 60,
            windDownLeadMinutes: -20,
            debtBalanceMinutes: nil,
            historyNights: -3
        )
        XCTAssertEqual(short.wakeMinute, 1439)
        XCTAssertEqual(short.baseSleepMinutes, 300)
        XCTAssertEqual(short.windDownMinute, short.bedtimeMinute)
        XCTAssertEqual(short.historyNights, 0)

        let long = SleepPlanner.plan(
            wakeMinute: 2_000,
            sleepTargetMinutes: 1_000,
            windDownLeadMinutes: 999,
            debtBalanceMinutes: nil,
            historyNights: 4
        )
        XCTAssertEqual(long.wakeMinute, 560)
        XCTAssertEqual(long.baseSleepMinutes, 660)
        XCTAssertEqual(
            long.windDownMinute,
            SleepPlanner.wrappedMinute(long.bedtimeMinute - 120)
        )
        XCTAssertEqual(long.confidence, .building)
    }
}
