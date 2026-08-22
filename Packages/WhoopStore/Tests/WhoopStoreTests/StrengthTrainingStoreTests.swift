import XCTest
import GRDB
@testable import WhoopStore

final class StrengthTrainingStoreTests: XCTestCase {
    private let now = 1_777_000_000

    private func session(id: String = "session-1", endedAt: Int? = nil) -> StrengthSessionRow {
        StrengthSessionRow(
            id: id,
            name: "Full body",
            startedAt: now,
            endedAt: endedAt,
            createdAt: now,
            updatedAt: endedAt ?? now
        )
    }

    private func set(
        id: String,
        sessionId: String = "session-1",
        exerciseId: String = "barbell_back_squat",
        exercisePosition: Int = 0,
        setPosition: Int = 0,
        reps: Int? = 5,
        loadKg: Double? = 100,
        durationS: Int? = nil,
        restSeconds: Int? = 120,
        completedAt: Int? = 1_777_000_100
    ) -> StrengthSetRow {
        StrengthSetRow(
            id: id,
            sessionId: sessionId,
            exerciseId: exerciseId,
            exercisePosition: exercisePosition,
            setPosition: setPosition,
            reps: reps,
            loadKg: loadKg,
            durationS: durationS,
            rpe: 8,
            restSeconds: restSeconds,
            completedAt: completedAt,
            createdAt: now,
            updatedAt: completedAt ?? now
        )
    }

    func testV40SeedsOwnedExerciseCatalogAndTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for table in [
            "strengthExercise", "strengthRoutine", "strengthRoutineExercise",
            "strengthSession", "strengthSet",
        ] {
            XCTAssertTrue(tables.contains(table), "missing \(table)")
        }
        let exercises = try await store.strengthExercises()
        XCTAssertEqual(exercises.count, StrengthTrainingContract.builtInExercises.count)
        XCTAssertEqual(exercises.first { $0.id == "barbell_back_squat" }?.primaryMuscle, "quadriceps")
        XCTAssertTrue(exercises.allSatisfy { !$0.isCustom })
    }

    func testContractRejectsCorruptCompletedSetsAndPreservesDrafts() throws {
        XCTAssertThrowsError(try StrengthTrainingContract.validated(
            set(id: "bad", reps: nil, loadKg: nil, completedAt: now)
        )) { error in
            XCTAssertEqual(error as? StrengthTrainingContract.ValidationError, .invalidSet)
        }
        XCTAssertThrowsError(try StrengthTrainingContract.validated(
            set(id: "bad-load", loadKg: -1)
        ))
        XCTAssertThrowsError(try StrengthTrainingContract.validated(
            set(id: "bad-rpe", setPosition: 1).withRPE(11)
        ))
        XCTAssertThrowsError(try StrengthTrainingContract.validated(
            set(id: "bad-rest", setPosition: 2, restSeconds: 3_601)
        ))

        let draft = try StrengthTrainingContract.validated(
            set(id: "draft", reps: nil, loadKg: nil, completedAt: nil)
        )
        XCTAssertNil(draft.completedAt)
        XCTAssertNil(draft.volumeKg)
    }

    func testRoutineSaveReplacesOrderedPrescriptionAtomically() async throws {
        let store = try await WhoopStore.inMemory()
        let routine = StrengthRoutineRow(
            id: "routine-a", name: "Day A", createdAt: now, updatedAt: now
        )
        let squat = StrengthRoutineExerciseRow(
            id: "rx-squat", routineId: routine.id, exerciseId: "barbell_back_squat",
            position: 0, targetSets: 3, targetRepsMin: 5, targetRepsMax: 5,
            targetRPE: 8, restSeconds: 180, createdAt: now, updatedAt: now
        )
        let bench = StrengthRoutineExerciseRow(
            id: "rx-bench", routineId: routine.id, exerciseId: "barbell_bench_press",
            position: 1, targetSets: 3, targetRepsMin: 6, targetRepsMax: 8,
            restSeconds: 120, createdAt: now, updatedAt: now
        )
        _ = try await store.saveStrengthRoutine(routine, exercises: [squat, bench])
        _ = try await store.saveStrengthRoutine(
            StrengthRoutineRow(
                id: routine.id, name: "Day A — revised", createdAt: now, updatedAt: now + 10
            ),
            exercises: [bench]
        )

        let routines = try await store.strengthRoutines()
        let saved = try XCTUnwrap(routines.first)
        XCTAssertEqual(saved.routine.name, "Day A — revised")
        XCTAssertEqual(saved.exercises.map(\.id), ["rx-bench"])
    }

    func testInProgressSessionSurvivesAndEditReplacesSets() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveStrengthSession(
            session(),
            sets: [
                set(id: "set-1", setPosition: 0),
                set(id: "set-2", setPosition: 1, reps: nil, loadKg: nil, completedAt: nil),
            ]
        )
        var snapshots = try await store.strengthSessions()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNil(snapshots[0].session.endedAt)
        XCTAssertEqual(snapshots[0].sets.count, 2)
        XCTAssertEqual(snapshots[0].sets.map(\.restSeconds), [120, 120])

        _ = try await store.saveStrengthSession(
            session(endedAt: now + 3_600),
            sets: [
                set(
                    id: "set-1", setPosition: 0, reps: 6, loadKg: 102.5,
                    restSeconds: 180
                ),
            ]
        )
        snapshots = try await store.strengthSessions(includeInProgress: false)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].sets.map(\.id), ["set-1"])
        XCTAssertEqual(snapshots[0].sets[0].volumeKg, 615)
        XCTAssertEqual(snapshots[0].sets[0].restSeconds, 180)
    }

    func testSummaryAndRecordsDoNotInventBodyweightVolume() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveStrengthSession(
            session(endedAt: now + 1_800),
            sets: [
                set(id: "loaded", setPosition: 0, reps: 5, loadKg: 100),
                set(
                    id: "bodyweight", exerciseId: "pull_up", exercisePosition: 1,
                    setPosition: 0, reps: 10, loadKg: nil
                ),
                set(
                    id: "timed", exerciseId: "plank", exercisePosition: 2,
                    setPosition: 0, reps: nil, loadKg: nil, durationS: 60
                ),
            ]
        )

        let summary = try await store.strengthSummary(from: now - 1, to: now + 1)
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.completedSetCount, 3)
        XCTAssertEqual(summary.totalReps, 15)
        XCTAssertEqual(summary.loadedVolumeKg, 500)
        XCTAssertEqual(summary.loadedVolumeSetCount, 1)

        let squat = try await store.strengthExerciseProgress(exerciseId: "barbell_back_squat")
        XCTAssertEqual(squat.maxLoadKg, 100)
        XCTAssertEqual(squat.maxReps, 5)
        XCTAssertEqual(squat.bestSetVolumeKg, 500)
        let pullUp = try await store.strengthExerciseProgress(exerciseId: "pull_up")
        XCTAssertNil(pullUp.maxLoadKg)
        XCTAssertEqual(pullUp.maxReps, 10)
        XCTAssertNil(pullUp.bestSetVolumeKg)
    }

    func testDeletingSessionDeletesItsSetsOnly() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.saveStrengthSession(
            session(id: "one", endedAt: now + 100),
            sets: [set(id: "one-set", sessionId: "one", setPosition: 0)]
        )
        _ = try await store.saveStrengthSession(
            session(id: "two", endedAt: now + 200),
            sets: [set(id: "two-set", sessionId: "two", setPosition: 0)]
        )
        let firstDelete = try await store.deleteStrengthSession(id: "one")
        let secondDelete = try await store.deleteStrengthSession(id: "one")
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)
        let remaining = try await store.strengthSessions()
        XCTAssertEqual(remaining.map(\.session.id), ["two"])
        XCTAssertEqual(remaining[0].sets.map(\.id), ["two-set"])
    }
}

private extension StrengthSetRow {
    func withRPE(_ value: Double?) -> StrengthSetRow {
        var copy = self
        copy.rpe = value
        return copy
    }
}
