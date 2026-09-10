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

    func testRepeatingMotionYieldsToStillAndInteractionPolicies() {
        XCTAssertTrue(
            noopAllowsRepeatingMotion(
                requested: true,
                poseStill: false,
                interactionInProgress: false
            )
        )
        XCTAssertFalse(
            noopAllowsRepeatingMotion(
                requested: false,
                poseStill: false,
                interactionInProgress: false
            )
        )
        XCTAssertFalse(
            noopAllowsRepeatingMotion(
                requested: true,
                poseStill: true,
                interactionInProgress: false
            )
        )
        XCTAssertFalse(
            noopAllowsRepeatingMotion(
                requested: true,
                poseStill: false,
                interactionInProgress: true
            )
        )
    }
}
