import Foundation
import XCTest
@testable import StrandAnalytics

final class DailyAutonomicLoadTests: XCTestCase {

    func testNeedsSevenValidPriorDaysAndNeverUsesTargetInBaseline() {
        let sixPrior = (1...6).map { sample($0, rhr: 58 + Double($0 % 3), hrv: 66 + Double($0 * 2)) }
        let target = sample(7, rhr: 66, hrv: 55)

        let cold = DailyAutonomicLoad.readout(days: sixPrior + [target])
        XCTAssertNil(cold.value)
        XCTAssertNil(cold.band)
        XCTAssertEqual(cold.confidence, .unavailable)
        XCTAssertEqual(cold.baselineDays, 6)
        XCTAssertTrue(cold.limitations.contains(.restingHeartRateHistoryInsufficient))
        XCTAssertTrue(cold.limitations.contains(.heartRateVariabilityHistoryInsufficient))

        let seventhPrior = sample(7, rhr: 61, hrv: 75)
        let shiftedTarget = sample(8, rhr: 66, hrv: 55)
        let scored = DailyAutonomicLoad.readout(days: sixPrior + [seventhPrior, shiftedTarget])
        XCTAssertNotNil(scored.value, "exactly seven prior valid days must cross the history gate")
        XCTAssertEqual(scored.baselineDays, 7,
                       "the target must not become an eighth baseline day")
        XCTAssertEqual(scored.asOf, dayKey(8))
    }

    func testGoldenTwoSignalLogisticUsesStrictlyPriorPopulationBaselines() {
        let rhr = [60.0, 61, 59, 62, 58, 60, 60]
        let hrv = [70.0, 72, 68, 74, 66, 70, 70]
        let prior = zip(rhr, hrv).enumerated().map {
            sample($0.offset + 1, rhr: $0.element.0, hrv: $0.element.1)
        }
        let target = sample(8, rhr: 62, hrv: 66)

        let read = DailyAutonomicLoad.readout(days: prior + [target])
        let rhrMean = 60.0
        let hrvMean = 70.0
        let rhrSD = sqrt(10.0 / 7.0)
        let hrvSD = sqrt(40.0 / 7.0)
        let raw = (62.0 - rhrMean) / rhrSD + (hrvMean - 66.0) / hrvSD
        let expected = 3.0 / (1.0 + exp(-raw))

        XCTAssertEqual(read.value!, expected, accuracy: 1e-12)
        XCTAssertEqual(read.band, .high)
        XCTAssertEqual(read.confidence, .reliable)
        XCTAssertEqual(read.observedSignals, [.restingHeartRate, .heartRateVariability])
        XCTAssertEqual(read.baselineDays, 7)
        XCTAssertEqual(read.limitations, [.experimentalNonClinicalProxy])
    }

    func testZeroSpreadReturnsNoValueInsteadOfManufacturedNeutralOnePointFive() {
        let prior = (1...10).map { sample($0, rhr: 60, hrv: 70) }
        let read = DailyAutonomicLoad.readout(days: prior + [sample(11, rhr: 60, hrv: 70)])

        XCTAssertNil(read.value, "an empty z-term set must never be squashed into 1.5")
        XCTAssertNil(read.band)
        XCTAssertEqual(read.confidence, .unavailable)
        XCTAssertEqual(read.baselineDays, 10)
        XCTAssertTrue(read.observedSignals.isEmpty)
        XCTAssertTrue(read.limitations.contains(.restingHeartRateBaselineHasNoSpread))
        XCTAssertTrue(read.limitations.contains(.heartRateVariabilityBaselineHasNoSpread))
    }

    func testOneUsableSignalIsLimitedAndListsOnlyItsEvidence() {
        let prior = (1...8).map { sample($0, rhr: nil, hrv: 60 + Double($0)) }
        let read = DailyAutonomicLoad.readout(days: prior + [sample(9, rhr: nil, hrv: 58)])

        XCTAssertNotNil(read.value)
        XCTAssertEqual(read.confidence, .limited)
        XCTAssertEqual(read.baselineDays, 8)
        XCTAssertEqual(read.observedSignals, [.heartRateVariability])
        XCTAssertTrue(read.limitations.contains(.restingHeartRateMissing))
        XCTAssertTrue(read.limitations.contains(.singleSignalEstimate))
    }

    func testOneZeroSpreadBaselineLeavesOtherSignalLimited() {
        let prior = (1...8).map { sample($0, rhr: 60, hrv: 60 + Double($0)) }
        let read = DailyAutonomicLoad.readout(days: prior + [sample(9, rhr: 64, hrv: 58)])

        XCTAssertNotNil(read.value)
        XCTAssertEqual(read.confidence, .limited)
        XCTAssertEqual(read.observedSignals, [.heartRateVariability])
        XCTAssertTrue(read.limitations.contains(.restingHeartRateBaselineHasNoSpread))
        XCTAssertTrue(read.limitations.contains(.singleSignalEstimate))
    }

    func testTwoUsableSignalsAreReliableOnlyWhenBothSpreadsWork() {
        let prior = (1...8).map {
            sample($0, rhr: 58 + Double($0 % 4), hrv: 62 + Double(($0 * 3) % 7))
        }
        let read = DailyAutonomicLoad.readout(days: prior + [sample(9, rhr: 65, hrv: 55)])

        XCTAssertNotNil(read.value)
        XCTAssertEqual(read.confidence, .reliable)
        XCTAssertEqual(read.observedSignals, [.restingHeartRate, .heartRateVariability])
        XCTAssertFalse(read.limitations.contains(.singleSignalEstimate))
    }

    func testStaleFallbackRetainsActualObservedAsOf() {
        let prior = (1...7).map {
            sample($0, rhr: 58 + Double($0 % 4), hrv: 64 + Double(($0 * 2) % 5))
        }
        let observed = sample(8, rhr: 64, hrv: 58)
        let emptyNewerRow = sample(9, rhr: nil, hrv: nil)

        let read = DailyAutonomicLoad.readout(days: prior + [observed, emptyNewerRow])
        XCTAssertEqual(read.asOf, dayKey(8),
                       "stale data must retain its real source day, never be relabelled day 9")
        XCTAssertNotNil(read.value)
        XCTAssertTrue(read.limitations.contains(.staleSourceDay))
    }

    func testExplicitAsOfIsAHardFutureCutoffAndOlderScoreIsInvariant() {
        let history = (1...7).map {
            sample($0, rhr: 58 + Double($0 % 4), hrv: 64 + Double(($0 * 2) % 5))
        }
        let target = sample(8, rhr: 64, hrv: 58)
        let beforeFuture = DailyAutonomicLoad.readout(days: history + [target], asOf: dayKey(8))
        let extremeFuture = (9...14).map { sample($0, rhr: 150, hrv: 5) }
        let afterFuture = DailyAutonomicLoad.readout(
            days: extremeFuture.reversed() + history + [target], asOf: dayKey(8))

        XCTAssertEqual(afterFuture, beforeFuture,
                       "future observations must not leak into an older requested score")
    }

    func testCausalTrendDoesNotRewriteOldPointsWhenFutureDaysAreAppended() {
        let firstEight = (1...8).map {
            sample($0, rhr: 58 + Double($0 % 5), hrv: 65 + Double(($0 * 3) % 8))
        }
        let original = DailyAutonomicLoad.causalTrend(days: firstEight)
        let withFuture = DailyAutonomicLoad.causalTrend(days: firstEight + [
            sample(9, rhr: 120, hrv: 12), sample(10, rhr: 45, hrv: 120)
        ])

        XCTAssertEqual(Array(withFuture.prefix(original.count)), original)
        XCTAssertEqual(original.map(\.asOf), (1...8).map(dayKey))
        XCTAssertTrue(original.prefix(7).allSatisfy { $0.value == nil })
        XCTAssertNotNil(original.last?.value,
                        "the eighth observed day is the first point with seven prior days")
        XCTAssertEqual(DailyAutonomicLoad.trend(days: firstEight), original)
    }

    func testDuplicateDayCannotInflateBaselineDayCount() {
        let sixDistinct = (1...6).map {
            sample($0, rhr: 58 + Double($0 % 3), hrv: 65 + Double($0))
        }
        let duplicates = sixDistinct.flatMap { [$0, $0] }
        let read = DailyAutonomicLoad.readout(days: duplicates + [sample(7, rhr: 65, hrv: 55)])

        XCTAssertNil(read.value)
        XCTAssertEqual(read.baselineDays, 6)
        XCTAssertEqual(read.confidence, .unavailable)
    }

    func testInvalidNonFiniteAndNonPositiveMeasurementsDoNotBecomeEvidence() {
        let invalid = (1...9).map {
            sample($0, rhr: $0.isMultiple(of: 2) ? .infinity : -1,
                   hrv: $0.isMultiple(of: 2) ? .nan : 0)
        }
        let read = DailyAutonomicLoad.readout(days: invalid)

        XCTAssertNil(read.value)
        XCTAssertNil(read.asOf)
        XCTAssertEqual(read.confidence, .unavailable)
        XCTAssertEqual(read.limitations, [.targetSignalsMissing, .experimentalNonClinicalProxy])
    }

    func testBandBoundariesMatchDocumentedZeroToThreeScale() {
        XCTAssertEqual(DailyAutonomicLoad.Band(value: 0.999), .low)
        XCTAssertEqual(DailyAutonomicLoad.Band(value: 1.0), .moderate)
        XCTAssertEqual(DailyAutonomicLoad.Band(value: 1.999), .moderate)
        XCTAssertEqual(DailyAutonomicLoad.Band(value: 2.0), .high)
    }

    // MARK: - Fixtures

    private func sample(_ day: Int, rhr: Double?, hrv: Double?) -> DailyAutonomicLoad.Day {
        .init(day: dayKey(day), restingHeartRate: rhr, hrv: hrv)
    }

    private func dayKey(_ day: Int) -> String {
        String(format: "2026-01-%02d", day)
    }
}
