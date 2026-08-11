import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WorkoutHeartRateEnrichmentTests: XCTestCase {
    func testDenseWorkoutProducesSharedMetricsAndStableZones() throws {
        let start = 1_000
        // Twenty minutes: 10 min in Z2 and 10 min in Z4 for HRmax 200.
        let samples = (0..<1_200).map { offset in
            HRSample(ts: start + offset, bpm: offset < 600 ? 130 : 170)
        }
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: start, workoutEnd: start + 1_200,
            maxHR: 200, restingHR: 60, sex: "female"
        )

        XCTAssertEqual(result.avgHR, 150)
        XCTAssertEqual(result.maxHR, 170)
        XCTAssertNotNil(result.strain)
        let json = try XCTUnwrap(result.zonesJSON)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber]
        )
        XCTAssertEqual(decoded["z2"]?.doubleValue ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(decoded["z4"]?.doubleValue ?? -1, 50, accuracy: 0.01)
        XCTAssertEqual(json, WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: start, workoutEnd: start + 1_200,
            maxHR: 200, restingHR: 60
        ).zonesJSON, "zone serialization must be deterministic for idempotent upserts")
    }

    func testSampleExactlyAtWorkoutEndIsExcludedFromEveryFallbackMetric() {
        let start = 20_000
        let inside = (0..<600).map { HRSample(ts: start + $0, bpm: 130) }
        let baseline = WorkoutHeartRateEnrichment.summarize(
            samples: inside, workoutStart: start, workoutEnd: start + 600,
            maxHR: 200, restingHR: 60
        )
        let withEndBoundarySample = WorkoutHeartRateEnrichment.summarize(
            samples: inside + [HRSample(ts: start + 600, bpm: 220)],
            workoutStart: start, workoutEnd: start + 600,
            maxHR: 200, restingHR: 60
        )

        XCTAssertEqual(withEndBoundarySample, baseline,
                       "[start, end) must exclude a reading exactly at workoutEnd")
        XCTAssertEqual(withEndBoundarySample.avgHR, 130)
        XCTAssertEqual(withEndBoundarySample.maxHR, 130)
    }

    func testShortFinalIntervalUsesSameClippedDurationForAverageZonesAndEffort() throws {
        let start = 30_000
        // Twenty 30-second Z2 holds cover 600 s. The final Z5 reading is only inside the workout for
        // five seconds; none of the derived metrics may give it another inferred 30-second tail.
        let samples = (0..<20).map { HRSample(ts: start + $0 * 30, bpm: 130) }
            + [HRSample(ts: start + 600, bpm: 220)]
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: start, workoutEnd: start + 605,
            maxHR: 200, restingHR: 60
        )

        XCTAssertEqual(result.avgHR, 131,
                       "weighted average must use 600 s at 130 plus only 5 s at 220")
        let json = try XCTUnwrap(result.zonesJSON)
        let zones = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber]
        )
        XCTAssertEqual(zones["z2"]?.doubleValue ?? -1, 99.17, accuracy: 0.01)
        XCTAssertEqual(zones["z5"]?.doubleValue ?? -1, 0.83, accuracy: 0.01)

        // At maxHR 200 / resting 60, 130 bpm is Edwards weight 1 and 220 bpm is weight 5.
        let expectedTRIMP = 600.0 / 60.0 + (5.0 / 60.0) * 5.0
        XCTAssertEqual(try XCTUnwrap(result.strain),
                       StrainScorer.trimpToStrain(expectedTRIMP), accuracy: 1e-9)
    }

    func testExtremeWorkoutBoundsCannotOverflowAndStillExcludeEndSample() {
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: [
                HRSample(ts: Int.min, bpm: 100),
                HRSample(ts: 0, bpm: 150),
                HRSample(ts: Int.max, bpm: 220), // exactly at the exclusive end
            ],
            workoutStart: Int.min, workoutEnd: Int.max, maxHR: 200
        )

        XCTAssertEqual(result.avgHR, 125)
        XCTAssertEqual(result.maxHR, 150)
        XCTAssertNil(result.zonesJSON)
        XCTAssertNil(result.strain)
    }

    func testSourceStatisticsWinButSamplesStillDriveZones() throws {
        let samples = (0..<600).map { HRSample(ts: 2_000 + $0, bpm: 130) }
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: 2_000, workoutEnd: 2_600,
            maxHR: 200, statisticsAverage: 141.6, statisticsMaximum: 181.2
        )

        XCTAssertEqual(result.avgHR, 142)
        XCTAssertEqual(result.maxHR, 181)
        XCTAssertNotNil(result.zonesJSON)
    }

    func testSparseTraceKeepsAvgMaxButDoesNotFabricateZonesOrEffort() {
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: [
                HRSample(ts: 3_000, bpm: 120),
                HRSample(ts: 3_900, bpm: 180),
            ],
            workoutStart: 3_000, workoutEnd: 4_800, maxHR: 200
        )

        XCTAssertEqual(result.avgHR, 150)
        XCTAssertEqual(result.maxHR, 180)
        XCTAssertNil(result.zonesJSON, "a wall-clock gap is not measured zone time")
        XCTAssertNil(result.strain)
    }

    func testTwoReadingsNeverBecomeACompleteZoneTrace() {
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: [
                HRSample(ts: 3_000, bpm: 130),
                HRSample(ts: 3_240, bpm: 130),
            ],
            workoutStart: 3_000, workoutEnd: 3_480, maxHR: 200
        )

        XCTAssertEqual(result.avgHR, 130)
        XCTAssertEqual(result.maxHR, 130)
        XCTAssertNil(result.zonesJSON, "two held values are not 480 seconds of measured HR")
        XCTAssertNil(result.strain)
    }

    func testOutOfWindowAndImpossibleSamplesAreRejected() {
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: [
                HRSample(ts: 3_999, bpm: 200), // outside
                HRSample(ts: 4_000, bpm: 29),  // impossible low
                HRSample(ts: 4_001, bpm: 221), // impossible high
                HRSample(ts: 4_002, bpm: 140),
            ],
            workoutStart: 4_000, workoutEnd: 4_600, maxHR: 200,
            statisticsAverage: .infinity, statisticsMaximum: .greatestFiniteMagnitude
        )

        XCTAssertEqual(result.avgHR, 140)
        XCTAssertEqual(result.maxHR, 140)
        XCTAssertNil(result.zonesJSON)
        XCTAssertNil(result.strain)
    }

    func testImpossibleSourceStatisticRelationshipDoesNotInventPeak() {
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: [], workoutStart: 4_000, workoutEnd: 4_600, maxHR: 200,
            statisticsAverage: 170, statisticsMaximum: 120
        )

        XCTAssertEqual(result.avgHR, 170)
        XCTAssertNil(result.maxHR)
        XCTAssertNil(result.zonesJSON)
        XCTAssertNil(result.strain)
    }

    func testBelowZoneOneAndUnmeasuredTimeAreNotRedistributed() throws {
        let start = 5_000
        // Ten measured minutes in Z2 inside a twenty-minute workout; the other ten are unknown.
        let samples = (0..<300).map { HRSample(ts: start + $0 * 2, bpm: 130) }
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: start, workoutEnd: start + 1_200, maxHR: 200
        )
        let json = try XCTUnwrap(result.zonesJSON)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: NSNumber]
        )
        let total = (1...5).reduce(0.0) { $0 + (decoded["z\($1)"]?.doubleValue ?? 0) }
        XCTAssertEqual(total, 50, accuracy: 0.01,
                       "missing time must not be normalized into a falsely complete zone split")
    }

    func testInvalidMaxHRKeepsObservedStatisticsButRejectsDerivedMetrics() {
        let samples = (0..<600).map { HRSample(ts: 8_000 + $0, bpm: 130) }
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: 8_000, workoutEnd: 8_600, maxHR: 1
        )

        XCTAssertEqual(result.avgHR, 130)
        XCTAssertEqual(result.maxHR, 130)
        XCTAssertNil(result.zonesJSON)
        XCTAssertNil(result.strain)
    }

    func testFiniteButUnrepresentableRestingHRFallsBackWithoutTrapping() {
        let samples = (0..<600).map { HRSample(ts: 9_000 + $0, bpm: 130) }
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: 9_000, workoutEnd: 9_600,
            maxHR: 200, restingHR: .greatestFiniteMagnitude
        )

        XCTAssertEqual(result.avgHR, 130)
        XCTAssertEqual(result.maxHR, 130)
        XCTAssertNotNil(result.zonesJSON)
        XCTAssertNotNil(result.strain)
    }

    func testIsolatedSamplesCannotFabricateZoneCoverage() {
        let samples = (0..<20).map { HRSample(ts: 10_000 + $0 * 3_600, bpm: 170) }
        let result = WorkoutHeartRateEnrichment.summarize(
            samples: samples, workoutStart: 10_000,
            workoutEnd: 10_000 + 20 * 3_600, maxHR: 200
        )

        XCTAssertEqual(result.avgHR, 170)
        XCTAssertEqual(result.maxHR, 170)
        XCTAssertNil(result.zonesJSON)
        XCTAssertNil(result.strain)
    }
}
