import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testProvisionedAltStoreGroupWins() {
        let configured = "group.com.noopapp.noop.staging"
        XCTAssertEqual(WidgetSnapshot.resolveSuiteName(infoDictionary: [
            "AppGroupIdentifier": configured,
            "ALTAppGroups": [configured + ".TEAM123456"]
        ]), configured + ".TEAM123456")
    }

    func testConfiguredAndSingleProvisionedFallbacks() {
        XCTAssertEqual(WidgetSnapshot.resolveSuiteName(infoDictionary: [
            "AppGroupIdentifier": "group.example.noop"
        ]), "group.example.noop")
        XCTAssertEqual(WidgetSnapshot.resolveSuiteName(infoDictionary: [
            "ALTAppGroups": ["group.example.noop.TEAM123456"]
        ]), "group.example.noop.TEAM123456")
    }

    func testRuntimeFallbackNeverUsesDemoMetrics() {
        XCTAssertNil(WidgetSnapshot.unavailable.recovery)
        XCTAssertNil(WidgetSnapshot.unavailable.bpm)
        XCTAssertFalse(WidgetSnapshot.unavailable.bonded)
    }
}
