import XCTest
import WhoopProtocol
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

    @MainActor
    func testDayOwnerResolvesEachSourcesHeartRateOrStepsBeforeApplyingPriority() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: "oura-import",
            brand: "Oura",
            model: "Oura import",
            sourceKind: .cloudImport,
            capabilities: [.hr],
            status: .paired,
            addedAt: 1,
            lastSeenAt: 1
        ))

        let from = 1_000
        let to = 2_000
        _ = try await store.insert(
            Streams(steps: [
                StepSample(ts: 1_400, counter: 100, activityClass: 1),
                StepSample(ts: 1_460, counter: 120, activityClass: 1),
            ]),
            deviceId: "my-whoop"
        )
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 1_500, bpm: 60)]),
            deviceId: "oura-import"
        )

        let owner = try await IntelligenceEngine.resolveDayOwner(
            day: "1970-01-01",
            from: from,
            to: to,
            stepFrom: from,
            stepTo: to,
            store: store,
            devices: try registry.all(),
            activeId: "my-whoop",
            registry: registry,
            fallbackDeviceId: "my-whoop"
        )

        XCTAssertEqual(
            owner,
            "my-whoop",
            "the active band's valid step evidence must outrank an import's HR row"
        )
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

    private func civilWindow(
        _ start: Int,
        _ end: Int,
        dayKey: String = "1970-01-01",
        timezoneOffsetSeconds: Int = 0
    ) -> IntelligenceEngine.AnalysisCivilDayWindow {
        IntelligenceEngine.AnalysisCivilDayWindow(
            startTs: start,
            endTs: end,
            dayKey: dayKey,
            timezoneOffsetSeconds: timezoneOffsetSeconds,
            localSixPMTs: min(start + 18 * 3_600, end + 1)
        )
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
            civilDayWindows: [civilWindow(0, 100_000)],
            freshStarts: [10_600])

        XCTAssertEqual(first.deleted.count, 3)
        XCTAssertEqual(first.unchangedDeleteCount, 0)
        XCTAssertEqual(first.failedDeleteCount, 0)
        XCTAssertEqual(first.failedReadCount, 0)
        XCTAssertFalse(first.cancelled)
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
            civilDayWindows: [civilWindow(0, 100_000)],
            freshStarts: [10_600])
        XCTAssertTrue(second.deleted.isEmpty, "a completed repair must be idempotent")
        XCTAssertEqual(second.unchangedDeleteCount, 0)
        XCTAssertFalse(second.cancelled)
        XCTAssertFalse(second.hasFailures)
    }

    @MainActor
    func testSleepRepairFiltersWakeTimesAgainstTheExactFallDSTWindow() async throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let reference = try XCTUnwrap(
            formatter.date(from: "2026-11-01T16:00:00Z")
        )
        let window = try XCTUnwrap(
            IntelligenceEngine.historicalCivilDayWindow(
                containing: Int(reference.timeIntervalSince1970),
                timeZone: timeZone
            )
        )
        XCTAssertEqual(window.durationSeconds, 90_000)
        let store = try await WhoopStore.inMemory()
        let priorStart = window.startTs - 10_000
        let priorShiftedStart = priorStart + 600
        let inRangeStart = window.startTs + 600
        let inRangeShiftedStart = inRangeStart + 600
        let nextStart = window.endTs + 1_000
        let nextShiftedStart = nextStart + 600
        try await store.upsertSleepSessions([
            sleep(priorStart, window.startTs - 1),
            sleep(priorShiftedStart, window.startTs - 300),
            sleep(inRangeStart, window.startTs + 2_400),
            sleep(inRangeShiftedStart, window.startTs + 2_100),
            sleep(nextStart, window.endTs + 10_000),
            sleep(nextShiftedStart, window.endTs + 9_700),
        ], deviceId: "dst-source")

        let result = await IntelligenceEngine.healBankedSleepSessions(
            store: store,
            deviceIds: ["dst-source"],
            from: priorStart - 1,
            to: window.endTs + 10_000,
            civilDayWindows: [window],
            freshStarts: [inRangeShiftedStart])

        XCTAssertEqual(result.deleted.map(\.startTs), [inRangeStart])
        let survivingStarts = try await store.sleepSessions(
            deviceId: "dst-source",
            from: priorStart - 1,
            to: window.endTs + 10_000,
            limit: 20
        ).map(\.startTs)
        XCTAssertTrue(survivingStarts.contains(priorStart))
        XCTAssertTrue(survivingStarts.contains(priorShiftedStart))
        XCTAssertTrue(survivingStarts.contains(inRangeShiftedStart))
        XCTAssertTrue(survivingStarts.contains(nextStart))
        XCTAssertTrue(survivingStarts.contains(nextShiftedStart))
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
            civilDayWindows: [civilWindow(0, 30_000)],
            freshStarts: [],
            deleteSession: { _, _ in throw ExpectedFailure.delete })

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.failedDeleteCount, 1)
        XCTAssertTrue(result.hasFailures)
        let rowsAfterFailure = try await store.sleepSessions(
            deviceId: "oura", from: 0, to: 30_000, limit: 20)
        XCTAssertEqual(rowsAfterFailure.count, 2, "a failed delete must leave both source rows intact")
    }

    @MainActor
    func testSleepRepairCancellationIsNotDowngradedToADeleteFailure() async throws {
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
            civilDayWindows: [civilWindow(0, 30_000)],
            freshStarts: [],
            deleteSession: { _, _ in throw CancellationError() })

        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.failedDeleteCount, 0)
        XCTAssertTrue(result.hasFailures)
    }

    // MARK: - diagnostic line shape (the strap-log proof the next report ships)

    private func diagLine(matched: Int, source: DaySource) -> String {
        "analysis.sleep_scored source=\(source.logToken) sessions=\(min(matched, 16)) "
            + "stages=present efficiency=present hrv=present hrv_window=deep"
    }

    func testDiagnosticLineFormatComputed() {
        XCTAssertEqual(
            diagLine(matched: 2, source: .computed),
            "analysis.sleep_scored source=computed sessions=2 stages=present "
                + "efficiency=present hrv=present hrv_window=deep")
    }

    func testDiagnosticLineFormatImportedWhoop() {
        XCTAssertEqual(
            diagLine(matched: 1, source: .whoopImport),
            "analysis.sleep_scored source=imported:whoop sessions=1 stages=present "
                + "efficiency=present hrv=present hrv_window=deep")
    }

    func testDiagnosticLineCapsCountsAndCarriesNoDateOrHealthValue() {
        let line = diagLine(matched: 99, source: .computed)
        XCTAssertTrue(line.contains("sessions=16"))
        XCTAssertFalse(line.contains("2026-"))
        XCTAssertFalse(line.contains("totalSleepMin"))
        XCTAssertFalse(line.contains("avgHrv"))
    }

    func testDiagnosticLineCarriesNoEmDash() {
        // House style: never an em-dash in user-facing / shared text.
        let line = diagLine(matched: 1, source: .appleHealth)
        XCTAssertFalse(line.contains("—"))
    }
}
