import XCTest
@testable import WhoopStore

final class StrengthProgressTests: XCTestCase {
    private func session(
        id: String,
        startedAt: Int,
        ended: Bool = true,
        sets: [StrengthSetRow]
    ) -> StrengthSessionSnapshot {
        StrengthSessionSnapshot(
            session: StrengthSessionRow(
                id: id,
                startedAt: startedAt,
                endedAt: ended ? startedAt + 3_600 : nil,
                createdAt: startedAt,
                updatedAt: startedAt + 3_600
            ),
            sets: sets
        )
    }

    private func set(
        id: String,
        sessionId: String,
        exerciseId: String,
        position: Int,
        reps: Int?,
        load: Double?,
        setType: String = "working",
        completed: Bool = true
    ) -> StrengthSetRow {
        StrengthSetRow(
            id: id,
            sessionId: sessionId,
            exerciseId: exerciseId,
            exercisePosition: 0,
            setPosition: position,
            setType: setType,
            reps: reps,
            loadKg: load,
            completedAt: completed ? 2_000 : nil,
            createdAt: 1_000,
            updatedAt: 2_000
        )
    }

    func testHistoryUsesCompletedFinishedWorkOnly() {
        let old = session(
            id: "old",
            startedAt: 100,
            sets: [
                set(id: "a", sessionId: "old", exerciseId: "barbell_back_squat",
                    position: 0, reps: 5, load: 100),
                set(id: "warm", sessionId: "old", exerciseId: "barbell_back_squat",
                    position: 1, reps: 20, load: 150, setType: "warmup"),
                set(id: "draft", sessionId: "old", exerciseId: "barbell_back_squat",
                    position: 2, reps: 8, load: 120, completed: false),
            ]
        )
        let recent = session(
            id: "recent",
            startedAt: 200,
            sets: [
                set(id: "b", sessionId: "recent", exerciseId: "barbell_back_squat",
                    position: 0, reps: 6, load: 105),
            ]
        )
        let active = session(
            id: "active",
            startedAt: 300,
            ended: false,
            sets: [
                set(id: "c", sessionId: "active", exerciseId: "barbell_back_squat",
                    position: 0, reps: 10, load: 200),
            ]
        )

        let points = StrengthProgressCalculator.exerciseHistory(
            exerciseId: "barbell_back_squat",
            sessions: [old, recent, active]
        )
        XCTAssertEqual(points.map(\.sessionId), ["recent", "old"])
        XCTAssertEqual(points[0].maxLoadKg, 105)
        XCTAssertEqual(points[0].bestSetVolumeKg, 630)
        XCTAssertEqual(points[1].completedSetCount, 1)
    }

    func testWeeklyProgressAndMuscleExposureStayFactual() {
        let completed = session(
            id: "week",
            startedAt: 150,
            sets: [
                set(id: "squat", sessionId: "week", exerciseId: "barbell_back_squat",
                    position: 0, reps: 5, load: 100),
                set(id: "pull", sessionId: "week", exerciseId: "pull_up",
                    position: 1, reps: 8, load: nil),
                set(id: "warmup", sessionId: "week", exerciseId: "barbell_back_squat",
                    position: 2, reps: 10, load: 20, setType: "warmup"),
            ]
        )
        let progress = StrengthProgressCalculator.weeklyProgress(
            sessions: [completed],
            from: 100,
            to: 200
        )
        XCTAssertEqual(progress.sessionCount, 1)
        XCTAssertEqual(progress.completedSetCount, 2)
        XCTAssertEqual(progress.totalReps, 13)
        XCTAssertEqual(progress.loadedVolumeKg, 500)

        let focus = StrengthProgressCalculator.muscleFocus(
            exercises: StrengthTrainingContract.builtInExercises,
            sessions: [completed],
            from: 100,
            to: 200
        )
        XCTAssertEqual(focus.first { $0.muscle == "back" }?.directSetCount, 1)
        XCTAssertEqual(focus.first { $0.muscle == "quadriceps" }?.weightedSetExposure, 1)
        XCTAssertEqual(focus.first { $0.muscle == "glutes" }?.weightedSetExposure, 0.5)
        XCTAssertEqual(focus.first { $0.muscle == "biceps" }?.supportingSetCount, 1)
        XCTAssertEqual(focus.first { $0.muscle == "quadriceps" }?.directSetCount, 1)
    }
}
