import SwiftUI
import XCTest
@testable import StrandDesign

final class AppearanceModeTests: XCTestCase {
    override func tearDown() {
        StrandPalette.appearanceMode = .system
        StrandPalette.chartStyle = .titanium
        super.tearDown()
    }

    func testStoredValuesRemainStableAndBlackIsAdditive() {
        XCTAssertEqual(AppearanceMode.allCases.map(\.rawValue), ["system", "light", "dark", "black"])
        XCTAssertEqual(AppearanceMode.resolve("system"), .system)
        XCTAssertEqual(AppearanceMode.resolve("light"), .light)
        XCTAssertEqual(AppearanceMode.resolve("dark"), .dark)
        XCTAssertEqual(AppearanceMode.resolve("black"), .black)
    }

    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppearanceMode.resolve("future-theme"), .system)
    }

    func testAppearanceStorageKeyMatchesWidgetBridgeContract() {
        XCTAssertEqual(AppearanceMode.storageKey, "theme.appearance")
    }

    func testBlackForcesDarkSchemeButKeepsDistinctSurfaceVariant() {
        XCTAssertEqual(AppearanceMode.black.colorScheme, .dark)
        StrandPalette.appearanceMode = .dark
        XCTAssertFalse(StrandPalette.usesOLEDBlack)
        StrandPalette.appearanceMode = .black
        XCTAssertTrue(StrandPalette.usesOLEDBlack)
    }

    func testSystemDoesNotForceAColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
    }

    func testDimensionalBackgroundDefaultIsCanonical() {
        XCTAssertTrue(SkyBehindCardsPrefs.defaultEnabled)
    }

    func testPearlSemanticStatusTextTokensMeetWCAGAA() {
        let raisedPearl = "#FAFBFC"
        let titanium = [
            StrandPalette.statusPositiveTextLightHex,
            StrandPalette.statusWarningTextLightHex,
            StrandPalette.statusCriticalTextLightHex,
        ]
        let classic = [
            StrandPalette.statusPositiveTextLightHex,
            StrandPalette.statusWarningTextLightHex,
            StrandPalette.classicStatusCriticalTextLightHex,
        ]

        XCTAssertEqual(titanium, ["#19734A", "#895900", "#A83D21"])
        XCTAssertEqual(classic, ["#19734A", "#895900", "#B33A2F"])
        for foreground in titanium + classic {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(foreground, raisedPearl),
                4.5,
                "\(foreground) must remain legible as normal-size text on \(raisedPearl)"
            )
        }
    }

    private func contrastRatio(_ first: String, _ second: String) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func relativeLuminance(_ hex: String) -> Double {
        let components = Color.sRGBComponents(hex: hex)
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.r)
            + 0.7152 * linear(components.g)
            + 0.0722 * linear(components.b)
    }
}
