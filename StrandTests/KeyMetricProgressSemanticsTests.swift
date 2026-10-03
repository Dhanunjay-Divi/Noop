import XCTest
@testable import Strand

final class KeyMetricProgressSemanticsTests: XCTestCase {
    func testOnlyTrueScoresUseProgressRails() {
        XCTAssertEqual(Set(KeyMetric.allCases.filter(\.isBoundedProgress)),
                       Set([.charge, .effort, .rest, .hydration]))
    }

    func testRawVitalsAndAssumedGoalsNeverLookLikeCompletion() {
        for metric in [KeyMetric.hrv, .restingHr, .bloodOxygen, .respiratory,
                       .averageHr, .maxHr, .asleepTime, .vo2Max, .steps, .weight,
                       .calories, .stress, .vitality, .skinTemp, .menstrualCycle] {
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
        XCTAssertTrue(keyMetrics.contains("KeyMetric.Origin.allCases"))
        XCTAssertTrue(keyMetrics.contains("selected.count <= KeyMetricPrefs.minimumSelectionCount"))
        XCTAssertFalse(keyMetrics.contains("Six metrics are already selected."))
        XCTAssertTrue(keyMetrics.contains(".foregroundStyle(Color.black)"))
        XCTAssertTrue(keyMetrics.contains(
            #".accessibilityIdentifier("noop.key-metric.add.\(metric.rawValue)")"#
        ))
        XCTAssertTrue(dashboard.contains(".toggleStyle(.noopSwitch)"))
        XCTAssertTrue(dashboard.contains(
            "enabled ? StrandPalette.statusPositive : StrandPalette.textTertiary"
        ))
    }

    func testTodayMetricCardsKeepOneStableHeaderGeometry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let today = try String(
            contentsOf: root.appendingPathComponent("Strand/Liquid/LiquidTodayView.swift"),
            encoding: .utf8
        )
        let header = today
            .components(separatedBy: "private func keyMetricTileHeader")
            .dropFirst()
            .first?
            .components(separatedBy: "enum KeyMetricTrendDirection")
            .first ?? ""
        let sectionHeader = today
            .components(separatedBy: "private func sectionHead")
            .dropFirst()
            .first?
            .components(separatedBy: "private func card")
            .first ?? ""

        XCTAssertTrue(header.contains("VStack(alignment: .leading"))
        XCTAssertTrue(header.contains("MetricGlyph(symbol, size: 24)"))
        XCTAssertTrue(header.contains("if let trend, trend.count > 1"))
        XCTAssertTrue(header.contains("Text(label.uppercased())"))
        XCTAssertFalse(header.contains("} else {"))
        XCTAssertFalse(sectionHeader.contains(".padding(.horizontal, 2)"))
    }

    func testTodayMetricCardsUseOneNeutralVisibleTrendBadge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let today = try String(
            contentsOf: root.appendingPathComponent("Strand/Liquid/LiquidTodayView.swift"),
            encoding: .utf8
        )
        let badge = today
            .components(separatedBy: "private func trendDirectionBadge")
            .dropFirst()
            .first?
            .components(separatedBy: "/// Builds every compact tile trace")
            .first ?? ""

        XCTAssertTrue(badge.contains(#"Image(systemName: "chart.xyaxis.line")"#))
        XCTAssertFalse(badge.contains("direction.symbol"))
        XCTAssertTrue(badge.contains(".accessibilityValue(direction.spokenValue)"))
    }

    func testEditorCopyIsLocalizedAcrossEverySupportedLocale() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let editor = try String(
            contentsOf: root.appendingPathComponent("Strand/Screens/KeyMetricsEditorSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(editor.contains(#"String(localized: "Choose your snapshot")"#))
        XCTAssertTrue(editor.contains(#"String(localized: "All supported metrics are selected.")"#))
        XCTAssertTrue(editor.contains(#"String(localized: "Remove \(metric.title) from Today")"#))

        let data = try Data(
            contentsOf: root.appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"]
                as? [String: Any]
        )
        let requiredKeys = [
            "Choose your snapshot",
            "%lld selected",
            "%lld metrics selected",
            "Clear metric search",
            "All supported metrics are selected.",
            "No metrics match this search.",
            "Remove %@ from Today",
            "Enable hydration tracking in Settings",
            "Add %@ to Today",
        ]
        let locales = Set(["de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"])

        for key in requiredKeys {
            let entry = try XCTUnwrap(catalog[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), locales, key)
        }
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

    func testSelectionContractMatchesTheCompleteCatalog() {
        XCTAssertEqual(KeyMetricPrefs.minimumSelectionCount, 3)
        XCTAssertEqual(KeyMetricPrefs.maximumSelectionCount, KeyMetric.allCases.count)
        XCTAssertEqual(Set(KeyMetric.defaultOrder), Set(KeyMetric.allCases))
        XCTAssertEqual(KeyMetric.allCases.count, 19)
        XCTAssertEqual(
            Set(KeyMetric.allCases),
            Set([
                .charge, .effort, .rest, .hrv, .restingHr, .bloodOxygen,
                .averageHr, .maxHr, .respiratory, .asleepTime, .steps, .weight,
                .calories, .vo2Max, .stress, .vitality, .skinTemp, .hydration,
                .menstrualCycle,
            ])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.category == .dailySignal }),
            Set([.charge, .effort, .rest])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.category == .vitals }),
            Set([
                .hrv, .restingHr, .averageHr, .maxHr, .bloodOxygen, .respiratory,
                .vo2Max, .skinTemp,
            ])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.category == .sleep }),
            Set([.asleepTime])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.origin == .noopInsight }),
            Set([.charge, .rest, .effort, .stress, .vitality])
        )
        XCTAssertEqual(
            Set(KeyMetric.allCases.filter { $0.origin == .sourceDependent }),
            Set([.calories])
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

    func testDecodePreservesEveryKnownUniqueSelectionInOrder() {
        XCTAssertEqual(
            KeyMetricPrefs.decodeEnabled(
                "steps, hrv,steps,bloodOxygen,restingHr,calories,weight,effort"
            ),
            [.steps, .hrv, .bloodOxygen, .restingHr, .calories, .weight, .effort]
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
