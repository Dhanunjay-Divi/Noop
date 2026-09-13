import Foundation
import XCTest
import WhoopStore
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

    func testTrendsHasBoundedTimeoutFailureAndRetry() throws {
        let trends = try sourceText("Strand/Screens/TrendsView.swift")
        XCTAssertTrue(trends.contains("productionTimeoutNanoseconds"))
        XCTAssertTrue(trends.contains("--demo-trends-timeout"))
        XCTAssertEqual(
            TrendsView.LoadPolicy.timeoutNanoseconds(
                arguments: ["NOOP", "--demo-trends-timeout"],
                retryGeneration: 0
            ),
            TrendsView.LoadPolicy.demoTimeoutNanoseconds
        )
        XCTAssertEqual(
            TrendsView.LoadPolicy.timeoutNanoseconds(
                arguments: ["NOOP", "--demo-trends-timeout"],
                retryGeneration: 1
            ),
            TrendsView.LoadPolicy.productionTimeoutNanoseconds
        )
        XCTAssertTrue(trends.contains("noop.trends.failure"))
        XCTAssertTrue(trends.contains("action: retryTrends"))
        XCTAssertTrue(trends.contains("outcome = \"timed_out\""))
    }

    func testExternalHealthProjectionReconcilesOptInRoutineNotifications() throws {
        let iosApp = try sourceText("StrandiOS/App/StrandiOSApp.swift")
        let appleModel = try sourceText("Strand/App/AppModel.swift")
        let androidWorker = try sourceText(
            "android/app/src/main/java/com/noop/ingest/HealthConnectAutoSync.kt"
        )

        XCTAssertTrue(iosApp.contains(
            "await model.processAppleHealthProjectionChange("
        ))
        XCTAssertTrue(appleModel.contains(
            "func processAppleHealthProjectionChange("
        ))
        XCTAssertTrue(appleModel.contains(
            "postSyncRoutineCoordinationActive = true"
        ))
        XCTAssertTrue(appleModel.contains(
            "await evaluateContextualInterventions(\n            notificationBudget: notificationBudget"
        ))
        XCTAssertTrue(androidWorker.contains("if (outcome.rebuilt)"))
        XCTAssertTrue(androidWorker.contains("ScheduledReportNotifier.onWorkout("))
        XCTAssertTrue(androidWorker.contains("AdaptiveDayEvaluator.evaluateAndNotify("))
        XCTAssertTrue(androidWorker.contains("ScheduledReportNotifier.onMorning("))
        XCTAssertTrue(androidWorker.contains("\"source\" to \"external_health\""))
    }

    func testAuditedCoreSurfacesUseTheSharedMissingValueToken() throws {
        let auditedPaths = [
            "Strand/Liquid/LiquidTodayView.swift",
            "Strand/Screens/FriendsView.swift",
            "Strand/Screens/HealthView.swift",
            "Strand/Screens/LiveView.swift",
            "Strand/Screens/SleepView.swift",
            "Strand/Screens/StressView.swift",
            "Strand/Screens/TodayView.swift",
            "Strand/Screens/TrendsView.swift",
            "Strand/Screens/WeeklyDigestView.swift",
            "StrandiOS/System/ManagedFriendsView.swift",
        ]
        let forbidden = [
            #"?? "-""#,
            #"?? "–""#,
            #"return "-""#,
            #"return "–""#,
            #"== "-""#,
            #"== "–""#,
        ]

        for path in auditedPaths {
            let source = try sourceText(path)
            for fragment in forbidden {
                XCTAssertFalse(
                    source.contains(fragment),
                    "\(path) reintroduced a raw missing-value token: \(fragment)"
                )
            }
        }

        XCTAssertTrue(
            try sourceText("Strand/Screens/TodayView.swift")
                .contains("StrandFormat.missing")
        )
        XCTAssertTrue(
            try sourceText("StrandiOS/System/ManagedFriendsView.swift")
                .contains("StrandFormat.missing")
        )
    }

    func testAuditedSocialAndBandCopyUsesCurrentVocabulary() throws {
        let managedFriends = try sourceText(
            "StrandiOS/System/ManagedFriendsView.swift"
        )
        let androidStrings = try sourceText(
            "android/app/src/main/res/values/strings.xml"
        )
        let canonicalCopy = try sourceText(
            "Tools/AppWideLocalization/appwide_strings.json"
        )
        let today = try sourceText("Strand/Screens/TodayView.swift")
        let breathing = try sourceText("Strand/Screens/BreathingView.swift")
        let androidModel = try sourceText(
            "android/app/src/main/java/com/noop/ui/AppViewModel.kt"
        )

        XCTAssertTrue(managedFriends.contains(#"label: "Sleep Score""#))
        XCTAssertFalse(managedFriends.contains(#"label: "Rest""#))
        XCTAssertFalse(androidStrings.contains("Sync your strap"))
        XCTAssertTrue(
            androidStrings.contains(
                #"<string name="managed_friends_rest">Sleep Score</string>"#
            )
        )
        XCTAssertFalse(canonicalCopy.contains("Only Recovery, Effort, Rest"))
        XCTAssertTrue(
            canonicalCopy.contains(
                "Only Recovery, Effort, Sleep Score, sleep duration"
            )
        )
        XCTAssertFalse(today.contains(#""Strap sync""#))
        XCTAssertTrue(today.contains(#""Band sync""#))
        XCTAssertFalse(breathing.contains("pulse on the strap"))
        XCTAssertTrue(breathing.contains("pulse on the band"))
        XCTAssertFalse(androidModel.contains("after your strap synced"))
        XCTAssertTrue(androidModel.contains("after your band synced"))
    }

    func testAuditedP2PresentationFixesRemainMounted() throws {
        XCTAssertTrue(
            try sourceText("Strand/Screens/DevicesView.swift")
                .contains("if !profile.footnote.isEmpty")
        )
        XCTAssertTrue(
            try sourceText("Strand/Screens/SettingsView.swift")
                .contains(#"Text("Age")"#)
        )
        let stress = try sourceText("Strand/Screens/StressView.swift")
        XCTAssertTrue(stress.contains("appwide.stress.band.light_load"))
        XCTAssertTrue(stress.contains("appwide.common.vs_baseline"))
        XCTAssertTrue(
            try sourceText("Strand/Screens/JournalLogCard.swift")
                .contains(".padding(.horizontal, NoopMetrics.space4)")
        )
        let health = try sourceText("Strand/Screens/HealthView.swift")
        XCTAssertTrue(health.contains("appwide.health.live_hr.disconnected"))
        let settings = try sourceText("Strand/Screens/SettingsView.swift")
        XCTAssertTrue(settings.contains("appwide.health.live_activity.lock_screen"))
        XCTAssertTrue(settings.contains("appwide.health.live_activity.recovery_indicator"))
        let sleep = try sourceText("Strand/Screens/SleepView.swift")
        XCTAssertTrue(sleep.contains(#"SectionHeader("Sleep Score""#))
        XCTAssertTrue(sleep.contains("appwide.sleep.imported_confidence_note"))
        let managed = try sourceText("StrandiOS/System/ManagedCloudViews.swift")
        XCTAssertTrue(managed.contains("managedBenefit("))
        XCTAssertTrue(managed.contains(#"title: "Stays local-first""#))
    }
}

/// Dynamic Type must reach the user's selected accessibility size across app
/// content. Fixed navigation chrome may retain a local cap when it preserves
/// stable destinations and spoken labels.
final class RootDynamicTypeContractTests: XCTestCase {
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

    func testAppleAppRootsDoNotClampAccessibilityText() throws {
        let macApp = try text("Strand/App/StrandApp.swift")
        let iosApp = try text("StrandiOS/App/StrandiOSApp.swift")
        let globalClamp = ".dynamicTypeSize(...DynamicTypeSize.accessibility1)"

        XCTAssertFalse(macApp.contains(globalClamp))
        XCTAssertFalse(iosApp.contains(globalClamp))
    }

    func testFixedIOSNavigationChromeKeepsLocalLargeTextBehavior() throws {
        let shell = try text("StrandiOS/App/RootTabView.swift")

        XCTAssertTrue(shell.contains(
            "compact && !dynamicTypeSize.isAccessibilitySize"
        ))
        XCTAssertTrue(shell.contains(
            ".dynamicTypeSize(...DynamicTypeSize.xxxLarge)"
        ))
        XCTAssertTrue(shell.contains("accessibilityShowsLargeContentViewer"))
    }

    func testTodayContentHonorsAccessibilityTextAndQAExpandsTheRealPlan() throws {
        let today = try text("Strand/Liquid/LiquidTodayView.swift")
        let localClamp = ".dynamicTypeSize(...DynamicTypeSize.accessibility1)"

        XCTAssertFalse(today.contains(localClamp))
        XCTAssertTrue(today.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(today.contains(
            "@State private var todayDetailsExpanded = Self.initialTodayDetailsExpanded"
        ))
        XCTAssertTrue(today.contains(
            #"CommandLine.arguments.contains("--demo-daily-plan")"#
        ))
        XCTAssertTrue(today.contains(
            "return [.target] + saved.filter { $0 != .target }"
        ))
        XCTAssertTrue(today.contains(
            "Color.clear.frame(height: 0).id(Self.dailyPlanAnchorID)"
        ))
        XCTAssertTrue(today.contains(
            "dynamicTypeSize.isAccessibilitySize ? 0.12 : 0.08"
        ))
        XCTAssertTrue(today.contains(
            #"CommandLine.arguments.contains("--demo-daily-plan-collapsed")"#
        ))
        XCTAssertTrue(today.contains(
            "? Self.dailyPlanDisclosureAnchorID"
        ))
        XCTAssertTrue(today.contains(
            ": Self.dailyPlanAnchorID"
        ))
        XCTAssertTrue(today.contains(
            "proxy.scrollTo(framingID, anchor: framingAnchor)"
        ))
    }

    func testDailyPlanVisualMatrixIncludesMaximumAccessibilityText() throws {
        let script = try text("Tools/ios-daily-plan-visual-qa.sh")

        XCTAssertTrue(script.contains("accessibility5-stop"))
        XCTAssertTrue(script.contains(
            "accessibility-extra-extra-extra-large"
        ))
        XCTAssertTrue(script.contains("collapsed-planned-workout"))
        XCTAssertTrue(script.contains(
            "accessibility-collapsed-planned-workout"
        ))
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
        XCTAssertEqual(source.count, 103)
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
        XCTAssertTrue(apple.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(apple.contains("@ScaledMetric(relativeTo: .title3)"))
        XCTAssertFalse(apple.contains(#"Text("Imported total prevents double counting")"#))
        XCTAssertFalse(apple.contains("mixedSourceCard"))

        XCTAssertTrue(android.contains("R.string.nutrition_title"))
        XCTAssertTrue(android.contains("R.string.nutrition_entries_saved_title"))
        XCTAssertTrue(android.contains("semantics(mergeDescendants = true)"))
        XCTAssertTrue(android.contains("userFacingNutritionMessage(context: Context)"))
        XCTAssertTrue(android.contains("LocalDensity.current.fontScale > 1.3f"))
        XCTAssertTrue(android.contains("NutritionMacroSummaryColumn("))
        XCTAssertFalse(android.contains(#"title = "Nutrition""#))
        XCTAssertFalse(android.contains("NutritionMixedSourceCard"))

        XCTAssertTrue(shell.contains("expandedReservedHeight: CGFloat = 76"))
        XCTAssertTrue(shell.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(shell.contains(".frame(height: visibleTabBarHeight)"))
        XCTAssertTrue(shell.contains(
            "if !keyboardVisible, dynamicTypeSize.isAccessibilitySize"
        ))
        XCTAssertTrue(shell.contains(".frame(height: visibleTabBarHeight + 28)"))
        XCTAssertFalse(shell.contains(".padding(.bottom, visibleTabBarHeight)"))
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
        XCTAssertTrue(script.contains("today-accessibility"))
        XCTAssertTrue(script.contains("--demo-daily-plan"))
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
        let pattern = try NSRegularExpression(
            pattern: #"name="((?:managed_)?safety_[^"]+)""#
        )
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
        XCTAssertEqual(source.count, 314)
        for (key, translations) in source {
            XCTAssertTrue(
                key.hasPrefix("safety.") || key.hasPrefix("managed.safety."),
                key
            )
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
        let safetyCatalog = strings.filter {
            $0.key.hasPrefix("safety.") || $0.key.hasPrefix("managed.safety.")
        }
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
/// Pins the ten-reference consolidation to existing data-backed NOOP surfaces.
final class ReferenceSurfaceContractTests: XCTestCase {
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

    func testMonthOffersEveryReferenceDomainWithoutInventingEnergyScore() throws {
        let calendar = try text("Strand/Screens/CalendarMonthView.swift")

        XCTAssertTrue(calendar.contains("case effort, recovery, sleep, stress, energy, nutrition"))
        XCTAssertTrue(calendar.contains(#".accessibilityIdentifier("noop.calendar.metric.\(m.rawValue)")"#))
        XCTAssertTrue(calendar.contains(#"key: "active_kcal", source: "apple-health""#))
        XCTAssertFalse(calendar.contains(#"key: "energy_kcal", source: "my-whoop""#))
        XCTAssertTrue(calendar.contains("readout.confidence == .reliable"))
        XCTAssertTrue(calendar.contains(#"key: "calories_in", source: "nutrition-log""#))
        XCTAssertTrue(calendar.contains("relativeProgress(value, values: Array(energyByDay.values))"))
        XCTAssertFalse(calendar.contains("bodyBattery"))
    }

    func testHealthMonitorKeepsRawOpticsOutAndAddsRecordedTimelineAndBiomarkers() throws {
        let health = try text("Strand/Screens/HealthView.swift")
        let vitals = try text("Strand/Screens/VitalSignsSummary.swift")

        XCTAssertTrue(health.contains(
            #").filter { ["resp", "spo2", "rhr", "hrv", "skin"].contains($0.key) }"#
        ))
        XCTAssertTrue(health.contains("HealthTimelineSection()"))
        XCTAssertTrue(health.contains("BiomarkerTrendsSection()"))
        XCTAssertTrue(health.contains("Missing wear time stays blank."))
        XCTAssertTrue(vitals.contains(#"key: "sleep""#))
        XCTAssertTrue(vitals.contains("populationRange: 7...9"))
        XCTAssertTrue(health.contains("sleepOverrideDays: repo.editedSleepDays"))
        XCTAssertTrue(health.contains("duration(sleep.durationSeconds)"))
        XCTAssertFalse(health.contains("let seconds = daily?.totalSleepMin"))
        XCTAssertTrue(health.contains(#"MetricCatalog.metric(key: "vo2max", source: "apple-health")"#))
        XCTAssertFalse(health.contains(#"title: "Biological Age""#))
    }

    func testFitnessCalendarAndReferenceDestinationsStayDiscoverable() throws {
        let fitness = try text("Strand/Screens/WorkoutsView.swift")
        let calendar = try text("Strand/Screens/CalendarMonthView.swift")
        let androidFitness = try text(
            "android/app/src/main/java/com/noop/ui/WorkoutsScreen.kt"
        )
        let androidCalendar = try text(
            "android/app/src/main/java/com/noop/ui/CalendarMonthScreen.kt"
        )
        let shell = try text("StrandiOS/App/RootTabView.swift")

        XCTAssertTrue(fitness.contains("activityCalendarSection(rows: allRows)"))
        XCTAssertTrue(fitness.contains("WorkoutActivityCalendarSummary.resolve("))
        XCTAssertTrue(fitness.contains(#""activity-calendar-leading-\($0)""#))
        XCTAssertFalse(fitness.contains("ForEach(0..<leading, id: \\.self)"))
        XCTAssertTrue(fitness.contains(
            #"String(localized: "appwide.workouts.activity_calendar.one_recorded_activity")"#
        ))
        XCTAssertTrue(fitness.contains(
            #"String(localized: "appwide.workouts.activity_calendar.recorded_activities")"#
        ))
        XCTAssertTrue(fitness.contains(
            "scope: target.scope"
        ))
        XCTAssertTrue(fitness.contains("scope: .activity,"))
        XCTAssertTrue(calendar.contains(
            "scope: metric.overviewScope"
        ))
        XCTAssertTrue(calendar.contains("focusValue: raw"))
        XCTAssertFalse(calendar.contains("scope: .all"))
        XCTAssertTrue(androidFitness.contains("scope = DayOverviewScope.ACTIVITY"))
        XCTAssertTrue(androidCalendar.contains("scope = target.metric.dayOverviewScope()"))
        XCTAssertTrue(androidCalendar.contains("focusValue = target.focusValue"))
        XCTAssertFalse(androidCalendar.contains("scope = DayOverviewScope.ALL"))
        XCTAssertTrue(shell.contains(#"tab(WorkoutsView(), "Workouts""#))
        XCTAssertTrue(shell.contains(#"MoreRow("Month", "calendar", .calendar)"#))
        XCTAssertTrue(shell.contains(#"MoreRow("Journal & Insights", "book.closed.fill", .insights)"#))
        XCTAssertTrue(shell.contains(#"MoreRow("Health & Biology", "heart.text.square.fill", .health)"#))
    }

    func testTodayShowsTheFullCatalogWithSavedMetricsPinnedFirst() throws {
        let classic = try text("Strand/Screens/TodayView.swift")
        let liquid = try text("Strand/Liquid/LiquidTodayView.swift")
        let recoveryRing = try text("Packages/StrandDesign/Sources/StrandDesign/RecoveryRing.swift")
        let androidToday = try text("android/app/src/main/java/com/noop/ui/TodayScreen.kt")
        let androidRing = try text("android/app/src/main/java/com/noop/ui/Components.kt")

        XCTAssertTrue(classic.contains("private var visibleKeyMetrics: [KeyMetric]"))
        XCTAssertTrue(classic.contains("ForEach(visibleKeyMetrics)"))
        XCTAssertTrue(classic.contains(
            "KeyMetricPrefs.catalogOrder(startingWith: enabledKeyMetrics)"
        ))
        XCTAssertTrue(liquid.contains("private var visibleKeyMetrics: [KeyMetric]"))
        XCTAssertTrue(liquid.contains("ForEach(visibleKeyMetrics)"))
        XCTAssertTrue(liquid.contains(
            "KeyMetricPrefs.catalogOrder(startingWith: enabledKeyMetrics)"
        ))
        XCTAssertTrue(classic.contains("StrandPalette.recoveryGaugeColors(s).base"))
        XCTAssertTrue(liquid.contains("StrandPalette.recoveryGaugeColors(score)"))
        XCTAssertTrue(recoveryRing.contains("StrandPalette.recoveryGaugeStops(score)"))
        XCTAssertTrue(androidToday.contains("Palette.recoveryGaugeColors(it).first"))
        XCTAssertTrue(androidRing.contains("Palette.recoveryGaugeStops(score)"))
    }
}

final class LiveSessionPreflightContractTests: XCTestCase {
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

    func testOpeningCoachIsInertUntilExplicitConfirmationOnBothPlatforms() throws {
        let apple = try text("Strand/Liquid/LiveSessionView.swift")
        let androidScreen = try text(
            "android/app/src/main/java/com/noop/ui/LiveSessionScreen.kt")
        let androidToday = try text(
            "android/app/src/main/java/com/noop/ui/TodayScreen.kt")

        XCTAssertTrue(apple.contains("@State private var hasStarted = false"))
        XCTAssertTrue(apple.contains(
            "LiveSessionPreflightView(onStart: startSession, onClose: onClose)"))
        XCTAssertFalse(apple.contains(".onAppear {\n            runner.start("))

        XCTAssertTrue(androidScreen.contains(
            "if (runner == null) {\n        LiveSessionPreflight("))
        XCTAssertTrue(androidScreen.contains(
            "if (liveSessionBandReady(vm.live.value)) {\n" +
            "                    startOrResumeLiveSession(vm, context)"))
        XCTAssertTrue(androidScreen.contains("enabled = bandReady"))
        XCTAssertTrue(androidScreen.contains(
            "live.connected && live.bonded && live.encryptedBond && live.worn"))
        XCTAssertTrue(apple.contains(".disabled(!canStart)"))
        XCTAssertTrue(apple.contains(
            "internal func liveSessionBandReady(_ live: LiveState) -> Bool"))
        XCTAssertTrue(apple.contains(
            "guard !hasStarted,\n" +
            "              liveSessionBandReady(model.live)"))
        XCTAssertTrue(androidToday.contains("appwide_live_session_connect_band"))
        XCTAssertTrue(androidToday.contains("appwide_live_session_band_required"))
        XCTAssertFalse(androidToday.contains(
            "if (LiveSessionRunner.active.value == null) {\n" +
            "                                    startOrResumeLiveSession"))
    }
}

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
        XCTAssertEqual(source.count, 726)
        XCTAssertEqual(source["appwide.daily_signal.status.aligned"]?["en"], "Steady")
        XCTAssertEqual(source["appwide.daily_signal.status.recheck"]?["en"], "Watch")
        XCTAssertEqual(
            source["appwide.weekly_digest.imported_sleep_not_included"]?["en"],
            "Imported sleep not included"
        )
        XCTAssertEqual(
            source["appwide.live_session.start_detail_unavailable"]?["en"],
            "Live heart-rate coaching uses heart rate while today's Recovery is unavailable."
        )
        XCTAssertNil(source["appwide.live_session.start_detail_calibrating"])
        XCTAssertEqual(
            source["appwide.friends.data_boundary"]?["en"],
            "Only Recovery, Effort, Sleep Score, sleep duration, HRV, and resting heart rate can be shared. Raw streams, locations, journals, routes, workouts, and sleep stages are excluded."
        )
        XCTAssertEqual(
            source["appwide.terms.title"]?["en"],
            "NOOP Band is coming"
        )
        XCTAssertEqual(
            source["appwide.terms.subtitle"]?["en"],
            "Until NOOP Band is ready, this version works with a compatible band you own."
        )
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

    func testTermsVersionsStayInSyncAcrossPlatformsAndBundledDocument() throws {
        let apple = try text("Strand/App/Terms.swift")
        let android = try text("android/app/src/main/java/com/noop/ui/TermsGate.kt")
        let document = try text("TERMS.md")

        func capture(_ pattern: String, in source: String) throws -> String {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            let match = try XCTUnwrap(regex.firstMatch(in: source, range: range))
            let capture = try XCTUnwrap(Range(match.range(at: 1), in: source))
            return String(source[capture])
        }

        let appleVersion = try capture(#"currentVersion = "([^"]+)""#, in: apple)
        let androidVersion = try capture(#"CURRENT_VERSION = "([^"]+)""#, in: android)
        let documentVersion = try capture(#"\*\*Version ([^*]+)\*\*"#, in: document)

        XCTAssertEqual(appleVersion, androidVersion)
        XCTAssertEqual(appleVersion, documentVersion)
    }
}

final class NutritionSummaryContractTests: XCTestCase {
    func testLatestFastingGlucoseIgnoresFutureAndQualitativeRows() throws {
        let numeric = marker(
            id: "numeric",
            day: "2026-08-20",
            takenAt: 100,
            value: 5.2
        )
        let qualitative = marker(
            id: "qualitative",
            day: "2026-08-20",
            takenAt: 200,
            value: nil
        )
        let future = marker(
            id: "future",
            day: "2026-08-22",
            takenAt: 300,
            value: 5.4
        )

        let selected = try XCTUnwrap(
            NutritionSummaryContract.latestFastingGlucose(
                in: [future, qualitative, numeric],
                through: "2026-08-21"
            )
        )

        XCTAssertEqual(selected.id, numeric.id)
    }

    func testLatestFastingGlucoseUsesLatestNumericReadingByTimestamp() throws {
        let early = marker(id: "early", day: "2026-08-20", takenAt: 100, value: 5.0)
        let late = marker(id: "late", day: "2026-08-20", takenAt: 200, value: 5.3)

        let selected = try XCTUnwrap(
            NutritionSummaryContract.latestFastingGlucose(
                in: [late, early],
                through: "2026-08-20"
            )
        )

        XCTAssertEqual(selected.id, late.id)
        XCTAssertNil(
            NutritionSummaryContract.latestFastingGlucose(
                in: [late],
                through: "2026-08-19"
            )
        )
    }

    func testMacroDotsAreRelativeAndDoNotInventMissingValues() {
        let values: [Double?] = [100, 200, nil]

        XCTAssertEqual(
            NutritionSummaryContract.relativeMacroDotCount(value: 100, among: values),
            12
        )
        XCTAssertEqual(
            NutritionSummaryContract.relativeMacroDotCount(value: 200, among: values),
            NutritionSummaryContract.macroDotCapacity
        )
        XCTAssertEqual(
            NutritionSummaryContract.relativeMacroDotCount(value: nil, among: values),
            0
        )
        XCTAssertEqual(
            NutritionSummaryContract.relativeMacroDotCount(value: 0, among: values),
            0
        )
        XCTAssertNil(
            NutritionSummaryContract.bestEffortLatestFastingGlucose(
                in: nil,
                through: "2026-08-20"
            )
        )
    }

    func testLabBookFormattingUsesTheRequestedLocale() {
        let german = Locale(identifier: "de_DE")
        let english = Locale(identifier: "en_US")

        XCTAssertEqual(
            LabBookFormat.value(
                5.2,
                key: NutritionSummaryContract.fastingGlucoseKey,
                locale: german
            ),
            "5,2"
        )
        XCTAssertNotEqual(
            LabBookFormat.dayFromKey("2026-08-23", locale: german),
            LabBookFormat.dayFromKey("2026-08-23", locale: english)
        )
    }

    private func marker(
        id: String,
        day: String,
        takenAt: Int,
        value: Double?
    ) -> LabMarkerRow {
        LabMarkerRow(
            id: id,
            deviceId: "my-whoop",
            markerKey: NutritionSummaryContract.fastingGlucoseKey,
            category: "bloodPanel",
            day: day,
            takenAt: takenAt,
            value: value,
            valueText: value == nil ? "not recorded" : nil,
            unit: "mmol/L",
            source: "manual",
            note: nil,
            referenceText: nil
        )
    }
}
