import XCTest
@testable import StrandDesign

final class QuietMotionPolicyTests: XCTestCase {
    func testPreferenceKeyIsStableAcrossAppAndSensorReaders() {
        XCTAssertEqual(QuietMotionPrefs.enabledKey, "noop.quietMotion")
    }

    @MainActor
    func testAccessibilityReduceMotionAlwaysWins() {
        XCTAssertTrue(NoopMotionState.shared.poseStill(true))
    }
}
