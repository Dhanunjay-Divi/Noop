import XCTest
@testable import Strand
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// #H9 — the Sleep stage-breakdown LOW-CONFIDENCE badge gate (`SleepView.isStagingLowConfidence`).
///
/// The UI badge must agree with the engine's persisted Rest confidence: it flags ONLY the suspicious case
/// — a high-efficiency night (lots of measured sleep) whose deep+REM share is implausibly low, which the
/// EEG-free classifier is far likelier to have mis-staged than a real night with no restorative sleep. It
/// must NOT flag a healthy night, a genuinely fragmented (low-efficiency) night, or an unstaged night. The
/// gate delegates to `ScoreConfidence.rest(...)`, so these pin the UI side against the same thresholds the
/// daily pass uses. Pure → no view, no BLE.
final class SleepStagingConfidenceTests: XCTestCase {
    func testLegacyStagedSleepRequiresDeepOrREM() {
        XCTAssertFalse(SleepView.hasEngineStagedSleep(deepMin: 0, remMin: 0),
                       "awake/light-only segments are not staged sleep evidence")
        XCTAssertTrue(SleepView.hasEngineStagedSleep(deepMin: 1, remMin: 0))
        XCTAssertTrue(SleepView.hasEngineStagedSleep(deepMin: 0, remMin: 1))
    }

    func testImportedRestHeroUsesOneNeutralBadge() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Strand/Screens/SleepView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"if isProviderScore {"#))
        XCTAssertTrue(source.contains(#"SourceBadge("Imported", tint: StrandPalette.restColor)"#))
        XCTAssertFalse(source.contains(#"SourceBadge(isProviderScore ? "Provider score""#))
    }

    /// A high-efficiency night with near-zero deep+REM → flagged low-confidence (likely staging miss).
    func testHighEfficiencyLowRestorative_isLowConfidence() {
        // 7h asleep, ~2% restorative, 95% efficiency → well below the 10% restorative floor on a >85%-eff night.
        let asleep = 7.0 * 60.0      // 420 min
        let deep = 4.0, rem = 4.0    // 8 min restorative ≈ 1.9% of asleep
        XCTAssertTrue(SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem,
                                                       efficiency: 0.95))
    }

    /// A healthy night (deep+REM ~45% of asleep) is NEVER flagged — its staging is plausible.
    func testHealthyRestorativeShare_isNotFlagged() {
        let asleep = 7.0 * 60.0
        let deep = 90.0, rem = 100.0   // ~45% restorative
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem,
                                                        efficiency: 0.95))
    }

    /// A genuinely FRAGMENTED night (low efficiency) legitimately carries less deep/REM, so the floor must
    /// not false-positive there — the badge is only for the high-efficiency-yet-low-restorative case.
    func testLowEfficiencyNight_isNotFlagged_evenWithLowRestorative() {
        let asleep = 5.0 * 60.0
        let deep = 3.0, rem = 3.0      // tiny restorative …
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem,
                                                        efficiency: 0.60))   // … but the night was fragmented
    }

    /// An UNSTAGED night (no deep+REM at all) isn't flagged here — there's no staging split to doubt; its
    /// base Rest confidence already reads honestly (.building from no staged sleep), not a downgrade.
    func testUnstagedNight_isNotFlagged() {
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: 6 * 60, deepMin: 0, remMin: 0,
                                                        efficiency: 0.95))
    }

    /// A zero-asleep night can't be evaluated → never flagged (guard against a divide-by-zero / nonsense).
    func testZeroAsleep_isNotFlagged() {
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: 0, deepMin: 0, remMin: 0,
                                                        efficiency: 0.95))
    }

    /// The UI gate and the engine agree: where `isStagingLowConfidence` is true, the engine's H9 Rest
    /// overload also downgrades to `.building`. Pins the two surfaces to the same threshold.
    func testAgreesWithEngineRestConfidence() {
        let asleep = 7.0 * 60.0, deep = 4.0, rem = 4.0, eff = 0.95
        let uiFlag = SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem, efficiency: eff)
        let tier = ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                        asleepSeconds: asleep * 60, restorativeSeconds: (deep + rem) * 60,
                                        efficiency: eff)
        XCTAssertTrue(uiFlag)
        XCTAssertEqual(tier, .building)
    }

    // MARK: Canonical motion-coverage provenance

    func testTwoMotionEpochsDoNotOverrideCanonicalSparseLimitation() {
        let asleep = 8.0 * 3_600.0
        let assessment = SleepView.localRestAssessment(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: asleep, restorativeSeconds: asleep * 0.45,
            efficiency: 0.95, motionEpochCount: 2, gravitySparse: true)

        XCTAssertEqual(assessment.confidence, .building)
        XCTAssertEqual(assessment.limitations, [.sparseMotion])
    }

    func testExpandedMotionTraceWithoutCoverageProvenanceRemainsLimited() {
        let asleep = 8.0 * 3_600.0
        let assessment = SleepView.localRestAssessment(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: asleep, restorativeSeconds: asleep * 0.45,
            efficiency: 0.95, motionEpochCount: 960, gravitySparse: nil)

        XCTAssertEqual(assessment.confidence, .building)
        XCTAssertEqual(assessment.limitations, [.motionUnavailable])
    }

    func testExplicitDenseCoverageCanRetainHigherConfidence() {
        let asleep = 8.0 * 3_600.0
        let assessment = SleepView.localRestAssessment(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: asleep, restorativeSeconds: asleep * 0.45,
            efficiency: 0.95, motionEpochCount: 960, gravitySparse: false)

        XCTAssertEqual(assessment.confidence, .solid)
        XCTAssertTrue(assessment.limitations.isEmpty)
    }

    func testMissingCardiorespiratoryEvidenceReachesSleepPresentationAssessment() {
        let asleep = 8.0 * 3_600.0
        let assessment = SleepView.localRestAssessment(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: asleep, restorativeSeconds: asleep * 0.45,
            efficiency: 0.95, motionEpochCount: 960, gravitySparse: false,
            hasRREvidence: false, hasRespirationEvidence: false)

        XCTAssertEqual(assessment.confidence, .building)
        XCTAssertEqual(
            assessment.limitations,
            [.missingRREvidence, .missingRespirationEvidence])
    }

    func testMissingRrAndRespirationHaveDistinctAccuratePresentationCopy() throws {
        let rr = try XCTUnwrap(SleepView.restLimitationText(.missingRREvidence))
        let respiration = try XCTUnwrap(
            SleepView.restLimitationText(.missingRespirationEvidence))

        XCTAssertTrue(rr.contains("beat-to-beat timing evidence"))
        XCTAssertTrue(respiration.contains("breathing-rate evidence"))
        XCTAssertTrue(rr.contains("stage estimates"))
        XCTAssertTrue(respiration.contains("stage estimates"))
        XCTAssertFalse(rr.contains("Stage detail is unavailable"))
        XCTAssertFalse(respiration.contains("Stage detail is unavailable"))
        XCTAssertNotEqual(rr, respiration)
    }

    func testPersistedEvidenceKeepsRrAndRespirationIndependentInPresentation() {
        let evidence = ScoreConfidence.restEvidenceFlags(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: 8 * 3_600, restorativeSeconds: 3 * 3_600,
            efficiency: 0.9, motionAvailable: true, gravitySparse: false,
            hasRREvidence: true, hasRespirationEvidence: false)
        let legacy = ScoreConfidence.restAssessment(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: 8 * 3_600, restorativeSeconds: 3 * 3_600,
            efficiency: 0.9, motionUnavailable: false,
            hasRREvidence: false, hasRespirationEvidence: false)

        let resolved = SleepView.resolvedRestAssessment(
            persistedConfidence: .building,
            persistedEvidence: evidence,
            legacyAssessment: legacy)

        XCTAssertEqual(resolved.confidence, .building)
        XCTAssertEqual(resolved.limitations, [.missingRespirationEvidence])
    }

    func testLegacyTierCannotImplyCardiorespiratoryEvidence() {
        let legacy = ScoreConfidence.restAssessment(
            hasSession: true, hasStagedSleep: true,
            asleepSeconds: 8 * 3_600, restorativeSeconds: 3 * 3_600,
            efficiency: 0.9, motionUnavailable: false,
            hasRREvidence: false, hasRespirationEvidence: false)

        let resolved = SleepView.resolvedRestAssessment(
            persistedConfidence: .solid,
            persistedEvidence: nil,
            legacyAssessment: legacy)

        XCTAssertEqual(resolved.confidence, .building)
        XCTAssertEqual(
            resolved.limitations,
            [.missingRREvidence, .missingRespirationEvidence])
    }

    func testIntelligenceRecomputesRestEvidenceFromEditedDailyStages() {
        let edited = DailyMetric(
            day: "2026-08-25", totalSleepMin: 480, efficiency: 0.9,
            deepMin: 10, remMin: 10, lightMin: 460,
            disturbances: nil, restingHr: nil, avgHrv: nil,
            recovery: nil, strain: nil, exerciseCount: nil)
        let raw = ScoreConfidence.RestRawEvidence(
            hasRREvidence: true, hasRespirationEvidence: true)

        let evidence = IntelligenceEngine.restEvidenceAfterSleepEdits(
            edited, motionAvailable: true, gravitySparse: false, rawEvidence: raw)

        XCTAssertEqual(ScoreConfidence.restAssessment(evidence: evidence).confidence, .building)
        XCTAssertTrue(evidence.contains(.implausibleStageMix))
    }

    func testEditedWinnerUsesItsOwnRawAndMotionEvidence() throws {
        let firstStart = 100_000
        let secondStart = 200_000
        func stages(start: Int, hours: Int) throws -> String {
            try XCTUnwrap(AnalyticsEngine.encodeStages([
                StageSegment(start: start, end: start + hours * 3_600, stage: "light"),
            ]))
        }
        let first = CachedSleepSession(
            startTs: firstStart,
            endTs: firstStart + 4 * 3_600,
            efficiency: 1,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: try stages(start: firstStart, hours: 4),
            gravitySparse: false)
        let second = CachedSleepSession(
            startTs: secondStart,
            endTs: secondStart + 2 * 3_600,
            efficiency: 1,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: try stages(start: secondStart, hours: 2),
            gravitySparse: false)
        let editedSecond = CachedSleepSession(
            startTs: secondStart,
            endTs: secondStart + 8 * 3_600,
            efficiency: 1,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: try stages(start: secondStart, hours: 8),
            userEdited: true,
            gravitySparse: false)
        let daily = DailyMetric(
            day: "2026-08-25",
            totalSleepMin: 240,
            efficiency: 1,
            deepMin: 0,
            remMin: 0,
            lightMin: 240,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: nil,
            strain: nil,
            exerciseCount: nil)

        let edited = IntelligenceEngine.sleepEditedDaily(
            daily,
            detected: [first, second],
            editsByStart: [secondStart: editedSecond],
            tzOffsetSeconds: 0,
            habitualMidsleepSec: nil,
            fallbackMainSessionStarts: [firstStart])

        XCTAssertEqual(edited.mainSessionStarts, [secondStart])
        XCTAssertEqual(edited.daily.totalSleepMin, 480)
        XCTAssertFalse(IntelligenceEngine.restMotionAvailable(
            mainSessionStarts: edited.mainSessionStarts,
            sessionMotionByStart: [firstStart: [0.01, 0.02]]))

        let firstSession = SleepSession(
            start: firstStart,
            end: first.endTs,
            efficiency: 1,
            stages: [],
            restingHR: nil,
            avgHRV: nil)
        let secondSession = SleepSession(
            start: secondStart,
            end: second.endTs,
            efficiency: 1,
            stages: [],
            restingHR: nil,
            avgHRV: nil)
        let rr = (firstStart..<(firstStart + 3_600)).map { ts in
            RRInterval(ts: ts, rrMs: ts.isMultiple(of: 2) ? 995 : 1_005)
        }
        let resp = (firstStart..<(firstStart + 3_600)).map { ts in
            let phase = Double(ts - firstStart)
            return RespSample(
                ts: ts,
                raw: 1_000 + Int((100 * sin(2 * Double.pi * phase / 4)).rounded()))
        }
        let raw = ScoreConfidence.restRawEvidence(
            sessions: [firstSession, secondSession],
            rr: rr,
            resp: resp,
            offsetSec: 0,
            habitualMidsleepSec: nil)
            .selecting(mainSessionStarts: edited.mainSessionStarts)

        XCTAssertFalse(raw.hasRREvidence)
        XCTAssertFalse(raw.hasRespirationEvidence)
    }

    @MainActor
    func testTransientEmptyPassPreservesPersistedRestSeries() async throws {
        let store = try await WhoopStore.inMemory()
        let day = Repository.localDayKey(Date())
        try await store.upsertMetricSeries([
            MetricPoint(
                day: day,
                key: ScoreConfidence.sleepPerformanceSeriesKey,
                value: 82),
            MetricPoint(
                day: day,
                key: ScoreConfidence.restConfidenceSeriesKey,
                value: ScoreConfidence.solid.persistedValue),
            MetricPoint(
                day: day,
                key: ScoreConfidence.restEvidenceSeriesKey,
                value: 55),
        ], deviceId: "my-whoop-noop")

        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let engine = IntelligenceEngine(
            repo: repo,
            profile: ProfileStore(),
            deviceId: "my-whoop")

        _ = await engine.analyzeRecent(maxDays: 1, force: true)

        let rest = try await store.metricSeries(
            deviceId: "my-whoop-noop",
            key: ScoreConfidence.sleepPerformanceSeriesKey,
            from: day,
            to: day)
        let confidence = try await store.metricSeries(
            deviceId: "my-whoop-noop",
            key: ScoreConfidence.restConfidenceSeriesKey,
            from: day,
            to: day)
        let evidence = try await store.metricSeries(
            deviceId: "my-whoop-noop",
            key: ScoreConfidence.restEvidenceSeriesKey,
            from: day,
            to: day)

        XCTAssertEqual(rest.map(\.value), [82])
        XCTAssertEqual(confidence.map(\.value), [ScoreConfidence.solid.persistedValue])
        XCTAssertEqual(evidence.map(\.value), [55])
    }

    func testMergedNightKeepsSparseAndUnknownFragmentProvenance() {
        func session(_ start: Int, sparse: Bool?) -> CachedSleepSession {
            CachedSleepSession(startTs: start, endTs: start + 3_600, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil,
                               gravitySparse: sparse)
        }

        XCTAssertEqual(SleepView.mergedGravitySparse([session(0, sparse: false),
                                                      session(4_000, sparse: true)]), true)
        XCTAssertEqual(SleepView.mergedGravitySparse([session(0, sparse: false),
                                                      session(4_000, sparse: false)]), false)
        XCTAssertNil(SleepView.mergedGravitySparse([session(0, sparse: false),
                                                    session(4_000, sparse: nil)]))
    }

    func testDetailedStageDayFilterFailsClosedWithoutCompleteEvidence() {
        let supported = CachedSleepSession(
            startTs: 1_777_500_000,
            endTs: 1_777_528_800,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"awake":30,"light":230,"deep":80,"rem":100}"#,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 24)
        let unsupported = CachedSleepSession(
            startTs: supported.startTs + 86_400,
            endTs: supported.endTs + 86_400,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: supported.stagesJSON,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 23)
        let days = Repository.publishableDetailedStageDays([
            supported,
            unsupported,
        ], habitualMidsleepSec: nil)

        let supportedEnd = Date(
            timeIntervalSince1970: TimeInterval(supported.endTs))
        XCTAssertEqual(days, [
            AnalyticsEngine.dayString(
                supported.endTs,
                offsetSec: TimeZone.current.secondsFromGMT(for: supportedEnd)),
        ])
    }

    func testDetailedStagePayloadMustDecodeAndDerivedValuesComeFromSession() {
        let malformed = CachedSleepSession(
            startTs: 1_777_500_000,
            endTs: 1_777_528_800,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"unrelated":"nonblank"}"#,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 24)
        XCTAssertTrue(Repository.publishableDetailedStageMinutesByDay(
            [malformed],
            habitualMidsleepSec: nil).isEmpty)

        let valid = CachedSleepSession(
            startTs: malformed.startTs,
            endTs: malformed.endTs,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"awake":20,"light":210,"deep":75,"rem":95}"#,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 24)
        let derived = Repository.publishableDetailedStageMinutesByDay(
            [valid],
            habitualMidsleepSec: nil)
        let wakeDate = Date(timeIntervalSince1970: TimeInterval(valid.endTs))
        let wakeDay = AnalyticsEngine.dayString(
            valid.endTs,
            offsetSec: TimeZone.current.secondsFromGMT(for: wakeDate))
        XCTAssertEqual(derived[wakeDay]?.deep, 75)
        XCTAssertEqual(derived[wakeDay]?.rem, 95)
        XCTAssertEqual(derived[wakeDay]?.light, 210)

        let stale = DailyMetric(
            day: wakeDay,
            totalSleepMin: 380,
            efficiency: 0.95,
            deepMin: 999,
            remMin: 999,
            lightMin: 999,
            disturbances: 2,
            restingHr: 52,
            avgHrv: 60,
            recovery: 70,
            strain: 10,
            exerciseCount: 0)
        let replaced = Repository.replacingDetailedStageColumns(
            stale,
            with: derived[wakeDay])
        XCTAssertEqual(replaced.deepMin, 75)
        XCTAssertEqual(replaced.remMin, 95)
        XCTAssertEqual(replaced.lightMin, 210)

        let bridgedStart = 1_777_600_000
        let stagedFragment = CachedSleepSession(
            startTs: bridgedStart,
            endTs: bridgedStart + 4 * 3_600,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"awake":10,"light":150,"deep":40,"rem":40}"#,
            rrEligibleWindowCount: 48,
            rrValidWindowCount: 12)
        let malformedFragment = CachedSleepSession(
            startTs: bridgedStart + 4 * 3_600 + 600,
            endTs: bridgedStart + 8 * 3_600 + 600,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"not_a_stage":240}"#,
            rrEligibleWindowCount: 48,
            rrValidWindowCount: 12)
        XCTAssertTrue(
            Repository.publishableDetailedStageMinutesByDay(
                [stagedFragment, malformedFragment],
                habitualMidsleepSec: nil
            ).isEmpty,
            "one undecodable fragment must withhold the whole bridged stage split")
    }

    @MainActor
    func testRepositoryEvidenceAuthorizesMainNightButNotSameDayNap() async throws {
        let store = try await WhoopStore.inMemory()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let mainStart = Int(startOfDay.addingTimeInterval(-2 * 3_600).timeIntervalSince1970)
        let mainEnd = Int(startOfDay.addingTimeInterval(6 * 3_600).timeIntervalSince1970)
        let napStart = Int(startOfDay.addingTimeInterval(14 * 3_600).timeIntervalSince1970)
        let stages = #"{"awake":30,"light":230,"deep":80,"rem":100}"#
        let main = CachedSleepSession(
            startTs: mainStart, endTs: mainEnd, efficiency: 0.9,
            restingHr: nil, avgHrv: 55, stagesJSON: stages,
            rrEligibleWindowCount: 96, rrValidWindowCount: 24)
        let nap = CachedSleepSession(
            startTs: napStart, endTs: napStart + 3_600, efficiency: 0.9,
            restingHr: nil, avgHrv: nil, stagesJSON: stages,
            rrEligibleWindowCount: 12, rrValidWindowCount: 12)

        try await store.upsertSleepSessions(
            [main, nap],
            deviceId: Repository.whoopSource + "-noop")

        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        let snapshot = await repo.detailedSleepStageEvidence(
            habitualMidsleepSec: nil)

        XCTAssertTrue(snapshot.canPublish(main))
        XCTAssertFalse(snapshot.canPublish(nap))
    }

    @MainActor
    func testEditedReplacementCannotBorrowStaleWakeDayEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let start = Int(startOfDay.addingTimeInterval(-2 * 3_600).timeIntervalSince1970)
        let end = Int(startOfDay.addingTimeInterval(6 * 3_600).timeIntervalSince1970)
        let stages = #"{"awake":30,"light":230,"deep":80,"rem":100}"#
        let original = CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: 55,
            stagesJSON: stages,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 24)
        let source = Repository.whoopSource + "-noop"
        try await store.upsertSleepSessions([original], deviceId: source)
        try await store.upsertMetricSeries([
            MetricPoint(
                day: Repository.localDayKey(
                    Date(timeIntervalSince1970: TimeInterval(end))),
                key: ScoreConfidence.restEvidenceSeriesKey,
                value: 19),
        ], deviceId: source)

        _ = try await store.applySleepEdit(
            deviceId: source,
            detectedStartTs: start,
            newStartTs: start + 15 * 60,
            newEndTs: end,
            stagesJSON: stages)
        let editedRows = try await store.sleepSessions(
            deviceId: source,
            from: start,
            to: start,
            limit: 2)
        let edited = try XCTUnwrap(editedRows.first)
        XCTAssertNil(edited.rrEligibleWindowCount)
        XCTAssertNil(edited.rrValidWindowCount)

        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        let staleSnapshot = await repo.detailedSleepStageEvidence(
            habitualMidsleepSec: nil)
        XCTAssertFalse(staleSnapshot.canPublish(edited))

        _ = try await store.updateSleepStages(
            deviceId: source,
            detectedStartTs: start,
            stagesJSON: stages,
            rrEligibleWindowCount: 93,
            rrValidWindowCount: 24)
        let rescoredRows = try await store.sleepSessions(
            deviceId: source,
            from: start,
            to: start,
            limit: 2)
        let rescored = try XCTUnwrap(rescoredRows.first)
        let rescoredSnapshot = await repo.detailedSleepStageEvidence(
            habitualMidsleepSec: nil)
        XCTAssertTrue(rescoredSnapshot.canPublish(rescored))
    }

    @MainActor
    func testHealthWritebackSnapshotThrowsWhenAnySourceReadFails() async throws {
        enum ExpectedFailure: Error { case read }

        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        repo.strictSleepSessionReaderForTesting = { source, _, _, _ in
            if source.hasSuffix("-noop") { throw ExpectedFailure.read }
            return []
        }

        do {
            _ = try await repo.sleepWritebackSnapshot(
                from: 0,
                to: Int(Date().timeIntervalSince1970),
                limit: 100)
            XCTFail("A partial source snapshot must not reach HealthKit.")
        } catch ExpectedFailure.read {
            // Expected: no empty-array fallback.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testImportedNapCannotAuthorizeUnsupportedLocalMainNight() {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let mainStart = Int(startOfDay.timeIntervalSince1970)
        let mainEnd = mainStart + 8 * 3_600
        let napStart = mainStart + 14 * 3_600
        let stages = #"{"awake":30,"light":230,"deep":80,"rem":100}"#
        let localMain = CachedSleepSession(
            startTs: mainStart,
            endTs: mainEnd,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: stages)
        let importedNap = CachedSleepSession(
            startTs: napStart,
            endTs: napStart + 3_600,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"awake":5,"light":35,"deep":10,"rem":10}"#)
        let localIdentity = SleepStageEvidenceFingerprint(localMain)
        let napIdentity = SleepStageEvidenceFingerprint(importedNap)
        let unsupported = DetailedSleepStageEvidenceSnapshot(
            independentlyStagedImports: [napIdentity],
            localPermissionBySession: [localIdentity: false])

        XCTAssertTrue(SleepView.detailedStagePublicationDays(
            sessions: [localMain, importedNap],
            evidence: unsupported,
            habitualMidsleepSec: nil
        ).isEmpty)

        let importedMain = DetailedSleepStageEvidenceSnapshot(
            independentlyStagedImports: [localIdentity, napIdentity],
            localPermissionBySession: [:])
        XCTAssertEqual(
            SleepView.detailedStagePublicationDays(
                sessions: [localMain, importedNap],
                evidence: importedMain,
                habitualMidsleepSec: nil),
            [Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(mainEnd)))])
    }

    @MainActor
    func testBridgedStageDetailRequiresEverySelectedFragment() {
        let start = 1_767_312_000
        let staged = CachedSleepSession(
            startTs: start,
            endTs: start + 4 * 3_600,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"awake":10,"light":150,"deep":40,"rem":40}"#)
        let missing = CachedSleepSession(
            startTs: start + 4 * 3_600 + 600,
            endTs: start + 8 * 3_600,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil)
        let evidence = DetailedSleepStageEvidenceSnapshot(
            independentlyStagedImports: [
                SleepStageEvidenceFingerprint(staged),
                SleepStageEvidenceFingerprint(missing),
            ],
            localPermissionBySession: [:])

        XCTAssertEqual(
            SleepView.detailedStagePublicationDays(
                sessions: [staged],
                evidence: evidence,
                habitualMidsleepSec: nil
            ).count,
            1)
        XCTAssertTrue(
            SleepView.detailedStagePublicationDays(
                sessions: [staged, missing],
                evidence: evidence,
                habitualMidsleepSec: nil
            ).isEmpty)
    }

    func testDetailedStageAliasesUseAuthorizedSessionMinutes() {
        let minutes = SleepStageTotals.Minutes(
            awake: 30,
            light: 230,
            deep: 80,
            rem: 100)

        XCTAssertEqual(
            Repository.detailedStageValue(key: "awake_min", minutes: minutes),
            30)
        XCTAssertEqual(
            Repository.detailedStageValue(key: "restorative_min", minutes: minutes),
            180)
        XCTAssertEqual(
            Repository.detailedStageValue(
                key: "restorative_pct",
                minutes: minutes) ?? -1,
            180.0 / 410.0 * 100.0,
            accuracy: 1e-9)
    }

    func testStageEvidenceDoesNotLeakBetweenSameTimestampSourceTwins() {
        let start = 1_777_500_000
        let end = start + 8 * 3_600
        let stages = #"{"awake":30,"light":230,"deep":80,"rem":100}"#
        let imported = CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: stages)
        let localWithDifferentEvidence = CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: stages,
            rrEligibleWindowCount: 96,
            rrValidWindowCount: 23)
        let editedTwin = CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: stages,
            userEdited: true,
            startTsAdjusted: start + 15 * 60)
        let snapshot = DetailedSleepStageEvidenceSnapshot(
            independentlyStagedImports: [SleepStageEvidenceFingerprint(imported)],
            localPermissionBySession: [
                SleepStageEvidenceFingerprint(localWithDifferentEvidence): false,
                SleepStageEvidenceFingerprint(editedTwin): false,
            ])

        XCTAssertTrue(snapshot.canPublish(imported))
        XCTAssertTrue(snapshot.isIndependentlyStagedImport(imported))
        XCTAssertFalse(snapshot.canPublish(localWithDifferentEvidence))
        XCTAssertFalse(snapshot.isIndependentlyStagedImport(localWithDifferentEvidence))
        XCTAssertFalse(snapshot.canPublish(editedTwin))
        XCTAssertFalse(snapshot.isIndependentlyStagedImport(editedTwin))
    }

    func testByteIdenticalImportedAndLocalStageRowsFailClosed() {
        let session = CachedSleepSession(
            startTs: 1_777_500_000,
            endTs: 1_777_528_800,
            efficiency: 0.9,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: #"{"awake":30,"light":230,"deep":80,"rem":100}"#)
        let identity = SleepStageEvidenceFingerprint(session)
        let ambiguous = DetailedSleepStageEvidenceSnapshot(
            independentlyStagedImports: [identity],
            localPermissionBySession: [identity: false])

        XCTAssertFalse(ambiguous.canPublish(session))
        XCTAssertFalse(ambiguous.isIndependentlyStagedImport(session))
    }

    func testFinalLocalWakeDayUsesLastFragmentOfBridgedNight() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = 1_767_312_000
        let first = CachedSleepSession(
            startTs: midnight - 4 * 3_600,
            endTs: midnight - 300,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil)
        let second = CachedSleepSession(
            startTs: midnight + 300,
            endTs: midnight + 4 * 3_600,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil)
        let group = SleepView.mainNightGroup([first, second], timeZone: utc)

        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(SleepView.finalLocalWakeDay(group, timeZone: utc), "2026-01-02")
    }

    func testHistoricalHabitualMidsleepUsesWinterOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let baseMidpoint = 1_767_254_400 // 2026-01-01 08:00 UTC
        let sessions = (0..<14).map { index in
            let midpoint = baseMidpoint + index * 86_400
            return CachedSleepSession(
                startTs: midpoint - 4 * 3_600,
                endTs: midpoint + 4 * 3_600,
                efficiency: nil,
                restingHr: nil,
                avgHrv: nil,
                stagesJSON: nil)
        }

        XCTAssertEqual(
            Repository.historicalHabitualMidsleepSec(
                sessions,
                timeZone: zone),
            3 * 3_600)
    }

    @MainActor
    func testExploreGatesDetailedStagesPerComputedSourceBeforeMerging() async throws {
        let store = try await WhoopStore.inMemory()
        let active = "whoop-active"
        let day = "2026-08-20"
        let end = Int(ISO8601DateFormatter()
            .date(from: "2026-08-20T10:00:00Z")!.timeIntervalSince1970)
        let stages = #"{"awake":30,"light":230,"deep":80,"rem":100}"#
        try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: end - 8 * 3_600,
                endTs: end,
                efficiency: 0.9,
                restingHr: nil,
                avgHrv: nil,
                stagesJSON: stages,
                rrEligibleWindowCount: 96,
                rrValidWindowCount: 23),
        ], deviceId: active + "-noop")
        try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: end - 8 * 3_600,
                endTs: end,
                efficiency: 0.9,
                restingHr: nil,
                avgHrv: nil,
                stagesJSON: stages,
                rrEligibleWindowCount: 96,
                rrValidWindowCount: 24),
        ], deviceId: Repository.whoopSource + "-noop")

        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "sleep_deep_min", value: 111),
            MetricPoint(day: day, key: ScoreConfidence.restEvidenceSeriesKey,
                        value: 19),
        ], deviceId: active + "-noop")
        try await store.upsertMetricSeries([
            MetricPoint(day: day, key: "sleep_deep_min", value: 82),
            MetricPoint(day: day, key: ScoreConfidence.restEvidenceSeriesKey,
                        value: 3),
        ], deviceId: Repository.whoopSource + "-noop")

        let repo = Repository(deviceId: active)
        repo.setStoreForTesting(store)
        XCTAssertEqual(Repository.dayAfter("9999-12-31"), "9999-12-31")
        let expected: [String: Double] = [
            "sleep_deep_min": 80,
            "deep_min": 80,
            "sleep_rem_min": 100,
            "rem_min": 100,
            "sleep_light_min": 230,
            "core_min": 230,
            "sleep_awake_min": 30,
            "awake_min": 30,
            "restorative_min": 180,
            "restorative_pct": 180.0 / 410.0 * 100.0,
        ]
        for (key, value) in expected {
            let points = await repo.exploreSeries(
                key: key,
                source: Repository.whoopSource,
                fullHistory: true)
            XCTAssertEqual(points.map(\.day), [day], key)
            XCTAssertEqual(
                try XCTUnwrap(points.first?.value),
                value,
                accuracy: 1e-9,
                "\(key) must be derived from the authorized session JSON")
        }
    }

    func testMainSleepUsesOffsetAtHistoricalWakeInsteadOfCurrentOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func session(_ start: Int, _ end: Int) -> CachedSleepSession {
            CachedSleepSession(
                startTs: start,
                endTs: end,
                efficiency: nil,
                restingHr: nil,
                avgHrv: nil,
                stagesJSON: nil
            )
        }
        // 2026-01-11 04:30...05:30 UTC = 23:30...00:30 EST, midpoint 00:00.
        let early = session(1_768_105_800, 1_768_109_400)
        // 2026-01-11 11:00...12:00 UTC = 06:00...07:00 EST, midpoint 06:30.
        let late = session(1_768_129_200, 1_768_132_800)

        XCTAssertEqual(-18_000, SleepView.tzOffsetSec(at: late.endTs, timeZone: zone))
        XCTAssertEqual(
            late.startTs,
            SleepView.mainNightSession([early, late], timeZone: zone)?.startTs
        )
        XCTAssertEqual(
            [late.startTs],
            SleepView.mainNightGroup([early, late], timeZone: zone).map(\.startTs)
        )
    }

    func testPortableCsvAttributesEveryCrossMidnightFragmentToFinalWakeDay() throws {
        let midnight = 1_767_312_000
        let first = CachedSleepSession(
            startTs: midnight - 4 * 3_600,
            endTs: midnight - 300,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil)
        let second = CachedSleepSession(
            startTs: midnight + 300,
            endTs: midnight + 4 * 3_600,
            efficiency: nil,
            restingHr: nil,
            avgHrv: nil,
            stagesJSON: nil)
        let source = "computed-source"
        let sourceMap = Dictionary(uniqueKeysWithValues: [first, second].map {
            (CsvExport.SleepExportIdentity($0), source)
        })
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let wakeDays = CsvExport.bridgedWakeDayBySleep(
            [first, second],
            sourceBySession: sourceMap,
            timeZone: utc)

        XCTAssertEqual(Set(wakeDays.values), ["2026-01-02"])
        XCTAssertEqual(wakeDays.count, 2)
    }
}
