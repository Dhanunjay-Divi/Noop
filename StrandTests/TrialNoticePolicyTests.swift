import XCTest
@testable import Strand

final class TrialNoticePolicyTests: XCTestCase {
    private let current = TrialNoticePolicy.buildIdentifier(
        marketingVersion: "9.1.2",
        buildNumber: "223"
    )

    func testFreshInstallShowsTrialNotice() {
        XCTAssertTrue(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: "",
                currentBuildIdentifier: current,
                demoBypass: false
            )
        )
    }

    func testAcknowledgedBuildStaysHiddenAcrossLaunches() {
        XCTAssertFalse(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: current,
                currentBuildIdentifier: current,
                demoBypass: false
            )
        )
    }

    func testHigherBuildWithSameMarketingVersionShowsNotice() {
        let previous = TrialNoticePolicy.buildIdentifier(
            marketingVersion: "9.1.2",
            buildNumber: "222"
        )
        XCTAssertTrue(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: previous,
                currentBuildIdentifier: current,
                demoBypass: false
            )
        )
    }

    func testHigherMarketingVersionShowsNoticeEvenWhenBuildNumberResets() {
        let previous = TrialNoticePolicy.buildIdentifier(
            marketingVersion: "9.1.1",
            buildNumber: "999"
        )
        XCTAssertTrue(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: previous,
                currentBuildIdentifier: current,
                demoBypass: false
            )
        )
    }

    func testDowngradeDoesNotPretendToBeANewerBuild() {
        let future = TrialNoticePolicy.buildIdentifier(
            marketingVersion: "9.2.0",
            buildNumber: "1"
        )
        XCTAssertFalse(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: future,
                currentBuildIdentifier: current,
                demoBypass: false
            )
        )
    }

    func testLowerBuildOfSameVersionDoesNotReplayNotice() {
        let laterBuild = TrialNoticePolicy.buildIdentifier(
            marketingVersion: "9.1.2",
            buildNumber: "224"
        )
        XCTAssertFalse(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: laterBuild,
                currentBuildIdentifier: current,
                demoBypass: false
            )
        )
    }

    func testNumericVersionComparisonHandlesDoubleDigitComponents() {
        let previous = TrialNoticePolicy.buildIdentifier(
            marketingVersion: "9.2.0",
            buildNumber: "999"
        )
        let newer = TrialNoticePolicy.buildIdentifier(
            marketingVersion: "9.10.0",
            buildNumber: "1"
        )
        XCTAssertTrue(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: previous,
                currentBuildIdentifier: newer,
                demoBypass: false
            )
        )
    }

    func testReleaseNotesOnlyTreatGenuinelyNewerVersionAsDue() {
        XCTAssertTrue(
            TrialNoticePolicy.isNewerMarketingVersion("9.10.0", than: "9.2.0")
        )
        XCTAssertFalse(
            TrialNoticePolicy.isNewerMarketingVersion("9.1.2", than: "9.1.2")
        )
        XCTAssertFalse(
            TrialNoticePolicy.isNewerMarketingVersion("9.1.1", than: "9.1.2")
        )
    }

    func testBundleIdentityUsesBothVersionAndBuild() {
        XCTAssertEqual(
            TrialNoticePolicy.currentBuildIdentifier(infoDictionary: [
                "CFBundleShortVersionString": "9.1.2",
                "CFBundleVersion": 223
            ]),
            current
        )
    }

    func testDemoHarnessBypassesNotice() {
        XCTAssertFalse(
            TrialNoticePolicy.shouldPresent(
                acknowledgedBuildIdentifier: "",
                currentBuildIdentifier: current,
                demoBypass: true
            )
        )
    }
}
