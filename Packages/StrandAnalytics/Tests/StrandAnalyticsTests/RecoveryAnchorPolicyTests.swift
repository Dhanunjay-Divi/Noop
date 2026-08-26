import XCTest
@testable import StrandAnalytics

/// Guards the recovery anchor against being "corrected" to match a vendor.
///
/// WHY THIS TEST EXISTS
/// Measured against three real WHOOP exports (904 paired days, three different wearers confirmed by 0%
/// value match on overlapping dates), NOOP's Recovery reads systematically lower:
///
///   wearer      WHOOP mean   NOOP mean   bias      r       direction agreement
///   A (162d)    67.6         57.8        -9.7      0.905   94.2%
///   B (406d)    59.7         56.2        -3.4      0.905   93.8%
///   C (336d)    60.6         53.9        -6.7      0.867   87.9%
///
/// The physiology read replicates well (r 0.867-0.905, direction 88-94%). Only the LEVEL differs, and the
/// obvious-looking fix is to raise `personalBaselineLogisticMidpointZ` until the means line up. Solving
/// 100/(1+exp(-1.6*(0-z0))) for a WHOOP-like centre of 62.6 gives z0 = +0.322, which would close most of
/// the gap in one character.
///
/// THAT FIX IS WRONG, FOR THREE REASONS.
///
/// 1. It asserts a population mean NOOP has no basis for. Three wearers is not a population, and the
///    constant's own documentation states the midpoint exists to map a neutral personal-baseline day
///    "without asserting a population mean or supplying any cold-start score". `populationMean` was
///    deliberately removed from this file; reintroducing it through the midpoint is the same claim wearing
///    a different name.
/// 2. It treats WHOOP as ground truth. WHOOP's Recovery is an unpublished proprietary score, not a
///    reference measurement. Agreement with it is evidence that NOOP tracks the same physiology, which the
///    correlations already establish; it is not evidence that WHOOP's level is correct.
/// 3. The gap is not a constant offset. It ranges -3.4 to -9.7 across three wearers, so no single midpoint
///    closes it. That is the between-person compression documented in
///    docs/validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md, and shifting a global constant cannot fix a
///    per-person scale problem. It would help wearer A and overshoot wearer B.
///
/// THE SUPPORTED ROUTE, for a user who wants their history to line up with a vendor score, is
/// `PersonalCalibrationModel`: an opt-in per-user affine transform fitted only from paired days that user
/// supplies, accepted only when it improves unseen chronological holdout days, and applied as a
/// presentation layer without mutating the raw estimate. That is a per-person answer to a per-person
/// problem, and it is validated rather than tuned.
///
/// If this test fails, someone is closing a measured vendor gap by moving a global constant. Read the three
/// reasons above and use the calibration path instead.
final class RecoveryAnchorPolicyTests: XCTestCase {

    func testAnchorConstantsAreUnchanged() {
        XCTAssertEqual(RecoveryScorer.personalBaselineLogisticSlope, 1.6, accuracy: 1e-9,
                       "slope spans roughly +/-2 composite z over the red-green band; changing it rescales "
                       + "every historical score a user has already seen")
        XCTAssertEqual(RecoveryScorer.personalBaselineLogisticMidpointZ, -0.20, accuracy: 1e-9,
                       "do NOT tune this to match a vendor mean; use PersonalCalibrationModel")
    }

    /// The property that actually matters: a person sitting exactly at their own baseline lands mid-scale,
    /// in the yellow band, rather than being told a typical day is bad.
    func testNeutralBaselineDayLandsMidScale() {
        let neutral = 100.0 / (1.0 + exp(
            -RecoveryScorer.personalBaselineLogisticSlope
                * (0.0 - RecoveryScorer.personalBaselineLogisticMidpointZ)))
        XCTAssertEqual(neutral, 57.9, accuracy: 0.1)
        XCTAssertGreaterThan(neutral, RecoveryScorer.bandRedMax,
                             "a day at one's own baseline must never read red")
        XCTAssertLessThan(neutral, RecoveryScorer.bandYellowMax,
                          "nor green: green should require being genuinely better than personal baseline")
    }

    /// The behavioral boundary behind the no-population-mean policy: without a usable personal HRV
    /// baseline there is no honest anchor, so the scorer must withhold rather than supply a default score.
    func testMissingPersonalBaselineWithholdsScore() {
        let score = RecoveryScorer.recovery(
            hrv: 50,
            rhr: 55,
            resp: nil,
            hrvBaseline: nil,
            rhrBaseline: nil,
            respBaseline: nil,
            sleepPerf: RecoveryScorer.sleepPerfCenter
        )
        XCTAssertNil(score)
    }

    /// Monotonicity, so the display mapping can never invert the underlying physiology. A higher composite
    /// z must always produce a higher score regardless of where the midpoint sits.
    func testMappingIsStrictlyMonotonic() {
        func score(_ z: Double) -> Double {
            100.0 / (1.0 + exp(-RecoveryScorer.personalBaselineLogisticSlope
                               * (z - RecoveryScorer.personalBaselineLogisticMidpointZ)))
        }
        var previous = -Double.infinity
        for step in stride(from: -4.0, through: 4.0, by: 0.25) {
            let value = score(step)
            XCTAssertGreaterThan(value, previous, "mapping inverted at z=\(step)")
            previous = value
        }
        XCTAssertGreaterThan(score(-4), 0.0)
        XCTAssertLessThan(score(4), 100.0)
    }
}
