import Foundation
import XCTest
@testable import Strand

final class RetainedScreenPerformanceContractTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testSleepHistoryStartsIndependentReadsTogetherAndTimesTheBoundary() throws {
        let text = try source("Strand/Screens/SleepView.swift")
        let start = try XCTUnwrap(
            text.range(of: #".task(id: "\(repo.refreshSeq)|\(repo.deviceId)|\(historyWriteQueryGate)")"#)
        )
        let end = try XCTUnwrap(
            text.range(of: ".sheet(item: $wakeEdit)", range: start.lowerBound..<text.endIndex)
        )
        let block = text[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(block.contains("async let sessionsTask"))
        XCTAssertTrue(block.contains("async let habitualTask"))
        XCTAssertTrue(block.contains("async let confidenceTask"))
        XCTAssertTrue(block.contains("async let motionsTask"))
        XCTAssertTrue(block.contains(#"\(repo.deviceId)"#))
        XCTAssertTrue(block.contains("\"sleep.history_load\""))
        XCTAssertTrue(block.contains("\"session_bucket\""))
        XCTAssertTrue(block.contains("\"motion_bucket\""))
        XCTAssertTrue(block.contains("shouldPublishHistoryLoad("))
        XCTAssertTrue(block.contains("requestRefreshSeq: requestRefreshSeq"))
        XCTAssertTrue(block.contains("requestDeviceId: requestDeviceId"))
        XCTAssertTrue(block.contains("guard !historyWriteQueryGate else { return }"))
        XCTAssertTrue(text.contains("HistoryWriteQueryGateBridge(blocked: $historyWriteQueryGate)"))
    }

    func testHistoryWriteQueryGateWaitsForAStableQuietEdge() throws {
        let text = try source("Strand/Screens/ScreenScaffold.swift")
        let start = try XCTUnwrap(text.range(of: "struct HistoryWriteQueryGateBridge"))
        let end = try XCTUnwrap(
            text.range(of: "/// Standard scrollable screen container", range: start.upperBound..<text.endIndex)
        )
        let block = text[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(block.contains("quietNanoseconds: UInt64 = 2_000_000_000"))
        XCTAssertTrue(block.contains("releaseTask?.cancel()"))
        XCTAssertTrue(block.contains("try? await Task.sleep"))
        XCTAssertTrue(block.contains("!live.backfilling"))
        XCTAssertTrue(block.contains("blocked = false"))
    }

    func testClassicTodayDefersColdAndWarmReadsUntilHistoryWritesAreQuiet() throws {
        let text = try source("Strand/Screens/TodayView.swift")
        let start = try XCTUnwrap(text.range(of: "private func loadAll() async"))
        let end = try XCTUnwrap(
            text.range(of: "private var backfillActivelyWriting", range: start.upperBound..<text.endIndex)
        )
        let block = text[start.lowerBound..<end.lowerBound]

        let writeGate = try XCTUnwrap(block.range(of: "if backfillActivelyWriting"))
        let dayLoad = try XCTUnwrap(block.range(of: "await loadDayScoped"))
        XCTAssertLessThan(writeGate.lowerBound, dayLoad.lowerBound)
        XCTAssertTrue(block.contains("deferredDashboardReadsForHistoryWrite = true"))
        XCTAssertTrue(block.contains("restoreDayScoped(cached)"))
        XCTAssertTrue(block.contains("restoreHistoryWide(cached)"))
        XCTAssertTrue(block.contains("forceReload: forceAfterHistoryWrite"))
        XCTAssertTrue(text.contains("historyWriteGate: historyWriteQueryGate"))
    }

    func testSleepHistoryPublicationRejectsCancellationRefreshAndDeviceSupersession() {
        XCTAssertTrue(SleepView.shouldPublishHistoryLoad(
            requestRefreshSeq: 7,
            currentRefreshSeq: 7,
            requestDeviceId: "device-a",
            currentDeviceId: "device-a",
            isCancelled: false
        ))
        XCTAssertFalse(SleepView.shouldPublishHistoryLoad(
            requestRefreshSeq: 7,
            currentRefreshSeq: 8,
            requestDeviceId: "device-a",
            currentDeviceId: "device-a",
            isCancelled: false
        ))
        XCTAssertFalse(SleepView.shouldPublishHistoryLoad(
            requestRefreshSeq: 7,
            currentRefreshSeq: 7,
            requestDeviceId: "device-a",
            currentDeviceId: "device-b",
            isCancelled: false
        ))
        XCTAssertFalse(SleepView.shouldPublishHistoryLoad(
            requestRefreshSeq: 7,
            currentRefreshSeq: 7,
            requestDeviceId: "device-a",
            currentDeviceId: "device-a",
            isCancelled: true
        ))
    }

    func testSleepHeroDoesNotSpendScrollFramesOnDecorativeAtmosphere() throws {
        let text = try source("Strand/Screens/SleepView.swift")
        XCTAssertTrue(text.contains(".timeOfDayBackground(.night, animated: false)"))
    }

    func testTodayDecorativeStatusClocksPauseDuringScrollInteraction() throws {
        let classic = try source("Strand/Screens/TodayView.swift")
        let liquid = try source("Strand/Liquid/LiquidTodayView.swift")
        let statusPill = try source(
            "Packages/StrandDesign/Sources/StrandDesign/StatePill.swift"
        )

        XCTAssertTrue(classic.contains("@Environment(\\.liquidInteractionInProgress)"))
        XCTAssertTrue(classic.contains("!interactionInProgress else"))
        XCTAssertTrue(liquid.contains("@Environment(\\.liquidInteractionInProgress)"))
        XCTAssertTrue(liquid.contains("syncing && !reduceMotion && !interactionInProgress"))
        XCTAssertTrue(liquid.contains("guard !posed, !interactionInProgress else"))
        XCTAssertTrue(statusPill.contains("@Environment(\\.noopInteractionInProgress)"))
        XCTAssertTrue(statusPill.contains("&& !interactionInProgress"))
        XCTAssertTrue(statusPill.contains(".task(id: shouldAnimatePulse)"))
    }

    func testWorkoutRecoveryHistoryLoadsOnlyAtItsLazyMount() throws {
        let text = try source("Strand/Screens/WorkoutsView.swift")

        XCTAssertFalse(text.contains(".task(id: recoveryTrendInputKey)"))
        XCTAssertTrue(text.contains("recoveryTrendLazySection"))
        XCTAssertTrue(text.contains(".task(id: inputKey)"))
        XCTAssertTrue(text.contains(#"\(repo.deviceId)"#))
        XCTAssertTrue(text.contains("\"workouts.recovery_trend_load\""))
        XCTAssertTrue(text.contains("candidate_bucket"))
        XCTAssertTrue(text.contains("requestKey == recoveryTrendInputKey"))
    }

    func testAutoWorkoutDensePreprocessingRunsOffMainAndReadsConcurrently() throws {
        let text = try source("Strand/Data/Repository.swift")
        let start = try XCTUnwrap(text.range(of: "private func computeAutoDetectCandidate"))
        let end = try XCTUnwrap(
            text.range(of: "func saveDetectedWorkout", range: start.lowerBound..<text.endIndex)
        )
        let block = text[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(block.contains("async let samplesTask"))
        XCTAssertTrue(block.contains("async let gravityTask"))
        XCTAssertTrue(block.contains("async let savedSpansTask"))
        let detached = try XCTUnwrap(block.range(of: "Task.detached(priority: .utility)"))
        let mapping = try XCTUnwrap(block.range(of: "let hr = samples.map"))
        XCTAssertLessThan(detached.lowerBound, mapping.lowerBound)
        XCTAssertTrue(block.contains("\"workouts.auto_detect_scan\""))
    }

    func testAutoWorkoutCacheAndPublicationAreOwnedByTheActiveDevice() throws {
        let text = try source("Strand/Data/Repository.swift")
        let keyStart = try XCTUnwrap(text.range(of: "private struct AutoDetectCandidateCacheKey"))
        let keyEnd = try XCTUnwrap(
            text.range(of: "private struct AutoDetectCandidateCache", range: keyStart.upperBound..<text.endIndex)
        )
        let keyBlock = text[keyStart.lowerBound..<keyEnd.lowerBound]
        let scanStart = try XCTUnwrap(text.range(of: "func autoDetectCandidate"))
        let scanEnd = try XCTUnwrap(
            text.range(of: "private func computeAutoDetectCandidate", range: scanStart.upperBound..<text.endIndex)
        )
        let scanBlock = text[scanStart.lowerBound..<scanEnd.lowerBound]
        let adoptionStart = try XCTUnwrap(text.range(of: "func adoptActiveDeviceId"))
        let adoptionEnd = try XCTUnwrap(
            text.range(of: "#if DEBUG", range: adoptionStart.upperBound..<text.endIndex)
        )
        let adoptionBlock = text[adoptionStart.lowerBound..<adoptionEnd.lowerBound]

        XCTAssertTrue(keyBlock.contains("let deviceId: String"))
        XCTAssertTrue(scanBlock.contains("deviceId: deviceId"))
        XCTAssertTrue(scanBlock.contains("let requestDeviceId = deviceId"))
        XCTAssertTrue(scanBlock.contains("deviceId == requestDeviceId"))
        XCTAssertTrue(adoptionBlock.contains("autoDetectScanTask?.cancel()"))
        XCTAssertTrue(adoptionBlock.contains("autoDetectCandidateCache = nil"))
    }

    func testStressUsesTheActiveAndCanonicalRrUnion() throws {
        let text = try source("Strand/Screens/StressView.swift")
        XCTAssertTrue(text.contains("repo.rrIntervals(from: from, to: to, limit: 200_000)"))
        XCTAssertFalse(text.contains("storeHandle()?.rrIntervals("))
    }
}
