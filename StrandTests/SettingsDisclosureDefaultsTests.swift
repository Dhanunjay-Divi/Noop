import Foundation
import XCTest
@testable import Strand

/// Pins the Settings "Advanced" disclosure defaults (S3). The fact that must never regress is the
/// DEFAULT: a fresh install lands COLLAPSED, so a first-run user sees the everyday handful of sections
/// instead of the full wall of cards. Also guards the @AppStorage key stays in lockstep with the Android
/// `SettingsDisclosurePrefs.KEY` suffix so a backup/restore round-trip carries the choice across platforms.
final class SettingsDisclosureDefaultsTests: XCTestCase {

    func testFreshInstallDefaultsCollapsed() {
        XCTAssertFalse(SettingsDisclosureDefaults.advancedOpenDefault,
                       "The Advanced disclosure must default collapsed so first-run isn't a wall of cards.")
    }

    func testKeyMatchesAndroidSuffix() {
        // iOS @AppStorage("settingsAdvancedOpen"); Android persists "noop.settingsAdvancedOpen".
        XCTAssertEqual(SettingsDisclosureDefaults.advancedOpenKey, "settingsAdvancedOpen")
    }

    func testDefaultRoundTripsThroughUserDefaults() {
        // Registering the default value reads back as collapsed when nothing has been written.
        let defaults = UserDefaults(suiteName: "SettingsDisclosureDefaultsTests")!
        defaults.removePersistentDomain(forName: "SettingsDisclosureDefaultsTests")
        defaults.register(defaults: [SettingsDisclosureDefaults.advancedOpenKey: SettingsDisclosureDefaults.advancedOpenDefault])
        XCTAssertFalse(defaults.bool(forKey: SettingsDisclosureDefaults.advancedOpenKey))

        // A user opening it persists true and reads back true.
        defaults.set(true, forKey: SettingsDisclosureDefaults.advancedOpenKey)
        XCTAssertTrue(defaults.bool(forKey: SettingsDisclosureDefaults.advancedOpenKey))
        defaults.removePersistentDomain(forName: "SettingsDisclosureDefaultsTests")
    }
}

final class SwitchStyleContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testIOSSwitchesUseTheSemanticPositiveStyle() throws {
        let components = try source(
            "Packages/StrandDesign/Sources/StrandDesign/Components.swift"
        )
        XCTAssertTrue(
            components.contains("SwitchToggleStyle(tint: StrandPalette.statusPositive)")
        )

        let app = try source("StrandiOS/App/StrandiOSApp.swift")
        XCTAssertTrue(
            app.contains(".toggleStyle(.noopSwitch)"),
            "The root style is required for bare SwiftUI toggles."
        )

        for directory in ["Strand", "StrandiOS"] {
            for file in try swiftSources(in: directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(
                    text.contains(".toggleStyle(.switch)"),
                    "\(file.lastPathComponent) bypasses the canonical green switch style."
                )
            }
        }
    }

    func testSelectionControlsRetainTheirNonSwitchStyles() throws {
        let keyMetrics = try source("Strand/Screens/KeyMetricsEditorSheet.swift")
        XCTAssertTrue(keyMetrics.contains(".toggleStyle(KeyMetricSelectionToggleStyle())"))

        let terms = try source("Strand/App/TermsGateView.swift")
        XCTAssertTrue(terms.contains(".toggleStyle(.checkbox)"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func swiftSources(in relativePath: String) throws -> [URL] {
        let root = repoRoot.appendingPathComponent(relativePath)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}
