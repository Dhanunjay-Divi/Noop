import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class AgeMetricReconciliationTests: XCTestCase {
    private struct ExpectedReadFailure: Error {}

    func testFitnessAgePresentationUsesNearestMonthWithoutDecimalMonthNotation() {
        XCTAssertEqual(
            FitnessAgePresentation.components(23.9),
            .init(totalMonths: 287, years: 23, months: 11)
        )
        XCTAssertEqual(
            FitnessAgePresentation.value(23 + 11.0 / 12.0),
            "23.11"
        )
        XCTAssertEqual(FitnessAgePresentation.value(23.75), "23.9")
        XCTAssertEqual(FitnessAgePresentation.spokenValue(23 + 11.0 / 12.0), "23 yr 11 mo")
        XCTAssertEqual(
            FitnessAgePresentation.comparison(estimate: 29.5, profileAge: 30),
            "6 mo younger than your profile age"
        )
        XCTAssertEqual(
            FitnessAgePresentation.weeklyProgress(current: 29.5, previous: 29.75),
            "3 mo younger this week"
        )
    }

    func testFocusedAgeAndWorkoutRevisionsAdvanceIndependently() {
        let repo = Repository(deviceId: "test-band")

        repo.noteAgeMetricsChanged()
        XCTAssertEqual(repo.ageMetricsSeq, 1)
        XCTAssertEqual(repo.workoutsSeq, 0)

        repo.noteWorkoutsChanged()
        XCTAssertEqual(repo.ageMetricsSeq, 1)
        XCTAssertEqual(repo.workoutsSeq, 1)
    }

    func testTrackedDayMetricsIncludesScaleAndUnknownValuesButHidesInternalMarkers() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-band")
        repo.setStoreForTesting(store)
        let day = "2026-08-27"

        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "weightKg", value: 72.4),
            MetricPoint(day: day, key: "heightCm", value: 181),
            MetricPoint(day: day, key: "custom_load", value: 4.25),
            MetricPoint(day: day, key: "device_profile_marker", value: 1),
        ], deviceId: "bluetooth-scale")
        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "cycle_phase_marker", value: 2),
        ], deviceId: "cycle-tracking")

        let metrics = await repo.trackedMetrics(day: day)
        let byKey = Dictionary(
            metrics.map { ($0.descriptor.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(byKey["weight"]?.value, 72.4)
        XCTAssertEqual(byKey["weight"]?.descriptor.unit, "kg")
        XCTAssertEqual(byKey["height"]?.value, 181)
        XCTAssertEqual(byKey["height"]?.descriptor.unit, "cm")
        XCTAssertEqual(
            byKey["height"]?.descriptor.format(
                181,
                system: .imperial,
                temperature: .fahrenheit
            ),
            "5′ 11″"
        )
        XCTAssertEqual(byKey["custom_load"]?.value, 4.25)
        XCTAssertNil(byKey["device_profile_marker"])
        XCTAssertNil(byKey["cycle_phase_marker"])
    }

    func testEmptyDailyHistoryIsSuccessfulRatherThanAReadFailure() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-band")
        repo.setStoreForTesting(store)

        let rows = try await repo.dailyMetricsForReconciliation(
            fromDay: "2026-08-01",
            toDay: "2026-08-24"
        )

        XCTAssertTrue(rows.isEmpty)
    }

    func testDailyHistoryFailureLeavesBothEnginePassesIncomplete() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test-band")
        repo.setStoreForTesting(store)
        repo.reconciliationDailyMetricsReaderForTesting = { _, _ in
            throw ExpectedReadFailure()
        }
        let profile = ProfileStore()
        let engine = IntelligenceEngine(
            repo: repo,
            profile: profile,
            deviceId: "test-band"
        )

        let fitness = await engine.recomputeFitnessAgeOutcome()
        let vitality = await engine.recomputeVitalityOutcome()

        XCTAssertEqual(fitness, .failed)
        XCTAssertEqual(vitality, .failed)
        XCTAssertFalse(fitness.completed)
        XCTAssertFalse(vitality.completed)
    }

    func testVitalityNoValueStillCompletesAfterSuccessfulCleanup() async throws {
        let store = try await WhoopStore.inMemory()

        let outcome = await IntelligenceEngine.reconcileVitalityV2Outcome(
            store: store,
            computedReadIds: ["test-band-noop"],
            writeId: "test-band-noop",
            days: [],
            age: 40,
            inputsUsable: true,
            saturdayKey: "2026-08-22"
        )

        XCTAssertEqual(outcome, .reconciled(wroteValue: false))
        XCTAssertTrue(outcome.completed)
    }
}
