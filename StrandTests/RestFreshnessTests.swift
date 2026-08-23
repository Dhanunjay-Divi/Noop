import XCTest
@testable import Strand

/// #977 (display half) — the freshness-gated Rest resolution that keeps the Today Rest hero HONEST for a
/// live 5.0 whose sleep never scores (no overnight gravity ⇒ no `sleep_performance` point ever written).
/// The display used to resolve Rest as "today's value, else the LATEST point in the whole series", which
/// pinned Rest to a weeks-old scored night while Charge (recovery) kept advancing — the frozen "93 since
/// forever" the reporter hit. `freshRestScore` gates the tail-fallback on recency: it still carries last
/// night's Rest before today scores, but once the last scored night is STALE it returns nil so the Rest
/// hero falls through to its No-Data / calibrating state instead of freezing on a stale number. Pure +
/// headless. Mirrors the Android `freshRestScoreTest`.
final class RestFreshnessTests: XCTestCase {

    // A fixed "today" so the recency window is deterministic regardless of the test host's wall clock.
    private let todayKey = "2026-06-19"

    func testTodaysOwnRow_wins_regardlessOfTail() {
        // Today's own scored Rest is shown even when a (fresher or staler) tail exists.
        XCTAssertEqual(
            TodayView.freshRestScore(todayValue: 71, lastDay: "2026-06-18", lastValue: 93,
                                     isTodaySelected: true, todayKey: todayKey),
            71)
        // …and even with a stale tail present.
        XCTAssertEqual(
            TodayView.freshRestScore(todayValue: 71, lastDay: "2026-06-07", lastValue: 93,
                                     isTodaySelected: true, todayKey: todayKey),
            71)
    }

    func testFreshTail_carries_whenNoTodayRow() {
        // No today row + a FRESH last-scored night (yesterday) → tail-fallback carries last night's Rest.
        // Unchanged (legitimate) morning-carry behaviour.
        XCTAssertEqual(
            TodayView.freshRestScore(todayValue: nil, lastDay: "2026-06-18", lastValue: 88,
                                     isTodaySelected: true, todayKey: todayKey),
            88)
    }

    func testStaleTail_doesNotCarry_readsNoData() {
        // No today row + a STALE last-scored night (12 days ago) → NO tail-fallback. This is the frozen-93
        // case: it now reads honestly as no data (nil), so the Rest hero shows its No-Data/calibrating state.
        XCTAssertNil(
            TodayView.freshRestScore(todayValue: nil, lastDay: "2026-06-07", lastValue: 93,
                                     isTodaySelected: true, todayKey: todayKey))
    }

    func testPastDaySelected_neverTailFalls() {
        // A navigated PAST day with no row shows nothing rather than borrowing the newest value.
        XCTAssertNil(
            TodayView.freshRestScore(todayValue: nil, lastDay: "2026-06-18", lastValue: 88,
                                     isTodaySelected: false, todayKey: todayKey))
    }

    func testNoTailAtAll_readsNoData() {
        // Cold start: no today row and no scored night anywhere → no number, no fabrication.
        XCTAssertNil(
            TodayView.freshRestScore(todayValue: nil, lastDay: nil, lastValue: nil,
                                     isTodaySelected: true, todayKey: todayKey))
    }
}

/// The multi-vital adapter has its own, stricter freshness gate: imported history is useful for trends,
/// but a weeks-old last row must never become a current "signals shifted together" message.
final class IllnessFreshnessTests: XCTestCase {
    func testJournalDayKeysFollowCivilDaysAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 9,
            hour: 0,
            minute: 30
        )))

        XCTAssertEqual(
            AppModel.illnessJournalDayKeys(now: now, calendar: calendar),
            Set(["2026-03-07", "2026-03-08", "2026-03-09"])
        )
    }

    func testJournalDayKeysUseTheSuppliedTimeZoneAcrossYearBoundary() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026,
            month: 1,
            day: 1,
            hour: 2,
            minute: 30
        )))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        XCTAssertEqual(
            AppModel.illnessJournalDayKeys(now: instant, calendar: newYork),
            Set(["2025-12-29", "2025-12-30", "2025-12-31"])
        )
    }

    func testCurrentAndRecentWakeDaysAreFresh() {
        XCTAssertTrue(AppModel.illnessHistoryIsFresh(
            dayKeys: ["2026-07-26"], todayKey: "2026-07-26"))
        XCTAssertTrue(AppModel.illnessHistoryIsFresh(
            dayKeys: ["2026-07-24"], todayKey: "2026-07-26"))
    }

    func testHistoricalImportAndFutureRowAreRejected() {
        XCTAssertFalse(AppModel.illnessHistoryIsFresh(
            dayKeys: ["2026-07-23"], todayKey: "2026-07-26"))
        XCTAssertFalse(AppModel.illnessHistoryIsFresh(
            dayKeys: ["2026-07-27"], todayKey: "2026-07-26"))
    }

    func testNewestKeyWinsRegardlessOfInputOrder() {
        XCTAssertTrue(AppModel.illnessHistoryIsFresh(
            dayKeys: ["2026-06-01", "2026-07-25", "2026-05-01"],
            todayKey: "2026-07-26"))
    }
}
