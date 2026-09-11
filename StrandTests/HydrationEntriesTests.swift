import XCTest
import WhoopStore
@testable import Strand

/// #798 - the per-entry hydration list (add / delete / edit / total). The day total banked into
/// `metricSeries` is always re-derived from this list, so the math here is the source of truth for an
/// edited day. These pin: a non-positive amount never enters the list, deleting/editing keeps the total
/// non-negative and self-consistent, and an edit to 0 is a delete (no zero rows linger).
@MainActor
final class HydrationEntriesTests: XCTestCase {

    private func entry(_ ml: Int, secondsAgo: TimeInterval = 0) -> HydrationEntry {
        HydrationEntry(amountMl: ml, loggedAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo))
    }

    // MARK: - adding

    func testAddingAppendsPositiveAmount() {
        let out = HydrationEntries.adding([], amountMl: 237)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.amountMl, 237)
    }

    func testAddingRejectsNonPositive() {
        XCTAssertTrue(HydrationEntries.adding([], amountMl: 0).isEmpty)
        XCTAssertTrue(HydrationEntries.adding([], amountMl: -50).isEmpty)
    }

    // MARK: - total

    func testTotalSumsAmounts() {
        let list = [entry(30), entry(237), entry(500)]
        XCTAssertEqual(HydrationEntries.total(list), 767, accuracy: 0.0001)
    }

    func testTotalOfEmptyIsZero() {
        XCTAssertEqual(HydrationEntries.total([]), 0, accuracy: 0.0001)
    }

    func testDisplayPolicyKeepsMissingAndClearedTotalsUnlogged() {
        XCTAssertNil(HydrationStore.confirmedTotal(nil))
        XCTAssertNil(HydrationStore.confirmedTotal(0))
        XCTAssertNil(HydrationStore.confirmedTotal(-1))
        XCTAssertNil(HydrationStore.confirmedTotal(.nan))
        XCTAssertEqual(
            HydrationStore.cardValue(totalML: nil, goalML: 3_200, missingText: "Not logged"),
            "Not logged"
        )
        XCTAssertEqual(
            HydrationStore.cardValue(totalML: 1_200, goalML: 3_200, missingText: "Not logged"),
            "1.2 / 3.2 L"
        )
    }

    // MARK: - removing

    func testRemovingDropsTheTargetAndRederivesTotal() {
        let a = entry(30), b = entry(500)
        let after = HydrationEntries.removing([a, b], id: a.id)
        XCTAssertEqual(after.map(\.id), [b.id])
        XCTAssertEqual(HydrationEntries.total(after), 500, accuracy: 0.0001)
    }

    func testRemovingUnknownIdIsNoOp() {
        let a = entry(30)
        let after = HydrationEntries.removing([a], id: UUID())
        XCTAssertEqual(after.map(\.id), [a.id])
    }

    // MARK: - updating

    func testUpdatingSetsNewAmountAndKeepsIdentity() {
        let a = entry(30)
        let after = HydrationEntries.updating([a], id: a.id, amountMl: 250)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, a.id)              // identity preserved
        XCTAssertEqual(after.first?.amountMl, 250)
        XCTAssertEqual(after.first?.loggedAt, a.loggedAt)  // timestamp preserved
    }

    func testUpdatingToNonPositiveDeletesTheEntry() {
        let a = entry(30), b = entry(500)
        let after = HydrationEntries.updating([a, b], id: a.id, amountMl: 0)
        XCTAssertEqual(after.map(\.id), [b.id])
        XCTAssertEqual(HydrationEntries.total(after), 500, accuracy: 0.0001)
    }

    func testUpdatingUnknownIdIsNoOp() {
        let a = entry(30)
        let after = HydrationEntries.updating([a], id: UUID(), amountMl: 999)
        XCTAssertEqual(after.first?.amountMl, 30)
    }

    // MARK: - Persistence integrity

    func testConcurrentAddsPreserveEveryIncrementAndEntry() async throws {
        let day = "2098-01-01"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()

        async let first = repo.logHydration(amountMl: 237, day: day)
        async let second = repo.logHydration(amountMl: 500, day: day)
        let results = await (first, second)

        XCTAssertTrue(results.0.succeeded)
        XCTAssertTrue(results.1.succeeded)
        let rows = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(rows.first?.value), 737, accuracy: 0.0001)
        let amounts = try await repo.hydrationEntries(day: day).map(\.amountMl).sorted()
        XCTAssertEqual(amounts, [237, 500])
        XCTAssertEqual(repo.hydrationSeq, 2)
    }

    func testFailedMutationsLeaveCanonicalEntriesAndRevisionUnchanged() async throws {
        let day = "2098-01-02"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        let seeded = await repo.logHydration(amountMl: 237, day: day)
        XCTAssertTrue(seeded.succeeded)
        let originalEntries = try await repo.hydrationEntries(day: day)
        let originalRevision = repo.hydrationSeq
        let entry = try XCTUnwrap(originalEntries.first)
        repo.setHydrationFailureForTesting(writes: true)

        let added = await repo.logHydration(amountMl: 500, day: day)
        let updated = await repo.updateHydrationEntry(
            id: entry.id,
            amountMl: 300,
            day: day
        )
        let deleted = await repo.deleteHydrationEntry(id: entry.id, day: day)

        XCTAssertFalse(added.succeeded)
        XCTAssertFalse(updated.succeeded)
        XCTAssertFalse(deleted.succeeded)
        let persistedEntries = try await repo.hydrationEntries(day: day)
        XCTAssertEqual(persistedEntries, originalEntries)
        XCTAssertEqual(repo.hydrationSeq, originalRevision)
        repo.setHydrationFailureForTesting()
        let rows = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(rows.first?.value), 237, accuracy: 0.0001)
    }

    func testDeletingLastEntryIsSuccessfulAndBanksCanonicalZero() async throws {
        let day = "2098-01-03"
        clearEntries(day: day)
        defer { clearEntries(day: day) }
        let (repo, store) = try await makeRepository()
        let seeded = await repo.logHydration(amountMl: 237, day: day)
        XCTAssertTrue(seeded.succeeded)
        let seededEntries = try await repo.hydrationEntries(day: day)
        let entry = try XCTUnwrap(seededEntries.first)

        let result = await repo.deleteHydrationEntry(id: entry.id, day: day)

        XCTAssertEqual(result, .saved(totalML: nil))
        let persistedEntries = try await repo.hydrationEntries(day: day)
        XCTAssertTrue(persistedEntries.isEmpty)
        let rows = try await store.metricSeries(
            deviceId: HydrationStore.sourceId,
            key: HydrationStore.key,
            from: day,
            to: day
        )
        XCTAssertEqual(try XCTUnwrap(rows.first?.value), 0, accuracy: 0.0001)
        XCTAssertEqual(repo.hydrationSeq, 2)
    }

    func testReadFailureDoesNotMasqueradeAsMissingIntake() async throws {
        let (repo, _) = try await makeRepository()
        repo.setHydrationFailureForTesting(reads: true)

        do {
            _ = try await repo.hydrationTotal(day: "2098-01-04")
            XCTFail("Expected the broken local store read to throw")
        } catch {
            XCTAssertTrue(true)
        }
    }

    private func makeRepository() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "hydration-test", mac: nil, name: "Test")
        let repo = Repository(deviceId: "hydration-test")
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    private func clearEntries(day: String) {
        UserDefaults.standard.removeObject(
            forKey: HydrationStore.entriesKey(forDay: day)
        )
    }
}
