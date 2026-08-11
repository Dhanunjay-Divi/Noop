import XCTest
@testable import StrandAnalytics

final class RrCoverageVerdictTests: XCTestCase {
    func testCoverageVerdictsAndBoundaries() {
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 1.0, collapsed: 1.0), .plausible)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0.89, collapsed: 0.88), .underCovered)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 1.60, collapsed: 1.02),
                       .sameSecondOverCount)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 2.54, collapsed: 1.99),
                       .crossSecondOverCount)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: 0, collapsed: 0), .unmeasurable)
        XCTAssertEqual(HRVAnalyzer.classifyCoverage(coverage: .nan, collapsed: .nan), .unmeasurable)

        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(.plausible))
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(.underCovered))
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(.unmeasurable))
        XCTAssertFalse(HRVAnalyzer.beatSpreadIsTrustworthy(.sameSecondOverCount))
        XCTAssertFalse(HRVAnalyzer.beatSpreadIsTrustworthy(.crossSecondOverCount))
    }

    func testBeatAccurateStreamIsTrusted() {
        let rr = [Double](repeating: 1000, count: 60)
        let ts = Array(0..<60)
        let fraction = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: rr)
        XCTAssertEqual(fraction, 1.0, accuracy: 1e-9)
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: fraction))
    }

    func testPerfectlyCoveredBankedStreamStillRefusesBeatValues() {
        let rr = [Double](repeating: 63_000.0 / 60.0, count: 60)
        let ts = (0..<60).map { ($0 / 6) * 7 }
        let verdict = HRVAnalyzer.classifyCoverage(
            coverage: HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: rr),
            collapsed: HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: rr))
        XCTAssertTrue(HRVAnalyzer.beatSpreadIsTrustworthy(verdict), "verdict was \(verdict)")

        let fraction = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: rr)
        XCTAssertLessThan(fraction, HRVAnalyzer.beatAccuracyMinFraction)
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: fraction))
    }

    func testUnknownBeatTimingStaysTrustedAndBoundaryIsInclusive() {
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: [], rrMs: []), 1.0)
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: [5], rrMs: [1000]), 1.0)
        XCTAssertEqual(HRVAnalyzer.beatAccurateFraction(tsSec: [0, 1], rrMs: [1000]), 1.0)
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: .nan))
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(
            beatAccurateFraction: HRVAnalyzer.beatAccuracyMinFraction))
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(
            beatAccurateFraction: HRVAnalyzer.beatAccuracyMinFraction - 0.01))
    }
}
