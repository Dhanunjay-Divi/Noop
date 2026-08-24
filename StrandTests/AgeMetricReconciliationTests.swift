import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class AgeMetricReconciliationTests: XCTestCase {
    private struct ExpectedReadFailure: Error {}

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
