import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class ScoreConfidenceEvidenceTests: XCTestCase {
    func testStableEvidenceMaskRoundTrips() {
        let evidence = ScoreConfidence.restEvidenceFlags(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: 8 * 3_600,
            restorativeSeconds: 3 * 3_600,
            efficiency: 0.9,
            motionAvailable: true,
            gravitySparse: false,
            hasRREvidence: true,
            hasRespirationEvidence: true)

        XCTAssertEqual(evidence.rawValue, 55)
        XCTAssertEqual(
            ScoreConfidence.RestEvidenceFlags(persistedValue: evidence.persistedValue),
            evidence)
        XCTAssertEqual(ScoreConfidence.sleepPerformanceSeriesKey, "sleep_performance")
        XCTAssertEqual(ScoreConfidence.restConfidenceSeriesKey, "rest_confidence")
        XCTAssertEqual(ScoreConfidence.restEvidenceSeriesKey, "rest_evidence_flags")
    }

    func testEvidenceDecoderRejectsUnknownAndInconsistentBits() {
        XCTAssertNil(ScoreConfidence.RestEvidenceFlags(persistedValue: 128))
        XCTAssertNil(ScoreConfidence.RestEvidenceFlags(persistedValue: 1.5))
        XCTAssertNil(ScoreConfidence.RestEvidenceFlags(persistedValue: 2))
        XCTAssertNil(ScoreConfidence.RestEvidenceFlags(persistedValue: 8))
        XCTAssertNil(ScoreConfidence.RestEvidenceFlags(persistedValue: .nan))
    }

    func testCardiorespiratoryEvidenceLanesRemainIndependent() {
        let rrOnly = ScoreConfidence.restEvidenceFlags(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: 8 * 3_600,
            restorativeSeconds: 3 * 3_600,
            efficiency: 0.9,
            motionAvailable: true,
            gravitySparse: false,
            hasRREvidence: true,
            hasRespirationEvidence: false)
        let respirationOnly = ScoreConfidence.restEvidenceFlags(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: 8 * 3_600,
            restorativeSeconds: 3 * 3_600,
            efficiency: 0.9,
            motionAvailable: true,
            gravitySparse: false,
            hasRREvidence: false,
            hasRespirationEvidence: true)

        XCTAssertEqual(
            ScoreConfidence.restAssessment(evidence: rrOnly).limitations,
            [.missingRespirationEvidence])
        XCTAssertEqual(
            ScoreConfidence.restAssessment(evidence: respirationOnly).limitations,
            [.missingRREvidence])
    }

    func testEditedStageMixRecomputesConfidenceFromPreservedSensorEvidence() {
        let beforeEdit = ScoreConfidence.restEvidenceFlags(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: 480 * 60,
            restorativeSeconds: 180 * 60,
            efficiency: 0.9,
            motionAvailable: true,
            gravitySparse: false,
            hasRREvidence: true,
            hasRespirationEvidence: true)
        let afterEdit = ScoreConfidence.restEvidenceFlags(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: 480 * 60,
            restorativeSeconds: 20 * 60,
            efficiency: 0.9,
            motionAvailable: true,
            gravitySparse: false,
            hasRREvidence: true,
            hasRespirationEvidence: true)

        XCTAssertEqual(ScoreConfidence.restAssessment(evidence: beforeEdit).confidence, .solid)
        XCTAssertEqual(ScoreConfidence.restAssessment(evidence: afterEdit).confidence, .building)
        XCTAssertTrue(afterEdit.contains(.implausibleStageMix))
    }

    func testSparseRespirationWindowsDoNotCountAsEvidence() {
        let start = 1_700_000_000
        let windowCount = AnalyticsEngine.restEvidenceMinimumWindows
        let end = start + windowCount * AnalyticsEngine.restEvidenceWindowSeconds
        let session = SleepSession(
            start: start,
            end: end,
            efficiency: 0.9,
            stages: [StageSegment(start: start, end: end, stage: "light")],
            restingHR: nil,
            avgHRV: nil
        )
        let sparse = (0..<windowCount).flatMap { window in
            (0..<30).map { index in
                let phase = Double(index % 4) * 2 * Double.pi / 4
                return RespSample(
                    ts: start + window * AnalyticsEngine.restEvidenceWindowSeconds + index * 10,
                    raw: 1_000 + Int((100 * sin(phase)).rounded())
                )
            }
        }
        let oldTimestampFreeWindow = sparse.prefix(30).map { Double($0.raw) }
        let oldEvidence = SleepStager.respRateAndRRV(oldTimestampFreeWindow)
        XCTAssertTrue(oldEvidence.0.isFinite)
        XCTAssertTrue(oldEvidence.1.isFinite)

        let counts = AnalyticsEngine.mainSleepEvidenceCounts(
            mainGroup: [session],
            rr: [],
            resp: sparse
        )

        XCTAssertEqual(counts.eligibleWindows, windowCount)
        XCTAssertEqual(counts.validRespirationWindows, 0)
        XCTAssertFalse(counts.resolved.hasRespirationEvidence)
    }

    func testDenseRespirationWindowsStillCountAsEvidence() {
        let start = 1_700_000_000
        let windowCount = AnalyticsEngine.restEvidenceMinimumWindows
        let end = start + windowCount * AnalyticsEngine.restEvidenceWindowSeconds
        let session = SleepSession(
            start: start,
            end: end,
            efficiency: 0.9,
            stages: [StageSegment(start: start, end: end, stage: "light")],
            restingHR: nil,
            avgHRV: nil
        )
        let dense = (start..<end).map { ts in
            let phase = Double((ts - start) % 4) * 2 * Double.pi / 4
            return RespSample(ts: ts, raw: 1_000 + Int((100 * sin(phase)).rounded()))
        }

        let counts = AnalyticsEngine.mainSleepEvidenceCounts(
            mainGroup: [session],
            rr: [],
            resp: dense
        )

        XCTAssertEqual(counts.validRespirationWindows, windowCount)
        XCTAssertTrue(counts.resolved.hasRespirationEvidence)
    }
}
