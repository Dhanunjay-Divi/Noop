#if DEBUG
import XCTest
import WhoopStore
@testable import Strand

final class AppleDemoSeederTests: XCTestCase {
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

    func testExistingFixtureRepairsFitnessAgeV2MarkersIdempotently() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-08", key: "fitness_age", value: 37),
            MetricPoint(day: "2026-08-15", key: "fitness_age", value: 36),
            MetricPoint(
                day: "2026-08-08",
                key: AgeMetricProfile.fitnessAgeKey,
                value: 999
            ),
        ], deviceId: AppleDemoSeeder.whoop)

        let firstRepair = try await AppleDemoSeeder.repairFitnessAgeProfileMarkers(
            in: store,
            profileAge: 30,
            profileSex: "female"
        )
        XCTAssertEqual(firstRepair, 2)

        let markers = try await store.metricSeries(
            deviceId: AppleDemoSeeder.whoop,
            key: AgeMetricProfile.fitnessAgeKey,
            from: "0000-00-00",
            to: "9999-99-99"
        )
        XCTAssertEqual(markers.map(\.day), ["2026-08-08", "2026-08-15"])
        XCTAssertEqual(markers.map(\.value), [302, 302])

        let secondRepair = try await AppleDemoSeeder.repairFitnessAgeProfileMarkers(
            in: store,
            profileAge: 30,
            profileSex: "female"
        )
        XCTAssertEqual(secondRepair, 0)
    }
}
#endif
