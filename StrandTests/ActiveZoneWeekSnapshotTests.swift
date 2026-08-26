import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

final class ActiveZoneWeekSnapshotTests: XCTestCase {
    func testResolveUsesOnlyCompleteIncludedDays() {
        let days: Set<String> = ["2026-08-25", "2026-08-26"]
        let result = ActiveZoneWeekSnapshot.resolve(
            moderate: [
                ("2026-08-25", 30),
                ("2026-08-26", 0),
                ("2026-08-19", 999)
            ],
            vigorous: [
                ("2026-08-25", 15),
                ("2026-08-26", 0)
            ],
            observed: [
                ("2026-08-25", 600),
                ("2026-08-26", 720)
            ],
            includedDays: days)

        XCTAssertEqual(result?.daysWithData, 2)
        XCTAssertEqual(result?.minutes.moderateMinutes, 30)
        XCTAssertEqual(result?.minutes.vigorousMinutes, 15)
        XCTAssertEqual(result?.minutes.creditedMinutes, 60)
        XCTAssertEqual(result?.minutes.observedMinutes, 1_320)
    }

    func testResolveDoesNotTurnPartialOrMissingRowsIntoZero() {
        XCTAssertNil(ActiveZoneWeekSnapshot.resolve(
            moderate: [("2026-08-26", 0)],
            vigorous: [],
            observed: [("2026-08-26", 600)],
            includedDays: ["2026-08-26"]))
        XCTAssertNil(ActiveZoneWeekSnapshot.resolve(
            moderate: [],
            vigorous: [],
            observed: [],
            includedDays: ["2026-08-26"]))
    }

    @MainActor
    func testDaytimeActivityPersistsWhenNightIsBelowSleepSampleGate() async throws {
        let defaults = UserDefaults.standard
        let watermarkKey = "noop.analyzeWatermark"
        let priorWatermark = defaults.object(forKey: watermarkKey)
        defaults.removeObject(forKey: watermarkKey)
        defer {
            if let priorWatermark {
                defaults.set(priorWatermark, forKey: watermarkKey)
            } else {
                defaults.removeObject(forKey: watermarkKey)
            }
        }

        let store = try await WhoopStore.inMemory()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let activityStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: yesterday))
        let start = Int(activityStart.timeIntervalSince1970)
        let samples = (0...120).map { HRSample(ts: start + $0, bpm: 200) }
        _ = try await store.insert(Streams(hr: samples), deviceId: "my-whoop")

        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo,
            profile: ProfileStore(),
            deviceId: "my-whoop")

        let receipt = await engine.analyzeRecent(maxDays: 2, force: true)
        XCTAssertNotNil(receipt)

        let observed = try await store.metricSeries(
            deviceId: "my-whoop-noop",
            key: ActiveZoneMinutesCalculator.observedSeriesKey,
            from: "0000-01-01",
            to: "9999-12-31")
        let vigorous = try await store.metricSeries(
            deviceId: "my-whoop-noop",
            key: ActiveZoneMinutesCalculator.vigorousSeriesKey,
            from: "0000-01-01",
            to: "9999-12-31")

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.value ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(vigorous.first?.value ?? 0, 2, accuracy: 0.001)
        XCTAssertTrue(engine.results.isEmpty, "121 daytime samples must not be promoted to a sleep-scored day")
    }

    func testActiveZoneUpgradeForcesOneBoundedBackfill() {
        XCTAssertEqual(ActiveZoneUpgradeGate.currentRevision, "noop-active-zone-v1")
        XCTAssertEqual(ActiveZoneUpgradeGate.historyDays, 21)
        XCTAssertTrue(ActiveZoneUpgradeGate.needsRescore(completedRevision: nil))
        XCTAssertFalse(ActiveZoneUpgradeGate.needsRescore(
            completedRevision: "noop-active-zone-v1"))
        XCTAssertNil(ActiveZoneUpgradeGate.revisionToPersist(
            passCompleted: false,
            wasRequired: true))
        XCTAssertEqual(
            ActiveZoneUpgradeGate.revisionToPersist(
                passCompleted: true,
                wasRequired: true),
            "noop-active-zone-v1")
    }

    func testPersistedDemoFixtureCanAddActiveZoneSeriesWithoutRawHr() {
        let days = [
            DailyMetric(
                day: "2026-08-25",
                totalSleepMin: 430,
                efficiency: 90,
                deepMin: 80,
                remMin: 95,
                lightMin: 255,
                disturbances: 4,
                restingHr: 55,
                avgHrv: 72,
                recovery: 74,
                strain: 68,
                exerciseCount: 1),
            DailyMetric(
                day: "2026-08-26",
                totalSleepMin: 420,
                efficiency: 88,
                deepMin: 75,
                remMin: 90,
                lightMin: 255,
                disturbances: 5,
                restingHr: 57,
                avgHrv: 68,
                recovery: 66,
                strain: 28,
                exerciseCount: 0)
        ]

        let points = AppleDemoSeeder.activeZoneFixturePoints(for: days)
        XCTAssertEqual(points.count, 8)
        XCTAssertEqual(Set(points.map(\.day)), Set(days.map(\.day)))
        XCTAssertEqual(Set(points.map(\.key)), ActiveZoneMinutesCalculator.managedSeriesKeys)
        XCTAssertTrue(points.allSatisfy { $0.value.isFinite && $0.value >= 0 })
    }
}
