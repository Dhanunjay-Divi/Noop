#if DEBUG
import XCTest
import WhoopStore
@testable import Strand

final class AppleDemoSeederTests: XCTestCase {
    func testLockedDemoFixtureWorkRequiresAnExplicitDebugLaunchArgument() {
        XCTAssertTrue(AppModel.shouldStartDemoFixtureWork(
            startOperationalWork: false,
            arguments: ["--demo-seed"]
        ))
        XCTAssertFalse(AppModel.shouldStartDemoFixtureWork(
            startOperationalWork: true,
            arguments: ["--demo-seed"]
        ))
        XCTAssertFalse(AppModel.shouldStartDemoFixtureWork(
            startOperationalWork: false,
            arguments: []
        ))
    }

    @MainActor
    func testLiveChargingFixtureDoesNotWaitForDatabaseSeed() {
        let live = LiveState()
        AppleDemoSeeder.applyLiveFixtureIfRequested(
            to: live,
            arguments: ["--demo-seed", "--demo-band-charging"]
        )

        XCTAssertTrue(live.connected)
        XCTAssertEqual(live.batteryPct, 68)
        XCTAssertEqual(live.charging, true)

        let inert = LiveState()
        AppleDemoSeeder.applyLiveFixtureIfRequested(
            to: inert,
            arguments: ["--demo-band-charging"]
        )
        XCTAssertFalse(inert.connected)
        XCTAssertNil(inert.batteryPct)
        XCTAssertNil(inert.charging)
    }

    func testExistingFixtureRepairsAgeMetricMarkersIdempotently() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-08", key: "fitness_age", value: 37),
            MetricPoint(day: "2026-08-15", key: "fitness_age", value: 36),
            MetricPoint(day: "2026-08-08", key: "vitality", value: 67),
            MetricPoint(day: "2026-08-15", key: "body_age", value: 28),
            MetricPoint(
                day: "2026-08-08",
                key: AgeMetricProfile.fitnessAgeKey,
                value: 999
            ),
            MetricPoint(
                day: "2026-08-08",
                key: AgeMetricProfile.vitalityKey,
                value: 999
            ),
        ], deviceId: AppleDemoSeeder.whoop)

        let firstRepair = try await AppleDemoSeeder.repairAgeMetricProfileMarkers(
            in: store,
            profileAge: 30,
            profileSex: "female"
        )
        XCTAssertEqual(firstRepair, 4)

        let fitnessMarkers = try await store.metricSeries(
            deviceId: AppleDemoSeeder.whoop,
            key: AgeMetricProfile.fitnessAgeKey,
            from: "0000-00-00",
            to: "9999-99-99"
        )
        XCTAssertEqual(fitnessMarkers.map(\.day), ["2026-08-08", "2026-08-15"])
        XCTAssertEqual(fitnessMarkers.map(\.value), [302, 302])

        let vitalityMarkers = try await store.metricSeries(
            deviceId: AppleDemoSeeder.whoop,
            key: AgeMetricProfile.vitalityKey,
            from: "0000-00-00",
            to: "9999-99-99"
        )
        XCTAssertEqual(vitalityMarkers.map(\.day), ["2026-08-08", "2026-08-15"])
        XCTAssertEqual(vitalityMarkers.map(\.value), [30, 30])

        let secondRepair = try await AppleDemoSeeder.repairAgeMetricProfileMarkers(
            in: store,
            profileAge: 30,
            profileSex: "female"
        )
        XCTAssertEqual(secondRepair, 0)
    }

    func testVitalityRepairDoesNotDependOnFitnessAgeProfileEligibility() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-15", key: "fitness_age", value: 36),
            MetricPoint(day: "2026-08-15", key: "vitality", value: 67),
            MetricPoint(
                day: "2026-08-15",
                key: AgeMetricProfile.vitalityKey,
                value: 999
            ),
        ], deviceId: AppleDemoSeeder.whoop)

        let repaired = try await AppleDemoSeeder.repairAgeMetricProfileMarkers(
            in: store,
            profileAge: 30,
            profileSex: "other"
        )
        XCTAssertEqual(repaired, 1)

        let vitalityMarkers = try await store.metricSeries(
            deviceId: AppleDemoSeeder.whoop,
            key: AgeMetricProfile.vitalityKey,
            from: "0000-00-00",
            to: "9999-99-99"
        )
        XCTAssertEqual(vitalityMarkers.map(\.value), [30])

        let fitnessMarkers = try await store.metricSeries(
            deviceId: AppleDemoSeeder.whoop,
            key: AgeMetricProfile.fitnessAgeKey,
            from: "0000-00-00",
            to: "9999-99-99"
        )
        XCTAssertTrue(fitnessMarkers.isEmpty)
    }
}
#endif
