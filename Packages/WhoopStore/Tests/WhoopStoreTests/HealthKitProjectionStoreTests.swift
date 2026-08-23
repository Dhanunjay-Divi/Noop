import XCTest
@testable import WhoopStore

final class HealthKitProjectionStoreTests: XCTestCase {
    func testStepDeletionReplacesOnlyOwnedFieldsAndCommitsAnchor() async throws {
        let store = try await WhoopStore.inMemory()
        let source = "apple-health"
        try await store.upsertAppleDaily([
            AppleDaily(day: "2026-01-01", steps: 1_000, activeKcal: 420, basalKcal: 1_600,
                       vo2max: 44, avgHr: 70, maxHr: 150, walkingHr: 88, weightKg: 75),
            AppleDaily(day: "2026-01-02", steps: 2_000, activeKcal: 430, basalKcal: nil,
                       vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil),
        ], deviceId: source)
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-01-01", totalSleepMin: 450, efficiency: 0.9,
                        deepMin: 80, remMin: 100, lightMin: 270, disturbances: 3,
                        restingHr: 51, avgHrv: 62, recovery: 80, strain: 9,
                        exerciseCount: 1, spo2Pct: 98, respRateBpm: 14, steps: 1_000),
            DailyMetric(day: "2026-01-02", totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                        restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                        exerciseCount: nil, steps: 2_000),
        ], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-01", key: "steps", value: 1_000),
            MetricPoint(day: "2026-01-01", key: "active_kcal", value: 420),
            MetricPoint(day: "2026-01-02", key: "steps", value: 2_000),
        ], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-01", key: "steps", value: 99),
        ], deviceId: "my-whoop")

        let anchor = Data([0x01, 0x02, 0x03])
        try await store.reconcileHealthKitProjection(
            kind: .steps,
            sampleType: "HKQuantityTypeIdentifierStepCount",
            anchor: anchor,
            deviceId: source,
            fromDay: "2026-01-01",
            toDay: "2026-01-02",
            fromTs: 0,
            toTs: Int.max,
            appleRows: [
                AppleDaily(day: "2026-01-02", steps: 2_500, activeKcal: nil, basalKcal: nil,
                           vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil),
            ],
            dailyRows: [
                DailyMetric(day: "2026-01-02", totalSleepMin: nil, efficiency: nil,
                            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                            restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                            exerciseCount: nil, steps: 2_500),
            ],
            metricPoints: [MetricPoint(day: "2026-01-02", key: "steps", value: 2_500)],
            workouts: []
        )

        let apple = try await store.appleDaily(deviceId: source, from: "2026-01-01", to: "2026-01-02")
        XCTAssertEqual(apple.first(where: { $0.day == "2026-01-01" })?.steps, nil)
        XCTAssertEqual(apple.first(where: { $0.day == "2026-01-01" })?.activeKcal, 420)
        XCTAssertEqual(apple.first(where: { $0.day == "2026-01-02" })?.steps, 2_500)

        let daily = try await store.dailyMetrics(deviceId: source, from: "2026-01-01", to: "2026-01-02")
        XCTAssertEqual(daily.first(where: { $0.day == "2026-01-01" })?.steps, nil)
        XCTAssertEqual(daily.first(where: { $0.day == "2026-01-01" })?.recovery, 80)
        XCTAssertEqual(daily.first(where: { $0.day == "2026-01-02" })?.steps, 2_500)

        let steps = try await store.metricSeries(deviceId: source, key: "steps",
                                                 from: "2026-01-01", to: "2026-01-02")
        XCTAssertEqual(steps, [MetricPoint(day: "2026-01-02", key: "steps", value: 2_500)])
        let active = try await store.metricSeries(deviceId: source, key: "active_kcal",
                                                  from: "2026-01-01", to: "2026-01-02")
        XCTAssertEqual(active.count, 1)
        let whoopSteps = try await store.metricSeries(deviceId: "my-whoop", key: "steps",
                                                      from: "2026-01-01", to: "2026-01-02")
        XCTAssertEqual(whoopSteps.count, 1)
        let storedAnchor = try await store.healthKitAnchor(
            sampleType: "HKQuantityTypeIdentifierStepCount"
        )
        XCTAssertEqual(storedAnchor, anchor)
    }

    func testDeletingLastOwnedValueRemovesOnlyEmptyShell() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertAppleDaily([
            AppleDaily(day: "2026-01-01", steps: 100, activeKcal: nil, basalKcal: nil,
                       vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil),
        ], deviceId: "apple-health")

        try await store.reconcileHealthKitProjection(
            kind: .steps, sampleType: "steps", anchor: Data([9]), deviceId: "apple-health",
            fromDay: "2026-01-01", toDay: "2026-01-01", fromTs: 0, toTs: 1,
            appleRows: [], dailyRows: [], metricPoints: [], workouts: []
        )

        let remaining = try await store.appleDaily(
            deviceId: "apple-health",
            from: "2026-01-01",
            to: "2026-01-01"
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testHydrationDeletionRebuildsOnlyAppleHealthWaterAndCommitsAnchor() async throws {
        let store = try await WhoopStore.inMemory()
        let source = "apple-health"
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-01", key: "hydration", value: 1_400),
            MetricPoint(day: "2026-01-02", key: "hydration", value: 900),
            MetricPoint(day: "2026-01-01", key: "active_kcal", value: 420),
        ], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-01-01", key: "hydration", value: 1_100),
        ], deviceId: "hydration")

        let anchor = Data([0x48, 0x32, 0x4F])
        try await store.reconcileHealthKitProjection(
            kind: .hydration,
            sampleType: "HKQuantityTypeIdentifierDietaryWater",
            anchor: anchor,
            deviceId: source,
            fromDay: "2026-01-01",
            toDay: "2026-01-02",
            fromTs: 0,
            toTs: Int.max,
            appleRows: [],
            dailyRows: [],
            metricPoints: [
                MetricPoint(day: "2026-01-02", key: "hydration", value: 650),
            ],
            workouts: []
        )

        let appleWater = try await store.metricSeries(
            deviceId: source,
            key: "hydration",
            from: "2026-01-01",
            to: "2026-01-02"
        )
        XCTAssertEqual(
            appleWater,
            [MetricPoint(day: "2026-01-02", key: "hydration", value: 650)]
        )
        let appleEnergy = try await store.metricSeries(
            deviceId: source,
            key: "active_kcal",
            from: "2026-01-01",
            to: "2026-01-02"
        )
        XCTAssertEqual(appleEnergy.count, 1)
        let noopWater = try await store.metricSeries(
            deviceId: "hydration",
            key: "hydration",
            from: "2026-01-01",
            to: "2026-01-02"
        )
        XCTAssertEqual(noopWater.first?.value, 1_100)
        let storedAnchor = try await store.healthKitAnchor(
            sampleType: "HKQuantityTypeIdentifierDietaryWater"
        )
        XCTAssertEqual(storedAnchor, anchor)
    }

    func testWorkoutReconcileRemovesDeletedSessionAndKeepsOtherSources() async throws {
        let store = try await WhoopStore.inMemory()
        let deleted = WorkoutRow(startTs: 100, endTs: 200, sport: "running", source: "apple-health",
                                 durationS: 100, energyKcal: 10, avgHr: 120, maxHr: 140,
                                 strain: nil, distanceM: 500, zonesJSON: nil, notes: nil)
        let current = WorkoutRow(startTs: 300, endTs: 500, sport: "cycling", source: "apple-health",
                                 durationS: 200, energyKcal: 20, avgHr: 110, maxHr: 130,
                                 strain: nil, distanceM: 1_000, zonesJSON: nil, notes: nil)
        let manual = WorkoutRow(startTs: 150, endTs: 250, sport: "lifting", source: "manual",
                                durationS: 100, energyKcal: nil, avgHr: nil, maxHr: nil,
                                strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        let boundary = WorkoutRow(startTs: 1_000, endTs: 1_100, sport: "walking",
                                  source: "apple-health", durationS: 100, energyKcal: nil,
                                  avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                  zonesJSON: nil, notes: nil)
        try await store.upsertWorkouts([deleted, current, manual, boundary], deviceId: "apple-health")

        try await store.reconcileHealthKitProjection(
            kind: .workout, sampleType: "HKWorkoutTypeIdentifier", anchor: Data([7]),
            deviceId: "apple-health", fromDay: "1970-01-01", toDay: "1970-01-02",
            fromTs: 0, toTs: 1_000, appleRows: [], dailyRows: [], metricPoints: [], workouts: [current]
        )

        let rows = try await store.workouts(deviceId: "apple-health", from: 0, to: 2_000, limit: 20)
        XCTAssertFalse(rows.contains(where: { $0.startTs == deleted.startTs }))
        XCTAssertTrue(rows.contains(where: { $0.startTs == current.startTs }))
        XCTAssertTrue(rows.contains(where: { $0.startTs == manual.startTs }))
        XCTAssertTrue(rows.contains(where: { $0.startTs == boundary.startTs }),
                      "The exclusive end boundary belongs to the next reconciliation window.")
    }
}
