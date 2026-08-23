import XCTest
@testable import Strand

@MainActor
final class UpdateDeliveryPolicyTests: XCTestCase {
    func testDistributionChannelsResolveToExpectedUpdateLanes() {
        XCTAssertEqual(
            UpdateDeliveryPolicy.destination(for: .privatePreview),
            .privateReleases
        )
        XCTAssertEqual(
            UpdateDeliveryPolicy.destination(for: .appStore),
            .appStore
        )
        XCTAssertEqual(
            UpdateDeliveryPolicy.destination(for: .testFlight),
            .testFlight
        )
    }

    func testAppleDistributedBuildsShortCircuitBeforePrivateReleaseCheck() {
        for channel in [
            TrialNoticePolicy.DistributionChannel.appStore,
            .testFlight,
        ] {
            let checker = UpdateChecker()
            checker.check(currentVersion: "1.0.0", channel: channel)
            XCTAssertEqual(checker.state, .managedByApple)
        }
    }
}
