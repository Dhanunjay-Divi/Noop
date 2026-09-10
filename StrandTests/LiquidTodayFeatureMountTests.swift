import XCTest
@testable import Strand

/// Guards the feature leaves that must stay reachable from Liquid Today, the default Apple home screen.
/// The leaves self-gate when inactive; these tests pin their mount position and Hydration's independent
/// opt-in without requiring a rendered SwiftUI hierarchy or a live wearable.
@MainActor
final class LiquidTodayFeatureMountTests: XCTestCase {
    func testCompactTodayLayoutRequiresCompactWidthAndOrdinaryText() {
        XCTAssertTrue(
            LiquidTodayView.shouldUseCompactTodayLayout(
                compactWidth: true,
                largeText: false
            )
        )
        XCTAssertFalse(
            LiquidTodayView.shouldUseCompactTodayLayout(
                compactWidth: false,
                largeText: false
            )
        )
        XCTAssertFalse(
            LiquidTodayView.shouldUseCompactTodayLayout(
                compactWidth: true,
                largeText: true
            )
        )
    }

    func testCompactWeatherKeepsFullTouchTargetAroundCompactCapsule() throws {
        let source = try sourceText("Strand/Liquid/LiquidTodayView.swift")
        let weather = try slice(
            source,
            from: "private var weatherChip",
            to: "@ViewBuilder private var weatherChipContent"
        )

        let compactVisualHeight = try XCTUnwrap(
            weather.range(of: "height: usesCompactPhoneTodayLayout ? 32 : 34")
        )
        let touchTarget = try XCTUnwrap(
            weather.range(of: ".frame(minHeight: NoopMetrics.controlHeight)")
        )
        let buttonStyle = try XCTUnwrap(
            weather.range(of: ".buttonStyle(LiquidPressStyle())")
        )

        XCTAssertLessThan(compactVisualHeight.lowerBound, touchTarget.lowerBound)
        XCTAssertLessThan(touchTarget.lowerBound, buttonStyle.lowerBound)
        XCTAssertTrue(weather.contains(".contentShape(Rectangle())"))
    }

    func testAutoDetectedWorkoutSuggestionIsMountedOnDefaultToday() throws {
        let source = try sourceText("Strand/Liquid/LiquidTodayView.swift")
        let body = try slice(source, from: "var body: some View", to: ".coordinateSpace(name: Self.pullSpace)")

        let suggestion = try XCTUnwrap(body.range(of: "AutoWorkoutCard()"))
        let sources = try XCTUnwrap(body.range(of: "dataSourcesSection"))
        XCTAssertLessThan(suggestion.lowerBound, sources.lowerBound,
                          "The self-gated workout suggestion must remain in the default Today flow.")

        let leaf = try sourceText("Strand/Screens/AutoWorkoutCard.swift")
        XCTAssertTrue(leaf.contains("currentMode != .off"),
                      "The mounted leaf must remain empty when automatic detection is off.")
    }

    func testHealthAlertIsPinnedAndPersistsWhileTheModelAlertExists() throws {
        let source = try sourceText("Strand/Liquid/LiquidTodayView.swift")
        let body = try slice(source, from: "var body: some View", to: ".coordinateSpace(name: Self.pullSpace)")

        let alert = try XCTUnwrap(body.range(of: "HealthAlertBanner()"))
        let reordered = try XCTUnwrap(body.range(of: "ForEach(sectionOrder)"))
        XCTAssertLessThan(alert.lowerBound, reordered.lowerBound,
                          "A health warning must be pinned above user-reorderable sections.")
        XCTAssertEqual(body.components(separatedBy: "HealthAlertBanner()").count - 1, 1)

        let leaf = try sourceText("Strand/Screens/HealthAlertBanner.swift")
        XCTAssertTrue(leaf.contains("if let alert = model.healthAlert"))
        XCTAssertFalse(leaf.contains("@AppStorage"),
                       "A raised health warning must not be permanently hidden by a display preference.")
    }

    func testHydrationOffRemovesSavedCardInsteadOfRenderingBlankRow() {
        let saved = DashboardCardPrefs.encode([.stress, .hydration, .hrv])

        XCTAssertEqual(
            LiquidTodayView.visibleDashboardCards(selectionRaw: saved, hydrationEnabled: false),
            [.stress, .hrv]
        )
        XCTAssertEqual(
            LiquidTodayView.visibleDashboardCards(selectionRaw: saved, hydrationEnabled: true),
            [.stress, .hydration, .hrv]
        )
    }

    func testIdleAnalysisBackstopIsThirtyMinutes() {
        XCTAssertEqual(AppModel.analysisBackstopNanoseconds, 30 * 60 * 1_000_000_000)
    }

    func testLiquidTodayCacheIsExactAndCurrentDayIsAgeGated() {
        let key = LiquidTodayQueryKey(
            refreshSeq: 4,
            ageMetricsSeq: 2,
            workoutsSeq: 3,
            deviceId: "device-a",
            dayKey: "2026-09-09",
            isToday: true,
            profileState: "profile-a"
        )
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(LiquidTodayView.shouldRestoreQueryCache(
            cachedKey: key,
            requestKey: key,
            bankedAt: now.addingTimeInterval(-30),
            now: now,
            isToday: true
        ))
        XCTAssertFalse(LiquidTodayView.shouldRestoreQueryCache(
            cachedKey: key,
            requestKey: key,
            bankedAt: now.addingTimeInterval(-121),
            now: now,
            isToday: true
        ))
        XCTAssertTrue(LiquidTodayView.shouldRestoreQueryCache(
            cachedKey: key,
            requestKey: key,
            bankedAt: now.addingTimeInterval(-240),
            now: now,
            isToday: false
        ))
        XCTAssertFalse(LiquidTodayView.shouldRestoreQueryCache(
            cachedKey: key,
            requestKey: key,
            bankedAt: now.addingTimeInterval(-301),
            now: now,
            isToday: false
        ))

        let newer = LiquidTodayQueryKey(
            refreshSeq: 5,
            ageMetricsSeq: 2,
            workoutsSeq: 3,
            deviceId: "device-a",
            dayKey: "2026-09-09",
            isToday: true,
            profileState: "profile-a"
        )
        XCTAssertFalse(LiquidTodayView.shouldRestoreQueryCache(
            cachedKey: key,
            requestKey: newer,
            bankedAt: now,
            now: now,
            isToday: false
        ))

        let otherDevice = LiquidTodayQueryKey(
            refreshSeq: 4,
            ageMetricsSeq: 2,
            workoutsSeq: 3,
            deviceId: "device-b",
            dayKey: "2026-09-09",
            isToday: true,
            profileState: "profile-a"
        )
        XCTAssertFalse(LiquidTodayView.shouldRestoreQueryCache(
            cachedKey: key,
            requestKey: otherDevice,
            bankedAt: now,
            now: now,
            isToday: false
        ))
    }

    func testLiquidTodayDefersEveryQueryLoadDuringHistoryWrites() {
        XCTAssertTrue(LiquidTodayView.shouldDeferQueryLoad(isBackfilling: true))
        XCTAssertFalse(LiquidTodayView.shouldDeferQueryLoad(isBackfilling: false))
    }

    func testLiquidTodayCanRestoreOnlyTheSameDeviceDayAndProfileDuringHistoryWrites() {
        let cached = LiquidTodayQueryKey(
            refreshSeq: 4,
            ageMetricsSeq: 2,
            workoutsSeq: 3,
            deviceId: "device-a",
            dayKey: "2026-09-09",
            isToday: true,
            profileState: "profile-a"
        )
        let newer = LiquidTodayQueryKey(
            refreshSeq: 9,
            ageMetricsSeq: 5,
            workoutsSeq: 6,
            deviceId: "device-a",
            dayKey: "2026-09-09",
            isToday: true,
            profileState: "profile-a"
        )
        XCTAssertTrue(LiquidTodayView.canRestoreDuringHistoryWrite(
            cachedKey: cached,
            requestKey: newer
        ))
        XCTAssertFalse(LiquidTodayView.canRestoreDuringHistoryWrite(
            cachedKey: cached,
            requestKey: LiquidTodayQueryKey(
                refreshSeq: 9,
                ageMetricsSeq: 5,
                workoutsSeq: 6,
                deviceId: "device-b",
                dayKey: "2026-09-09",
                isToday: true,
                profileState: "profile-a"
            )
        ))
        XCTAssertFalse(LiquidTodayView.canRestoreDuringHistoryWrite(
            cachedKey: cached,
            requestKey: LiquidTodayQueryKey(
                refreshSeq: 9,
                ageMetricsSeq: 5,
                workoutsSeq: 6,
                deviceId: "device-a",
                dayKey: "2026-09-09",
                isToday: false,
                profileState: "profile-a"
            )
        ))
    }

    func testLiquidTodayUsesDurableRefreshInsteadOfRawBackfillEdgeInvalidation() throws {
        let source = try sourceText("Strand/Liquid/LiquidTodayView.swift")
        let task = try slice(
            source,
            from: ".task(id:",
            to: "#if DEBUG"
        )

        XCTAssertTrue(task.contains("\\(repo.refreshSeq)"))
        XCTAssertTrue(task.contains("\\(historyReadsBlocked)"))
        XCTAssertTrue(task.contains("\\(repo.deviceId)"))
        XCTAssertFalse(task.contains("repo.liquidTodayLoadCache = nil"))
        XCTAssertTrue(task.contains("await load()"))

        let appModel = try sourceText("Strand/App/AppModel.swift")
        XCTAssertTrue(appModel.contains("persistedHistoryRefreshWorker"))
        XCTAssertTrue(appModel.contains("refreshAfterPersistedHistory()"))
        XCTAssertTrue(appModel.contains("await repo.refresh(days: 120)"))
    }

    func testChargeV2UpgradeForcesFullHistoryUntilPassCompletes() {
        XCTAssertEqual(ChargeFormulaUpgradeGate.currentRevision, "noop-charge-v2")
        XCTAssertEqual(ChargeFormulaUpgradeGate.historyDays, 4_000)
        XCTAssertTrue(ChargeFormulaUpgradeGate.needsRescore(completedRevision: nil))
        XCTAssertTrue(ChargeFormulaUpgradeGate.needsRescore(
            completedRevision: "noop-charge-v1"))
        XCTAssertFalse(ChargeFormulaUpgradeGate.needsRescore(
            completedRevision: "noop-charge-v2"))

        XCTAssertNil(ChargeFormulaUpgradeGate.revisionToPersist(
            passCompleted: false,
            wasRequired: true))
        XCTAssertNil(ChargeFormulaUpgradeGate.revisionToPersist(
            passCompleted: true,
            wasRequired: false))
        XCTAssertEqual(
            ChargeFormulaUpgradeGate.revisionToPersist(
                passCompleted: true,
                wasRequired: true),
            "noop-charge-v2")
    }

    func testMacRestorePickerHasNonCollapsingFrame() throws {
        let source = try sourceText("Strand/Screens/BackupSyncView.swift")
        let picker = try slice(source, from: "private struct RestorePickerSheet", to: "private func primaryLabel")
        XCTAssertTrue(picker.contains("#if os(macOS)"))
        XCTAssertTrue(picker.contains(".frame(width: 460, height: 420)"))
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)).lowerBound
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)).lowerBound
        return String(source[lower..<upper])
    }
}
