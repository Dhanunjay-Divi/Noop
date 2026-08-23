import Foundation
import XCTest
@testable import Strand

/// Pins the shared loading/empty/partial/stale/error vocabulary and its first production adopters.
/// These are source contracts because the state cards are SwiftUI views rather than pure value types.
final class ScreenStateContractTests: XCTestCase {
    private func sourceText(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testStateVocabularyIsCompleteAndStable() {
        XCTAssertEqual(
            Set(ScreenStateKind.allCases.map(\.rawValue)),
            Set(["loading", "empty", "partial", "stale", "error"])
        )
    }

    func testStateCardHasMotionAndAccessibilityFallbacks() throws {
        let source = try sourceText("Strand/Screens/ScreenScaffold.swift")

        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("kind == .loading && !reduceMotion"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(Text(title))"))
        XCTAssertTrue(source.contains(".accessibilityValue(Text(message))"))
        XCTAssertTrue(source.contains("if let actionTitle, let action"))
    }

    func testCompatibilityWrappersDelegateToTheStateCard() throws {
        let source = try sourceText("Strand/Screens/ScreenScaffold.swift")

        XCTAssertTrue(source.contains("ScreenStateCard(\n            kind: .empty,\n            title: \"Coming together\""))
        XCTAssertTrue(source.contains(
            "ScreenStateCard(kind: .partial, title: title, message: message, symbol: symbol)"
        ))
    }

    func testInitialProductionScreensUseExplicitStates() throws {
        let nutrition = try sourceText("Strand/Screens/NutritionLogView.swift")
        let workouts = try sourceText("Strand/Screens/WorkoutsView.swift")
        let rhythm = try sourceText("Strand/Screens/RhythmView.swift")

        XCTAssertTrue(nutrition.contains("kind: .loading"))
        XCTAssertTrue(nutrition.contains("kind: .empty"))
        XCTAssertTrue(workouts.contains("kind: .loading"))
        XCTAssertTrue(workouts.contains("kind: .empty"))
        XCTAssertTrue(rhythm.contains("kind: .empty"))
        XCTAssertFalse(nutrition.contains("Loading your private nutrition log"))
    }
}

/// Pins the production nutrition UI to the same provenance and fast-repeat contract as storage.
final class NutritionSourceIntegrityUIContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testAppleNutritionSurfaceExplainsMixedSourcesAndUsesValidatedRepeat() throws {
        let screen = try text("Strand/Screens/NutritionLogView.swift")
        let repository = try text("Strand/Data/NutritionLogRepository.swift")
        let demoSeeder = try text("Strand/Data/AppleDemoSeeder.swift")
        let store = try text(
            "Packages/WhoopStore/Sources/WhoopStore/NutritionEntryStore.swift"
        )
        let portable = try text(
            "Packages/WhoopStore/Sources/WhoopStore/PortableUserData.swift"
        )

        XCTAssertTrue(screen.contains("if totals.hasMixedSources"))
        XCTAssertTrue(screen.contains("NutritionLogContract.repeatedManualEntry("))
        XCTAssertTrue(screen.contains("recentEntries = snapshot.recentManualEntries"))
        XCTAssertTrue(screen.contains("NutritionLogContract.parseUserNumber(clean"))
        XCTAssertTrue(screen.contains(
            #".accessibilityHint(Text("nutrition.repeat.hint"))"#
        ))
        XCTAssertFalse(screen.contains(#"replacingOccurrences(of: ",", with: ".")"#))
        XCTAssertTrue(repository.contains("let recentManualEntries: [NutritionEntryRow]"))
        XCTAssertTrue(repository.contains(
            "await AppleDemoSeeder.seedNutritionIfRequested(into: store)"
        ))
        XCTAssertTrue(demoSeeder.contains(#""--demo-nutrition""#))
        XCTAssertGreaterThanOrEqual(
            store.components(separatedBy: "NutritionLogContract.resolvedTotals(").count - 1,
            2
        )
        XCTAssertTrue(portable.contains("NutritionLogContract.resolvedTotals("))
    }
}

/// Pins Nutrition logging to one generated nine-locale catalog and complete spoken actions.
final class NutritionLocalizationAccessibilityContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func nutritionResourceKeys(_ source: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"name="(nutrition_[^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }

    func testGeneratedNutritionCopyCoversAllNineLocalesAndBothPlatforms() throws {
        let sourceData = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Tools/NutritionLocalization/nutrition_strings.json"
            )
        )
        let source = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceData) as? [String: [String: String]]
        )
        let locales = Set(["en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"])
        XCTAssertEqual(source.count, 99)
        for (key, translations) in source {
            XCTAssertTrue(key.hasPrefix("nutrition."), key)
            XCTAssertEqual(Set(translations.keys), locales, key)
            XCTAssertTrue(
                translations.values.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                },
                key
            )
        }

        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let nutritionCatalog = strings.filter { $0.key.hasPrefix("nutrition.") }
        XCTAssertEqual(Set(nutritionCatalog.keys), Set(source.keys))
        for (key, rawEntry) in nutritionCatalog {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertEqual(Set(localizations.keys), locales, key)
        }

        let expectedAndroid = Set(source.keys.map { $0.replacingOccurrences(of: ".", with: "_") })
        let folders = [
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        ]
        for folder in folders {
            let resource = try text("android/app/src/main/res/\(folder)/nutrition.xml")
            XCTAssertEqual(try nutritionResourceKeys(resource), expectedAndroid, folder)
            XCTAssertTrue(
                resource.contains("Generated by Tools/NutritionLocalization/generate.rb")
            )
        }
    }

    func testNutritionSurfacesUseLocalizedAccessibleCopyAndClearTabBar() throws {
        let apple = try text("Strand/Screens/NutritionLogView.swift")
        let android = try text("android/app/src/main/java/com/noop/ui/NutritionLogScreen.kt")
        let shell = try text("StrandiOS/App/RootTabView.swift")

        XCTAssertTrue(apple.contains(#"title: "nutrition.title""#))
        XCTAssertTrue(apple.contains(#"Text("nutrition.entries.saved_title")"#))
        XCTAssertTrue(apple.contains(#"String(localized: "nutrition.editor.invalid_number_format")"#))
        XCTAssertTrue(apple.contains(".accessibilityElement(children: .combine)"))
        XCTAssertFalse(apple.contains(#"Text("Imported total prevents double counting")"#))
        XCTAssertFalse(apple.contains("mixedSourceCard"))

        XCTAssertTrue(android.contains("R.string.nutrition_title"))
        XCTAssertTrue(android.contains("R.string.nutrition_entries_saved_title"))
        XCTAssertTrue(android.contains("semantics(mergeDescendants = true)"))
        XCTAssertTrue(android.contains("userFacingNutritionMessage(context: Context)"))
        XCTAssertFalse(android.contains(#"title = "Nutrition""#))
        XCTAssertFalse(android.contains("NutritionMixedSourceCard"))

        XCTAssertTrue(shell.contains("expandedReservedHeight: CGFloat = 88"))
        XCTAssertTrue(shell.contains(".padding(.bottom, visibleTabBarHeight)"))
        XCTAssertFalse(shell.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertFalse(shell.contains("floatingTabBarClearance"))
    }
}

/// Pins the executable iPhone-shell visual matrix so bottom reachability cannot regress into
/// an undocumented one-off screenshot. Runtime execution remains in the script; these source
/// contracts keep its device/state coverage and cleanup guarantees reviewable in normal tests.
final class TabShellVisualQAContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testRuntimeMatrixCoversDevicesRoutesAndAccessibilityStates() throws {
        let script = try text("Tools/ios-tab-shell-visual-qa.sh")

        XCTAssertTrue(script.contains("iPhone-17-Pro-Max"))
        XCTAssertTrue(script.contains("iPhone-17e"))
        XCTAssertTrue(script.contains("--demo-tab today"))
        XCTAssertTrue(script.contains("--demo-tab trends"))
        XCTAssertTrue(script.contains("--demo-tab sleep"))
        XCTAssertTrue(script.contains("--demo-tab more"))
        XCTAssertTrue(script.contains("--demo-more-route nutrition"))
        XCTAssertTrue(script.contains("--demo-scroll-bottom"))
        XCTAssertTrue(script.contains("--demo-compact-tab-bar"))
        XCTAssertTrue(script.contains("accessibility-large"))
        XCTAssertTrue(script.contains("increase_contrast"))
        XCTAssertTrue(script.contains("appearance"))
        XCTAssertTrue(script.contains("--demo-shell-keyboard-visible"))
        XCTAssertTrue(script.contains("--demo-shell-keyboard-restored"))
        XCTAssertTrue(script.contains("manifest.tsv"))
        XCTAssertTrue(script.contains("--validate-only"))
        XCTAssertTrue(script.contains("validate_device_artifacts"))
        XCTAssertTrue(script.contains("validate_manifest"))
    }

    func testRuntimeMatrixUsesDisposableSimulatorsAndRealShellKeyboardEvents() throws {
        let script = try text("Tools/ios-tab-shell-visual-qa.sh")
        let shell = try text("StrandiOS/App/RootTabView.swift")
        let coach = try text("Strand/Screens/CoachView.swift")

        XCTAssertTrue(script.contains("trap cleanup EXIT INT TERM"))
        XCTAssertTrue(script.contains("simctl shutdown"))
        XCTAssertTrue(script.contains("simctl delete"))
        XCTAssertTrue(script.contains("ConnectHardwareKeyboard"))
        XCTAssertTrue(shell.contains(#"case "coach": return .coach"#))
        XCTAssertTrue(shell.contains("UIResponder.keyboardWillShowNotification"))
        XCTAssertTrue(shell.contains("UIResponder.keyboardDidHideNotification"))
        XCTAssertTrue(coach.contains(".focused($setupKeyFocused)"))
        XCTAssertTrue(coach.contains("Tab shell keyboard QA focused"))
        XCTAssertTrue(coach.contains("Tab shell keyboard QA dismissed"))
        XCTAssertTrue(script.contains("mixed=true"))
        XCTAssertTrue(script.contains("Crash signature found"))
        XCTAssertTrue(script.contains("cmp -s"))
    }
}

/// Pins Safety Center's generated nine-locale catalog/resources and its assistive-technology contract.
final class SafetyCenterLocalizationContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func safetyResourceKeys(_ source: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"name="(safety_[^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }

    func testGeneratedSafetyCopyCoversAllNineLocalesAndBothPlatforms() throws {
        let sourceData = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Tools/SafetyLocalization/safety_strings.json"
            )
        )
        let source = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceData) as? [String: [String: String]]
        )
        let locales = Set(["en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"])
        XCTAssertEqual(source.count, 182)
        for (key, translations) in source {
            XCTAssertTrue(key.hasPrefix("safety."), key)
            XCTAssertEqual(Set(translations.keys), locales, key)
            XCTAssertTrue(translations.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }

        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let safetyCatalog = strings.filter { $0.key.hasPrefix("safety.") }
        XCTAssertEqual(Set(safetyCatalog.keys), Set(source.keys))
        for (key, rawEntry) in safetyCatalog {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertEqual(Set(localizations.keys), locales, key)
        }

        let expectedAndroid = Set(source.keys.map { $0.replacingOccurrences(of: ".", with: "_") })
        let folders = [
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        ]
        for folder in folders {
            let resource = try text("android/app/src/main/res/\(folder)/safety.xml")
            XCTAssertEqual(try safetyResourceKeys(resource), expectedAndroid, folder)
            XCTAssertTrue(resource.contains("Generated by Tools/SafetyLocalization/generate.rb"))
        }
    }

    func testSafetySurfacesUseLocalizedCopyAndAccessibleControls() throws {
        let apple = try text("Strand/Screens/SafetyCenterView.swift")
        let notifications = try text("Strand/System/SafetyCheckInNotifications.swift")
        let android = try text("android/app/src/main/java/com/noop/ui/SafetyCenterScreen.kt")
        let androidNotifications = try text(
            "android/app/src/main/java/com/noop/safety/SafetyCheckInReminder.kt"
        )
        let components = try text("android/app/src/main/java/com/noop/ui/Components.kt")

        XCTAssertTrue(apple.contains("copy: localizedSafetyShareCopy"))
        XCTAssertTrue(apple.contains("DateComponentsFormatter()"))
        XCTAssertTrue(apple.contains("minHeight: NoopMetrics.controlHeight"))
        XCTAssertTrue(apple.contains(".accessibilityHint(shareAccessibilityHint)"))
        XCTAssertFalse(apple.contains(#"Text("If danger is immediate")"#))
        XCTAssertTrue(notifications.contains(#"String(localized: "safety.notification.title")"#))

        XCTAssertTrue(android.contains("copy = safetyShareCopy"))
        XCTAssertTrue(android.contains("accessibilityLabel = {"))
        XCTAssertTrue(android.contains("role = Role.Switch"))
        XCTAssertTrue(android.contains("semantics(mergeDescendants = true)"))
        XCTAssertFalse(android.contains(#"title = "Safety""#))
        XCTAssertTrue(androidNotifications.contains("R.string.safety_notification_channel_description"))
        XCTAssertTrue(components.contains("accessibilityLabel: (T) -> String = label"))
        XCTAssertTrue(components.contains("contentDescription = accessibilityLabel(item)"))
    }
}

/// Pins shared app-wide copy to one complete nine-locale source on Apple and Android.
final class AppWideLocalizationContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func appWideResourceKeys(_ source: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"name="(appwide_[^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }

    func testGeneratedAppWideCopyCoversAllNineLocalesAndBothPlatforms() throws {
        let sourceData = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Tools/AppWideLocalization/appwide_strings.json"
            )
        )
        let source = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceData) as? [String: [String: String]]
        )
        let locales = Set(["en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"])
        XCTAssertEqual(source.count, 61)
        for (key, translations) in source {
            XCTAssertTrue(key.hasPrefix("appwide."), key)
            XCTAssertEqual(Set(translations.keys), locales, key)
            XCTAssertTrue(
                translations.values.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                },
                key
            )
        }

        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let appWideCatalog = strings.filter { $0.key.hasPrefix("appwide.") }
        XCTAssertEqual(Set(appWideCatalog.keys), Set(source.keys))
        for (key, rawEntry) in appWideCatalog {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertEqual(Set(localizations.keys), locales, key)
        }

        let expectedAndroid = Set(source.keys.map { $0.replacingOccurrences(of: ".", with: "_") })
        let folders = [
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        ]
        for folder in folders {
            let resource = try text("android/app/src/main/res/\(folder)/appwide.xml")
            XCTAssertEqual(try appWideResourceKeys(resource), expectedAndroid, folder)
            XCTAssertTrue(
                resource.contains("Generated by Tools/AppWideLocalization/generate.rb")
            )
        }
    }
}
