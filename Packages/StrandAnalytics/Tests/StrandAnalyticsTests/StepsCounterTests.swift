import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Unit tests for the shared windowed step kernel `StepsCounter.stepsInWindow` (#398). The same
/// wrap-aware positive-delta math the daily total uses (see StepsDailyTests), but exercised directly and
/// order-independently so a manual-workout window can reuse it. Returns the RAW motion-tick total (before
/// the caller's `stepTicksPerStep` calibration). Mirrors the Android StepsCounterTest vectors value-for-value.
final class StepsCounterTests: XCTestCase {

    private func step(_ ts: Int, _ counter: Int, _ activityClass: Int? = nil) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: activityClass)
    }

    func testSumsPositiveConsecutiveDeltas() {
        // counters 100 -> 150 -> 220 => deltas 50 + 70 = 120
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 100), step(60, 150), step(120, 220)]), 120)
    }

    func testSortsUnorderedInput() {
        // Same three samples shuffled — the kernel sorts by ts, so the result is identical (120).
        XCTAssertEqual(StepsCounter.stepsInWindow([step(120, 220), step(0, 100), step(60, 150)]), 120)
    }

    func testHandlesU16Wraparound() {
        // 65500 -> 20 wraps: (20 - 65500) & 0xFFFF = 56, a small real increment; then 20 -> 80 => 60.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 65_500), step(60, 20), step(120, 80)]), 116)
    }

    func testFewerThanTwoSamplesIsNil() {
        let empty = StepsCounter.analyze([])
        XCTAssertNil(empty.steps)
        XCTAssertFalse(empty.counterObserved)
        XCTAssertTrue(empty.allowsMotionFallback)
        XCTAssertFalse(empty.hasAuthoritativeCounterOutcome)

        let singleton = StepsCounter.analyze([step(0, 100)])
        XCTAssertNil(singleton.steps)
        XCTAssertTrue(singleton.counterObserved)
        XCTAssertFalse(singleton.allowsMotionFallback)
        XCTAssertFalse(singleton.hasAuthoritativeCounterOutcome)
    }

    func testNoForwardMovementIsNil() {
        // Flat counter across the window => no positive delta => nil (not 0).
        XCTAssertNil(StepsCounter.stepsInWindow([step(0, 500), step(60, 500), step(120, 500)]))
    }

    func testDropsBigGapDeltaAsBoundary() {
        // A jump >= 512 (sync-gap / reboot boundary) is dropped; the real 40 + 30 survive.
        // 100 -> 140 (=40) -> 5000 (=4860, dropped) -> 5030 (=30) => 70.
        XCTAssertEqual(StepsCounter.stepsInWindow(
            [step(0, 100), step(60, 140), step(120, 5_000), step(180, 5_030)]), 70)
    }

    func testMaxStepDeltaBoundaryIsExclusive() {
        // Exactly maxStepDelta (512) is dropped; 511 counts.
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(60, 512)]), nil)   // 512 dropped => no movement
        XCTAssertEqual(StepsCounter.stepsInWindow([step(0, 0), step(60, 511)]), 511)   // 511 kept
    }

    func testClassZeroStationaryFourThousandTickBurstIsRejected() {
        // Ten individually plausible 400-tick deltas must not evade maxStepDelta when every later sample
        // says the wrist is still.
        let samples = (0...10).map { step($0 * 60, $0 * 400, 0) }
        let analysis = StepsCounter.analyze(samples)

        XCTAssertEqual(analysis.filterMode, .activityClassFiltered)
        XCTAssertEqual(analysis.deltaCount, 10)
        XCTAssertEqual(analysis.keptDeltaCount, 0)
        XCTAssertEqual(analysis.rejectedStillDeltaCount, 10)
        XCTAssertEqual(analysis.unfilteredRawTicks, 4_000)
        XCTAssertEqual(analysis.rawTicks, 0)
        XCTAssertNil(analysis.steps)
        XCTAssertTrue(analysis.counterObserved)
        XCTAssertFalse(analysis.allowsMotionFallback)
        XCTAssertFalse(analysis.hasAuthoritativeCounterOutcome)
        XCTAssertEqual(analysis.stationaryOnlyLegacyTicks, 4_000)
        XCTAssertEqual(
            StepsCounter.scaledSteps(
                rawTicks: try XCTUnwrap(analysis.stationaryOnlyLegacyTicks),
                ticksPerStep: 2
            ),
            2_000
        )
        XCTAssertNil(StepsCounter.stepsInWindow(samples))
    }

    func testContinuousAllStillCoverageCanRepairExactLegacyValue() {
        let samples = (0...6).map { step($0 * 600, $0 * 100, 0) }
        let analysis = StepsCounter.analyze(
            samples,
            classificationPolicy: .requireActivityClass
        )

        XCTAssertEqual(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis: analysis,
                samples: samples,
                ticksPerStep: 2,
                dayStartTs: 0,
                observedThroughTs: 3_600
            ),
            300
        )
    }

    func testShortStationaryBurstCannotRepairWholeDayValue() {
        let samples = (0...10).map { step(43_200 + $0 * 60, $0 * 400, 0) }
        let analysis = StepsCounter.analyze(
            samples,
            classificationPolicy: .requireActivityClass
        )

        XCTAssertEqual(analysis.stationaryOnlyLegacyTicks, 4_000)
        XCTAssertNil(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis: analysis,
                samples: samples,
                ticksPerStep: 1,
                dayStartTs: 0,
                observedThroughTs: 86_399
            )
        )
    }

    func testAllStillCoverageWithInternalOrTrailingGapCannotRepair() {
        let internalGap = [
            step(0, 0, 0),
            step(600, 100, 0),
            step(1_200, 200, 0),
            step(3_000, 300, 0),
            step(3_600, 400, 0),
        ]
        let internalAnalysis = StepsCounter.analyze(
            internalGap,
            classificationPolicy: .requireActivityClass
        )
        XCTAssertNil(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis: internalAnalysis,
                samples: internalGap,
                ticksPerStep: 1,
                dayStartTs: 0,
                observedThroughTs: 3_600
            )
        )

        let trailingGap = (0...3).map { step($0 * 600, $0 * 100, 0) }
        let trailingAnalysis = StepsCounter.analyze(
            trailingGap,
            classificationPolicy: .requireActivityClass
        )
        XCTAssertNil(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis: trailingAnalysis,
                samples: trailingGap,
                ticksPerStep: 1,
                dayStartTs: 0,
                observedThroughTs: 3_600
            )
        )
    }

    func testRepairFailsClosedWhenAnalysisAndCoveredRowsDiffer() {
        let samples = (0...6).map { step($0 * 600, $0 * 100, 0) }
            + [step(4_200, 700, 0)]
        let analysis = StepsCounter.analyze(
            samples,
            classificationPolicy: .requireActivityClass
        )

        XCTAssertNil(
            StepsCounter.stationaryLegacyRepairSteps(
                analysis: analysis,
                samples: samples,
                ticksPerStep: 1,
                dayStartTs: 0,
                observedThroughTs: 3_600
            )
        )
    }

    func testMixedStillAndWalkRetainsOnlyWalkDeltas() {
        let samples = [
            step(0, 100, 0),
            step(60, 300, 0),   // +200 still: reject
            step(120, 450, 1),  // +150 walk: keep
            step(180, 550, 0),  // +100 still: reject
            step(240, 700, 2),  // +150 run: keep
        ]
        let analysis = StepsCounter.analyze(samples)

        XCTAssertEqual(analysis.rawTicks, 300)
        XCTAssertEqual(analysis.unfilteredRawTicks, 600)
        XCTAssertEqual(analysis.keptDeltaCount, 2)
        XCTAssertEqual(analysis.rejectedStillDeltaCount, 2)
        XCTAssertNil(analysis.stationaryOnlyLegacyTicks)
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 300)
    }

    func testUnknownDeltaIsRejectedInsideClassedWindow() {
        let samples = [
            step(0, 100, 0),
            step(60, 150, nil), // +50 unknown: reject because the window has class evidence
            step(120, 220, 1),  // +70 walk: keep
        ]
        let analysis = StepsCounter.analyze(samples)

        XCTAssertEqual(analysis.filterMode, .activityClassFiltered)
        XCTAssertEqual(analysis.rawTicks, 70)
        XCTAssertEqual(analysis.unfilteredRawTicks, 120)
        XCTAssertEqual(analysis.keptDeltaCount, 1)
        XCTAssertEqual(analysis.rejectedUnknownDeltaCount, 1)
        XCTAssertNil(analysis.stationaryOnlyLegacyTicks)
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 70)
    }

    func testInvalidActivityClassCountsAsUnknown() {
        let analysis = StepsCounter.analyze([
            step(0, 100, 1),
            step(60, 180, 7),
        ])

        XCTAssertEqual(analysis.rawTicks, 0)
        XCTAssertEqual(analysis.rejectedUnknownDeltaCount, 1)
        XCTAssertNil(analysis.stationaryOnlyLegacyTicks)
        XCTAssertNil(analysis.steps)
    }

    func testAllNilActivityClassesRetainLegacyRawMotionBehavior() {
        let samples = (0...10).map { step($0 * 60, $0 * 400) }
        let analysis = StepsCounter.analyze(samples)

        XCTAssertEqual(analysis.filterMode, .legacyRawMotion)
        XCTAssertEqual(analysis.keptDeltaCount, 10)
        XCTAssertEqual(analysis.unfilteredRawTicks, 4_000)
        XCTAssertEqual(analysis.rawTicks, 4_000)
        XCTAssertNil(analysis.stationaryOnlyLegacyTicks)
        XCTAssertTrue(analysis.counterObserved)
        XCTAssertFalse(analysis.allowsMotionFallback)
        XCTAssertTrue(analysis.hasAuthoritativeCounterOutcome)
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 4_000)
    }

    func testCurrentClasslessFourThousandTickBurstFailsClosed() {
        let samples = (0...10).map { step($0 * 60, $0 * 400) }
        let analysis = StepsCounter.analyze(
            samples,
            classificationPolicy: .requireActivityClass
        )

        XCTAssertEqual(analysis.filterMode, .activityClassRequiredMissing)
        XCTAssertEqual(analysis.keptDeltaCount, 0)
        XCTAssertEqual(analysis.rejectedUnknownDeltaCount, 10)
        XCTAssertEqual(analysis.unfilteredRawTicks, 4_000)
        XCTAssertEqual(analysis.rawTicks, 0)
        XCTAssertNil(analysis.stationaryOnlyLegacyTicks)
        XCTAssertNil(analysis.steps)
        XCTAssertTrue(analysis.counterObserved)
        XCTAssertFalse(analysis.allowsMotionFallback)
        XCTAssertFalse(analysis.hasAuthoritativeCounterOutcome)
    }

    func testGapOnlyAndUnknownOnlyWindowsDoNotDisproveStoredSteps() {
        let gapOnly = StepsCounter.analyze([
            step(0, 100, 0),
            step(60, 900, 0),
        ])
        XCTAssertNil(gapOnly.steps)
        XCTAssertTrue(gapOnly.counterObserved)
        XCTAssertFalse(gapOnly.hasAuthoritativeCounterOutcome)
        XCTAssertNil(gapOnly.stationaryOnlyLegacyTicks)

        let unknownOnly = StepsCounter.analyze([
            step(0, 100, 9),
            step(60, 200, 9),
        ])
        XCTAssertNil(unknownOnly.steps)
        XCTAssertTrue(unknownOnly.counterObserved)
        XCTAssertFalse(unknownOnly.hasAuthoritativeCounterOutcome)
        XCTAssertNil(unknownOnly.stationaryOnlyLegacyTicks)
    }

    func testStillMixedWithUnknownOrGapRemainsAmbiguous() {
        let stillAndUnknown = StepsCounter.analyze([
            step(0, 100, 0),
            step(60, 200, 0),
            step(120, 300, 9),
        ])
        XCTAssertNil(stillAndUnknown.steps)
        XCTAssertEqual(stillAndUnknown.rejectedStillDeltaCount, 1)
        XCTAssertEqual(stillAndUnknown.rejectedUnknownDeltaCount, 1)
        XCTAssertFalse(stillAndUnknown.hasAuthoritativeCounterOutcome)
        XCTAssertNil(stillAndUnknown.stationaryOnlyLegacyTicks)

        let stillAndGap = StepsCounter.analyze([
            step(0, 100, 0),
            step(60, 200, 0),
            step(120, 900, 0),
        ])
        XCTAssertNil(stillAndGap.steps)
        XCTAssertEqual(stillAndGap.rejectedStillDeltaCount, 1)
        XCTAssertEqual(stillAndGap.rejectedGapDeltaCount, 1)
        XCTAssertFalse(stillAndGap.hasAuthoritativeCounterOutcome)
        XCTAssertNil(stillAndGap.stationaryOnlyLegacyTicks)
    }

    func testClassedWindowRetainsWrapAndGapBehavior() {
        let samples = [
            step(0, 65_500, 1),
            step(60, 20, 1),      // wrap-aware +56: keep
            step(120, 1_000, 1),  // +980 gap: reject
            step(180, 1_060, 2),  // +60 run: keep
        ]
        let analysis = StepsCounter.analyze(samples)

        XCTAssertEqual(analysis.rawTicks, 116)
        XCTAssertEqual(analysis.keptDeltaCount, 2)
        XCTAssertEqual(analysis.rejectedGapDeltaCount, 1)
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 116)
    }
}
