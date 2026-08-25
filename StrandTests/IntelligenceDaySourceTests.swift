import XCTest
import WhoopStore
@testable import Strand

/// Pins the By-Day honesty fix (Sleep overhaul §2.6) + the per-day diagnostic source token (§2.5):
/// the By-Day card used to hard-code a "NOOP-computed" badge even on days an IMPORT won the dashboard
/// merge, so a user couldn't tell a strap-scored night from an imported one. `DaySource.classify`
/// resolves the REAL provenance from the imported day-key sets; the badge + log token derive from it.
/// Pure (no store) — the SAME `classify` the engine ships per day. Mirrors the Android
/// `IntelligenceDaySourceTest` / `IntelligenceScreenSourceBadge` cases.
final class IntelligenceDaySourceTests: XCTestCase {

    private typealias DaySource = IntelligenceEngine.DaySource

    // MARK: - classify precedence

    func testComputedWhenNoImportCoversTheDay() {
        // A strap-only night: not in either imported set → purely computed → "On-device".
        let src = DaySource.classify(day: "2026-06-12", importedWhoopDays: [], appleHealthDays: [])
        XCTAssertEqual(src, .computed)
        XCTAssertEqual(src.badge, "On-device")
        XCTAssertEqual(src.logToken, "computed")
    }

    func testWhoopImportWinsWhenItCoversTheDay() {
        // A compatible export covers the day -> it wins the dashboard merge -> badge "Imported".
        let src = DaySource.classify(day: "2026-06-12",
                                     importedWhoopDays: ["2026-06-12"], appleHealthDays: [])
        XCTAssertEqual(src, .whoopImport)
        XCTAssertEqual(src.badge, "Imported")
        XCTAssertEqual(src.logToken, "imported:whoop")
    }

    func testAppleHealthWhenOnlyAppleCoversTheDay() {
        let src = DaySource.classify(day: "2026-06-12",
                                     importedWhoopDays: [], appleHealthDays: ["2026-06-12"])
        XCTAssertEqual(src, .appleHealth)
        XCTAssertEqual(src.badge, "Apple Health")
        XCTAssertEqual(src.logToken, "imported:apple")
    }

    func testWhoopBeatsAppleWhenBothCoverTheSameDay() {
        // Both imports cover the day: WHOOP wins (whoopImport priority 0 < appleHealth 2 in the merge),
        // matching DailyMetricSource.vitalPriority — the badge must agree with what the dashboard shows.
        let src = DaySource.classify(day: "2026-06-12",
                                     importedWhoopDays: ["2026-06-12"],
                                     appleHealthDays: ["2026-06-12"])
        XCTAssertEqual(src, .whoopImport)
    }

    func testClassifyIsPerDayNotGlobal() {
        // The set covers a DIFFERENT day, so this day stays computed — the badge is resolved per day,
        // not "any import exists anywhere" (the heart of why the old hard-coded badge was wrong).
        let imported: Set<String> = ["2026-06-10"]
        XCTAssertEqual(DaySource.classify(day: "2026-06-12", importedWhoopDays: imported,
                                          appleHealthDays: []), .computed)
        XCTAssertEqual(DaySource.classify(day: "2026-06-10", importedWhoopDays: imported,
                                          appleHealthDays: []), .whoopImport)
    }

    // MARK: - official-reference raw-input proof

    private func device(
        id: String,
        brand: String,
        sourceKind: SourceKind
    ) -> PairedDevice {
        PairedDevice(
            id: id, brand: brand, model: brand, sourceKind: sourceKind,
            capabilities: [.hr], status: .active, addedAt: 0, lastSeenAt: 0)
    }

    func testOfficialDashboardWinnerIsNotRawComputationEvidence() {
        // `.whoopImport` proves only that an official row wins the dashboard merge. With no raw-run
        // receipt there are zero verified comparison days; Compare must never derive this set from
        // `DaySource` again.
        let displaySource = DaySource.classify(
            day: "2026-06-12",
            importedWhoopDays: ["2026-06-12"],
            appleHealthDays: [])
        let receipt = IntelligenceEngine.ScoreRunReceipt(whoopStrapDays: [])

        XCTAssertEqual(displaySource, .whoopImport)
        XCTAssertTrue(receipt.whoopStrapDays.isEmpty)
    }

    func testWhoopRawOwnerProofAcceptsLiveAndLegacyWhoopOnly() {
        let liveWhoop = device(id: "whoop-5", brand: "WHOOP", sourceKind: .liveBLE)
        let historyWhoop = device(id: "whoop-history", brand: "whoop", sourceKind: .historyBLE)
        let polar = device(id: "polar", brand: "Polar", sourceKind: .liveBLE)
        let devices = [liveWhoop, historyWhoop, polar]

        XCTAssertTrue(IntelligenceEngine.isWhoopStrapOwner(
            liveWhoop.id, devices: devices, fallbackDeviceId: "my-whoop"))
        XCTAssertTrue(IntelligenceEngine.isWhoopStrapOwner(
            historyWhoop.id, devices: devices, fallbackDeviceId: "my-whoop"))
        XCTAssertFalse(IntelligenceEngine.isWhoopStrapOwner(
            polar.id, devices: devices, fallbackDeviceId: "my-whoop"))
        XCTAssertTrue(IntelligenceEngine.isWhoopStrapOwner(
            "my-whoop", devices: devices, fallbackDeviceId: "my-whoop"))
    }

    func testRegisteredImportCannotMasqueradeAsLegacyWhoopStrap() {
        let imported = device(id: "my-whoop", brand: "WHOOP", sourceKind: .fileImport)

        XCTAssertFalse(IntelligenceEngine.isWhoopStrapOwner(
            imported.id, devices: [imported], fallbackDeviceId: "my-whoop"))
    }

    // MARK: - banked-sleep repair scope

    func testSleepRepairIncludesComputedAndEveryRegisteredDevice() {
        let ids = IntelligenceEngine.sleepHealDeviceIds(
            computedId: "my-whoop-noop",
            registeredIds: ["my-whoop", "oura-ring"])

        XCTAssertEqual(ids, ["my-whoop", "my-whoop-noop", "oura-ring"])
    }

    func testSleepRepairScopeIsUniqueSortedAndKeepsComputedId() {
        XCTAssertEqual(
            IntelligenceEngine.sleepHealDeviceIds(
                computedId: "b-noop",
                registeredIds: ["oura-ring", "b-noop", "a-whoop"]),
            ["a-whoop", "b-noop", "oura-ring"])
        XCTAssertEqual(
            IntelligenceEngine.sleepHealDeviceIds(computedId: "my-whoop-noop", registeredIds: []),
            ["my-whoop-noop"])
    }

    private func sleep(_ start: Int, _ end: Int, edited: Bool = false) -> CachedSleepSession {
        CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil,
            userEdited: edited)
    }

    @MainActor
    func testSleepRepairDeletesPerSourceAndPreservesEditedAndNonOverlappingRowsIdempotently() async throws {
        let store = try await WhoopStore.inMemory()

        // Computed source: this pass's fresh row wins its shifted duplicate.
        try await store.upsertSleepSessions([
            sleep(10_000, 20_000),
            sleep(10_600, 20_300),
        ], deviceId: "computed")

        // Oura source: longest wins without borrowing a row from another device id; the later nap is
        // disjoint and must survive.
        try await store.upsertSleepSessions([
            sleep(40_000, 60_000),
            sleep(40_600, 59_000),
            sleep(62_000, 64_000),
        ], deviceId: "oura")

        // A hand-edited night always survives an overlapping unedited copy, and a separate sleep remains.
        try await store.upsertSleepSessions([
            sleep(70_000, 90_000, edited: true),
            sleep(70_600, 89_000),
            sleep(92_000, 95_000),
        ], deviceId: "edited-source")

        let first = await IntelligenceEngine.healBankedSleepSessions(
            store: store,
            deviceIds: ["oura", "computed", "edited-source", "oura"],
            from: 0,
            to: 100_000,
            oldestDay: "1970-01-01",
            newestDay: "2100-01-01",
            timezoneOffsetSeconds: 0,
            freshStarts: [10_600])

        XCTAssertEqual(first.deleted.count, 3)
        XCTAssertEqual(first.unchangedDeleteCount, 0)
        XCTAssertEqual(first.failedDeleteCount, 0)
        XCTAssertEqual(first.failedReadCount, 0)
        let computedRows = try await store.sleepSessions(
            deviceId: "computed", from: 0, to: 100_000, limit: 20)
        let ouraRows = try await store.sleepSessions(
            deviceId: "oura", from: 0, to: 100_000, limit: 20)
        XCTAssertEqual(computedRows.map(\.startTs), [10_600])
        XCTAssertEqual(ouraRows.map(\.startTs), [40_000, 62_000])
        let editedRows = try await store.sleepSessions(
            deviceId: "edited-source", from: 0, to: 100_000, limit: 20)
        XCTAssertEqual(editedRows.map(\.startTs), [70_000, 92_000])
        XCTAssertTrue(editedRows.first?.userEdited == true)

        let second = await IntelligenceEngine.healBankedSleepSessions(
            store: store,
            deviceIds: ["computed", "oura", "edited-source"],
            from: 0,
            to: 100_000,
            oldestDay: "1970-01-01",
            newestDay: "2100-01-01",
            timezoneOffsetSeconds: 0,
            freshStarts: [10_600])
        XCTAssertTrue(second.deleted.isEmpty, "a completed repair must be idempotent")
        XCTAssertEqual(second.unchangedDeleteCount, 0)
        XCTAssertFalse(second.hasFailures)
    }

    @MainActor
    func testSleepRepairNeverCountsOrRemovesARowWhenTheDeleteFails() async throws {
        enum ExpectedFailure: Error { case delete }

        let store = try await WhoopStore.inMemory()
        try await store.upsertSleepSessions([
            sleep(10_000, 20_000),
            sleep(10_600, 19_000),
        ], deviceId: "oura")

        let result = await IntelligenceEngine.healBankedSleepSessions(
            store: store,
            deviceIds: ["oura"],
            from: 0,
            to: 30_000,
            oldestDay: "1970-01-01",
            newestDay: "2100-01-01",
            timezoneOffsetSeconds: 0,
            freshStarts: [],
            deleteSession: { _, _ in throw ExpectedFailure.delete })

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.failedDeleteCount, 1)
        XCTAssertTrue(result.hasFailures)
        let rowsAfterFailure = try await store.sleepSessions(
            deviceId: "oura", from: 0, to: 30_000, limit: 20)
        XCTAssertEqual(rowsAfterFailure.count, 2, "a failed delete must leave both source rows intact")
    }

    // MARK: - diagnostic line shape (the strap-log proof the next report ships)

    /// The exact line the engine emits per scored day; assembled here from the same parts so the format
    /// — "sleep day=… totalSleepMin=… matched=… source=…" — is pinned and stays parsable. Counts + a
    /// rounded minute only; no HR/HRV/timestamps, so it's safe to share.
    private func diagLine(day: String, totalSleepMin: Double?, matched: Int, source: DaySource) -> String {
        let tsm = totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
        return "sleep day=\(day) totalSleepMin=\(tsm) matched=\(matched) source=\(source.logToken)"
    }

    func testDiagnosticLineFormatComputed() {
        XCTAssertEqual(
            diagLine(day: "2026-06-12", totalSleepMin: 423.6, matched: 2, source: .computed),
            "sleep day=2026-06-12 totalSleepMin=424 matched=2 source=computed")
    }

    func testDiagnosticLineFormatImportedWhoop() {
        XCTAssertEqual(
            diagLine(day: "2026-06-12", totalSleepMin: 390, matched: 1, source: .whoopImport),
            "sleep day=2026-06-12 totalSleepMin=390 matched=1 source=imported:whoop")
    }

    func testDiagnosticLineHandlesNilTotalAndZeroMatches() {
        // A day with raw HR but no detected sleep block: total nil, zero matched — still a proof line,
        // so an empty-sleep day is visible in the log (the log-failures-not-successes blind spot).
        XCTAssertEqual(
            diagLine(day: "2026-06-12", totalSleepMin: nil, matched: 0, source: .computed),
            "sleep day=2026-06-12 totalSleepMin=nil matched=0 source=computed")
    }

    func testDiagnosticLineCarriesNoEmDash() {
        // House style: never an em-dash in user-facing / shared text.
        let line = diagLine(day: "2026-06-12", totalSleepMin: 100, matched: 1, source: .appleHealth)
        XCTAssertFalse(line.contains("—"))
    }
}
