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

    func testGuidedPlayerAndRichTodayPlanStayMounted() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")
        let motion = try sourceText("Strand/Screens/StrengthExerciseMotionView.swift")
        let iosApp = try sourceText("StrandiOS/App/StrandiOSApp.swift")

        XCTAssertTrue(source.contains("StrengthExerciseMotionView(exercise: value.exercise)"))
        XCTAssertTrue(source.contains("@State private var currentBlockID: String?"))
        XCTAssertTrue(source.contains("finishTimedSet(id: setID, useTargetDuration: true)"))
        XCTAssertTrue(source.contains("todayExercisePlans(for: routine, data: data)"))
        XCTAssertTrue(source.contains("\"Start today’s workout\""))
        XCTAssertTrue(source.contains("StrengthAdaptivePlanner.recommendation("))
        XCTAssertTrue(source.contains("StrengthProgramBuilder("))
        XCTAssertTrue(source.contains("sourceRoutineExerciseID"))
        XCTAssertTrue(source.contains("updateRoutine: Bool"))
        XCTAssertTrue(source.contains("AVSpeechSynthesizer()"))
        XCTAssertTrue(source.contains("completePacedSet(id: setID)"))
        XCTAssertTrue(source.contains("exercisePerformanceContext(for: value)"))
        XCTAssertTrue(source.contains("@State private var exerciseGuide = Self.initialExerciseGuide"))
        XCTAssertTrue(source.contains("StrengthExerciseGuidePreview(exercise: exerciseGuide)"))
        XCTAssertTrue(source.contains("exerciseGuide = plan.exercise"))
        XCTAssertTrue(source.contains("exerciseGuide = exercise"))
        XCTAssertTrue(source.contains(".navigationDestination("))
        XCTAssertFalse(source.contains(".sheet(item: $exerciseGuide)"))
        XCTAssertTrue(motion.contains("\"strength.exerciseMediaCompact.v2\""))
        XCTAssertFalse(motion.contains("\"strength.exerciseMediaExpanded\""))
        XCTAssertTrue(motion.contains("var presentation: StrengthExerciseMediaPresentation"))
        XCTAssertTrue(motion.contains("case (.detail, _):"))
        XCTAssertTrue(motion.contains("StrengthExerciseMediaLayout(aspectRatio: stageAspectRatio)"))
        XCTAssertTrue(motion.contains("height: width / max(0.1, aspectRatio)"))
        XCTAssertTrue(motion.contains("case (.workout, false):\n            1"))
        XCTAssertFalse(motion.contains("controlRailWidth"))
        XCTAssertTrue(motion.contains("StrengthNativeExerciseMediaView("))
        XCTAssertTrue(motion.contains("StrengthLoopingVideoView("))
        XCTAssertTrue(motion.contains("AVPlayerLooper("))
        XCTAssertTrue(motion.contains("StrengthAnimatedGIFView("))
        XCTAssertTrue(
            motion.contains(
                ".padding(8)\n"
                    + "                    .frame(maxWidth: .infinity, "
                    + "maxHeight: .infinity, alignment: .topTrailing)"
            )
        )
        XCTAssertTrue(motion.contains("StrengthExerciseThumbnailView"))
        XCTAssertTrue(source.contains("StrengthExerciseThumbnailView(exercise: exercise)"))
        XCTAssertTrue(source.contains("presentation: .detail"))
        XCTAssertTrue(motion.contains("raw.githubusercontent.com/omercotkd"))
        XCTAssertTrue(motion.contains("NOOPStrengthVideoURLTemplate"))
        XCTAssertTrue(motion.contains("exercise-media"))
        XCTAssertTrue(motion.contains("exercise-guidance"))
        XCTAssertTrue(motion.contains("NSCache<NSString, UIImage>"))
        XCTAssertTrue(iosApp.contains("args.contains(\"--demo-strength-guide\")"))
        XCTAssertTrue(motion.contains("[\"StrengthMotion\", nestedSubdirectory]"))
        XCTAssertTrue(motion.contains(".joined(separator: \"/\")"))
        XCTAssertTrue(motion.contains("webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessURL)"))
        XCTAssertFalse(motion.contains("StrengthMotionWebView("))
        XCTAssertFalse(motion.contains("TimelineView("))
    }

    func testExerciseMediaManifestCoversTheCompleteCatalog() throws {
        let iosURL = repoRoot.appendingPathComponent(
            "Strand/Resources/StrengthMotion/exercise-media.json"
        )
        let androidURL = repoRoot.appendingPathComponent(
            "android/app/src/main/assets/strength-motion/exercise-media.json"
        )
        let toolURL = repoRoot.appendingPathComponent(
            "Tools/StrengthMotion/exercise-media.json"
        )
        let iosData = try Data(contentsOf: iosURL)
        XCTAssertEqual(iosData, try Data(contentsOf: androidURL))
        XCTAssertEqual(iosData, try Data(contentsOf: toolURL))

        let mapping = try JSONDecoder().decode(
            [String: StrengthExerciseMediaDescriptor].self,
            from: iosData
        )
        let catalogData = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Tools/StrengthMotion/manifest.json"
            )
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let catalogRows = try XCTUnwrap(catalog["exercises"] as? [[String: String]])
        XCTAssertEqual(Set(mapping.keys), Set(catalogRows.compactMap { $0["id"] }))
        XCTAssertEqual(mapping.count, 56)
        XCTAssertEqual(mapping.values.compactMap(\.gif).count, 51)
        XCTAssertEqual(mapping.values.compactMap(\.video).count, 19)
        XCTAssertTrue(
            mapping.values.compactMap(\.gif).allSatisfy {
                $0.range(
                    of: #"^[0-9]{4}$"#,
                    options: .regularExpression
                ) != nil
            }
        )
        XCTAssertEqual(mapping["lat_pulldown"]?.gif, "2330")
        XCTAssertEqual(mapping["parallel_bar_dip"]?.gif, "1430")
        XCTAssertEqual(mapping["back_extension"]?.gif, "0489")
        XCTAssertNil(mapping["plank"]?.gif)
        XCTAssertNil(mapping["band_pull_apart"]?.gif)
        XCTAssertNil(mapping["barbell_hip_thrust"]?.gif)
        XCTAssertEqual(mapping["barbell_hip_thrust"]?.video, "0057")
        XCTAssertEqual(mapping["treadmill_run"]?.gif, "0684")
        XCTAssertNil(mapping["rowing_ergometer"]?.gif)
        XCTAssertNil(mapping["side_plank"]?.gif)
        XCTAssertEqual(mapping["barbell_back_squat"]?.video, "0054")
        XCTAssertEqual(mapping["rowing_ergometer"]?.video, "0077")
    }

    func testExerciseMediaURLTemplatesAreExtensionAwareAndHTTPSOnly() {
        XCTAssertEqual(
            StrengthExerciseMediaPolicy.mediaURL(
                template: "https://cdn.example.com/{id}.{ext}",
                mediaID: "0054",
                fileExtension: "mp4"
            )?.absoluteString,
            "https://cdn.example.com/0054.mp4"
        )
        XCTAssertEqual(
            StrengthExerciseMediaPolicy.mediaURL(
                template: "https://cdn.example.com/media",
                mediaID: "0043",
                fileExtension: "gif"
            )?.absoluteString,
            "https://cdn.example.com/media/0043.gif"
        )
        XCTAssertNil(
            StrengthExerciseMediaPolicy.mediaURL(
                template: "http://cdn.example.com/{id}.gif",
                mediaID: "0043",
                fileExtension: "gif"
            )
        )
    }

    func testExerciseMediaPlaybackKeepsOnlyAShortEndpointHold() {
        XCTAssertEqual(
            StrengthExerciseMediaPolicy.playbackFrameDelay(1),
            0.4,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            StrengthExerciseMediaPolicy.playbackFrameDelay(0.1),
            0.125,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            StrengthExerciseMediaPolicy.playbackFrameDelay(0),
            0.05,
            accuracy: 0.000_1
        )
    }

    func testInstructorProfileAndInteractiveBodyMapStayMounted() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")
        let motion = try sourceText("Strand/Screens/StrengthExerciseMotionView.swift")
        let planner = try sourceText(
            "Packages/WhoopStore/Sources/WhoopStore/StrengthAdaptivePlanning.swift"
        )
        let progress = try sourceText(
            "Packages/WhoopStore/Sources/WhoopStore/StrengthProgress.swift"
        )

        XCTAssertTrue(source.contains("StrengthProgramRequest("))
        XCTAssertTrue(source.contains("\"strength.profile.experience\""))
        XCTAssertTrue(source.contains("\"strength.profile.style\""))
        XCTAssertTrue(source.contains("\"strength.profile.physiqueGoal\""))
        XCTAssertTrue(source.contains("\"strength.profile.sessionMinutes\""))
        XCTAssertTrue(source.contains("\"strength.profile.dayCount\""))
        XCTAssertTrue(source.contains("\"strength.profile.weekdays\""))
        XCTAssertTrue(source.contains("\"strength.profile.focusMuscles\""))
        XCTAssertTrue(source.contains("@State private var didOfferProgramBuilder"))
        XCTAssertTrue(source.contains("if exerciseGuide == nil,"))
        XCTAssertTrue(source.contains("loaded.routines.isEmpty,"))
        XCTAssertTrue(source.contains("let draft = StrengthSessionSnapshot(session: session, sets: sets)"))
        XCTAssertTrue(source.contains("muscleCoachSection(snapshot)"))
        XCTAssertTrue(source.contains("StrengthBodyMapView("))
        XCTAssertTrue(source.contains(".minimumScaleFactor(0.58)"))
        XCTAssertTrue(source.contains("startFocusSession("))
        XCTAssertTrue(source.contains("selectedFocusExerciseIDs"))
        XCTAssertTrue(source.contains("@State private var selectedFocusMuscles: [String] = []"))
        XCTAssertTrue(source.contains("toggleFocusMuscle("))
        XCTAssertTrue(source.contains("selectedMuscles: Set(selectedFocusMuscles)"))
        XCTAssertTrue(source.contains("for candidates in rankedByMuscle"))
        XCTAssertTrue(source.contains("nextSelection.formUnion(additions)"))
        XCTAssertTrue(source.contains("Picker(\"Training emphasis\""))
        XCTAssertTrue(source.contains("Text(\"Experience\")"))
        XCTAssertTrue(source.contains("Text(\"Workout style\")"))
        XCTAssertTrue(source.contains("Text(\"Training emphasis\")"))
        XCTAssertTrue(source.contains("StrengthPhysiqueGoal.lowerBodyGlutes.rawValue"))
        XCTAssertTrue(
            source.contains(
                "Workout style sets reps and rest. Emphasis changes exercise priority, not bone structure or where body fat is stored."
            )
        )
        XCTAssertTrue(source.contains("physiqueGoal: physiqueGoal"))
        XCTAssertTrue(motion.contains("enum StrengthBodyMapMode"))
        XCTAssertTrue(motion.contains("StrengthBodyMapWebView"))
        XCTAssertTrue(motion.contains("noop-body-map"))
        XCTAssertTrue(
            motion.contains("\"selected\": selectedMuscles.sorted()")
        )
        XCTAssertTrue(planner.contains("public static func focusWorkout("))
        XCTAssertTrue(progress.contains("recoveryWindowSeconds = 72 * 60 * 60"))
        XCTAssertTrue(progress.contains("$0.setType != \"warmup\""))
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

    func testCompactWorkoutCopyCanWrapWithoutBeingClipped() throws {
        let source = try sourceText("Strand/Screens/StrengthTrainerView.swift")
        let shell = try sourceText("StrandiOS/App/RootTabView.swift")
        let guideStart = try XCTUnwrap(
            source.range(of: "private func currentExerciseGuide(")?.lowerBound
        )
        let guideEnd = try XCTUnwrap(
            source.range(
                of: "@ViewBuilder\n    private func exercisePerformanceContext",
                range: guideStart..<source.endIndex
            )?.lowerBound
        )
        let guide = String(source[guideStart..<guideEnd])
        let target = try XCTUnwrap(
            guide.range(of: "Text(currentTargetLabel(next, in: value))")?.lowerBound
        )
        let media = try XCTUnwrap(
            guide.range(of: "StrengthExerciseMotionView(exercise: value.exercise)")?.lowerBound
        )

        XCTAssertLessThan(target, media)
        XCTAssertTrue(guide.contains(".font(StrandFont.title2)"))
        XCTAssertTrue(guide.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(guide.contains(".lineLimit(2)"))
        XCTAssertTrue(source.contains(".frame(height: 24)"))
        XCTAssertTrue(shell.contains(".lineLimit(3)"))
        XCTAssertTrue(shell.contains(".minimumScaleFactor(0.88)"))
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
