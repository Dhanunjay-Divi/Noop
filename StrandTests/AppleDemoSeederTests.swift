#if DEBUG
import XCTest
import StrandAnalytics
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

    func testExistingFixtureRepairsAStaleActiveMinutesWeekIdempotently() async throws {
        let store = try await WhoopStore.inMemory()
        let staleDays = (1...7).map { day in
            DailyMetric(
                day: String(format: "2026-08-%02d", day),
                totalSleepMin: 420,
                efficiency: 90,
                deepMin: 80,
                remMin: 90,
                lightMin: 250,
                disturbances: 4,
                restingHr: 55,
                avgHrv: 70,
                recovery: 72,
                strain: Double(day * 8),
                exerciseCount: day.isMultiple(of: 2) ? 1 : 0
            )
        }
        try await store.upsertMetricSeries(
            AppleDemoSeeder.activeZoneFixturePoints(for: staleDays),
            deviceId: "\(AppleDemoSeeder.whoop)-noop"
        )

        var calendar = Calendar(identifier: .gregorian)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.timeZone = utc
        let now = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 31, hour: 12)
        ))
        let firstRepair = try await AppleDemoSeeder.repairActiveZoneFixtures(
            in: store,
            existingDays: staleDays,
            now: now,
            timeZone: utc
        )
        XCTAssertEqual(firstRepair, 28)

        let expectedDays = (25...31).map { String(format: "2026-08-%02d", $0) }
        for key in ActiveZoneMinutesCalculator.managedSeriesKeys {
            let rows = try await store.metricSeries(
                deviceId: "\(AppleDemoSeeder.whoop)-noop",
                key: key,
                from: expectedDays[0],
                to: expectedDays[6]
            )
            XCTAssertEqual(rows.map(\.day), expectedDays)
        }

        let secondRepair = try await AppleDemoSeeder.repairActiveZoneFixtures(
            in: store,
            existingDays: staleDays,
            now: now,
            timeZone: utc
        )
        XCTAssertEqual(secondRepair, 0)
    }
}
#endif
