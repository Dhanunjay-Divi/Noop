import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class CycleTrackingStoreTests: XCTestCase {
    private func makeRepository() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "cycle-test", mac: nil, name: "Test")
        let repo = Repository(deviceId: "cycle-test")
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    func testManualAnchorWinsPresentationWithoutOverwritingImportedProvenance() async throws {
        let (repo, store) = try await makeRepository()
        let reconciled = await repo.reconcileAppleHealthPeriodStarts(
            days: ["2026-06-03", "2026-07-01"])
        let logged = await repo.logPeriodStart(day: "2026-07-01")
        XCTAssertTrue(reconciled)
        XCTAssertTrue(logged)

        let entries = await repo.periodStartEntries()
        XCTAssertEqual(entries, [
            .init(day: "2026-06-03", source: .appleHealth),
            .init(day: "2026-07-01", source: .manual),
        ])

        // Both physical rows remain: the manual presentation win is not destructive.
        let imported = try await store.metricSeries(
            deviceId: CycleTrackingStore.appleHealthSourceId,
            key: CycleTrackingStore.periodStartKey,
            from: CycleTrackingStore.earliestDay,
            to: CycleTrackingStore.latestDay)
        XCTAssertEqual(imported.map(\.day), ["2026-06-03", "2026-07-01"])
    }

    func testAppleHealthReconciliationIsIdempotentAndRemovesOnlyStaleImportedDates() async throws {
        let (repo, _) = try await makeRepository()
        let logged = await repo.logPeriodStart(day: "2026-05-09")
        let first = await repo.reconcileAppleHealthPeriodStarts(
            days: ["2026-05-09", "2026-06-06"])
        let second = await repo.reconcileAppleHealthPeriodStarts(
            days: ["2026-06-06", "2026-07-04"])
        let repeated = await repo.reconcileAppleHealthPeriodStarts(
            days: ["2026-06-06", "2026-07-04"])
        XCTAssertTrue(logged)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertTrue(repeated, "same set is an idempotent success")

        let entries = await repo.periodStartEntries()
        XCTAssertEqual(entries, [
            .init(day: "2026-05-09", source: .manual),
            .init(day: "2026-06-06", source: .appleHealth),
            .init(day: "2026-07-04", source: .appleHealth),
        ])
    }

    func testManualDeletionNeverDeletesAppleHealthAnchorAndPurgeDoesTheInverse() async throws {
        let (repo, _) = try await makeRepository()
        let logged = await repo.logPeriodStart(day: "2026-07-01")
        let reconciled = await repo.reconcileAppleHealthPeriodStarts(days: ["2026-07-01"])
        XCTAssertTrue(logged)
        XCTAssertTrue(reconciled)

        let deletedManual = await repo.deleteAllPeriodStarts()
        let afterManualDelete = await repo.periodStartEntries()
        XCTAssertTrue(deletedManual)
        XCTAssertEqual(afterManualDelete, [
            .init(day: "2026-07-01", source: .appleHealth),
        ])

        let deletedApple = await repo.deleteAllAppleHealthPeriodStarts()
        let afterAppleDelete = await repo.periodStartEntries()
        XCTAssertTrue(deletedApple)
        XCTAssertEqual(afterAppleDelete, [])
    }

    func testReconciliationRejectsMalformedOrOutOfRangeDaysWithoutMutation() async throws {
        let (repo, _) = try await makeRepository()
        let seeded = await repo.reconcileAppleHealthPeriodStarts(days: ["2026-06-01"])
        let malformed = await repo.reconcileAppleHealthPeriodStarts(days: ["../../secret"])
        let outOfRange = await repo.reconcileAppleHealthPeriodStarts(
            days: ["2026-06-01"], from: "2026-07-01", to: "2026-07-31")
        let starts = await repo.periodStarts()
        XCTAssertTrue(seeded)
        XCTAssertFalse(malformed)
        XCTAssertFalse(outOfRange)
        XCTAssertEqual(starts, ["2026-06-01"])
    }
}
