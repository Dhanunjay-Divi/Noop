import Combine
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
            text.range(of: #".task(id: "\(repo.refreshSeq)|\(repo.deviceId)|\(historyReadsBlocked)")"#)
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
        XCTAssertTrue(block.contains("guard !historyReadsBlocked else { return }"))
        XCTAssertTrue(text.contains("active: repo.historyWritesActive"))
        XCTAssertTrue(text.contains("repo.historyWritesActive || historyWriteQueryGate"))
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
        XCTAssertTrue(block.contains("!active"))
        XCTAssertTrue(block.contains("blocked = false"))
    }

    func testHistoryWriteGateBlocksSynchronouslyBeforeTheLeafQuietHoldArrives() throws {
        let repository = try source("Strand/Data/Repository.swift")
        let model = try source("Strand/App/AppModel.swift")
        let screens = try [
            source("Strand/Screens/TodayView.swift"),
            source("Strand/Liquid/LiquidTodayView.swift"),
            source("Strand/Screens/SleepView.swift"),
        ]

        XCTAssertTrue(repository.contains("@Published private(set) var historyWritesActive = false"))
        XCTAssertTrue(model.contains("live.$backfilling.removeDuplicates()"))
        XCTAssertTrue(model.contains("repo.setHistoryWritesActive(active)"))
        for screen in screens {
            XCTAssertTrue(screen.contains("repo.historyWritesActive || historyWriteQueryGate"))
            XCTAssertTrue(screen.contains("active: repo.historyWritesActive"))
        }
    }

    @MainActor
    func testRepositoryHistoryWriteBoundaryPublishesOnlyStateEdges() {
        let repository = Repository(deviceId: "history-write-gate")
        var observed: [Bool] = []
        let observation = repository.$historyWritesActive.sink {
            observed.append($0)
        }

        repository.setHistoryWritesActive(true)
        repository.setHistoryWritesActive(true)
        repository.setHistoryWritesActive(false)

        XCTAssertEqual(observed, [false, true, false])
        withExtendedLifetime(observation) {}
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
        XCTAssertTrue(text.contains("historyWriteGate: historyReadsBlocked"))
    }

    func testClassicTodayCachesAndPublicationAreOwnedByTheActiveDevice() throws {
        let today = try source("Strand/Screens/TodayView.swift")
        let repository = try source("Strand/Data/Repository.swift")

        XCTAssertTrue(today.contains("deviceId: repo.deviceId"))
        XCTAssertTrue(today.contains("cached.deviceId == currentDeviceId"))
        XCTAssertTrue(today.contains("cached.deviceId == loadDeviceId"))
        XCTAssertTrue(today.contains("requestDeviceId == repo.deviceId"))
        XCTAssertTrue(today.contains("loadDeviceId == repo.deviceId"))
        XCTAssertTrue(today.contains("requestRefreshSeq == repo.refreshSeq"))
        XCTAssertTrue(today.contains("loadSeq == repo.refreshSeq"))

        let dayStart = try XCTUnwrap(today.range(of: "private func loadDayScoped"))
        let dayEnd = try XCTUnwrap(
            today.range(of: "private func announceNewDaysIfNeeded", range: dayStart.upperBound..<today.endIndex)
        )
        let dayBlock = today[dayStart.lowerBound..<dayEnd.lowerBound]
        let publishGuard = try XCTUnwrap(dayBlock.range(of: "guard loadDeviceId == repo.deviceId"))
        for assignment in [
            "restScore = restScoreLocal",
            "hrPoints = hrPointsLocal",
            "liveTodayStrain = liveStrainLocal",
            "sleepToday = sleepTodayLocal",
        ] {
            let write = try XCTUnwrap(dayBlock.range(of: assignment))
            XCTAssertLessThan(publishGuard.lowerBound, write.lowerBound)
        }

        let adoptStart = try XCTUnwrap(repository.range(of: "func adoptActiveDeviceId"))
        let adoptEnd = try XCTUnwrap(
            repository.range(of: "#if DEBUG", range: adoptStart.upperBound..<repository.endIndex)
        )
        let adoptBlock = repository[adoptStart.lowerBound..<adoptEnd.lowerBound]
        XCTAssertTrue(adoptBlock.contains("todayHistoryWideLoadedSeq = -1"))
        XCTAssertTrue(adoptBlock.contains("todayHistoryWideCache = nil"))
        XCTAssertTrue(adoptBlock.contains("todayDayScopedLoadedSeq = -1"))
        XCTAssertTrue(adoptBlock.contains("todayDayScopedLoadedDayKey = \"\""))
        XCTAssertTrue(adoptBlock.contains("todayDayScopedCache = nil"))
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

    func testSleepStressWaitsForStableHistoryWritesAndRejectsSupersededLoads() throws {
        let text = try source("Strand/Screens/SleepView.swift")
        let start = try XCTUnwrap(text.range(of: "private func sleepStressCard"))
        let end = try XCTUnwrap(
            text.range(of: "private func sleepStressTrace", range: start.upperBound..<text.endIndex)
        )
        let block = text[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(block.contains("SleepStressLoadKey("))
        XCTAssertTrue(block.contains("historyReadsBlocked: historyReadsBlocked"))
        XCTAssertTrue(block.contains(".task(id: loadKey)"))
        XCTAssertTrue(block.contains("guard !loadKey.historyReadsBlocked else { return }"))
        XCTAssertTrue(block.contains("repo.deviceId == loadKey.deviceId"))
        XCTAssertTrue(block.contains("repo.refreshSeq == window.refreshSeq"))
        XCTAssertTrue(block.contains("!historyReadsBlocked"))
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

    func testSharedWorkoutAndScoreMotionYieldToScrollInteraction() throws {
        let illustration = try source(
            "Packages/StrandDesign/Sources/StrandDesign/SemanticBodyIllustration.swift"
        )
        let components = try source(
            "Packages/StrandDesign/Sources/StrandDesign/Components.swift"
        )

        XCTAssertTrue(illustration.contains("@Environment(\\.noopInteractionInProgress)"))
        XCTAssertTrue(illustration.contains("interactionInProgress: interactionInProgress"))
        XCTAssertTrue(illustration.contains("paused: !repeatsMotion"))
        XCTAssertTrue(components.contains("@Environment(\\.noopInteractionInProgress)"))
        XCTAssertTrue(components.contains("requested: pulsing && scheme == .dark"))
        XCTAssertTrue(components.contains(".task(id: shouldAnimatePulse)"))
    }

    func testAppleScrollRootsPublishTheSharedInteractionBudget() throws {
        let scaffold = try source("Strand/Screens/ScreenScaffold.swift")
        let liquidToday = try source("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertTrue(scaffold.contains("final class ScrollInteractionTracker"))
        XCTAssertTrue(scaffold.contains("guard settleTask == nil else { return }"))
        XCTAssertTrue(scaffold.contains("scrollInteraction.observe(offset: offset)"))
        XCTAssertTrue(
            scaffold.contains(
                ".environment(\\.noopInteractionInProgress, scrollInteraction.isActive)"
            )
        )
        XCTAssertTrue(liquidToday.contains("scrollInteraction.observe(offset: offset)"))
        XCTAssertTrue(
            liquidToday.contains(
                ".environment(\\.noopInteractionInProgress, scrollInteraction.isActive)"
            )
        )
    }

    func testScrollInteractionTrackerSettlesAgainstTheLatestMovementEdge() {
        let settleNanoseconds: UInt64 = 180_000_000

        XCTAssertEqual(
            ScrollInteractionTiming.remainingSeconds(
                lastMovementUptime: 10,
                nowUptime: 10,
                settleNanoseconds: settleNanoseconds
            ),
            0.18,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ScrollInteractionTiming.remainingSeconds(
                lastMovementUptime: 10.10,
                nowUptime: 10.18,
                settleNanoseconds: settleNanoseconds
            ),
            0.10,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            ScrollInteractionTiming.remainingSeconds(
                lastMovementUptime: 10,
                nowUptime: 10.18,
                settleNanoseconds: settleNanoseconds
            ),
            0,
            accuracy: 0.000_001
        )
    }

    func testWorkoutRecoveryHistoryLoadsOnlyAtItsLazyMount() throws {
        let text = try source("Strand/Screens/WorkoutsView.swift")

        XCTAssertFalse(text.contains(".task(id: recoveryTrendInputKey)"))
        XCTAssertTrue(text.contains("recoveryTrendLazySection"))
        XCTAssertTrue(text.contains("@State private var recoveryTrendLoadTask: Task<Void, Never>?"))
        XCTAssertTrue(text.contains("@State private var recoveryTrendLoadKey: String?"))
        XCTAssertTrue(text.contains("@State private var recoveryTrendLoadToken: UUID?"))
        XCTAssertTrue(text.contains("@State private var recoveryTrendRequestedKey: String?"))
        XCTAssertTrue(text.contains("startRecoveryTrendLoad(requestKey: inputKey, rows: inputRows)"))
        XCTAssertTrue(text.contains(".onChangeCompat(of: recoveryTrendInputKey)"))
        XCTAssertTrue(text.contains("restartRecoveryTrendLoadIfRequested(for: newKey)"))
        XCTAssertTrue(text.contains("resumeRecoveryTrendLoadIfRequested()"))
        XCTAssertTrue(text.contains(".onDisappear {\n            suspendRecoveryTrendLoad()"))
        XCTAssertTrue(text.contains("guard recoveryTrendLoadToken == requestToken"))
        XCTAssertFalse(text.contains(".task(id: inputKey)"))
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
