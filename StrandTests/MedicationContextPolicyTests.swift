import XCTest
@testable import Strand

final class MedicationContextPolicyTests: XCTestCase {
    func testRecentStartOrDoseChangeIsContext() {
        let entries = [
            MedicationEntry(name: "Example", changeDay: "2026-08-10")
        ]
        XCTAssertTrue(MedicationContextPolicy.hasRecentChange(entries, asOfDay: "2026-08-23"))
    }

    func testStableFutureAndMalformedDatesAreNotRecent() {
        let entries = [
            MedicationEntry(name: "Stable", changeDay: "2026-01-01"),
            MedicationEntry(name: "Future", changeDay: "2026-08-24"),
            MedicationEntry(name: "Malformed", changeDay: "2026-02-30"),
        ]
        XCTAssertFalse(MedicationContextPolicy.hasRecentChange(entries, asOfDay: "2026-08-23"))
    }

    func testFourteenDayBoundaryIsInclusive() {
        let entries = [
            MedicationEntry(name: "Example", changeDay: "2026-08-09")
        ]
        XCTAssertTrue(MedicationContextPolicy.hasRecentChange(entries, asOfDay: "2026-08-23"))
        XCTAssertFalse(MedicationContextPolicy.hasRecentChange(entries, asOfDay: "2026-08-24"))
    }

    func testLocalDayKeyUsesTheSuppliedTimeZone() {
        let date = Date(timeIntervalSince1970: 1_787_451_600) // 2026-08-23 02:20 UTC
        XCTAssertEqual(
            MedicationContextPolicy.localDayKey(date, timeZone: TimeZone(secondsFromGMT: 0)!),
            "2026-08-23"
        )
        XCTAssertEqual(
            MedicationContextPolicy.localDayKey(date, timeZone: TimeZone(secondsFromGMT: -4 * 3_600)!),
            "2026-08-22"
        )
    }
}
