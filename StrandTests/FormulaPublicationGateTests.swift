import Foundation
import NoopRemoteSync
import StrandAnalytics
import WhoopStore
import XCTest
@testable import Strand

final class FormulaPublicationGateTests: XCTestCase {
    func testComputedPublicationRequiresBothCurrentMarkers() {
        XCTAssertFalse(
            FormulaPublicationGate.computedDerivedReady(
                completedChargeRevision: nil,
                completedRestRevision: nil
            )
        )
        XCTAssertFalse(
            FormulaPublicationGate.computedDerivedReady(
                completedChargeRevision: ChargeFormulaUpgradeGate.currentRevision,
                completedRestRevision: nil
            )
        )
        XCTAssertFalse(
            FormulaPublicationGate.computedDerivedReady(
                completedChargeRevision: "noop-charge-v1",
                completedRestRevision: RestFormulaUpgradeGate.currentRevision
            )
        )
        XCTAssertTrue(
            FormulaPublicationGate.computedDerivedReady(
                completedChargeRevision: ChargeFormulaUpgradeGate.currentRevision,
                completedRestRevision: RestFormulaUpgradeGate.currentRevision
            )
        )
    }

    func testPersistedMarkersStayFailClosedAcrossRestartUntilBothComplete() throws {
        let suiteName = "FormulaPublicationGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ChargeFormulaUpgradeGate.currentRevision,
            forKey: ChargeFormulaUpgradeGate.completedRevisionKey
        )
        XCTAssertFalse(
            FormulaPublicationGate.computedDerivedReady(defaults: defaults)
        )

        defaults.set(
            RestFormulaUpgradeGate.currentRevision,
            forKey: RestFormulaUpgradeGate.completedRevisionKey
        )
        XCTAssertTrue(
            FormulaPublicationGate.computedDerivedReady(defaults: defaults)
        )
    }

    func testOnlyComputedDerivedPublicationIsDeferred() {
        let alwaysPublish = [
            "strap_measured",
            "official_reference",
            "noop_journal",
            "apple_health_import",
            "health_connect_import",
            "activity_file_import",
            "wearable_import",
        ]
        for sourceKind in alwaysPublish {
            XCTAssertTrue(
                FormulaPublicationGate.shouldPublishDerived(
                    sourceKind: sourceKind,
                    computedDerivedReady: false
                )
            )
        }
        XCTAssertFalse(
            FormulaPublicationGate.shouldPublishDerived(
                sourceKind: FormulaPublicationGate.computedSourceKind,
                computedDerivedReady: false
            )
        )
        XCTAssertTrue(
            FormulaPublicationGate.shouldPublishDerived(
                sourceKind: FormulaPublicationGate.computedSourceKind,
                computedDerivedReady: true
            )
        )
    }

    func testManagedGateRemovesOnlyComputedDerivedSummaries() {
        let all = [
            "essential_timeseries",
            "raw_auxiliary",
            "raw_ppg",
            "raw_motion",
            FormulaPublicationGate.managedDerivedDataClass,
        ]
        XCTAssertEqual(
            FormulaPublicationGate.managedDataClasses(
                sourceKind: FormulaPublicationGate.computedSourceKind,
                available: all,
                computedDerivedReady: false
            ),
            Array(all.dropLast())
        )
        XCTAssertEqual(
            FormulaPublicationGate.managedDataClasses(
                sourceKind: "apple_health",
                available: all,
                computedDerivedReady: false
            ),
            all
        )
        XCTAssertEqual(
            FormulaPublicationGate.deferredDiagnosticFields,
            [
                "computed_derived": "deferred",
                "reason": "formula_migration",
            ]
        )
    }

    func testSocialSummaryPublicationWaitsForFormulaMigration() {
        XCTAssertFalse(
            FormulaPublicationGate.shouldPublishSocialSummaries(
                computedDerivedReady: false
            )
        )
        XCTAssertTrue(
            FormulaPublicationGate.shouldPublishSocialSummaries(
                computedDerivedReady: true
            )
        )
    }

    func testManagedSocialSummaryUploadBodyWaitsForFormulaMigration() async {
        var uploadAttempts = 0
        let deferred = await FormulaPublicationGate.publishSocialSummariesIfReady(
            computedDerivedReady: false
        ) {
            uploadAttempts += 1
            return 7
        }
        XCTAssertNil(deferred)
        XCTAssertEqual(uploadAttempts, 0)

        let published = await FormulaPublicationGate.publishSocialSummariesIfReady(
            computedDerivedReady: true
        ) {
            uploadAttempts += 1
            return 7
        }
        XCTAssertEqual(published, 7)
        XCTAssertEqual(uploadAttempts, 1)
    }

    func testUploadPathsUseTheSharedFailClosedGate() throws {
        let remote = try source("Strand/Data/RemoteSyncService.swift")
        XCTAssertTrue(remote.contains("includeDerived: namespace.derived && publishDerived"))
        XCTAssertTrue(remote.contains("hasDeferredComputedDerived"))
        XCTAssertTrue(remote.contains("replay && !hasMore && !hasDeferredComputedDerived"))
        XCTAssertFalse(remote.contains(
            "result.hasMoreDerivedRows\n                    || (namespace.derived && !publishDerived)"
        ))
        XCTAssertTrue(remote.contains("FormulaPublicationGate.deferredDiagnosticFields"))

        let managed = try source("StrandiOS/System/ManagedCloudService.swift")
        XCTAssertTrue(managed.contains("FormulaPublicationGate.managedDataClasses"))
        XCTAssertTrue(
            managed.contains("publishSocialSummariesIfReady")
        )
        XCTAssertTrue(managed.contains("FormulaPublicationGate.deferredDiagnosticFields"))
    }

    func testFormulaReplayIntentSurvivesRestartAndWaitsForMigration() throws {
        let suiteName = "FormulaReplayIntentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let revision = "noop-charge-v2+noop-rest-v2"

        XCTAssertTrue(
            RemoteSyncPreferences.prepareFormulaReplay(
                currentRevision: revision,
                computedDerivedReady: false,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            RemoteSyncPreferences.requiredFormulaReplayRevision(defaults: defaults),
            revision
        )
        XCTAssertFalse(defaults.bool(forKey: "remoteSync.needsFullReplay"))

        let restarted = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertTrue(
            RemoteSyncPreferences.prepareFormulaReplay(
                currentRevision: revision,
                computedDerivedReady: true,
                defaults: restarted
            )
        )
        XCTAssertTrue(restarted.bool(forKey: "remoteSync.needsFullReplay"))
    }

    func testActiveFormulaReplayPreservesFixedWindowAndDoesNotRequestReset() throws {
        let suiteName = "FormulaReplayCursorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let revision = "noop-charge-v2+noop-rest-v2"
        let window = RemoteDerivedWindow(
            endingAt: Date(timeIntervalSince1970: 1_800_000_000),
            historyDays: 3_650,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        RemoteSyncPreferences.beginReplay(window, defaults: defaults)
        XCTAssertTrue(
            RemoteSyncPreferences.prepareFormulaReplay(
                currentRevision: revision,
                computedDerivedReady: true,
                defaults: defaults
            )
        )

        XCTAssertFalse(defaults.bool(forKey: "remoteSync.needsFullReplay"))
        let persistedData = try XCTUnwrap(
            defaults.data(forKey: "remoteSync.replayWindow")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteDerivedWindow.self, from: persistedData),
            window
        )
    }

    func testFormulaReplayClearsOnlyAfterMatchingSuccessfulCompletion() throws {
        let suiteName = "FormulaReplayCompletionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let revision = "noop-charge-v2+noop-rest-v2"
        let window = RemoteDerivedWindow(
            endingAt: Date(timeIntervalSince1970: 1_800_000_000),
            historyDays: 3_650,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        _ = RemoteSyncPreferences.prepareFormulaReplay(
            currentRevision: revision,
            computedDerivedReady: true,
            defaults: defaults
        )
        RemoteSyncPreferences.beginReplay(window, defaults: defaults)

        let restarted = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(
            RemoteSyncPreferences.requiredFormulaReplayRevision(defaults: restarted),
            revision
        )
        XCTAssertNil(
            RemoteSyncPreferences.completedFormulaReplayRevision(defaults: restarted)
        )

        RemoteSyncPreferences.finishReplay(
            completingFormulaRevision: "older-revision",
            defaults: restarted
        )
        XCTAssertEqual(
            RemoteSyncPreferences.requiredFormulaReplayRevision(defaults: restarted),
            revision
        )
        XCTAssertNil(
            RemoteSyncPreferences.completedFormulaReplayRevision(defaults: restarted)
        )

        RemoteSyncPreferences.finishReplay(
            completingFormulaRevision: revision,
            defaults: restarted
        )
        XCTAssertNil(
            RemoteSyncPreferences.requiredFormulaReplayRevision(defaults: restarted)
        )
        XCTAssertEqual(
            RemoteSyncPreferences.completedFormulaReplayRevision(defaults: restarted),
            revision
        )
    }

    @MainActor
    func testFormulaTraversalRemovesUnrecomputablePriorScoresBeforeCompletion()
        async throws
    {
        let sourceID = "my-whoop"
        let computedID = sourceID + "-noop"
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: sourceID)
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo,
            profile: ProfileStore(),
            deviceId: sourceID
        )
        let now = Date()
        let timeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firstObservation = Int(
            calendar.startOfDay(for: now).timeIntervalSince1970
        )
        engine.setAnalysisTimeZoneTimelineForTesting(
            AnalysisTimeZoneTimeline(
                observations: [
                    AnalysisTimeZoneObservation(
                        observedAtSec: firstObservation,
                        timeZoneIdentifier: timeZone.identifier,
                        offsetSeconds: timeZone.secondsFromGMT(
                            for: Date(
                                timeIntervalSince1970:
                                    TimeInterval(firstObservation)
                            )
                        )
                    ),
                ],
                unresolvableBeforeTs: firstObservation
            )
        )

        let day = Repository.localDayKey(now)
        try await store.upsertDailyMetrics(
            [
                DailyMetric(
                    day: day,
                    totalSleepMin: 420,
                    efficiency: 0.9,
                    deepMin: 90,
                    remMin: 100,
                    lightMin: 230,
                    disturbances: 2,
                    restingHr: 52,
                    avgHrv: 70,
                    recovery: 0.42,
                    strain: 8,
                    exerciseCount: 0
                ),
            ],
            deviceId: computedID
        )
        try await store.upsertMetricSeries(
            [
                MetricPoint(
                    day: day,
                    key: ScoreConfidence.sleepPerformanceSeriesKey,
                    value: 72
                ),
            ],
            deviceId: computedID
        )

        let runReceipt = await engine.analyzeRecent(
            maxDays: 1,
            force: true,
            traverseResolvableHistory: true
        )
        let receipt = try XCTUnwrap(runReceipt)

        XCTAssertTrue(receipt.completedResolvableHistory)
        XCTAssertEqual(
            RestFormulaUpgradeGate.progress(
                receipt: receipt,
                wasRequired: true,
                traversalWasSelected: true
            ),
            .complete(revision: RestFormulaUpgradeGate.currentRevision)
        )
        let remainingScores = try await store.dailyMetrics(
            deviceId: computedID,
            from: day,
            to: day
        )
        XCTAssertTrue(
            remainingScores.isEmpty,
            "A formula migration must invalidate a stale computed score when its raw HR is gone."
        )
        let remainingRestEvidence = try await store.metricSeries(
            deviceId: computedID,
            key: ScoreConfidence.sleepPerformanceSeriesKey,
            from: day,
            to: day
        )
        XCTAssertTrue(
            remainingRestEvidence.isEmpty,
            "Managed Rest evidence from the stale formula must be removed with the daily score."
        )
    }

    func testSelfHostedFormulaReplayUsesFullWindowWithoutDeferredBacklog() throws {
        let remote = try source("Strand/Data/RemoteSyncService.swift")
        XCTAssertTrue(remote.contains("derivedHistoryDays: replay ? 3_650 : 400"))
        XCTAssertTrue(remote.contains("prepareFormulaReplay("))
        XCTAssertTrue(remote.contains("replay && !hasMore && !hasDeferredComputedDerived"))
        XCTAssertFalse(remote.contains(
            "hasMore = hasMoreRaw || hasMoreDerived || hasDeferredComputedDerived"
        ))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
