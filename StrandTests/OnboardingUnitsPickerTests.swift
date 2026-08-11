import XCTest
@testable import Strand

/// Guards the onboarding measurement controls. Weight and height now have independent choices so kg +
/// ft/in (or lb + cm) works, and their numeric values are direct-entry TextFields backed by SI storage.
///
/// These tests pin that wiring contract so a rename of the key or a rawValue can't silently leave the
/// onboarding picker writing one place while the formatter reads another (which is the bug #781 fixed).
final class OnboardingUnitsPickerTests: XCTestCase {

    func testUnitPreferenceKeysAreStable() {
        XCTAssertEqual(UnitPrefs.systemKey, "units.system")
        XCTAssertEqual(UnitPrefs.massKey, "units.mass")
        XCTAssertEqual(UnitPrefs.heightKey, "units.height")
    }

    /// The picker tags are the `UnitSystem` rawValues; they must round-trip through the same initializer
    /// the ProfileStep's `unitSystem` computed property uses, so a picked tag resolves back to the case.
    func testRawValuesRoundTripThroughInitializer() {
        XCTAssertEqual(UnitSystem(rawValue: UnitSystem.metric.rawValue), .metric)
        XCTAssertEqual(UnitSystem(rawValue: UnitSystem.imperial.rawValue), .imperial)
        XCTAssertEqual(UnitSystem.metric.rawValue, "metric")
        XCTAssertEqual(UnitSystem.imperial.rawValue, "imperial")
    }

    /// An unset or unknown stored value resolves to Metric, matching the wizard's `@AppStorage` default
    /// and the `?? .metric` fallback in ProfileStep's `unitSystem` computed property.
    func testUnknownRawDefaultsToMetric() {
        XCTAssertEqual(UnitSystem(rawValue: "nonsense") ?? .metric, .metric)
    }

    /// Picking Imperial must actually change what the Weight/Height steppers render. The steppers format
    /// through `UnitFormatter`, so prove the same stored SI value reads differently per picked system.
    func testPickingImperialChangesTheDisplayedWeightAndHeight() {
        let kg = 74.5
        let cm = 178.0
        XCTAssertEqual(UnitFormatter.massFromKilograms(kg, system: .metric), "74.5 kg")
        XCTAssertNotEqual(UnitFormatter.massFromKilograms(kg, system: .imperial),
                          UnitFormatter.massFromKilograms(kg, system: .metric))
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(cm, system: .metric), "178 cm")
        XCTAssertNotEqual(UnitFormatter.heightFromCentimeters(cm, system: .imperial),
                          UnitFormatter.heightFromCentimeters(cm, system: .metric))
    }

    func testMixedUnitChoicesResolveIndependently() {
        XCTAssertEqual(UnitPrefs.resolveMass(system: .imperial, override: MassUnit.kilograms.rawValue),
                       .kilograms)
        XCTAssertEqual(UnitPrefs.resolveHeight(system: .metric, override: HeightUnit.feetInches.rawValue),
                       .feetInches)
        XCTAssertEqual(UnitFormatter.massFromKilograms(74.5, unit: .kilograms), "74.5 kg")
        XCTAssertEqual(UnitFormatter.heightFromCentimeters(178, unit: .feetInches), "5′ 10″")
    }

    func testOnboardingUsesDirectEntryAndContrastInk() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Onboarding/OnboardingWizard.swift"))
        XCTAssertTrue(source.contains("TextField(\"Weight\", value: displayedWeight"))
        XCTAssertTrue(source.contains("TextField(\"Feet\", value: displayedFeet"))
        XCTAssertTrue(source.contains("TextField(\"Inches\", value: displayedRemainingInches"))
        XCTAssertTrue(source.contains("foregroundStyle(StrandPalette.accentInk)"),
                      "The dark-mode near-white CTA must use dark contrast ink, not hard-coded white.")
    }
}
