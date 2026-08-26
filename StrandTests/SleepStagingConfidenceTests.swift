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
}
