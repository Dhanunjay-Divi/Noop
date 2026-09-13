import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the Swift Week-in-Review chip contract (#463): a ROUGH week-over-week comparison (either side
/// 1-2 days) neutralizes the chip tone and drops the VoiceOver verdict frame, so iOS/macOS matches the
/// Android WeeklyDigestCard gate instead of dressing a 43% "drop" off 2 days in a confident verdict.
/// `chipTone`/`rowAccessibility` in WeeklyDigestView delegate to WeeklyDigestChipStyle, so pinning it
/// here pins the code path the View actually runs. Mirrors WeeklyDigestCardFormattingTest's rough cases.
final class WeeklyDigestChipStyleTests: XCTestCase {

    func testRecoveryPresentationUsesPinnedBandEdges() {
        XCTAssertEqual(RecoveryBandPresentation.level(for: 33.999), .low)
        XCTAssertEqual(RecoveryBandPresentation.level(for: 34), .steady)
        XCTAssertEqual(RecoveryBandPresentation.level(for: 66.999), .steady)
        XCTAssertEqual(RecoveryBandPresentation.level(for: 67), .strong)
    }

    func testRecoveryPresentationUsesOneSummaryVocabulary() {
        XCTAssertEqual(RecoveryBandPresentation.label(for: 10), "Low")
        XCTAssertEqual(RecoveryBandPresentation.label(for: 41), "Steady")
        XCTAssertEqual(RecoveryBandPresentation.label(for: 82), "Strong")
    }

    func testImportedRestDisclosureIsScopedToTheSelectedWeek() {
        var current = ImportedSleepFigures()
        current.performancePct = 94
        var prior = ImportedSleepFigures()
        prior.performancePct = 88

        XCTAssertTrue(
            WeeklyDigestSource.hasImportedRestScore(
                ["2026-09-09": current, "2026-09-01": prior],
                anchorDay: "2026-09-12"
            )
        )
        XCTAssertFalse(
            WeeklyDigestSource.hasImportedRestScore(
                ["2026-09-01": prior],
                anchorDay: "2026-09-12"
            )
        )
    }

    private func stat(mean: Double, n: Int) -> SeriesStat {
        SeriesStat(mean: mean, median: mean, min: mean, max: mean, stdev: 0, n: n, slopePerDay: 0)
    }

    private func summary(_ metric: WeeklyMetric,
                         thisMean: Double, thisN: Int,
                         prevMean: Double, prevN: Int) -> WeeklyMetricSummary {
        let cur = stat(mean: thisMean, n: thisN)
        let prev = stat(mean: prevMean, n: prevN)
        let comparable = thisN > 0 && prevN > 0
        let delta = comparable ? thisMean - prevMean : 0
        let pct: Double? = (comparable && prevMean != 0) ? delta / prevMean * 100 : nil
        let direction = (!comparable || delta == 0) ? 0 : (delta > 0 ? 1 : -1)
        return WeeklyMetricSummary(metric: metric,
                                   thisWeek: cur,
                                   weekOverWeek: PeriodComparison(current: cur, previous: prev,
                                                                  delta: delta, pctChange: pct,
                                                                  direction: direction),
                                   baselineMean: nil, vsBaseline: nil)
    }

    // Full weeks (>= the focus floor both sides) keep their verdict tone + frame.
    func testFullWeeksAreNotNeutralized() {
        let full = summary(.charge, thisMean: 56, thisN: 5, prevMean: 50, prevN: 5)
        XCTAssertTrue(WeeklyDigestChipStyle.hasDefinedPercent(full))
        XCTAssertFalse(WeeklyDigestChipStyle.neutralizesTone(full))
        XCTAssertFalse(WeeklyDigestChipStyle.dropsVerdictFrame(full))
        // 3 days each side is exactly the focus floor: still a real comparison.
        let floor = summary(.charge, thisMean: 56, thisN: 3, prevMean: 50, prevN: 3)
        XCTAssertFalse(WeeklyDigestChipStyle.neutralizesTone(floor))
    }

    func testRecoveryDeltaUsesCurrentBandToneInsteadOfDirectionalVerdict() {
        let decline = summary(.charge, thisMean: 72, thisN: 5, prevMean: 82, prevN: 5)
        XCTAssertEqual(WeeklyDigestChipStyle.tone(for: decline), .recoveryBand)
    }

    func testSubOnePercentDeltaKeepsDirectionSeparateFromMagnitude() {
        let decline = summary(.charge, thisMean: 49.8, thisN: 5, prevMean: 50, prevN: 5)
        XCTAssertEqual(WeeklyDigestChipStyle.deltaText(for: decline), "<1%")
        XCTAssertFalse(WeeklyDigestChipStyle.deltaText(for: decline).contains("−"))
    }

    // A sparse PREVIOUS week (the reporter's #463 shape: this week 5 days, last week 2) is rough:
    // tone neutralized, frame dropped, so the chip can't read a green/rose verdict off 2 days.
    func testSparsePreviousWeekIsNeutralized() {
        let s = summary(.charge, thisMean: 41, thisN: 5, prevMean: 72, prevN: 2)
        XCTAssertTrue(WeeklyDigestChipStyle.neutralizesTone(s))
        XCTAssertTrue(WeeklyDigestChipStyle.dropsVerdictFrame(s))
    }

    // A sparse CURRENT week is rough too.
    func testSparseCurrentWeekIsNeutralized() {
        let s = summary(.charge, thisMean: 72, thisN: 2, prevMean: 41, prevN: 5)
        XCTAssertTrue(WeeklyDigestChipStyle.neutralizesTone(s))
        XCTAssertTrue(WeeklyDigestChipStyle.dropsVerdictFrame(s))
    }

    // A missing side reads "new" and has no percentage denominator.
    func testMissingSideIsNeutralAndUnpercentable() {
        let s = summary(.charge, thisMean: 60, thisN: 5, prevMean: 0, prevN: 0)
        XCTAssertFalse(WeeklyDigestChipStyle.hasDefinedPercent(s))
        XCTAssertTrue(WeeklyDigestChipStyle.neutralizesTone(s))
        XCTAssertTrue(WeeklyDigestChipStyle.dropsVerdictFrame(s))
    }

    func testZeroBaselineIsNewAndNeutral() {
        let s = summary(.effort, thisMean: 40, thisN: 5, prevMean: 0, prevN: 3)
        XCTAssertFalse(WeeklyDigestChipStyle.hasDefinedPercent(s))
        XCTAssertTrue(WeeklyDigestChipStyle.neutralizesTone(s))
        XCTAssertTrue(WeeklyDigestChipStyle.dropsVerdictFrame(s))
    }
}
