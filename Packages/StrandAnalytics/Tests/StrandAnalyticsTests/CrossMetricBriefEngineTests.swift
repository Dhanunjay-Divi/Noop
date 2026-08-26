import XCTest
@testable import StrandAnalytics

final class CrossMetricBriefEngineTests: XCTestCase {
    private func signal(_ key: String, _ label: String, flag: ReadinessEngine.Flag,
                        evidence: String = "today vs baseline") -> ReadinessEngine.Signal {
        .init(key: key, label: label, evidence: evidence, detail: "shifted", flag: flag)
    }

    private func readiness(_ level: ReadinessEngine.Level,
                           _ signals: [ReadinessEngine.Signal]) -> ReadinessEngine.Readiness {
        .init(level: level, headline: "Readiness", summary: "Summary",
              signals: signals, effortVariety: nil)
    }

    func testColdStartBuildsWithoutInventingAdvice() {
        let result = CrossMetricBriefEngine.evaluate(readiness: readiness(.insufficient, []))
        XCTAssertEqual(result.state, .building)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testSingleSignalIsOnlyARecheck() {
        let result = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.strained, [signal("hrv", "HRV", flag: .bad)]))
        XCTAssertEqual(result.findings.map(\.kind), [.singleSignal])
        XCTAssertEqual(result.findings.first?.confidence, .early)
        XCTAssertTrue(result.findings.first?.summary.contains("not a conclusion") == true)
    }

    func testEffortContextNeedsIndependentRecoverySignal() {
        let effortOnly = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.strained, [
                signal("effortVariety", "Effort variety", flag: .watch),
            ]))
        XCTAssertTrue(effortOnly.findings.isEmpty)

        let combined = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.rundown, [
                signal("effortVariety", "Effort variety", flag: .watch),
                signal("hrv", "HRV", flag: .bad),
            ]))
        XCTAssertEqual(combined.findings.first?.kind, .effortRecovery)
        XCTAssertTrue(combined.findings.first?.summary.contains("association") == true)
        XCTAssertTrue(combined.findings.first?.summary.contains("injury risk") == true)
        XCTAssertFalse(combined.findings.first?.possibleContributors.contains("Hard or unfamiliar training") == true)
    }

    func testSleepAssociationRequiresRecoveryCorroboration() {
        let sleepOnly = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.balanced, []), restScore: 55)
        XCTAssertTrue(sleepOnly.findings.isEmpty)

        let combined = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.strained, [signal("rhr", "Resting HR", flag: .bad)]),
            restScore: 55)
        XCTAssertEqual(combined.findings.first?.kind, .sleepRecovery)
        XCTAssertTrue(combined.findings.first?.summary.contains("association") == true)
        XCTAssertTrue(combined.findings.first?.summary.contains("Sleep Score") == true)
        XCTAssertTrue(combined.findings.first?.evidence.contains("Sleep Score 55 of 100") == true)
        XCTAssertTrue(combined.checkedSignals.contains("Sleep Score"))
        XCTAssertFalse(combined.checkedSignals.contains("Rest"))
    }

    func testConfoundedMultiVitalShiftUsesContextWithoutClaimingCause() {
        let illness = IllnessSignalEngine.Result(
            score: 32, level: .suppressed,
            firedSignals: ["RHR +6", "HRV −18%"],
            suppressedBy: ["alcohol"], signalCount: 2,
            copy: "Legacy condition-oriented copy should not be surfaced.")
        let result = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.rundown, [
                signal("rhr", "Resting HR", flag: .bad),
                signal("hrv", "HRV", flag: .bad),
            ]),
            illness: illness)
        XCTAssertEqual(result.findings.first?.kind, .multiVital)
        XCTAssertTrue(result.findings.first?.summary.contains("cannot prove the cause") == true)
        XCTAssertFalse(result.summary.contains("Legacy"))
    }

    func testOutputIsDeduplicatedAndCapped() {
        let illness = IllnessSignalEngine.Result(
            score: 72, level: .raised,
            firedSignals: ["RHR +6", "HRV −18%", "respiration up"],
            suppressedBy: [], signalCount: 3, copy: "unused")
        let result = CrossMetricBriefEngine.evaluate(
            readiness: readiness(.rundown, [
                signal("effortVariety", "Effort variety", flag: .watch),
                signal("hrv", "HRV", flag: .bad),
                signal("rhr", "Resting HR", flag: .bad),
            ]),
            illness: illness,
            restScore: 45)
        XCTAssertEqual(result.findings.count, 2)
        XCTAssertEqual(result.findings.map(\.kind), [.multiVital, .effortRecovery])
        XCTAssertEqual(result.checkedSignals.filter { $0 == "HRV" }.count, 1)
        XCTAssertTrue(CrossMetricBriefEngine.disclaimer.contains("not a diagnosis"))
    }
}
