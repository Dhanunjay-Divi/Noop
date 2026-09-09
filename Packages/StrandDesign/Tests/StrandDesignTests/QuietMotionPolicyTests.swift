import SwiftUI
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

    func testInteractionMotionBudgetDefaultsInactiveAndCanBePublishedByTheShell() {
        var environment = EnvironmentValues()
        XCTAssertFalse(environment.noopInteractionInProgress)

        environment.noopInteractionInProgress = true
        XCTAssertTrue(environment.noopInteractionInProgress)
    }
}
