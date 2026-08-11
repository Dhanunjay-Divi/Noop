import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Per-interval TRIMP regression fixtures. Swift/Kotlin twins intentionally use the same shapes.
final class StrainSampleDurationTests: XCTestCase {
    private let restingHR = 60.0
    private let maxHR = 190.0
    private var reserve: Double { maxHR - restingHR }
    private var hardHR: Int { Int(restingHR + 0.85 * reserve) } // Edwards zone 4

    private func series(_ timestamps: Int...) -> [HRSample] {
        timestamps.map { HRSample(ts: $0, bpm: hardHR) }
    }

    private func uniform(_ count: Int, stepSeconds: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: $0 * stepSeconds, bpm: hardHR) }
    }

    func testUniformSeriesMatchesPreviouslyShippedFormula() {
        let samples = uniform(120, stepSeconds: 30)
        let oldTRIMP = samples.reduce(0) {
            $0 + StrainScorer.zoneWeight(Double($1.bpm), restingHR: restingHR, hrReserve: reserve)
        }
        let oldValue = Double(oldTRIMP) * StrainScorer.sampleDurationMinutes(samples)
        let newValue = StrainScorer.edwardsTRIMP(
            samples,
            restingHR: restingHR,
            hrReserve: reserve,
            durations: StrainScorer.sampleDurationsMinutes(samples)
        )

        XCTAssertEqual(newValue, oldValue, accuracy: 1e-9)
        XCTAssertEqual(newValue, 240.0, accuracy: 1e-9)
    }

    func testMixedCadenceUsesEveryAdjacentInterval() {
        let live = (0..<10).map { HRSample(ts: $0, bpm: hardHR) }
        let banked = (0..<120).map { HRSample(ts: 60 + $0 * 30, bpm: hardHR) }
        let samples = live + banked
        let trimp = StrainScorer.edwardsTRIMP(
            samples,
            restingHR: restingHR,
            hrReserve: reserve,
            durations: StrainScorer.sampleDurationsMinutes(samples)
        )

        XCTAssertGreaterThan(trimp, 230.0)
    }

    func testAddingLowHeartRateContextCannotShrinkWorkoutTRIMP() {
        let workout = (0..<120).map { HRSample(ts: 1_000 + $0 * 30, bpm: hardHR) }
        let idle = (0..<60).map { HRSample(ts: $0, bpm: 55) }
        func trimp(_ samples: [HRSample]) -> Double {
            StrainScorer.edwardsTRIMP(
                samples,
                restingHR: restingHR,
                hrReserve: reserve,
                durations: StrainScorer.sampleDurationsMinutes(samples)
            )
        }

        XCTAssertGreaterThanOrEqual(trimp(idle + workout), trimp(workout) - 1e-9)
    }

    func testDropoutGapIsCapped() {
        XCTAssertEqual(
            StrainScorer.sampleDurationsMinutes(series(0, 3 * 3_600)),
            [StrainScorer.maxSampleGapMin, StrainScorer.maxSampleGapMin]
        )
    }

    func testNormalSparseCadenceIsNotCapped() {
        XCTAssertEqual(StrainScorer.sampleDurationsMinutes(uniform(3, stepSeconds: 30)), [0.5, 0.5, 0.5])
    }

    func testDurationEdgesPreserveFallbacks() {
        XCTAssertEqual(StrainScorer.sampleDurationsMinutes([]), [])
        XCTAssertEqual(StrainScorer.sampleDurationsMinutes(series(5)), [StrainScorer.fallbackSampleMin])
        for duration in StrainScorer.sampleDurationsMinutes(series(7, 7)) {
            XCTAssertEqual(duration, StrainScorer.fallbackSampleMin, accuracy: 1e-9)
        }
    }

    func testExtremeTimestampsCannotOverflow() {
        XCTAssertEqual(
            StrainScorer.sampleDurationsMinutes(series(Int.min, Int.max)),
            [StrainScorer.maxSampleGapMin, StrainScorer.maxSampleGapMin]
        )
        XCTAssertEqual(StrainScorer.observedCoverageSeconds(series(Int.min, Int.max)), 0)
    }

    func testIsolatedReadingsDoNotQualifyAsObservedCoverage() {
        let isolated = (0..<StrainScorer.minReadings).map {
            HRSample(ts: $0 * 3_600, bpm: hardHR)
        }
        XCTAssertEqual(StrainScorer.observedCoverageSeconds(isolated), 0)
        XCTAssertNil(StrainScorer.strain(isolated, maxHR: maxHR, restingHR: restingHR))
    }

    func testMismatchedDurationInputIsBoundedToAvailablePairs() {
        let samples = series(0, 30)
        let value = StrainScorer.edwardsTRIMP(
            samples, restingHR: restingHR, hrReserve: reserve, durations: [0.5]
        )
        XCTAssertEqual(value, 2.0, accuracy: 1e-9)
    }
}
