import Foundation
import XCTest
@testable import Strand

/// Source contracts for the complete local-first Strength Trainer flow.
final class StrengthTrainerContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testWorkoutsEntryAndHonestManualContractStayMounted() throws {
        let workouts = try sourceText("Strand/Screens/WorkoutsView.swift")
        let trainer = try sourceText("Strand/Screens/StrengthTrainerView.swift")

        XCTAssertTrue(workouts.contains("StrengthTrainerView()"))
        XCTAssertTrue(trainer.contains("NOOP does not infer reps or load"))
        XCTAssertTrue(trainer.contains("NOOP never invents tonnage or an estimated one-rep max"))
        XCTAssertFalse(trainer.localizedCaseInsensitiveContains("automatic rep detection"))
        XCTAssertFalse(trainer.localizedCaseInsensitiveContains("estimated 1rm"))
    }

    func testEditorCannotDismissBeforeAConfirmedSave() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")
        let editorSource = try XCTUnwrap(
            source.components(separatedBy: "private struct StrengthSessionEditor: View").last
        )

        XCTAssertTrue(editorSource.contains(".interactiveDismissDisabled()"))
        XCTAssertTrue(editorSource.contains("if await persist(silently: false) { dismiss() }"))
        XCTAssertTrue(editorSource.contains("@State private var pendingSave = false"))
        XCTAssertTrue(editorSource.contains("} while succeeded && pendingSave"))
        XCTAssertTrue(editorSource.contains("completed.completedAt = session.endedAt ?? now"))
        XCTAssertFalse(editorSource.contains(".accessibilityElement(children: .combine)"))
    }

    func testRoutineAndCustomEditorsCannotSwipeAwayUnsavedChanges() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")

        XCTAssertTrue(
            source.contains(
                """
                StrengthRoutineEditor(
                                    initial: target.routine,
                                    exercises: snapshot.exercises,
                                    massUnit: massUnit
                                )
                                .environmentObject(repo)
                                .interactiveDismissDisabled()
                """
            )
        )
        XCTAssertTrue(
            source.contains(
                """
                StrengthCustomExerciseEditor()
                                .environmentObject(repo)
                                .interactiveDismissDisabled()
                """
            )
        )
    }

    func testRecentSessionTotalsExcludeWarmupSets() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")

        XCTAssertTrue(
            source.contains(
                """
                let completed = session.sets.filter {
                            $0.completedAt != nil && $0.setType != "warmup"
                        }
                """
            )
        )
    }

    func testRestTargetIsPersistedAcrossEveryEditorMutation() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")
        let repository = try sourceText("Strand/Data/StrengthTrainingRepository.swift")
        let planner = try sourceText(
            "Packages/WhoopStore/Sources/WhoopStore/StrengthWorkoutPlanning.swift"
        )

        XCTAssertTrue(repository.contains("StrengthWorkoutPlanner.resolvedRestSeconds("))
        XCTAssertTrue(repository.contains("continuesSuperset: continuesSuperset"))
        XCTAssertTrue(planner.contains("if target.setType == \"warmup\""))
        XCTAssertTrue(source.contains("restSeconds: first.restSeconds ?? prescription?.restSeconds ?? 120"))
        XCTAssertTrue(source.contains("restSeconds: blocks[index].restSeconds"))
        XCTAssertTrue(source.contains("blocks[index].sets[setIndex].restSeconds = seconds"))
        XCTAssertTrue(source.contains("Task { await persist(silently: true) }"))
    }

    func testContextualStrengthKeysCoverEveryCatalogLocale() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "(strength\.[^"]+)""#)
        let range = NSRange(source.startIndex..., in: source)
        let keys = Set(pattern.matches(in: source, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
        XCTAssertEqual(keys.count, 44)

        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let locales = Set(["en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"])

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            XCTAssertEqual(Set(localizations.keys), locales, key)
        }

        func localizedValue(_ key: String, _ locale: String) throws -> String {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
            return try XCTUnwrap(unit["value"] as? String)
        }

        XCTAssertEqual(try localizedValue("strength.descriptor.back", "de"), "Rücken")
        XCTAssertEqual(try localizedValue("strength.descriptor.band", "zh-Hant"), "彈力帶")
        for locale in locales {
            XCTAssertEqual(try localizedValue("strength.field.rpe", locale), "RPE")
        }
    }
}
