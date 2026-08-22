import XCTest
@testable import Strand

final class TrialNoticeDistributionTests: XCTestCase {
    func testSandboxReceiptIsTestFlight() {
        let receipt = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/x/StoreKit/sandboxReceipt")
        XCTAssertEqual(TrialNoticePolicy.distributionChannel(receiptURL: receipt), .testFlight)
        XCTAssertEqual(TrialNoticePolicy.channelLabel(.testFlight), "TESTFLIGHT TRIAL")
    }

    func testDeveloperAndSideloadInstallsArePrivatePreview() {
        XCTAssertEqual(TrialNoticePolicy.distributionChannel(receiptURL: nil), .privatePreview)
        XCTAssertEqual(TrialNoticePolicy.channelLabel(.privatePreview), "PRIVATE PREVIEW")
    }

    func testProductionReceiptIsAppStoreAndNeverShowsTrialDisclosure() {
        let productionReceipt = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/x/StoreKit/receipt")
        XCTAssertEqual(TrialNoticePolicy.distributionChannel(receiptURL: productionReceipt), .appStore)
        XCTAssertEqual(TrialNoticePolicy.channelLabel(.appStore), "APP STORE")
        XCTAssertFalse(TrialNoticePolicy.shouldPresent(
            acknowledgedBuildIdentifier: "",
            currentBuildIdentifier: TrialNoticePolicy.buildIdentifier(
                marketingVersion: "9.2.0",
                buildNumber: "230"
            ),
            demoBypass: false,
            channel: .appStore
        ))
    }
}
