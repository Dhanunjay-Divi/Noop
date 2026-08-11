import XCTest
@testable import Strand

final class TrialNoticePolicyTests: XCTestCase {
    func testFreshProcessLaunchShowsTrialNotice() {
        XCTAssertTrue(
            TrialNoticePolicy.shouldPresent(
                acknowledgedThisLaunch: false,
                demoBypass: false
            )
        )
    }

    func testAcknowledgingHidesNoticeForCurrentProcess() {
        XCTAssertFalse(
            TrialNoticePolicy.shouldPresent(
                acknowledgedThisLaunch: true,
                demoBypass: false
            )
        )
    }

    func testDemoHarnessBypassesNotice() {
        XCTAssertFalse(
            TrialNoticePolicy.shouldPresent(
                acknowledgedThisLaunch: false,
                demoBypass: true
            )
        )
    }
}
