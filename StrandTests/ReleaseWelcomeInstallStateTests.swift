import XCTest
@testable import Strand

final class ReleaseWelcomeInstallStateTests: XCTestCase {
    func testFreshInstallKeepsFirstWelcomePendingThroughOnboarding() {
        XCTAssertEqual(
            ReleaseWelcomeInstallState.prepared(
                onboarded: false,
                storedPending: false,
                storedCompleted: false
            ),
            ReleaseWelcomeInstallState(pending: true, completed: false)
        )
        XCTAssertEqual(
            ReleaseWelcomeInstallState.prepared(
                onboarded: true,
                storedPending: true,
                storedCompleted: false
            ),
            ReleaseWelcomeInstallState(pending: true, completed: false)
        )
    }

    func testExistingInstallMigratesWithoutFirstInstallGlow() {
        XCTAssertEqual(
            ReleaseWelcomeInstallState.prepared(
                onboarded: true,
                storedPending: false,
                storedCompleted: false
            ),
            ReleaseWelcomeInstallState(pending: false, completed: true)
        )
    }

    func testCompletingWelcomePermanentlyClearsPendingState() {
        let pending = ReleaseWelcomeInstallState(pending: true, completed: false)
        XCTAssertEqual(
            pending.completingWelcome(),
            ReleaseWelcomeInstallState(pending: false, completed: true)
        )
        XCTAssertEqual(
            ReleaseWelcomeInstallState.prepared(
                onboarded: true,
                storedPending: true,
                storedCompleted: true
            ),
            ReleaseWelcomeInstallState(pending: false, completed: true)
        )
    }
}
