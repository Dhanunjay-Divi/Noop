import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testWidgetAppearanceUsesTheAppStorageContract() {
        XCTAssertEqual(WidgetAppearancePreference.storageKey, "theme.appearance")
    }

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
        XCTAssertNil(WidgetSnapshot.unavailable.connected)
        XCTAssertNil(WidgetSnapshot.unavailable.scoreDay)
    }

    func testOlderSnapshotDecodesWithoutInventingNewState() throws {
        let oldJSON = #"{"recovery":72,"bpm":58,"batteryPct":84,"bonded":true,"updated":0}"#
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(oldJSON.utf8))

        XCTAssertEqual(snapshot.recovery, 72)
        XCTAssertTrue(snapshot.bonded)
        XCTAssertNil(snapshot.connected, "Pairing must never be upgraded to a live connection")
        XCTAssertNil(snapshot.sleepMinutes)
        XCTAssertNil(snapshot.scoreDay)
    }

    func testFreshnessUsesPublicationTimeWithoutRemovingDailyScores() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = WidgetSnapshot.placeholder
        snapshot.updated = now.addingTimeInterval(-10 * 60)
        XCTAssertEqual(snapshot.freshness(at: now), .current)

        snapshot.updated = now.addingTimeInterval(-60 * 60)
        XCTAssertEqual(snapshot.freshness(at: now), .recent)

        snapshot.updated = now.addingTimeInterval(-3 * 60 * 60)
        XCTAssertEqual(snapshot.freshness(at: now), .stale)
        XCTAssertTrue(snapshot.hasDailySignal, "A stale live snapshot can still carry valid day scores")
    }

    func testWidgetDestinationURLsRoundTrip() {
        for destination in NOOPWidgetDestination.allCases {
            XCTAssertEqual(NOOPWidgetDestination(url: destination.url), destination)
        }
        XCTAssertNil(NOOPWidgetDestination(url: URL(string: "https://example.com/widget/today")!))
        XCTAssertNil(NOOPWidgetDestination(url: URL(string: "noop://widget/not-a-page")!))
    }
}
