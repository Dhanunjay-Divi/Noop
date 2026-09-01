import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class DailyEffortScorerTests: XCTestCase {
    private func gravity(_ ts: Int, _ x: Double) -> GravitySample {
        GravitySample(ts: ts, x: x, y: 0, z: 1)
    }

    func testMissingMovementPreservesCardiovascularResult() {
        XCTAssertNil(DailyEffortScorer.score(cardioEffort: nil, steps: nil))
        XCTAssertEqual(
            DailyEffortScorer.score(cardioEffort: 0, steps: nil),
            0
        )
        XCTAssertEqual(
            DailyEffortScorer.score(cardioEffort: 42.5, steps: nil),
            42.5
        )
    }

    func testOrdinaryWalkingProducesConservativeEffort() {
        // Reporter reference: 1,715 steps with no exercise-level HR should no longer read as zero.
        XCTAssertEqual(DailyEffortScorer.movementEffort(steps: 1_715)!, 18.75, accuracy: 1e-9)
        XCTAssertEqual(DailyEffortScorer.movementEffort(steps: 10_000)!, 36.68, accuracy: 1e-9)
    }

    func testMoreStepsIncreaseMovementEffort() {
        let light = DailyEffortScorer.movementEffort(steps: 1_715)!
        let active = DailyEffortScorer.movementEffort(steps: 10_000)!
        XCTAssertGreaterThan(active, light)
    }

    func testCardioAndMovementUseMaximumNotSum() {
        let movement = DailyEffortScorer.movementEffort(steps: 10_000)!
        XCTAssertEqual(
            DailyEffortScorer.score(cardioEffort: 50, steps: 10_000)!,
            50,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            DailyEffortScorer.score(cardioEffort: 5, steps: 10_000)!,
            movement,
            accuracy: 1e-9
        )
    }

    func testGravityFallbackMatchesEquivalentWalkingMinutes() {
        // Ten adjacent one-minute intervals above the existing walking-motion threshold.
        let samples = (0...10).map { index in
            gravity(index * 60, index.isMultiple(of: 2) ? 0 : 0.2)
        }
        XCTAssertEqual(DailyEffortScorer.activeMotionMinutes(samples)!, 10, accuracy: 1e-9)
        XCTAssertEqual(
            DailyEffortScorer.movementEffort(steps: nil, gravity: samples)!,
            DailyEffortScorer.movementEffort(steps: 1_000)!,
            accuracy: 1e-9
        )
    }

    func testGravityDoesNotBridgeTelemetryHole() {
        let samples = [gravity(0, 0), gravity(121, 0.3)]
        XCTAssertNil(DailyEffortScorer.activeMotionMinutes(samples))
        XCTAssertNil(DailyEffortScorer.movementEffort(steps: nil, gravity: samples))
    }

    func testMeasuredStepsTakePrecedenceOverGravityFallback() {
        let samples = (0...10).map { index in
            gravity(index * 60, index.isMultiple(of: 2) ? 0 : 0.3)
        }
        XCTAssertEqual(
            DailyEffortScorer.movementEffort(steps: 100, gravity: samples)!,
            DailyEffortScorer.movementEffort(steps: 100)!,
            accuracy: 1e-9
        )
    }
}
