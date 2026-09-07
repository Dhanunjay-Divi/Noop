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
        XCTAssertTrue(source.contains("TextField(\"Weight\", text: weightDraftBinding)"))
        XCTAssertTrue(source.contains("TextField(\"Feet\", text: heightFeetDraftBinding)"))
        XCTAssertTrue(source.contains("TextField(\"Inches\", text: heightInchesDraftBinding)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"noop.profile.weight.clear\")"),
                      "Weight entry must remain fully clearable before typing a replacement.")
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"noop.profile.height.clear\")"),
                      "Metric height entry must remain fully clearable before typing a replacement.")
        XCTAssertTrue(source.contains("foregroundStyle(StrandPalette.accentInk)"),
                      "The dark-mode near-white CTA must use dark contrast ink, not hard-coded white.")
    }

    func testOnboardingKeepsContentScrollableAndCTAKeyboardSafe() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Onboarding/OnboardingWizard.swift"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"noop.onboarding.footer\")"),
                      "The primary action must remain a distinct footer below the clipped page viewport.")
        XCTAssertTrue(source.contains("if step != .profile || !profileEditing"),
                      "The footer must yield to profile measurement entry while the keyboard is active.")
        XCTAssertTrue(source.contains("ScrollView(.vertical, showsIndicators: false)"),
                      "Every onboarding page must remain vertically reachable on compact phones.")
        XCTAssertTrue(source.contains(".scrollDismissesKeyboard(.interactively)"),
                      "Measurement entry should allow an interactive keyboard dismissal.")
        XCTAssertTrue(source.contains("@AppStorage(UnitPrefs.massKey)"))
        XCTAssertTrue(source.contains("@AppStorage(UnitPrefs.heightKey)"),
                      "Keyboard/layout work must not fold weight and height back into one unit choice.")
    }

    func testOnboardingRemovesDistributionAndLegacyBandNoticesButKeepsHistoryImport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("Strand/Onboarding/OnboardingWizard.swift")
        )
        let changelog = try String(
            contentsOf: root.appendingPathComponent("Strand/System/AppChangelog.swift")
        )

        XCTAssertFalse(onboarding.contains("Delivered through Apple"))
        XCTAssertFalse(changelog.contains("WHOOP 4.0 is the supported path"))
        XCTAssertTrue(onboarding.contains("StepShell(title: String(localized: \"Bring your history\")"))
        XCTAssertTrue(onboarding.contains("Import wearable export"))
        XCTAssertTrue(onboarding.contains("Import Apple Health export"))
    }
}

/// Pins the final onboarding map that teaches the same stable everyday entry points on iOS and Android.
final class OnboardingDiscoveryContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testDailyRhythmAndPlanAppearBeforeDoneAndUseLocalizedCopy() throws {
        let onboarding = try source("Strand/Onboarding/OnboardingWizard.swift")

        XCTAssertTrue(onboarding.contains("case .dailyRhythm: DailyRhythmStep()"))
        XCTAssertTrue(onboarding.contains("case .plan:"))
        XCTAssertTrue(onboarding.contains("ProductPlanStep("))
        XCTAssertTrue(onboarding.contains("case .dailyRhythm: return String(localized: \"Continue\")"))
        XCTAssertTrue(onboarding.contains("String(localized: \"Continue with NOOP\")"))
        XCTAssertTrue(onboarding.contains("String(localized: \"Save NOOP+ preference\")"))
        XCTAssertTrue(onboarding.contains("case .ownership:"))
        XCTAssertTrue(onboarding.contains("OwnershipAccountView()"))
        XCTAssertTrue(
            onboarding.contains(
                "$0 != .ownership || ownershipRequired"
            )
        )
        XCTAssertTrue(
            onboarding.contains(
                "forKey: Self.progressStorageKey"
            )
        )
        XCTAssertTrue(onboarding.contains("var initialStep = Step.welcome"))
        XCTAssertTrue(onboarding.contains("initialStep = restored"))
        XCTAssertTrue(onboarding.contains("initialStep = requestedStep"))
        XCTAssertEqual(
            onboarding.components(
                separatedBy: "_step = State(initialValue: initialStep)"
            ).count - 1,
            1,
            "Persisted progress and debug demos must resolve before State is initialized once."
        )
        XCTAssertTrue(onboarding.contains("\"onboarding.progress\""))
        XCTAssertTrue(onboarding.contains("return ownershipClaimed"))
        XCTAssertTrue(
            onboarding.contains(
                "guard await ownershipService.selectPlan(selectedPlan) else"
            )
        )
        XCTAssertTrue(onboarding.contains("guard step == .plan else { return }"))
        XCTAssertGreaterThanOrEqual(
            onboarding.components(
                separatedBy: "guard postClaimOwnershipReady else"
            ).count - 1,
            2
        )
        XCTAssertTrue(
            onboarding.contains(
                "return !planSubmissionBusy && postClaimOwnershipReady"
            )
        )
        XCTAssertTrue(onboarding.contains("reconcileOwnershipRequirement()"))
        XCTAssertTrue(
            onboarding.contains(
                "ownershipCanAccessPostClaimOnboarding("
            )
        )
        XCTAssertTrue(
            onboarding.contains(
                "candidate.rawValue > Step.ownership.rawValue"
            )
        )
        XCTAssertTrue(onboarding.contains("guard ownershipAllows(.done) else"))
        XCTAssertTrue(
            onboarding.contains(
                "removeObject(forKey: Self.progressStorageKey)"
            )
        )
        XCTAssertTrue(
            onboarding.contains(
                "if step == .scan && ownershipRequired { return bandBonded }"
            )
        )
        XCTAssertTrue(onboarding.contains("title: LocalizedStringKey"))
        XCTAssertTrue(onboarding.contains("subtitle: LocalizedStringKey"))
        XCTAssertTrue(onboarding.contains("detail: LocalizedStringKey"))
        XCTAssertLessThan(
            try XCTUnwrap(onboarding.range(of: "appearance, dailyRhythm, plan, done")?.lowerBound),
            try XCTUnwrap(onboarding.range(of: "private struct DoneStep")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(onboarding.range(of: "private struct ProductPlanStep")?.lowerBound),
            try XCTUnwrap(onboarding.range(of: "private struct DoneStep")?.lowerBound)
        )
        for key in [
            "onboarding.rhythm.title",
            "onboarding.rhythm.morning.body",
            "onboarding.rhythm.quick.body",
            "onboarding.rhythm.journal.body",
            "onboarding.rhythm.automations.body",
        ] {
            XCTAssertTrue(onboarding.contains("String(localized: \"\(key)\")"), key)
        }
    }

    func testDailyRhythmOnlyExplainsOptInAutomations() throws {
        let onboarding = try source("Strand/Onboarding/OnboardingWizard.swift")
        let step = try XCTUnwrap(
            onboarding.components(separatedBy: "private struct DailyRhythmStep").dropFirst().first
        ).components(separatedBy: "private struct StepShell").first ?? ""

        XCTAssertFalse(step.contains("setEnabled("))
        XCTAssertFalse(step.contains("requestAuthorization"))
        XCTAssertFalse(step.contains("Toggle("))
    }

    func testLocalFirstCopyDoesNotPromiseOptionalCloudCanNeverBeUsed() throws {
        let onboarding = try source("Strand/Onboarding/OnboardingWizard.swift")
        let settings = try source("Strand/Screens/SettingsView.swift")
        let catalogURL = repoRoot.appendingPathComponent(
            "Strand/Resources/Localizable.xcstrings"
        )
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: catalogData)
                as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        XCTAssertFalse(onboarding.contains("all your data, none of the cloud"))
        XCTAssertFalse(settings.contains("all your data, none of the cloud"))
        XCTAssertTrue(onboarding.contains("your health data, local by default"))
        XCTAssertTrue(onboarding.contains("cloud features are optional"))
        XCTAssertTrue(
            settings.contains("core health data stays local by default")
        )

        let activeKeys = [
            "your health data, local by default",
            "A private window into your recovery, sleep and effort. Core data is read from NOOP Band and processed on %@; cloud features are optional.",
            "NOOP: core health data stays local by default.",
        ]
        let supportedLocales = [
            "de", "en", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant",
        ]
        for key in activeKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            for locale in supportedLocales {
                XCTAssertNotNil(
                    localizations[locale],
                    "\(key) is missing \(locale)"
                )
            }
        }
    }
}
