import XCTest
@testable import StrandAnalytics

/// Pins the provenance gate that stops REM and deep being presented as measurements on nights that
/// lacked the R-R those stages are derived from. The numbers these tests defend are real: against expert
/// PSG (n=6, 5,720 epochs) REM recall was 3.7% and deep recall 6.9% without R-R, with 51% of REM epochs
/// classified as wake.
final class SleepStageEvidenceTests: XCTestCase {

    // MARK: Classification

    func testMotionOnlyWhenNoCardiacData() {
        XCTAssertEqual(SleepStageEvidenceGate.evidence(rrIntervalCount: 0), .motionOnly)
    }

    /// A handful of intervals is R-R "present" in a technical sense while carrying no usable
    /// parasympathetic signal. That must not unlock four-class staging.
    func testTokenCardiacDataIsStillMotionOnly() {
        XCTAssertEqual(SleepStageEvidenceGate.evidence(rrIntervalCount: 25), .motionOnly,
                       "above HRVAnalyzer's 20-interval floor but nowhere near a night of R-R")
    }

    func testResolvedWithEnoughIntervals() {
        XCTAssertEqual(
            SleepStageEvidenceGate.evidence(
                rrIntervalCount: SleepStageEvidenceGate.minimumIntervalsForStaging),
            .cardiacResolved)
    }

    func testThresholdIsPinnedSoChangingItIsADecision() {
        XCTAssertEqual(SleepStageEvidenceGate.minimumIntervalsForStaging, 120,
                       "a judgement, not a validated constant; move it deliberately or not at all")
    }

    // MARK: Withholding

    /// The core contract. REM recall was 3.7%, so a REM figure from a motion-only night is wrong about
    /// half the time. nil renders as an em-dash; a number would render as a confident lie.
    func testRemAndDeepWithheldOnMotionOnlyNight() {
        let t = SleepStageEvidenceGate.attribute(
            totalSleepMin: 420, efficiency: 0.9, lightMin: 200,
            deepMin: 90, remMin: 100, evidence: .motionOnly)
        XCTAssertNil(t.remMin)
        XCTAssertNil(t.deepMin)
    }

    /// Duration and sleep/wake validated at 71.8% and must survive the gate. Withholding everything would
    /// throw away the part that works.
    func testDurationAndEfficiencySurviveMotionOnly() {
        let t = SleepStageEvidenceGate.attribute(
            totalSleepMin: 420, efficiency: 0.9, lightMin: 200,
            deepMin: 90, remMin: 100, evidence: .motionOnly)
        XCTAssertEqual(t.totalSleepMin, 420, accuracy: 0.001)
        XCTAssertEqual(t.efficiency, 0.9, accuracy: 0.001)
        XCTAssertEqual(t.lightMin, 200, accuracy: 0.001)
    }

    func testRemAndDeepReportedWhenCardiacResolved() {
        let t = SleepStageEvidenceGate.attribute(
            totalSleepMin: 420, efficiency: 0.9, lightMin: 200,
            deepMin: 90, remMin: 100, evidence: .cardiacResolved)
        XCTAssertEqual(t.remMin ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(t.deepMin ?? -1, 90, accuracy: 0.001)
    }

    // MARK: The rejected alternative

    /// Deliberate: unresolved epochs are NOT folded into light. Doing so would assert they were light
    /// sleep, which is the same fabrication in a different coat, and would silently inflate light minutes.
    /// If this ever fails, someone has "fixed" the gate by moving the lie rather than removing it.
    func testUnresolvedEpochsAreNotFoldedIntoLight() {
        let t = SleepStageEvidenceGate.attribute(
            totalSleepMin: 420, efficiency: 0.9, lightMin: 200,
            deepMin: 90, remMin: 100, evidence: .motionOnly)
        XCTAssertEqual(t.lightMin, 200, accuracy: 0.001,
                       "light must report only what was labelled light, not light + withheld stages")
        XCTAssertLessThan(t.lightMin, t.totalSleepMin,
                          "the remainder stays accounted for by total sleep, not reassigned to a stage")
    }

    func testRemDeepReportableMirrorsTheCase() {
        XCTAssertTrue(SleepStageEvidence.cardiacResolved.remDeepReportable)
        XCTAssertFalse(SleepStageEvidence.motionOnly.remDeepReportable)
    }

    /// Codable and stable raw values, since provenance is persisted alongside the night it describes.
    func testEvidenceRawValuesAreStable() {
        XCTAssertEqual(SleepStageEvidence.cardiacResolved.rawValue, "cardiacResolved")
        XCTAssertEqual(SleepStageEvidence.motionOnly.rawValue, "motionOnly")
        XCTAssertEqual(SleepStageEvidence(rawValue: "motionOnly"), .motionOnly)
    }
}
