import XCTest
@testable import Strand

final class CycleTrackingValidationTests: XCTestCase {
    func testAcceptsStrictGregorianDayKeys() {
        XCTAssertTrue(Repository.isValidLocalDayKey("2026-08-11"))
        XCTAssertTrue(Repository.isValidLocalDayKey("2024-02-29"))
    }

    func testRejectsImpossibleOrNonCanonicalDayKeys() {
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-02-29"))
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-13-01"))
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-8-1"))
        XCTAssertFalse(Repository.isValidLocalDayKey("../../private"))
        XCTAssertFalse(Repository.isValidLocalDayKey("2026-08-11T00:00:00Z"))
    }
}
