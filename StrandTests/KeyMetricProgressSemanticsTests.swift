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

final class KeyMetricPrefsTests: XCTestCase {
    func testFreshInstallDefaultsToRecoveryEffortAndSleep() {
        XCTAssertEqual(KeyMetric.defaultSelection, [.charge, .effort, .rest])
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled(""), [.charge, .effort, .rest])
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("   "), [.charge, .effort, .rest])
    }

    func testSelectionContractMatchesProductLimit() {
        XCTAssertEqual(KeyMetricPrefs.minimumSelectionCount, 1)
        XCTAssertEqual(KeyMetricPrefs.maximumSelectionCount, 5)
        XCTAssertEqual(Set(KeyMetric.defaultOrder), Set(KeyMetric.allCases))
    }

    func testDecodePreservesOrderDeduplicatesAndCapsOlderSelections() {
        XCTAssertEqual(
            KeyMetricPrefs.decodeEnabled(
                "steps, hrv,steps,bloodOxygen,restingHr,calories,weight,effort"
            ),
            [.steps, .hrv, .bloodOxygen, .restingHr, .calories]
        )
    }

    func testDecodeAllUnknownFallsBackToCoreDefaults() {
        XCTAssertEqual(
            KeyMetricPrefs.decodeEnabled("retiredMetric,unknown"),
            KeyMetric.defaultSelection
        )
    }

    func testEncodeAlsoEnforcesDedupeCapAndNonemptySelection() {
        XCTAssertEqual(
            KeyMetricPrefs.encode([
                .steps, .hrv, .steps, .bloodOxygen, .restingHr, .calories, .weight,
            ]),
            "steps,hrv,bloodOxygen,restingHr,calories"
        )
        XCTAssertEqual(KeyMetricPrefs.encode([]), "charge,effort,rest")
    }
}
