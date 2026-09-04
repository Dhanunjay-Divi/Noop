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

    func testEnabledEditorControlsUseThePositiveSemanticColor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let keyMetrics = try String(
            contentsOf: root.appendingPathComponent("Strand/Screens/KeyMetricsEditorSheet.swift"),
            encoding: .utf8
        )
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("Strand/Screens/DashboardCardsEditorSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(keyMetrics.contains(".toggleStyle(KeyMetricSelectionToggleStyle())"))
        XCTAssertTrue(keyMetrics.contains(".disabled(toggleLocked)"))
        XCTAssertTrue(keyMetrics.contains("? StrandPalette.statusPositive"))
        XCTAssertTrue(keyMetrics.contains(".fill(Color.white)"))
        XCTAssertTrue(keyMetrics.contains(".foregroundStyle(Color.black)"))
        XCTAssertTrue(keyMetrics.contains(
            #".accessibilityIdentifier("noop.key-metric.toggle.\(item.metric.rawValue)")"#
        ))
        XCTAssertTrue(dashboard.contains(".toggleStyle(.noopSwitch)"))
        XCTAssertTrue(dashboard.contains(
            "enabled ? StrandPalette.statusPositive : StrandPalette.textTertiary"
        ))
    }
}

final class KeyMetricPrefsTests: XCTestCase {
    func testFreshInstallDefaultsToRecoveryEffortAndSleep() {
        XCTAssertEqual(KeyMetric.defaultSelection, [.charge, .effort, .rest])
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled(""), [.charge, .effort, .rest])
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("   "), [.charge, .effort, .rest])
    }

    func testSelectionContractMatchesProductLimit() {
        XCTAssertEqual(KeyMetricPrefs.minimumSelectionCount, 3)
        XCTAssertEqual(KeyMetricPrefs.maximumSelectionCount, 5)
        XCTAssertEqual(Set(KeyMetric.defaultOrder), Set(KeyMetric.allCases))
    }

    func testShortLegacySelectionKeepsUserOrderAndFillsToThree() {
        XCTAssertEqual(
            KeyMetricPrefs.decodeEnabled("steps,hrv"),
            [.steps, .hrv, .charge]
        )
        XCTAssertEqual(
            KeyMetricPrefs.encode([.bloodOxygen]),
            "bloodOxygen,charge,effort"
        )
    }

    func testFullCatalogKeepsPinsFirstWithoutRemovingPriorMetrics() {
        let catalog = KeyMetricPrefs.catalogOrder(startingWith: [.steps, .hrv, .bloodOxygen])
        XCTAssertEqual(Array(catalog.prefix(3)), [.steps, .hrv, .bloodOxygen])
        XCTAssertEqual(catalog.count, KeyMetric.allCases.count)
        XCTAssertEqual(Set(catalog), Set(KeyMetric.allCases))
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
