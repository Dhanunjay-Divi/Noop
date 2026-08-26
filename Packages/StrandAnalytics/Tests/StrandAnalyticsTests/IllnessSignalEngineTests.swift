import XCTest
@testable import StrandAnalytics

final class IllnessSignalEngineTests: XCTestCase {

    private let labels = [
        "restingHR": "RHR +6",
        "skinTemp": "skin temp +0.7 °C",
        "hrv": "HRV −22%",
        "respiration": "respiration up",
    ]

    private func reading(_ z: Double) -> IllnessSignalEngine.SignalReading {
        IllnessSignalEngine.SignalReading(zIllnessward: z)
    }

    // MARK: - Classic illness pattern (no tags) → raised

    func testClassicThreeSignalPatternRaises() {
        // RHR, skin temp and HRV all well over the firing threshold, no confounders.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.level, .raised)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertEqual(r.signalCount, 3)
        XCTAssertEqual(r.trustedSignalCount, 3)
        XCTAssertEqual(r.displayState, .alert)
        XCTAssertEqual(r.firedSignals, ["RHR +6", "skin temp +0.7 °C", "HRV −22%"])
        XCTAssertTrue(r.suppressedBy.isEmpty)
        XCTAssertTrue(r.copy.contains("not a diagnosis"))
    }

    // MARK: - Context is visible but never suppresses a corroborated shift

    func testAlcoholTagDoesNotSuppress() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let raised = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        let contextual = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true), firedLabels: labels)
        XCTAssertEqual(contextual.level, .raised)
        XCTAssertEqual(contextual.suppressedBy, ["alcohol"])
        XCTAssertEqual(contextual.score, raised.score, accuracy: 1e-9)
        XCTAssertTrue(contextual.copy.contains("alcohol"))
        XCTAssertTrue(contextual.copy.contains("does not rule out"))
        XCTAssertTrue(contextual.copy.contains("not a diagnosis"))
    }

    func testStressSaunaTravelRemainRaisedWithReason() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let stress = IllnessSignalEngine.evaluate(inputs, context: .init(stress: true), firedLabels: labels)
        XCTAssertEqual(stress.level, .raised)
        XCTAssertEqual(stress.suppressedBy, ["stress"])

        let sauna = IllnessSignalEngine.evaluate(inputs, context: .init(sauna: true), firedLabels: labels)
        XCTAssertEqual(sauna.suppressedBy, ["sauna"])

        let travel = IllnessSignalEngine.evaluate(
            inputs, context: .init(travelPhaseJump: true), firedLabels: labels)
        XCTAssertEqual(travel.suppressedBy, ["travel"])
        XCTAssertTrue(travel.copy.contains("travel"))
    }

    func testMultipleConfoundersJoinNaturally() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true, stress: true), firedLabels: labels)
        XCTAssertEqual(r.suppressedBy, ["alcohol", "stress"])
        XCTAssertTrue(r.copy.contains("alcohol and stress"))
    }

    func testRecentMedicationChangeIsContextOnly() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let raw = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        let contextual = IllnessSignalEngine.evaluate(
            inputs,
            context: .init(recentMedicationChange: true),
            firedLabels: labels
        )
        XCTAssertEqual(contextual.level, raw.level)
        XCTAssertEqual(contextual.score, raw.score, accuracy: 1e-9)
        XCTAssertEqual(contextual.signalCount, raw.signalCount)
        XCTAssertEqual(contextual.suppressedBy, ["a recent medication change"])
        XCTAssertTrue(contextual.copy.contains("recent medication change"))
        XCTAssertTrue(contextual.copy.contains("does not rule out"))
    }

    // MARK: - Already-sick tag → "rest up" copy, not "early warning"

    func testAlreadyUnwellSwitchesCopy() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alreadyUnwell: true), firedLabels: labels)
        XCTAssertEqual(r.level, .alreadyUnwell)
        XCTAssertTrue(r.copy.contains("feeling unwell"))
        XCTAssertTrue(r.copy.contains("signals also shifted"))
        XCTAssertTrue(r.copy.contains("cannot assess severity"))
        XCTAssertFalse(r.copy.contains("Heads-up"))
    }

    // MARK: - Gates: single noisy night / untrusted baseline → silent

    func testSingleSignalDoesNotRaise() {
        // Only one signal over threshold → below corroboration gate → quiet.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(4.0))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 1)
        XCTAssertEqual(r.trustedSignalCount, 1)
        XCTAssertEqual(r.displayState, .building)
    }

    func testUntrustedBaselineStaysSilent() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(baselineTrusted: false), firedLabels: labels)
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.trustedSignalCount, 0)
        XCTAssertEqual(r.displayState, .building)
        XCTAssertFalse(r.copy.contains("Heads-up"))
        XCTAssertTrue(r.copy.contains("Missing data is not a healthy result"))
    }

    func testAlreadyUnwellOverridesUntrustedBaselineAndMissingSignals() {
        let r = IllnessSignalEngine.evaluate(
            .init(),
            context: .init(alreadyUnwell: true, baselineTrusted: false),
            firedLabels: labels
        )
        XCTAssertEqual(r.level, .alreadyUnwell)
        XCTAssertTrue(r.copy.contains("cannot rule out"))
        XCTAssertTrue(r.copy.contains("severe or worsening"))
    }

    func testBelowThresholdSignalsAreMildNotRaised() {
        // Two signals just over the firing threshold but composite below raiseThreshold → mild.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(2.6), skinTemp: reading(2.6))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertEqual(r.level, .mild)
        XCTAssertEqual(r.displayState, .watch)
        XCTAssertLessThan(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.mildThreshold)
    }

    func testAbsentSignalsDoNotCount() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2),
            skinTemp: IllnessSignalEngine.SignalReading(zIllnessward: 9.0, present: false),
            hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        // The absent skin-temp does not fire despite its huge z.
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertFalse(r.firedSignals.contains("skin temp +0.7 °C"))
    }

    func testNonFiniteSignalsDoNotCountOrPoisonScore() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(.nan),
            skinTemp: reading(.infinity),
            hrv: reading(3.5),
            respiration: reading(3.2)
        )
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertTrue(r.score.isFinite)
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertEqual(r.firedSignals, ["HRV −22%", "respiration up"])
    }

    func testQuietCopyDoesNotClaimHealthOrNormality() {
        let r = IllnessSignalEngine.evaluate(
            .init(restingHR: reading(0), hrv: reading(0)),
            context: .init(),
            firedLabels: labels
        )
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.trustedSignalCount, 2)
        XCTAssertEqual(r.displayState, .steady)
        XCTAssertTrue(r.copy.contains("does not assess overall health"))
        XCTAssertFalse(r.copy.lowercased().contains("normal"))
    }

    // MARK: - Copy never names a condition

    func testCopyNeverNamesACondition() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let banned = ["covid", "flu", "fever", "infection", "sick with", "illness with", "disease"]
        for ctx in [IllnessSignalEngine.Context(),
                    .init(alcohol: true),
                    .init(alreadyUnwell: true)] {
            let copy = IllnessSignalEngine.evaluate(inputs, context: ctx, firedLabels: labels).copy.lowercased()
            for b in banned { XCTAssertFalse(copy.contains(b), "copy contained banned term \(b): \(copy)") }
        }
    }

    func testScorePerSignalCapping() {
        // A single enormous z is capped, so it alone can't saturate the composite.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(100.0), skinTemp: reading(2.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        // RHR caps at perSignalCap (40) + skinTemp small contribution.
        let expectedSkin = IllnessSignalEngine.kZToScore * (2.5 - IllnessSignalEngine.signalZThreshold)
        XCTAssertEqual(r.score, IllnessSignalEngine.perSignalCap + expectedSkin, accuracy: 1e-9)
    }

    func testDailySignalStatusRequiresSolidCurrentEvidence() {
        let aligned = ReadinessEngine.Readiness(
            level: .primed,
            headline: "Aligned",
            summary: "Available signals are aligned.",
            signals: [],
            effortVariety: nil,
            asOfDay: "2026-08-23",
            confidence: .solid
        )
        let thin = ReadinessEngine.Readiness(
            level: .primed,
            headline: "Aligned",
            summary: "Available signals are aligned.",
            signals: [],
            effortVariety: nil,
            asOfDay: "2026-08-23",
            confidence: .building
        )
        let quiet = IllnessSignalEngine.evaluate(
            .init(restingHR: reading(0), hrv: reading(0)),
            context: .init(),
            firedLabels: labels
        )
        let raised = IllnessSignalEngine.evaluate(
            .init(restingHR: reading(3.5), hrv: reading(3.5)),
            context: .init(),
            firedLabels: labels
        )

        XCTAssertEqual(DailySignalStatus.resolve(readiness: aligned, illness: quiet), .steady)
        XCTAssertEqual(DailySignalStatus.resolve(readiness: thin, illness: quiet), .building)
        XCTAssertEqual(DailySignalStatus.resolve(readiness: aligned, illness: raised), .alert)
        XCTAssertEqual(DailySignalStatus.resolve(readiness: thin, illness: nil), .building)
    }
}
