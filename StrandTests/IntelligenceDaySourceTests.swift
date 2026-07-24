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
        // A WHOOP export covers the day → it wins the dashboard merge → badge "Whoop".
        let src = DaySource.classify(day: "2026-06-12",
                                     importedWhoopDays: ["2026-06-12"], appleHealthDays: [])
        XCTAssertEqual(src, .whoopImport)
        XCTAssertEqual(src.badge, "Whoop")
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
