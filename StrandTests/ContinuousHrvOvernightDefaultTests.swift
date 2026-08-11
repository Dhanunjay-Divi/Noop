import XCTest
@testable import Strand

final class ContinuousHrvOvernightDefaultTests: XCTestCase {
    func testOnlyLegacyUnchosenInstallIsPinned() {
        XCTAssertTrue(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: true))
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: false, hasUsedContinuousHrv: false))
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: true, hasUsedContinuousHrv: true))
        XCTAssertFalse(PuffinExperiment.shouldPinLegacyOvernightDefault(
            hasOvernightChoice: true, hasUsedContinuousHrv: false))
    }
}
