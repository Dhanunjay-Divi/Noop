import XCTest
import WhoopStore
@testable import Strand

/// #796 - the per-session Effort surfaced on each workout row. It reuses the SAME stored 0-100 strain
/// and the SAME `UnitFormatter.effortDisplay` every other Effort read-out routes through, so the row,
/// the Effort ring and the detail card never disagree. These pin: a captured strain renders on the
/// selected scale to one decimal, and a session with no strain shows the honest "-" rather than a 0.
final class WorkoutEffortCellTests: XCTestCase {

    func testEffortLabelOnHundredScale() {
        // Stored 0-100 axis renders unchanged on the default Effort scale.
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: 60, scale: .hundred), "60.0")
    }

    func testEffortLabelOnWhoopScale() {
        // The WHOOP 0-21 scale applies the 21/100 factor (60 -> 12.6), matching every other read-out.
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: 60, scale: .whoop), "12.6")
    }

    func testMissingStrainShowsDash() {
        // The empty cell uses the en-dash glyph the other workout-row cells use (row.avgHr etc.).
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: nil, scale: .hundred), "\u{2013}")
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: nil, scale: .whoop), "\u{2013}")
    }

    func testZeroStrainRendersZeroNotDash() {
        // A real captured 0 is data, not "missing", so it must show as a number, not the empty dash.
        XCTAssertEqual(WorkoutsView.effortCellLabel(strain: 0, scale: .hundred), "0.0")
    }
}

final class WorkoutDateWindowTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func row(start: Date, end: Date) -> WorkoutRow {
        WorkoutRow(startTs: Int(start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970),
                   sport: "Walking", source: "manual", durationS: end.timeIntervalSince(start),
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                   zonesJSON: nil, notes: nil)
    }

    func testLocalDayUsesCalendarBoundaryAcrossDST() {
        let window = WorkoutDateWindow.localDay(containing: date(2026, 3, 8, hour: 12),
                                                calendar: calendar)
        XCTAssertEqual(window.upperBound - window.lowerBound, 23 * 60 * 60)
    }

    func testLocalDayKeyUsesTheSelectedLocalCalendarDay() {
        let window = WorkoutDateWindow.localDay(dayKey: "2026-08-12", calendar: calendar)
        XCTAssertEqual(window?.lowerBound, Int(date(2026, 8, 12).timeIntervalSince1970))
        XCTAssertEqual(window?.upperBound, Int(date(2026, 8, 13).timeIntervalSince1970))
        XCTAssertNil(WorkoutDateWindow.localDay(dayKey: "not-a-day", calendar: calendar))
    }

    func testLocalDayKeyRemainsGregorianUnderAnAlternateDisplayCalendar() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let window = WorkoutDateWindow.localDay(dayKey: "2026-08-12", calendar: buddhist)
        XCTAssertEqual(window?.lowerBound, Int(date(2026, 8, 12).timeIntervalSince1970))
        XCTAssertEqual(window?.upperBound, Int(date(2026, 8, 13).timeIntervalSince1970))
    }

    func testLocalDayIncludesMidnightSpanningWorkoutOnlyByOverlap() {
        let selected = date(2026, 8, 12, hour: 12)
        let window = WorkoutDateWindow.localDay(containing: selected, calendar: calendar)
        let crossingIn = row(start: date(2026, 8, 11, hour: 23, minute: 50),
                             end: date(2026, 8, 12, hour: 0, minute: 10))
        let endingAtStart = row(start: date(2026, 8, 11, hour: 23),
                                end: date(2026, 8, 12))
        let startingAtEnd = row(start: date(2026, 8, 13),
                                end: date(2026, 8, 13, hour: 1))

        XCTAssertTrue(window.intersects(crossingIn))
        XCTAssertFalse(window.intersects(endingAtStart))
        XCTAssertFalse(window.intersects(startingAtEnd))
    }

    func testCustomRangeNormalizesOrderAndIncludesWholeFinalDay() {
        let window = WorkoutDateWindow.custom(from: date(2026, 8, 12, hour: 18),
                                              through: date(2026, 8, 10, hour: 9),
                                              calendar: calendar)
        XCTAssertEqual(window.lowerBound, Int(date(2026, 8, 10).timeIntervalSince1970))
        XCTAssertEqual(window.upperBound, Int(date(2026, 8, 13).timeIntervalSince1970))
        XCTAssertTrue(window.intersects(row(start: date(2026, 8, 12, hour: 23, minute: 55),
                                            end: date(2026, 8, 13, hour: 0, minute: 5))))
    }

    func testTrailingRangeAnchorsToCurrentCalendarDayNotLatestWorkout() {
        let window = WorkoutDateWindow.trailingCalendarDays(7,
                                                            endingOn: date(2026, 8, 12, hour: 15),
                                                            calendar: calendar)
        XCTAssertEqual(window.lowerBound, Int(date(2026, 8, 6).timeIntervalSince1970))
        XCTAssertEqual(window.upperBound, Int(date(2026, 8, 13).timeIntervalSince1970))
    }
}
