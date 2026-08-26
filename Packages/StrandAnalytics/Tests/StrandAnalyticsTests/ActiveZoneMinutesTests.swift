import XCTest
@testable import StrandAnalytics

/// Pins the WHO/AHA guideline arithmetic and, more importantly, the no-fabrication contract:
/// an absent week must not render as "0 of 150", which reads as a failed week rather than an unmeasured one.
final class ActiveZoneMinutesTests: XCTestCase {

    private func tiz(z1: Double = 0, z2: Double = 0, z3: Double = 0,
                     z4: Double = 0, z5: Double = 0, below: Double = 0) -> TimeInZone {
        TimeInZone(seconds: [z1, z2, z3, z4, z5], belowZone1: below)
    }

    // MARK: Guideline arithmetic

    func testModerateMinutesCreditOneToOne() {
        let m = ActiveZoneMinutesCalculator.minutes(from: tiz(z3: 30 * 60))
        XCTAssertEqual(m?.moderateMinutes ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(m?.creditedMinutes ?? 0, 30, accuracy: 0.001)
    }

    /// The 2:1 credit is the guideline's own equivalence (150 moderate == 75 vigorous), not a NOOP choice.
    func testVigorousMinutesCreditTwoToOne() {
        let m = ActiveZoneMinutesCalculator.minutes(from: tiz(z4: 20 * 60))
        XCTAssertEqual(m?.vigorousMinutes ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(m?.creditedMinutes ?? 0, 40, accuracy: 0.001)
    }

    func testZone5CountsAsVigorous() {
        let m = ActiveZoneMinutesCalculator.minutes(from: tiz(z5: 10 * 60))
        XCTAssertEqual(m?.vigorousMinutes ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(m?.creditedMinutes ?? 0, 20, accuracy: 0.001)
    }

    /// 75 vigorous minutes must satisfy the same 150-minute target as 150 moderate. If this ever fails,
    /// the two guideline-equivalent paths have stopped agreeing.
    func testSeventyFiveVigorousMeetsGuidelineLikeOneFiftyModerate() {
        let vigorous = ActiveZoneMinutesCalculator.minutes(from: tiz(z4: 75 * 60))
        let moderate = ActiveZoneMinutesCalculator.minutes(from: tiz(z3: 150 * 60))
        XCTAssertTrue(vigorous?.meetsWeeklyGuideline ?? false)
        XCTAssertTrue(moderate?.meetsWeeklyGuideline ?? false)
        XCTAssertEqual(vigorous?.creditedMinutes ?? 0, moderate?.creditedMinutes ?? 0, accuracy: 0.001)
    }

    // MARK: Light activity is deliberately not credited

    /// The guideline does not count light activity toward the 150 minutes, so neither may NOOP. A user
    /// who strolled all week has not met a moderate-to-vigorous guideline and must not be told they did.
    func testLightZonesEarnNoCredit() {
        let m = ActiveZoneMinutesCalculator.minutes(from: tiz(z1: 60 * 60, z2: 60 * 60, below: 600))
        XCTAssertNotNil(m, "there WAS counted time, so this is a real zero rather than missing data")
        XCTAssertEqual(m?.creditedMinutes ?? -1, 0, accuracy: 0.001)
        XCTAssertFalse(m?.meetsWeeklyGuideline ?? true)
    }

    // MARK: No fabrication

    func testNoDataReturnsNilRatherThanZero() {
        XCTAssertNil(ActiveZoneMinutesCalculator.minutes(from: nil))
        XCTAssertNil(ActiveZoneMinutesCalculator.minutes(from: tiz()),
                     "an all-zero record carries no counted time and must not render as a failed week")
    }

    func testWeeklyWithNoUsableDayReturnsNil() {
        XCTAssertNil(ActiveZoneMinutesCalculator.weekly(from: [nil, nil, nil]))
    }

    /// A partially-worn week must credit the days that exist instead of being dragged down by the gaps.
    func testWeeklySkipsMissingDaysWithoutPenalising() {
        let week: [TimeInZone?] = [tiz(z3: 30 * 60), nil, tiz(z4: 15 * 60), nil, nil, nil, nil]
        let m = ActiveZoneMinutesCalculator.weekly(from: week)
        XCTAssertEqual(m?.moderateMinutes ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(m?.vigorousMinutes ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(m?.creditedMinutes ?? 0, 60, accuracy: 0.001)  // 30 + 2*15
    }

    // MARK: Target reporting

    /// Exceeding the guideline is a real outcome. Clamping it would erase the difference between a user
    /// who just met the target and one who doubled it.
    func testTargetFractionIsNotClamped() {
        let m = ActiveZoneMinutesCalculator.minutes(from: tiz(z3: 300 * 60))
        XCTAssertEqual(m?.targetFraction ?? 0, 2.0, accuracy: 0.001)
    }

    func testZoneMappingMatchesDocumentedBands() {
        XCTAssertEqual(ActiveZoneMinutesCalculator.moderateZone, 3, "Zone 3 is 70-80% HRmax")
        XCTAssertEqual(ActiveZoneMinutesCalculator.vigorousZoneFloor, 4, "Zone 4+ is >=80% HRmax")
        XCTAssertEqual(ActiveZoneMinutesCalculator.defaultWeeklyTarget, 150, "WHO/AHA weekly target")
    }

    /// Guards the conservative direction of the ACSM mismatch: Zone 2 (60-70% HRmax) overlaps ACSM's
    /// moderate band (64-76%) but is NOT credited. If someone "fixes" that by crediting Zone 2, this
    /// fails and forces the tradeoff to be re-argued rather than quietly inflating everyone's totals.
    func testZone2IsNotCreditedEvenThoughItOverlapsAcsmModerate() {
        let m = ActiveZoneMinutesCalculator.minutes(from: tiz(z2: 100 * 60))
        XCTAssertEqual(m?.creditedMinutes ?? -1, 0, accuracy: 0.001)
    }
}
