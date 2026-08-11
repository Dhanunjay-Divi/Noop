import XCTest
@testable import Strand

final class KeyMetricProgressSemanticsTests: XCTestCase {
    func testOnlyTrueScoresUseProgressRails() {
        XCTAssertEqual(Set(KeyMetric.allCases.filter(\.isBoundedProgress)),
                       Set([.charge, .effort, .rest]))
    }

    func testRawVitalsAndAssumedGoalsNeverLookLikeCompletion() {
        for metric in [KeyMetric.hrv, .restingHr, .bloodOxygen, .respiratory,
                       .steps, .weight, .calories] {
            XCTAssertFalse(metric.isBoundedProgress, "\(metric.rawValue) is not a fixed progress scale")
        }
    }
}
