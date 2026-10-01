import XCTest
@testable import Strand

final class KeyMetricProgressSemanticsTests: XCTestCase {
    func testOnlyTrueScoresUseProgressRails() {
        XCTAssertEqual(Set(KeyMetric.allCases.filter(\.isBoundedProgress)),
                       Set([.charge, .effort, .rest, .hydration]))
    }

    func testRawVitalsAndAssumedGoalsNeverLookLikeCompletion() {
        for metric in [KeyMetric.hrv, .restingHr, .bloodOxygen, .respiratory,
                       .steps, .weight, .calories, .stress, .vitality, .skinTemp] {
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

        XCTAssertTrue(keyMetrics.contains("TextField(\"Search metrics\""))
        XCTAssertTrue(keyMetrics.contains("minus.circle.fill"))
        XCTAssertTrue(keyMetrics.contains("plus.circle.fill"))
        XCTAssertTrue(keyMetrics.contains("KeyMetric.Category.allCases"))
        XCTAssertTrue(keyMetrics.contains("selected.count <= KeyMetricPrefs.minimumSelectionCount"))
        XCTAssertTrue(keyMetrics.contains("selected.count >= KeyMetricPrefs.maximumSelectionCount"))
        XCTAssertTrue(keyMetrics.contains(".foregroundStyle(Color.black)"))
        XCTAssertTrue(keyMetrics.contains(
            #".accessibilityIdentifier("noop.key-metric.add.\(metric.rawValue)")"#
        ))
        XCTAssertTrue(dashboard.contains(".toggleStyle(.noopSwitch)"))
        XCTAssertTrue(dashboard.contains(
            "enabled ? StrandPalette.statusPositive : StrandPalette.textTertiary"
        ))
    }
}

final class KeyMetricPrefsTests: XCTestCase {
    func testFreshInstallDefaultsComplementDailySignalSummary() {
        let secondaryDefaults: [KeyMetric] = [
            .hrv, .restingHr, .bloodOxygen, .respiratory, .steps, .weight,
        ]
        XCTAssertEqual(KeyMetric.defaultSelection, secondaryDefaults)
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled(""), secondaryDefaults)
        XCTAssertEqual(KeyMetricPrefs.decodeEnabled("   "), secondaryDefaults)
        XCTAssertTrue(
            Set(secondaryDefaults).isDisjoint(with: Set([.charge, .effort, .rest]))
        )
    }

    func testSelectionContractMatchesProductLimit() {
        XCTAssertEqual(KeyMetricPrefs.minimumSelectionCount, 3)
        XCTAssertEqual(KeyMetricPrefs.maximumSelectionCount, 6)
        XCTAssertEqual(Set(KeyMetric.defaultOrder), Set(KeyMetric.allCases))
        XCTAssertEqual(KeyMetric.allCases.count, 14)
        XCTAssertEqual(
            Set(KeyMetric.allCases),
            Set([
                .charge, .effort, .rest, .hrv, .restingHr, .bloodOxygen,
                .respiratory, .steps, .weight, .calories, .stress, .vitality,
                .skinTemp, .hydration,
            ])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.category == .dailySignal }),
            Set([.charge, .effort, .rest])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.category == .vitals }),
            Set([.hrv, .restingHr, .bloodOxygen, .respiratory, .skinTemp])
        )
    }

    func testShortLegacySelectionKeepsUserOrderAndFillsToThree() {
        XCTAssertEqual(
            KeyMetricPrefs.decodeEnabled("steps,hrv"),
            [.steps, .hrv, .restingHr]
        )
        XCTAssertEqual(
            KeyMetricPrefs.encode([.bloodOxygen]),
            "bloodOxygen,hrv,restingHr"
        )
    }

    func testExistingDailySignalSelectionIsNotSilentlyReplaced() {
        XCTAssertEqual(
            KeyMetricPrefs.decodeEnabled("charge,effort,rest"),
            [.charge, .effort, .rest]
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
            [.steps, .hrv, .bloodOxygen, .restingHr, .calories, .weight]
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
            "steps,hrv,bloodOxygen,restingHr,calories,weight"
        )
        XCTAssertEqual(
            KeyMetricPrefs.encode([]),
            "hrv,restingHr,bloodOxygen,respiratory,steps,weight"
        )
    }
}
