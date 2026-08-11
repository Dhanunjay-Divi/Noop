import Foundation
import XCTest
@testable import StrandAnalytics

final class TrainingLoadModelTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func day(_ offset: Int) -> String {
        let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let date = calendar.date(byAdding: .day, value: offset, to: start)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private func entries(count: Int, load: (Int) -> Double) -> [TrainingLoadModel.Entry] {
        (0..<count).map { TrainingLoadModel.Entry(day: day($0), load: load($0)) }
    }

    func testAggregationIsAdditiveAndRejectsInvalidInputs() {
        let result = TrainingLoadModel.aggregate([
            .init(day: "2024-01-01", load: 12),
            .init(day: "2024-01-01", load: 8),
            .init(day: "2024-01-02", load: 0), // explicit observed rest
            .init(day: "2024-02-30", load: 5),
            .init(day: "2024-01-03", load: -1),
            .init(day: "2024-01-04", load: .nan),
            .init(day: "2024-01-05", load: .greatestFiniteMagnitude),
            .init(day: "2024-01-05", load: .greatestFiniteMagnitude), // daily sum overflow
        ])

        XCTAssertEqual(result.days, [
            .init(day: "2024-01-01", load: 20),
            .init(day: "2024-01-02", load: 0),
            .init(day: "2024-01-05", load: .greatestFiniteMagnitude),
        ])
        XCTAssertEqual(result.rejectedEntryCount, 4)
    }

    func testSteadyLoadConvergesAndTSBIsExactlyCTLMinusATL() {
        let result = TrainingLoadModel.evaluate(entries: entries(count: 60) { _ in 50 })
        let latest = try! XCTUnwrap(result.latest)

        XCTAssertEqual(latest.atl!, 50, accuracy: 1e-12)
        XCTAssertEqual(latest.ctl!, 50, accuracy: 1e-12)
        XCTAssertEqual(latest.tsb!, latest.ctl! - latest.atl!, accuracy: 1e-12)
        XCTAssertEqual(latest.quality, .observed)
        XCTAssertEqual(latest.rampDirection, .steady)
        XCTAssertEqual(latest.observedCoverage, 1, accuracy: 1e-12)
        XCTAssertTrue(latest.interpretation.contains("not a fitness or fatigue measurement"))
    }

    func testColdStartAbstainsThenHardDayRaisesATLMoreThanCTL() {
        let inputs = entries(count: 14) { $0 == 13 ? 20 : 10 }
        let result = TrainingLoadModel.evaluate(entries: inputs)

        XCTAssertNil(result.points[12].atl)
        XCTAssertNil(result.points[12].ctl)
        let latest = try! XCTUnwrap(result.latest)
        let expectedATL = 10 + (1 - exp(-1.0 / 7.0)) * 10
        let expectedCTL = 10 + (1 - exp(-1.0 / 42.0)) * 10
        XCTAssertEqual(latest.atl!, expectedATL, accuracy: 1e-12)
        XCTAssertEqual(latest.ctl!, expectedCTL, accuracy: 1e-12)
        XCTAssertEqual(latest.tsb!, expectedCTL - expectedATL, accuracy: 1e-12)
        XCTAssertLessThan(latest.tsb!, 0)
        XCTAssertEqual(latest.currentRampWindowLoad, 80)
        XCTAssertEqual(latest.previousRampWindowLoad, 70)
        XCTAssertEqual(latest.rampChange, 10)
        XCTAssertEqual(latest.rampChangeFraction!, 1.0 / 7.0, accuracy: 1e-12)
        XCTAssertEqual(latest.rampDirection, .building)
        XCTAssertEqual(latest.quality, .provisional)
    }

    func testStrictMissingDayAbstainsAndRestartsWarmup() {
        var inputs = entries(count: 14) { _ in 10 }
        inputs.append(.init(day: day(15), load: 10)) // day 14 is absent, not a known rest day
        let result = TrainingLoadModel.evaluate(entries: inputs)

        XCTAssertEqual(result.points[14].day, day(14))
        XCTAssertEqual(result.points[14].source, .missing)
        XCTAssertNil(result.points[14].effectiveLoad)
        XCTAssertNil(result.points[14].atl)
        let latest = try! XCTUnwrap(result.latest)
        XCTAssertEqual(latest.source, .observed)
        XCTAssertEqual(latest.consecutiveHistoryDays, 1)
        XCTAssertNil(latest.atl)
        XCTAssertEqual(latest.rampDirection, .unavailable)
        XCTAssertTrue(latest.interpretation.contains("1 of 14"))
    }

    func testAssumeRestIsExplicitAndKeepsEstimateMarked() {
        let inputs = entries(count: 20) { _ in 10 }.filter { $0.day != day(14) }
        let configuration = TrainingLoadModel.Configuration(missingDayPolicy: .assumeRest)
        let result = TrainingLoadModel.evaluate(entries: inputs, configuration: configuration)

        let gap = result.points[14]
        XCTAssertEqual(gap.source, .assumedRest)
        XCTAssertEqual(gap.effectiveLoad, 0)
        XCTAssertNotNil(gap.atl)
        let latest = try! XCTUnwrap(result.latest)
        XCTAssertEqual(latest.quality, .estimated)
        XCTAssertEqual(latest.assumedRestDaysInWindow, 1)
        XCTAssertEqual(latest.assumedRestDaysInModelHistory, 1)
        XCTAssertEqual(latest.observedCoverage, 19.0 / 20.0, accuracy: 1e-12)
        XCTAssertTrue(latest.interpretation.contains("unobserved day treated as rest"))
    }

    func testExplicitZeroIsObservedRestNotMissingData() {
        let inputs = entries(count: 20) { $0 == 14 ? 0 : 10 }
        let result = TrainingLoadModel.evaluate(
            entries: inputs,
            configuration: .init(missingDayPolicy: .assumeRest)
        )

        XCTAssertEqual(result.points[14].source, .observed)
        XCTAssertEqual(result.points[14].observedLoad, 0)
        XCTAssertEqual(result.latest?.assumedRestDaysInWindow, 0)
        XCTAssertEqual(result.latest?.quality, .provisional)
        XCTAssertEqual(result.latest?.observedCoverage, 1)
    }

    func testOldAssumptionDoesNotBecomeObservedJustBecauseCoverageWindowMoved() {
        let inputs = entries(count: 60) { _ in 10 }.filter { $0.day != day(5) }
        let result = TrainingLoadModel.evaluate(
            entries: inputs,
            configuration: .init(missingDayPolicy: .assumeRest)
        )

        XCTAssertEqual(result.latest?.assumedRestDaysInWindow, 0)
        XCTAssertEqual(result.latest?.assumedRestDaysInModelHistory, 1)
        XCTAssertEqual(result.latest?.quality, .estimated)
    }

    func testAdversarialCalendarSpanIsRejectedBeforeTimelineExpansion() {
        let result = TrainingLoadModel.evaluate(entries: [
            .init(day: "0001-01-01", load: 10),
            .init(day: "9999-12-31", load: 10),
        ])

        XCTAssertEqual(result.status, .calendarSpanExceeded)
        XCTAssertEqual(result.observedDays.count, 2)
        XCTAssertTrue(result.points.isEmpty)
    }

    func testExtremeFiniteLoadsNeverExposeNonFiniteDerivedValues() {
        let result = TrainingLoadModel.evaluate(
            entries: entries(count: 30) { _ in .greatestFiniteMagnitude }
        )

        XCTAssertEqual(result.status, .complete)
        for point in result.points {
            let derived = [point.atl, point.ctl, point.tsb,
                           point.currentRampWindowLoad, point.previousRampWindowLoad,
                           point.rampChange, point.rampChangeFraction].compactMap { $0 }
            XCTAssertTrue(derived.allSatisfy(\.isFinite), "non-finite output on \(point.day)")
        }
        let latest = try! XCTUnwrap(result.latest)
        XCTAssertEqual(latest.atl, Double.greatestFiniteMagnitude)
        XCTAssertEqual(latest.ctl, Double.greatestFiniteMagnitude)
        XCTAssertEqual(latest.tsb, 0)
        XCTAssertEqual(latest.rampDirection, .unavailable)
        XCTAssertNil(latest.currentRampWindowLoad)
        XCTAssertNil(latest.rampChangeFraction)
    }

    func testOverflowingRampFractionIsUnavailableRatherThanInfinite() {
        let tiny = Double.leastNonzeroMagnitude
        let large = Double.greatestFiniteMagnitude / 8
        let result = TrainingLoadModel.evaluate(
            entries: entries(count: 14) { $0 < 7 ? tiny : large }
        )
        let latest = try! XCTUnwrap(result.latest)

        XCTAssertEqual(latest.rampDirection, .unavailable)
        XCTAssertNil(latest.rampChangeFraction)
        XCTAssertTrue(latest.currentRampWindowLoad?.isFinite == true)
        XCTAssertTrue(latest.previousRampWindowLoad?.isFinite == true)
        XCTAssertTrue(latest.rampChange?.isFinite == true)
    }
}
