import XCTest
@testable import Strand

final class XiaomiImporterUnitTests: XCTestCase {
    func testDailyEfficiencyUsesStoredFractionUnits() {
        guard let efficiency = XiaomiImporter.sleepEfficiency(total: 420, awake: 60) else {
            return XCTFail("Expected a finite sleep efficiency")
        }
        XCTAssertEqual(
            efficiency,
            0.875,
            accuracy: 1e-12
        )
        XCTAssertNil(XiaomiImporter.sleepEfficiency(total: 420, awake: .infinity))
    }

    func testSessionEfficiencyUsesStoredFractionUnits() {
        let segments: [[String: Any]] = [
            ["start": 0, "end": 90, "stage": "light"],
            ["start": 90, "end": 100, "stage": "wake"],
        ]
        guard let efficiency = XiaomiImporter.efficiency(segs: segments, start: 0, end: 100) else {
            return XCTFail("Expected a finite session efficiency")
        }
        XCTAssertEqual(
            efficiency,
            0.9,
            accuracy: 1e-12
        )
    }
}
