import Foundation
import XCTest
@testable import Strand

/// Pins the production Today presentation to the evidence-gated DailyActionPlanner contract.
final class DailyActionTodayContractTests: XCTestCase {
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

    private func androidResourceKeys(_ source: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"name="(daily_plan_[^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }

    func testAppleTodayUsesPlannerAndDayScopedCheckInForEveryState() throws {
        let today = try text("Strand/Liquid/LiquidTodayView.swift")

        XCTAssertTrue(today.contains("@AppStorage(BehaviorStore.dailyActionCheckInDayKey)"))
        XCTAssertTrue(today.contains("@AppStorage(BehaviorStore.dailyActionCheckInValueKey)"))
        XCTAssertTrue(today.contains("cachedDailyActionPlan"))
        XCTAssertTrue(today.contains("DailyActionPlanner.plan("))
        XCTAssertTrue(today.contains("BehaviorStore.decodeDailyActionCheckIn("))
        XCTAssertTrue(today.contains("setDailyActionCheckIn("))
        XCTAssertTrue(today.contains(
            "behavior.setDailyActionCheckIn(value, for: selectedDayKey)"
        ))
        XCTAssertTrue(today.contains("selectedDayOffset == 0"))
        XCTAssertTrue(today.contains("dailyPlanTargetStatusKey(plan)"))
        XCTAssertTrue(today.contains(#""daily_plan.target.withheld""#))
        XCTAssertTrue(today.contains("@Environment(\\.dynamicTypeSize)"))
        XCTAssertTrue(today.contains("if !dynamicTypeSize.isAccessibilitySize"))

        for state in ["checkInNeeded", "calibrating", "recoveryShift", "stop", "ready"] {
            XCTAssertTrue(today.contains("case .\(state):"), "Missing \(state) presentation")
        }

        XCTAssertTrue(today.contains("readiness.signals"))
        XCTAssertTrue(today.contains("$0.flag == .watch || $0.flag == .bad"))
        XCTAssertTrue(today.contains(#"String(localized: "daily_plan.effort.scale")"#))
        XCTAssertFalse(today.contains("effortTargetBand"))
        XCTAssertFalse(today.contains("targetAdvice"))
        XCTAssertFalse(today.contains("Your body can take a demanding session"))
        XCTAssertFalse(today.contains("A solid session is well supported"))
        XCTAssertFalse(today.contains("from your Recovery"))
    }

    func testAndroidTodayUsesSamePlannerAndSignalPolicy() throws {
        let today = try text("android/app/src/main/java/com/noop/ui/TodayScreen.kt")

        XCTAssertTrue(today.contains("import com.noop.analytics.DailyActionPlanner"))
        XCTAssertTrue(today.contains("NoopPrefs.dailyActionCheckIn(context, selectedDayKey)"))
        XCTAssertTrue(today.contains("NoopPrefs.setDailyActionCheckIn("))
        XCTAssertTrue(today.contains("DailyActionPlanner.plan("))
        XCTAssertTrue(today.contains("TodaySection.WHY -> DailyPlanWhySection("))
        XCTAssertTrue(today.contains("TodaySection.TARGET -> DailyPlanTargetSection("))
        XCTAssertTrue(today.contains("TodaySection.WATCH -> DailyPlanWatchSection("))
        XCTAssertTrue(today.contains("dailyPlanTargetStatusResource(plan)"))
        XCTAssertTrue(today.contains("R.string.daily_plan_target_withheld"))
        XCTAssertTrue(today.contains(
            "it.flag == ReadinessEngine.Flag.WATCH || it.flag == ReadinessEngine.Flag.BAD"
        ))

        for state in ["CHECK_IN_NEEDED", "CALIBRATING", "RECOVERY_SHIFT", "STOP", "READY"] {
            XCTAssertTrue(today.contains("Availability.\(state)"), "Missing \(state) presentation")
        }

        XCTAssertTrue(today.contains("R.string.daily_plan_effort_scale"))
        XCTAssertFalse(today.contains("Your body can take a demanding session"))
        XCTAssertFalse(today.contains("A solid session is well supported"))
    }

    func testDailyPlanVisualMatrixUsesRealPlannerStatesAndDisposableSimulator() throws {
        let today = try text("Strand/Liquid/LiquidTodayView.swift")
        let script = try text("Tools/ios-daily-plan-visual-qa.sh")

        XCTAssertTrue(today.contains(#""--demo-daily-plan""#))
        XCTAssertTrue(today.contains(#""--demo-daily-plan-check-in""#))
        XCTAssertTrue(today.contains(#""--demo-planned-workout""#))
        XCTAssertTrue(today.contains("Daily Plan QA availability="))
        XCTAssertTrue(today.contains("plannedWorkout="))
        for state in ["unanswered", "asUsual", "belowUsual", "painOrUnwell"] {
            XCTAssertTrue(script.contains(state), state)
        }
        XCTAssertTrue(script.contains("accessibility-large"))
        XCTAssertTrue(script.contains("increase_contrast"))
        XCTAssertTrue(script.contains("trap cleanup EXIT INT TERM"))
        XCTAssertTrue(script.contains("simctl delete"))
        XCTAssertTrue(script.contains("validate_capture"))
        XCTAssertTrue(script.contains("wait_for_qa_state"))
        XCTAssertTrue(script.contains("noop-daily-plan-qa.txt"))
        XCTAssertTrue(script.contains("|| return 1"))
        XCTAssertTrue(script.contains("|| exit 1"))
        XCTAssertTrue(script.contains("warm_up_seed"))
        XCTAssertTrue(script.contains("*.png(N)"))
        XCTAssertTrue(script.contains("signalstats"))
        XCTAssertTrue(script.contains("capture planned-workout"))
    }

    func testGeneratedDailyPlanCopyCoversNineLocalesAndBothPlatforms() throws {
        let sourceData = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Tools/DailyPlanLocalization/daily_plan_strings.json"
            )
        )
        let source = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceData) as? [String: [String: String]]
        )
        let locales = Set(["en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"])
        XCTAssertGreaterThanOrEqual(source.count, 25)
        for (key, translations) in source {
            XCTAssertTrue(key.hasPrefix("daily_plan."), key)
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
        let dailyPlanCatalog = strings.filter { $0.key.hasPrefix("daily_plan.") }
        XCTAssertEqual(Set(dailyPlanCatalog.keys), Set(source.keys))
        for (key, rawEntry) in dailyPlanCatalog {
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
            let resource = try text("android/app/src/main/res/\(folder)/daily_plan.xml")
            XCTAssertEqual(try androidResourceKeys(resource), expectedAndroid, folder)
            XCTAssertTrue(
                resource.contains("Generated by Tools/DailyPlanLocalization/generate.rb")
            )
        }
    }
}
