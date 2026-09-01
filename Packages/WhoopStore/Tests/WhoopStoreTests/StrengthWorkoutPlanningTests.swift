import XCTest
@testable import WhoopStore

final class StrengthWorkoutPlanningTests: XCTestCase {
    private let now = 1_800_000_000

    func testEveryBuiltInExerciseHasSpecificPositiveMotionGuidance() {
        XCTAssertEqual(StrengthTrainingContract.builtInExercises.count, 56)
        var variants = Set<StrengthExerciseAnimationVariant>()
        for exercise in StrengthTrainingContract.builtInExercises {
            let guide = StrengthExerciseGuidance.guide(for: exercise)
            XCTAssertTrue(guide.isExerciseSpecific, exercise.id)
            XCTAssertNotEqual(guide.profile, .generic, exercise.id)
            XCTAssertGreaterThan(guide.cycleDuration, 0, exercise.id)
            XCTAssertEqual(guide.animationVariant?.rawValue, exercise.id, exercise.id)
            if let variant = guide.animationVariant {
                variants.insert(variant)
            }
        }
        XCTAssertEqual(variants.count, StrengthTrainingContract.builtInExercises.count)
        XCTAssertEqual(variants.count, StrengthExerciseAnimationVariant.allCases.count)

        let custom = StrengthExerciseRow(
            id: "custom-squat",
            name: "Custom squat",
            primaryMuscle: "quadriceps",
            equipment: "other",
            movementPattern: "squat",
            isCustom: true,
            createdAt: now,
            updatedAt: now
        )
        let fallback = StrengthExerciseGuidance.guide(for: custom)
        XCTAssertEqual(fallback.profile, .squat)
        XCTAssertNil(fallback.animationVariant)
        XCTAssertFalse(fallback.isExerciseSpecific)
    }

    func testAdaptiveProgramsCoverTwoThroughSixGymDaysWithKnownExercises() {
        let known = Set(StrengthTrainingContract.builtInExercises.map(\.id))
        for count in 2...6 {
            let weekdays = StrengthAdaptivePlanner.suggestedWeekdays(for: count)
            let program = StrengthAdaptivePlanner.program(for: weekdays)
            XCTAssertEqual(weekdays.count, count)
            XCTAssertEqual(program.count, count)
            XCTAssertEqual(program.map(\.isoWeekday), weekdays)
            XCTAssertTrue(program.allSatisfy { !$0.exercises.isEmpty })
            XCTAssertTrue(
                program.flatMap(\.exercises).allSatisfy {
                    known.contains($0.exerciseId)
                        && $0.targetSets > 0
                        && $0.restSeconds > 0
                }
            )
        }
        XCTAssertTrue(StrengthAdaptivePlanner.program(for: [1]).isEmpty)
        XCTAssertTrue(StrengthAdaptivePlanner.program(for: [1, 1]).isEmpty)
    }

    func testProfileDrivenProgramScalesSessionWithoutInventingProgress() throws {
        let beginner = StrengthAdaptivePlanner.program(
            for: StrengthProgramRequest(
                weekdays: [1, 3, 5],
                experience: .beginner,
                style: .balanced,
                sessionMinutes: 30,
                focusMuscles: ["chest"]
            )
        )
        XCTAssertEqual(beginner.count, 3)
        XCTAssertTrue(beginner.allSatisfy { $0.exercises.count == 3 })
        XCTAssertTrue(beginner.flatMap(\.exercises).allSatisfy {
            $0.targetSets <= 2 && $0.targetRPE == 6.5
        })
        XCTAssertTrue(beginner.allSatisfy { routine in
            routine.exercises.contains { item in
                StrengthTrainingContract.builtInExercises.first {
                    $0.id == item.exerciseId
                }?.primaryMuscle == "chest"
            }
        })

        let experienced = StrengthAdaptivePlanner.program(
            for: StrengthProgramRequest(
                weekdays: [1, 4],
                experience: .experienced,
                style: .strength,
                sessionMinutes: 75
            )
        )
        XCTAssertTrue(experienced.flatMap(\.exercises).prefix(2).allSatisfy {
            $0.targetRepsMin == 4
                && $0.targetRepsMax == 6
                && $0.restSeconds >= 180
                && $0.targetRPE == 7.5
        })

        let custom = StrengthExerciseRow(
            id: "custom-row",
            name: "Custom row",
            primaryMuscle: "back",
            equipment: "band",
            movementPattern: "horizontal_pull",
            isCustom: true,
            createdAt: now,
            updatedAt: now
        )
        let focus = StrengthAdaptivePlanner.focusWorkout(
            exercises: [custom],
            experience: .beginner,
            style: .muscle,
            sessionMinutes: 30
        )
        XCTAssertEqual(focus.map(\.exerciseId), [custom.id])
        XCTAssertEqual(focus.first?.targetSets, 2)
        XCTAssertEqual(focus.first?.targetRepsMin, 8)
        XCTAssertEqual(focus.first?.targetRepsMax, 12)
    }

    func testMuscleStatusUsesCompletedSetExposureAndFadesOverSeventyTwoHours() throws {
        let bench = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first {
                $0.id == "barbell_bench_press"
            }
        )
        let session = StrengthSessionSnapshot(
            session: StrengthSessionRow(
                id: "body-map",
                startedAt: now - 3_600,
                endedAt: now - 1_800,
                createdAt: now - 3_600,
                updatedAt: now - 1_800
            ),
            sets: [
                StrengthSetRow(
                    id: "working",
                    sessionId: "body-map",
                    exerciseId: bench.id,
                    exercisePosition: 0,
                    setPosition: 0,
                    reps: 8,
                    completedAt: now - 3_600,
                    createdAt: now - 3_600,
                    updatedAt: now - 3_600
                ),
                StrengthSetRow(
                    id: "warmup",
                    sessionId: "body-map",
                    exerciseId: bench.id,
                    exercisePosition: 0,
                    setPosition: 1,
                    setType: "warmup",
                    reps: 5,
                    completedAt: now - 3_600,
                    createdAt: now - 3_600,
                    updatedAt: now - 3_600
                ),
            ]
        )

        let current = StrengthProgressCalculator.muscleStatus(
            exercises: [bench],
            sessions: [session],
            now: now
        )
        XCTAssertEqual(current.first { $0.muscle == "chest" }?.sevenDayExposure, 1)
        XCTAssertEqual(current.first { $0.muscle == "triceps" }?.sevenDayExposure, 0.5)
        XCTAssertLessThan(current.first { $0.muscle == "chest" }?.recoveryScore ?? 1, 1)

        let recovered = StrengthProgressCalculator.muscleStatus(
            exercises: [bench],
            sessions: [session],
            now: now + StrengthProgressCalculator.recoveryWindowSeconds + 1
        )
        XCTAssertEqual(recovered.first { $0.muscle == "chest" }?.recoveryScore, 1)
        XCTAssertGreaterThan(
            recovered.first { $0.muscle == "chest" }?.loadScore ?? 0,
            0
        )
    }

    func testAdaptiveScheduleUsesRestDayForRecentMissedRoutineWithoutStacking() {
        let push = scheduledRoutine(id: "push", weekday: 1, createdAt: 10)
        let pull = scheduledRoutine(id: "pull", weekday: 3, createdAt: 20)
        let routines = [pull, push]
        let monday = StrengthScheduleDay(dateKey: "2026-08-31", isoWeekday: 1)
        let tuesday = StrengthScheduleDay(dateKey: "2026-09-01", isoWeekday: 2)
        let wednesday = StrengthScheduleDay(dateKey: "2026-09-02", isoWeekday: 3)

        XCTAssertEqual(
            StrengthAdaptivePlanner.recommendation(
                today: tuesday,
                previousDaysNearestFirst: [monday],
                routines: routines,
                completions: []
            ),
            StrengthDayRecommendation(
                routineId: "push",
                reason: .makeUp,
                originallyScheduledDateKey: monday.dateKey
            )
        )

        XCTAssertEqual(
            StrengthAdaptivePlanner.recommendation(
                today: wednesday,
                previousDaysNearestFirst: [tuesday, monday],
                routines: routines,
                completions: []
            ).routineId,
            "pull",
            "A scheduled day must not stack or get replaced by missed work."
        )

        XCTAssertEqual(
            StrengthAdaptivePlanner.recommendation(
                today: tuesday,
                previousDaysNearestFirst: [monday],
                routines: routines,
                completions: [
                    StrengthRoutineCompletion(dateKey: tuesday.dateKey, routineId: "push"),
                ]
            ).reason,
            .completed
        )
    }

    func testAdaptiveScheduleDoesNotCarryStaleOrSupersededWork() {
        let push = scheduledRoutine(id: "push", weekday: 1, createdAt: 10)
        let friday = StrengthScheduleDay(dateKey: "2026-09-04", isoWeekday: 5)
        let previous = [
            StrengthScheduleDay(dateKey: "2026-09-03", isoWeekday: 4),
            StrengthScheduleDay(dateKey: "2026-09-02", isoWeekday: 3),
            StrengthScheduleDay(dateKey: "2026-09-01", isoWeekday: 2),
            StrengthScheduleDay(dateKey: "2026-08-31", isoWeekday: 1),
        ]
        let result = StrengthAdaptivePlanner.recommendation(
            today: friday,
            previousDaysNearestFirst: previous,
            routines: [push],
            completions: []
        )
        XCTAssertEqual(result.reason, .rest)
        XCTAssertNil(result.routineId)
    }

    private func scheduledRoutine(
        id: String,
        weekday: Int,
        createdAt: Int
    ) -> StrengthRoutineSnapshot {
        StrengthRoutineSnapshot(
            routine: StrengthRoutineRow(
                id: id,
                name: id,
                scheduledWeekdaysJSON: StrengthTrainingContract.encodeScheduledWeekdays([weekday]),
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            exercises: []
        )
    }

    private func routine(
        exerciseId: String,
        sets: Int = 3,
        minimum: Int = 6,
        maximum: Int = 8,
        plan: StrengthExercisePlan
    ) -> StrengthRoutineExerciseRow {
        StrengthRoutineExerciseRow(
            id: "rx-\(exerciseId)",
            routineId: "routine",
            exerciseId: exerciseId,
            position: 0,
            targetSets: sets,
            targetRepsMin: minimum,
            targetRepsMax: maximum,
            planJSON: StrengthTrainingContract.encodeExercisePlan(plan),
            createdAt: now - 10_000,
            updatedAt: now - 10_000
        )
    }

    private func history(
        exerciseId: String,
        reps: [Int?],
        load: Double?,
        durations: [Int?] = [],
        setTypes: [String] = []
    ) -> [StrengthSessionSnapshot] {
        let sessionID = "previous"
        return [
            StrengthSessionSnapshot(
                session: StrengthSessionRow(
                    id: sessionID,
                    startedAt: now - 86_400,
                    endedAt: now - 82_800,
                    createdAt: now - 86_400,
                    updatedAt: now - 82_800
                ),
                sets: reps.indices.map { index in
                    StrengthSetRow(
                        id: "set-\(index)",
                        sessionId: sessionID,
                        exerciseId: exerciseId,
                        exercisePosition: 0,
                        setPosition: index,
                        setType: setTypes.indices.contains(index) ? setTypes[index] : "working",
                        reps: reps[index],
                        loadKg: load,
                        durationS: durations.indices.contains(index) ? durations[index] : nil,
                        rpe: 8,
                        completedAt: now - 82_900 + index,
                        createdAt: now - 86_400,
                        updatedAt: now - 82_900 + index
                    )
                }
            ),
        ]
    }

    func testDoubleProgressionAddsLoadAndSeedsWarmupsAfterAllTargetsAreMet() throws {
        let exercise = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "barbell_bench_press" }
        )
        let result = StrengthWorkoutPlanner.prescription(
            exercise: exercise,
            prescription: routine(
                exerciseId: exercise.id,
                plan: StrengthExercisePlan(warmupSets: 2)
            ),
            history: history(exerciseId: exercise.id, reps: [8, 8, 8], load: 80)
        )
        XCTAssertEqual(result.reason, .repRangeAdvanced)
        XCTAssertEqual(result.sets.map(\.setType), ["warmup", "warmup", "working", "working", "working"])
        XCTAssertEqual(result.sets.map(\.loadKg), [41.5, 62, 82.5, 82.5, 82.5])
        XCTAssertEqual(result.sets.prefix(2).map(\.reps), [5, 3])
        XCTAssertEqual(result.sets.suffix(3).map(\.reps), [6, 6, 6])
    }

    func testMissedTargetHoldsLoadAndBodyweightProgressesByReps() throws {
        let bench = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "barbell_bench_press" }
        )
        let held = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(exerciseId: bench.id, plan: StrengthExercisePlan()),
            history: history(exerciseId: bench.id, reps: [8, 8, 7], load: 80)
        )
        XCTAssertEqual(held.reason, .repeatLoad)
        XCTAssertEqual(held.sets.map(\.loadKg), [80, 80, 80])

        let pullUp = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "pull_up" }
        )
        let progressed = StrengthWorkoutPlanner.prescription(
            exercise: pullUp,
            prescription: routine(exerciseId: pullUp.id, plan: StrengthExercisePlan()),
            history: history(exerciseId: pullUp.id, reps: [8, 8, 8], load: nil)
        )
        XCTAssertEqual(progressed.reason, .bodyweightRepProgress)
        XCTAssertEqual(progressed.sets.map(\.reps), [9, 9, 9])
        XCTAssertTrue(progressed.sets.allSatisfy { $0.setType == "bodyweight" })

        let progressedAgain = StrengthWorkoutPlanner.prescription(
            exercise: pullUp,
            prescription: routine(exerciseId: pullUp.id, plan: StrengthExercisePlan()),
            history: history(exerciseId: pullUp.id, reps: [9, 9, 9], load: nil)
        )
        XCTAssertEqual(progressedAgain.reason, .bodyweightRepProgress)
        XCTAssertEqual(progressedAgain.sets.map(\.reps), [10, 10, 10])
    }

    func testDoubleProgressionAdvancesUnevenSetsIndependently() throws {
        let bench = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "barbell_bench_press" }
        )
        let result = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(exerciseId: bench.id, plan: StrengthExercisePlan()),
            history: history(exerciseId: bench.id, reps: [8, 7, 6], load: 80)
        )

        XCTAssertEqual(result.reason, .repeatLoad)
        XCTAssertEqual(result.sets.map(\.loadKg), [80, 80, 80])
        XCTAssertEqual(result.sets.map(\.reps), [8, 8, 7])
    }

    func testConfiguredLoadStepIsCappedAtTenPercent() throws {
        let bench = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "barbell_bench_press" }
        )
        let capped = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(
                exerciseId: bench.id,
                plan: StrengthExercisePlan(loadStepKg: 100)
            ),
            history: history(exerciseId: bench.id, reps: [8, 8, 8], load: 10)
        )
        XCTAssertEqual(capped.reason, .repRangeAdvanced)
        XCTAssertEqual(capped.sets.map(\.loadKg), [11, 11, 11])

        let held = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(
                exerciseId: bench.id,
                plan: StrengthExercisePlan(loadStepKg: 100)
            ),
            history: history(exerciseId: bench.id, reps: [8, 8, 8], load: 2.5)
        )
        XCTAssertEqual(held.reason, .repeatLoad)
        XCTAssertEqual(held.sets.map(\.loadKg), [2.5, 2.5, 2.5])
    }

    func testTinyLoadsDoNotCreateZeroOrNonDroppingAccessorySets() throws {
        let bench = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "barbell_bench_press" }
        )
        let result = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(
                exerciseId: bench.id,
                plan: StrengthExercisePlan(
                    targetLoadKg: 0.25,
                    progression: "none",
                    warmupSets: 2,
                    setStyle: "drop"
                )
            ),
            history: []
        )

        XCTAssertEqual(result.sets.map(\.setType), ["working", "working", "working"])
        XCTAssertEqual(result.sets.map(\.loadKg), [0.25, 0.25, 0.25])
        XCTAssertTrue(result.sets.compactMap(\.loadKg).allSatisfy { $0 > 0 })
    }

    func testIntensityStylesAppendExplicitClusters() throws {
        let bench = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "barbell_bench_press" }
        )
        let drop = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(
                exerciseId: bench.id,
                plan: StrengthExercisePlan(
                    targetLoadKg: 100,
                    progression: "none",
                    setStyle: "drop",
                    dropPercent: 20
                )
            ),
            history: []
        )
        XCTAssertEqual(drop.sets.map(\.setType), ["working", "working", "working", "drop"])
        XCTAssertEqual(drop.sets.map(\.loadKg), [100, 100, 100, 80])
        XCTAssertEqual(drop.sets[2].restSecondsAfter, 0)

        let restPause = StrengthWorkoutPlanner.prescription(
            exercise: bench,
            prescription: routine(
                exerciseId: bench.id,
                plan: StrengthExercisePlan(
                    targetLoadKg: 100,
                    progression: "none",
                    setStyle: "rest_pause",
                    restPauseSeconds: 20
                )
            ),
            history: []
        )
        XCTAssertEqual(
            restPause.sets.map(\.setType),
            ["working", "working", "working", "rest_pause"]
        )
        XCTAssertEqual(restPause.sets[2].restSecondsAfter, 20)
        XCTAssertNil(restPause.sets[3].reps)
    }

    func testMalformedOrIncompleteExercisePlanIsRejected() {
        func row(_ planJSON: String) -> StrengthRoutineExerciseRow {
            StrengthRoutineExerciseRow(
                id: "rx",
                routineId: "routine",
                exerciseId: "barbell_bench_press",
                position: 0,
                planJSON: planJSON,
                createdAt: now,
                updatedAt: now
            )
        }

        XCTAssertThrowsError(try StrengthTrainingContract.validated(row("not-json")))
        XCTAssertThrowsError(try StrengthTrainingContract.validated(row("{}")))
        XCTAssertThrowsError(
            try StrengthTrainingContract.validated(
                row("""
                    {"dropPercent":20,"loadStepKg":2.5,"mode":"reps",\
                    "progression":"double_progression","repsPerSide":false,\
                    "restPauseSeconds":15,"setStyle":"straight","supersetGroup":null,\
                    "targetDurationS":null,"targetLoadKg":null,"warmupSets":"2"}
                    """)
            )
        )

        let plan = StrengthExercisePlan(warmupSets: 2, setStyle: "rest_pause")
        let encoded = StrengthTrainingContract.encodeExercisePlan(plan)
        XCTAssertNoThrow(try StrengthTrainingContract.validated(row(encoded ?? "")))
    }

    func testTimedProgressionAndEstimatedMaximumStayBounded() throws {
        let plank = try XCTUnwrap(
            StrengthTrainingContract.builtInExercises.first { $0.id == "plank" }
        )
        let timed = StrengthWorkoutPlanner.prescription(
            exercise: plank,
            prescription: routine(
                exerciseId: plank.id,
                sets: 2,
                plan: StrengthExercisePlan(
                    mode: "timed",
                    targetDurationS: 30,
                    progression: "time"
                )
            ),
            history: history(
                exerciseId: plank.id,
                reps: [nil, nil],
                load: nil,
                durations: [30, 30]
            )
        )
        XCTAssertEqual(timed.reason, .timeAdvanced)
        XCTAssertEqual(timed.sets.map(\.durationS), [35, 35])

        let repeated = StrengthWorkoutPlanner.prescription(
            exercise: plank,
            prescription: routine(
                exerciseId: plank.id,
                sets: 2,
                plan: StrengthExercisePlan(
                    mode: "timed",
                    targetDurationS: 30,
                    progression: "time"
                )
            ),
            history: history(
                exerciseId: plank.id,
                reps: [nil, nil],
                load: nil,
                durations: [35, 35]
            )
        )
        XCTAssertEqual(repeated.reason, .timeAdvanced)
        XCTAssertEqual(repeated.sets.map(\.durationS), [40, 40])

        XCTAssertEqual(
            try XCTUnwrap(StrengthWorkoutPlanner.estimatedOneRepMaximum(loadKg: 100, reps: 5)),
            116.666_666_666_7,
            accuracy: 0.000_001
        )
        XCTAssertNil(StrengthWorkoutPlanner.estimatedOneRepMaximum(loadKg: 100, reps: 11))

        let mixed = history(
            exerciseId: plank.id,
            reps: [5, 4, 3],
            load: 100,
            setTypes: ["drop", "rest_pause", "working"]
        )
        let best = try XCTUnwrap(
            StrengthWorkoutPlanner.bestEstimatedMaximum(exerciseId: plank.id, sessions: mixed)
        )
        XCTAssertEqual(best.sourceReps, 3)
        XCTAssertEqual(best.kilograms, 110, accuracy: 0.000_001)
    }

    func testPlanModeRejectsMismatchedProgression() {
        XCTAssertNil(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(mode: "timed", targetDurationS: 30)
            )
        )
        XCTAssertNil(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(mode: "reps", progression: "time")
            )
        )
        XCTAssertNotNil(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(
                    mode: "timed",
                    targetDurationS: 30,
                    progression: "time"
                )
            )
        )
        XCTAssertNil(
            StrengthTrainingContract.encodeExercisePlan(
                StrengthExercisePlan(supersetGroup: 0)
            )
        )
    }

    func testSupersetRestKeepsWarmupsAndExplicitClusterPauses() {
        let warmup = StrengthPlannedSet(
            setType: "warmup", reps: 5, loadKg: 40, durationS: nil,
            restSecondsAfter: nil
        )
        let working = StrengthPlannedSet(
            setType: "working", reps: 8, loadKg: 80, durationS: nil,
            restSecondsAfter: nil
        )
        let cluster = StrengthPlannedSet(
            setType: "working", reps: 8, loadKg: 80, durationS: nil,
            restSecondsAfter: 20
        )

        XCTAssertEqual(
            StrengthWorkoutPlanner.resolvedRestSeconds(
                for: warmup, prescriptionRestSeconds: 120, continuesSuperset: true
            ),
            120
        )
        XCTAssertEqual(
            StrengthWorkoutPlanner.resolvedRestSeconds(
                for: working, prescriptionRestSeconds: 120, continuesSuperset: true
            ),
            0
        )
        XCTAssertEqual(
            StrengthWorkoutPlanner.resolvedRestSeconds(
                for: working, prescriptionRestSeconds: 120, continuesSuperset: false
            ),
            120
        )
        XCTAssertEqual(
            StrengthWorkoutPlanner.resolvedRestSeconds(
                for: cluster, prescriptionRestSeconds: 120, continuesSuperset: true
            ),
            20
        )
    }

}
