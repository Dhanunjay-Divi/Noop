import XCTest
@testable import StrandAnalytics

final class SleepStagerRespEvidenceTests: XCTestCase {
    func testEvidenceSeparatesMissingMeasuredAndDegenerateBars() {
        XCTAssertEqual(SleepStager.RespEvidence.of(.nan, lowBar: 0.5, highBar: 1.0), .unmeasured)
        XCTAssertEqual(SleepStager.RespEvidence.of(0.4, lowBar: 0.5, highBar: 1.0), .regular)
        XCTAssertEqual(SleepStager.RespEvidence.of(0.7, lowBar: 0.5, highBar: 1.0), .measuredMidBand)
        XCTAssertEqual(SleepStager.RespEvidence.of(1.1, lowBar: 0.5, highBar: 1.0), .irregular)
        XCTAssertEqual(SleepStager.RespEvidence.of(0.5, lowBar: 0.5, highBar: 0.5), .barsDegenerate)
    }

    func testNewRepresentationPreservesFormerClassifierLabels() {
        let moves = [0.0, 0.12, 0.2]
        let hrs = [50.0, 60.0, 80.0, Double.nan]
        let hrVars = [0.0, 5.0]
        let rmssds = [20.0, 60.0, Double.nan]
        let rrvs = [0.4, 0.7, 1.1, Double.nan]
        let barPairs: [(Double?, Double?)] = [(0.5, 1.0), (0.5, 0.5), (nil, nil)]

        func former(_ f: SleepStager.EpochFeatures, low: Double?, high: Double?, sparse: Bool) -> String {
            let hasHR = f.hr.isFinite
            let hrLow = hasHR && f.hr <= 55
            let hrHigh = hasHR && f.hr >= 70
            let parasympOK = !f.rmssd.isFinite || f.rmssd >= 50
            let hrvarHigh = f.hrVar.isFinite && f.hrVar >= 1
            let cardiac = hrHigh || hrvarHigh
            let wakeCardiac = sparse ? hrHigh : cardiac
            let irregular = f.rrv.isFinite && high.map { f.rrv >= $0 } == true
            let regular = !f.rrv.isFinite || low.map { f.rrv <= $0 } == true
            let still = f.moveFrac <= SleepStager.stageStillMoveFrac
            let moving = f.moveFrac >= SleepStager.stageWakeMoveFrac
            if moving && (wakeCardiac || !hasHR) { return "wake" }
            if still && parasympOK && hrLow && regular { return "deep" }
            if still && cardiac && irregular { return "rem" }
            if still && hrHigh && hrvarHigh && !f.rrv.isFinite { return "rem" }
            return "light"
        }

        var checked = 0
        for move in moves {
            for hr in hrs {
                for hrVar in hrVars {
                    for rmssd in rmssds {
                        for rrv in rrvs {
                            for (low, high) in barPairs {
                                for sparse in [false, true] {
                                    let f = SleepStager.EpochFeatures(
                                        index: 0, midTs: 0, count: 0, moveFrac: move, ckSleep: true,
                                        hr: hr, hrVar: hrVar, rmssd: rmssd, sdnn: 0,
                                        respRate: rrv.isFinite ? 14 : .nan, rrv: rrv, clock: 0.5)
                                    XCTAssertEqual(
                                        SleepStager.classifyOne(
                                            f, hrLo: 55, hrHi: 70, rmssdHi: 50, hrvarHi: 1,
                                            rrvHi: high, rrvLo: low, cardiacSparse: sparse),
                                        former(f, low: low, high: high, sparse: sparse))
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1_000)
    }
}
