import XCTest
@testable import StrandAnalytics

/// Locks the week×hour stress-heatmap aggregation (R7): band cut points shared with the UI's StressBand,
/// row-major grid over the waking window, no-data cells staying nil, and the deterministic pattern
/// summary. BYTE-PARITY with the Android twin (com.noop.analytics.StressHeatmap).
final class StressHeatmapTests: XCTestCase {

    // MARK: - Bands

    func testBandCutPointsMatchStressBand() {
        XCTAssertEqual(StressHeatmap.band(0.0), .low)
        XCTAssertEqual(StressHeatmap.band(0.99), .low)
        XCTAssertEqual(StressHeatmap.band(1.0), .medium)   // low ceiling is exclusive
        XCTAssertEqual(StressHeatmap.band(1.99), .medium)
        XCTAssertEqual(StressHeatmap.band(2.0), .high)     // high floor is inclusive
        XCTAssertEqual(StressHeatmap.band(3.0), .high)
    }

    // MARK: - Grid

    func testGridIsRowMajorOverWakingWindow() {
        let a = StressHeatmap.DayColumn(day: "2026-08-20", levels: [6: 0.5, 7: 2.5])
        let b = StressHeatmap.DayColumn(day: "2026-08-21", levels: [7: 1.5])
        let cells = StressHeatmap.grid(columns: [a, b], startHour: 6, endHour: 8)
        // 2 hours × 2 columns, row-major: (6,a) (6,b) (7,a) (7,b)
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells[0].hour, 6); XCTAssertEqual(cells[0].dayIndex, 0)
        XCTAssertEqual(cells[0].level, 0.5)
        XCTAssertEqual(cells[1].hour, 6); XCTAssertEqual(cells[1].dayIndex, 1)
        XCTAssertNil(cells[1].level, "an hour with no signal stays nil — never zero-filled")
        XCTAssertEqual(cells[2].level, 2.5)
        XCTAssertEqual(cells[3].level, 1.5)
    }

    func testGridBandsOnlyWhenScored() {
        let col = StressHeatmap.DayColumn(day: "2026-08-21", levels: [6: 2.4])
        let cells = StressHeatmap.grid(columns: [col], startHour: 6, endHour: 8)
        XCTAssertEqual(cells[0].band, .high)
        XCTAssertNil(cells[1].band, "no level ⇒ no band guess")
    }

    func testGridEdgeCases() {
        XCTAssertTrue(StressHeatmap.grid(columns: []).isEmpty)
        let col = StressHeatmap.DayColumn(day: "d", levels: [6: 1])
        // Inverted / empty window ⇒ no cells.
        XCTAssertTrue(StressHeatmap.grid(columns: [col], startHour: 10, endHour: 10).isEmpty)
        XCTAssertTrue(StressHeatmap.grid(columns: [col], startHour: 12, endHour: 6).isEmpty)
    }

    func testGridDefaultWindowMatchesIntradayTimeline() {
        let col = StressHeatmap.DayColumn(day: "d", levels: [:])
        let cells = StressHeatmap.grid(columns: [col])
        // Defaults mirror DaytimeStress waking hours (6…22) so heatmap + timeline agree.
        XCTAssertEqual(StressHeatmap.defaultStartHour, DaytimeStress.wakingStartHour)
        XCTAssertEqual(StressHeatmap.defaultEndHour, DaytimeStress.wakingEndHour)
        XCTAssertEqual(cells.count, DaytimeStress.wakingEndHour - DaytimeStress.wakingStartHour)
    }

    // MARK: - meanByHour

    func testMeanByHourAveragesOnlyScoredCells() {
        let a = StressHeatmap.DayColumn(day: "d1", levels: [6: 1.0, 7: 3.0])
        let b = StressHeatmap.DayColumn(day: "d2", levels: [6: 2.0])          // hour 7 missing
        let cells = StressHeatmap.grid(columns: [a, b], startHour: 6, endHour: 8)
        let means = StressHeatmap.meanByHour(cells)
        XCTAssertEqual(means[6]!, 1.5, accuracy: 1e-9)   // (1.0 + 2.0) / 2
        XCTAssertEqual(means[7]!, 3.0, accuracy: 1e-9)   // only d1 scored ⇒ its own value
        XCTAssertEqual(means.count, 2)
    }

    func testMeanByHourOmitsUnscoredHours() {
        let col = StressHeatmap.DayColumn(day: "d", levels: [6: 1.0])
        let cells = StressHeatmap.grid(columns: [col], startHour: 6, endHour: 9)
        let means = StressHeatmap.meanByHour(cells)
        XCTAssertNil(means[7], "an all-nil hour is absent, not 0")
        XCTAssertNil(means[8])
    }

    // MARK: - Summary

    func testSummaryFindsPeakAndCalmestHours() {
        let a = StressHeatmap.DayColumn(day: "d1", levels: [6: 0.4, 7: 2.6, 8: 1.5])
        let b = StressHeatmap.DayColumn(day: "d2", levels: [6: 0.6, 7: 2.4, 8: 1.5])
        let cells = StressHeatmap.grid(columns: [a, b], startHour: 6, endHour: 9)
        let s = StressHeatmap.summary(cells)
        XCTAssertEqual(s.peakHour, 7)
        XCTAssertEqual(s.peakHourMean!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.calmestHour, 6)
        XCTAssertEqual(s.calmestHourMean!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.overallMean!, (0.4 + 2.6 + 1.5 + 0.6 + 2.4 + 1.5) / 6.0, accuracy: 1e-9)
        XCTAssertEqual(s.scoredCells, 6)
        XCTAssertEqual(s.totalCells, 6)
        XCTAssertEqual(s.coverage, 1.0, accuracy: 1e-9)
    }

    func testSummaryCoverageReflectsSparseWear() {
        let a = StressHeatmap.DayColumn(day: "d1", levels: [6: 1.0])   // 1 of 3 hours scored
        let cells = StressHeatmap.grid(columns: [a], startHour: 6, endHour: 9)
        let s = StressHeatmap.summary(cells)
        XCTAssertEqual(s.scoredCells, 1)
        XCTAssertEqual(s.totalCells, 3)
        XCTAssertEqual(s.coverage, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testSummaryEmptyWhenNothingScored() {
        let a = StressHeatmap.DayColumn(day: "d1", levels: [:])
        let cells = StressHeatmap.grid(columns: [a], startHour: 6, endHour: 9)
        let s = StressHeatmap.summary(cells)
        XCTAssertNil(s.peakHour)
        XCTAssertNil(s.overallMean)
        XCTAssertEqual(s.coverage, 0)
        XCTAssertEqual(s.totalCells, 3, "cells still counted so the UI can show an empty grid honestly")
        XCTAssertEqual(StressHeatmap.summary([]), .empty)
    }

    func testSummaryTieBreaksToEarlierHourDeterministically() {
        // Hours 6 and 7 share the same mean; peak and calmest must both resolve to the earlier hour.
        let a = StressHeatmap.DayColumn(day: "d1", levels: [6: 1.0, 7: 1.0])
        let cells = StressHeatmap.grid(columns: [a], startHour: 6, endHour: 8)
        let s = StressHeatmap.summary(cells)
        XCTAssertEqual(s.peakHour, 6)
        XCTAssertEqual(s.calmestHour, 6)
    }
}
