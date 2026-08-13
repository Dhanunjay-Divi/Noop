import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testWidgetAppearanceUsesTheAppStorageContract() {
        XCTAssertEqual(WidgetAppearancePreference.storageKey, "theme.appearance")
    }

    func testWidgetSupportingMetricDefaultsAreUsefulAndUnique() {
        XCTAssertEqual(WidgetMetricPreference.defaultSelection,
                       [.heartRate, .sleepDuration, .deviceBattery])
        XCTAssertEqual(Set(WidgetMetricPreference.defaultSelection.map(\.rawValue)).count,
                       WidgetMetricPreference.slotCount)
    }

    func testWidgetSupportingMetricsRepairDuplicatesAndUnknownValues() {
        let repaired = WidgetMetricPreference.normalized([
            WidgetMetric.hrv.rawValue,
            WidgetMetric.hrv.rawValue,
            "retiredMetric",
            WidgetMetric.restingHeartRate.rawValue
        ])
        XCTAssertEqual(repaired, [.hrv, .restingHeartRate, .heartRate])
        XCTAssertEqual(repaired.count, WidgetMetricPreference.slotCount)
    }

    func testWidgetSupportingMetricPreferenceRoundTrips() {
        let suite = "WidgetSnapshotTests.metrics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let selection: [WidgetMetric] = [.hrv, .restingHeartRate, .sleepDuration]
        WidgetMetricPreference.save(selection, defaults: defaults)

        XCTAssertEqual(WidgetMetricPreference.load(defaults: defaults), selection)
        XCTAssertEqual(defaults.stringArray(forKey: WidgetMetricPreference.storageKey),
                       selection.map(\.rawValue))
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
        XCTAssertNil(WidgetSnapshot.unavailable.heartRateObservedAt)
        XCTAssertNil(WidgetSnapshot.unavailable.scoreDay)
    }

    func testOlderSnapshotDecodesWithoutInventingNewState() throws {
        let oldJSON = #"{"recovery":72,"bpm":58,"batteryPct":84,"bonded":true,"updated":0}"#
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(oldJSON.utf8))

        XCTAssertEqual(snapshot.recovery, 72)
        XCTAssertTrue(snapshot.bonded)
        XCTAssertNil(snapshot.connected, "Pairing must never be upgraded to a live connection")
        XCTAssertNil(snapshot.heartRateObservedAt,
                     "An older snapshot must never invent a heart-rate observation time")
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

    func testLiveHeartRateUsesActualSampleTimeNotPublicationTime() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = WidgetSnapshot.placeholder
        snapshot.updated = now
        snapshot.heartRateObservedAt = now.addingTimeInterval(-30)

        XCTAssertTrue(snapshot.hasCurrentConnection(at: now))
        XCTAssertTrue(snapshot.hasLiveHeartRate(at: now))
        XCTAssertEqual(snapshot.heartRateFreshness(at: now), .current)

        snapshot.heartRateObservedAt = now.addingTimeInterval(
            -(WidgetSnapshot.liveHeartRateMaxAge + 1))
        XCTAssertTrue(snapshot.hasCurrentConnection(at: now),
                      "The connection observation remains distinct from HR freshness")
        XCTAssertFalse(snapshot.hasLiveHeartRate(at: now),
                       "Republishing now must not renew an old physiological sample")
        XCTAssertEqual(snapshot.heartRateFreshness(at: now), .recent)
    }

    func testLiveHeartRateRequiresTimestampValueAndCurrentConnection() {
        let now = Date(timeIntervalSince1970: 10_000)
        var snapshot = WidgetSnapshot.placeholder
        snapshot.updated = now
        snapshot.heartRateObservedAt = nil
        XCTAssertFalse(snapshot.hasLiveHeartRate(at: now))
        XCTAssertEqual(snapshot.heartRateFreshness(at: now), .unavailable)

        snapshot.heartRateObservedAt = now
        snapshot.bpm = nil
        XCTAssertFalse(snapshot.hasLiveHeartRate(at: now))
        XCTAssertEqual(snapshot.heartRateFreshness(at: now), .unavailable)

        snapshot.bpm = 60
        snapshot.connected = false
        XCTAssertFalse(snapshot.hasLiveHeartRate(at: now))

        snapshot.connected = true
        snapshot.updated = now.addingTimeInterval(-21 * 60)
        XCTAssertFalse(snapshot.hasLiveHeartRate(at: now),
                       "A stale saved connection bit must not imply a live wearable")
    }

    func testLiveHeartRateExpiryIsAnchoredToSampleObservation() {
        let observed = Date(timeIntervalSince1970: 10_000)
        var snapshot = WidgetSnapshot.placeholder
        snapshot.updated = observed.addingTimeInterval(60)
        snapshot.heartRateObservedAt = observed

        XCTAssertEqual(snapshot.liveHeartRateExpiresAt,
                       observed.addingTimeInterval(WidgetSnapshot.liveHeartRateMaxAge))
    }

    func testWidgetDestinationURLsRoundTrip() {
        for destination in NOOPWidgetDestination.allCases {
            XCTAssertEqual(NOOPWidgetDestination(url: destination.url), destination)
        }
        XCTAssertNil(NOOPWidgetDestination(url: URL(string: "https://example.com/widget/today")!))
        XCTAssertNil(NOOPWidgetDestination(url: URL(string: "noop://widget/not-a-page")!))
    }
}
