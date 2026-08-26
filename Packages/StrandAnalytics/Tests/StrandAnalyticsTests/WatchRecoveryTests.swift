import XCTest
@testable import StrandAnalytics

/// Tests for `WatchRecovery`, the honesty-critical recovery-from-daily-aggregate engine behind
/// "Apple Watch as a device". The watch gives sparse daily SDNN + resting HR rather than the
/// strap's dense RR stream, so these fixtures pin the BEHAVIOUR (at-baseline ≈ mid, high-HRV /
/// low-RHR → high, thin history / missing today → nil + calibrating) regardless of the exact
/// logistic constants, which are inherited unchanged from `RecoveryScorer` (the strap Charge
/// engine) so watch recovery and strap recovery sit on the same scale.
final class WatchRecoveryTests: XCTestCase {

    private let appleSDNN = WatchRecovery.HRVProvenance(
        sourceID: "apple-health", method: .sdnn)

    private func sample(_ value: Double,
                        provenance: WatchRecovery.HRVProvenance? = nil) -> WatchRecovery.HRVSample {
        WatchRecovery.HRVSample(value: value, provenance: provenance ?? appleSDNN)
    }

    private func compute(today: Double?, todayRHR: Int?,
                         history: [Double], rhrHistory: [Double]) -> WatchRecovery.Result {
        WatchRecovery.compute(
            provenance: appleSDNN,
            todayHRV: today.map { sample($0) },
            todayRHR: todayRHR,
            hrvHistory: history.map { sample($0) },
            rhrHistory: rhrHistory)
    }

    // A person whose HRV today equals their baseline and RHR equals baseline → mid recovery,
    // solid confidence (14 nights of history clears the trusted gate).
    func testAtBaselineGivesMidRecoverySolid() {
        let hist = Array(repeating: 45.0, count: 14)            // 14 nights of SDNN
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = compute(today: 45.0, todayRHR: 52,
                          history: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertGreaterThanOrEqual(out.recovery!, 40)
        XCTAssertLessThanOrEqual(out.recovery!, 60)
        XCTAssertEqual(out.confidence, .solid)
    }

    // HRV well above baseline + RHR below baseline → high recovery.
    func testHighHRVLowRHRGivesHighRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = compute(today: 70.0, todayRHR: 46,
                          history: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertGreaterThan(out.recovery!, 65)
    }

    // HRV well below baseline + RHR above baseline → low recovery (the symmetric case;
    // a bad night must read low, not get floored at mid).
    func testLowHRVHighRHRGivesLowRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = compute(today: 22.0, todayRHR: 62,
                          history: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        XCTAssertLessThan(out.recovery!, 40)
    }

    // Too little history → calibrating, nil recovery (never a fabricated number).
    func testInsufficientHistoryCalibrates() {
        let out = compute(today: 45.0, todayRHR: 52,
                          history: [45, 46], rhrHistory: [52, 51])
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // History just under the week gate → still calibrating (the gate is exactly minBaselineNights).
    func testHistoryJustBelowGateCalibrates() {
        let n = WatchRecovery.minBaselineNights - 1
        let out = compute(today: 45.0, todayRHR: 52,
                          history: Array(repeating: 45.0, count: n),
                          rhrHistory: Array(repeating: 52.0, count: n))
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // History at the week gate (and usable baseline) → scores, no longer calibrating.
    func testHistoryAtGateScores() {
        let n = WatchRecovery.minBaselineNights
        let out = compute(today: 45.0, todayRHR: 52,
                          history: Array(repeating: 45.0, count: n),
                          rhrHistory: Array(repeating: 52.0, count: n))
        XCTAssertNotNil(out.recovery)
        XCTAssertNotEqual(out.confidence, .calibrating)
    }

    // Missing today's HRV → calibrating, nil (we never score off RHR alone).
    func testMissingTodayCalibrates() {
        let out = compute(today: nil, todayRHR: 52,
                          history: Array(repeating: 45.0, count: 14),
                          rhrHistory: Array(repeating: 52.0, count: 14))
        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    // Missing today's RHR (but HRV present + baseline usable) → still scores off HRV alone,
    // honestly, rather than nil-ing out. RHR is an optional term.
    func testMissingTodayRHRStillScoresFromHRV() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = compute(today: 45.0, todayRHR: nil,
                          history: hist, rhrHistory: rhrHist)
        XCTAssertNotNil(out.recovery)
        // At-baseline HRV with the RHR term dropped should still land near the mid band.
        XCTAssertGreaterThanOrEqual(out.recovery!, 40)
        XCTAssertLessThanOrEqual(out.recovery!, 70)
    }

    // Watch recovery is on the SAME scale as strap recovery: feeding identical at-baseline inputs
    // to RecoveryScorer directly (HRV + RHR terms only) reproduces WatchRecovery's number.
    func testSameScaleAsStrapRecovery() {
        let hist = Array(repeating: 45.0, count: 14)
        let rhrHist = Array(repeating: 52.0, count: 14)
        let out = compute(today: 58.0, todayRHR: 50,
                          history: hist, rhrHistory: rhrHist)
        let hrvBase = Baselines.foldHistory(hist.map { Optional($0) }, cfg: Baselines.hrvCfg)
        let rhrBase = Baselines.foldHistory(rhrHist.map { Optional($0) }, cfg: Baselines.restingHRCfg)
        let strap = RecoveryScorer.recovery(hrv: 58.0, rhr: 50.0, resp: nil,
                                            hrvBaseline: hrvBase, rhrBaseline: rhrBase,
                                            respBaseline: nil, sleepPerf: nil)
        XCTAssertNotNil(out.recovery)
        XCTAssertNotNil(strap)
        XCTAssertEqual(out.recovery!, strap!, accuracy: 0.0001)
    }

    func testResultExposesExactHRVMethodAndSource() {
        let out = compute(
            today: 45, todayRHR: 52,
            history: Array(repeating: 45, count: 14),
            rhrHistory: Array(repeating: 52, count: 14))

        XCTAssertEqual(out.hrvProvenance, appleSDNN)
        XCTAssertEqual(out.hrvProvenance.method, .sdnn)
        XCTAssertEqual(out.hrvProvenance.label, "apple-health HRV (SDNN)")
    }

    func testBaselineExcludesOtherMethodsAndSources() {
        let otherMethod = WatchRecovery.HRVProvenance(
            sourceID: "apple-health", method: .rmssd)
        let otherSource = WatchRecovery.HRVProvenance(
            sourceID: "noop-band", method: .sdnn)
        let cleanHistory = Array(repeating: sample(45), count: 14)
        let contaminatedHistory = cleanHistory
            + Array(repeating: sample(200, provenance: otherMethod), count: 20)
            + Array(repeating: sample(5, provenance: otherSource), count: 20)

        let clean = WatchRecovery.compute(
            provenance: appleSDNN,
            todayHRV: sample(50),
            todayRHR: 52,
            hrvHistory: cleanHistory,
            rhrHistory: Array(repeating: 52, count: 14))
        let contaminated = WatchRecovery.compute(
            provenance: appleSDNN,
            todayHRV: sample(50),
            todayRHR: 52,
            hrvHistory: contaminatedHistory,
            rhrHistory: Array(repeating: 52, count: 14))

        XCTAssertEqual(contaminated.recovery, clean.recovery,
                       "RMSSD and other-source SDNN must not move the Apple SDNN baseline")
        XCTAssertEqual(contaminated.confidence, clean.confidence)
    }

    func testOtherMethodCannotSatisfyBaselineGate() {
        let rmssd = WatchRecovery.HRVProvenance(
            sourceID: "apple-health", method: .rmssd)
        let matching = Array(repeating: sample(45),
                             count: WatchRecovery.minBaselineNights - 1)
        let mismatched = Array(repeating: sample(45, provenance: rmssd), count: 30)

        let out = WatchRecovery.compute(
            provenance: appleSDNN,
            todayHRV: sample(45),
            todayRHR: 52,
            hrvHistory: matching + mismatched,
            rhrHistory: Array(repeating: 52, count: 30))

        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
    }

    func testTodaySampleMustMatchExpectedProvenance() {
        let rmssd = WatchRecovery.HRVProvenance(
            sourceID: "apple-health", method: .rmssd)
        let out = WatchRecovery.compute(
            provenance: appleSDNN,
            todayHRV: sample(45, provenance: rmssd),
            todayRHR: 52,
            hrvHistory: Array(repeating: sample(45), count: 14),
            rhrHistory: Array(repeating: 52, count: 14))

        XCTAssertNil(out.recovery)
        XCTAssertEqual(out.confidence, .calibrating)
        XCTAssertEqual(out.hrvProvenance, appleSDNN)
    }
}
