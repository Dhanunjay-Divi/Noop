import Foundation
import WhoopStore

extension Notification.Name {
    static let strengthTrainingChanged = Notification.Name("noop.strengthTrainingChanged")
}

enum StrengthTrainingRepositoryError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return String(localized: "NOOP could not open the private strength log on this device.")
        }
    }
}

struct StrengthTrainerSnapshot: Sendable {
    let exercises: [StrengthExerciseRow]
    let routines: [StrengthRoutineSnapshot]
    let sessions: [StrengthSessionSnapshot]
    let summary: StrengthSummary

    var activeSession: StrengthSessionSnapshot? {
        sessions.first(where: { $0.session.endedAt == nil })
    }
}

@MainActor
extension Repository {
    /// One coherent local-first read for the Strength Trainer. The generic workout log remains the
    /// imported/cardio summary substrate; this snapshot owns editable exercises, routines, and sets.
    func strengthTrainerSnapshot() async throws -> StrengthTrainerSnapshot {
        guard let store = await storeHandle() else {
            throw StrengthTrainingRepositoryError.storeUnavailable
        }
        async let exercises = store.strengthExercises()
        async let routines = store.strengthRoutines()
        async let sessions = store.strengthSessions()
        async let summary = store.strengthSummary(from: 0, to: Int.max)
        return try await StrengthTrainerSnapshot(
            exercises: exercises,
            routines: routines,
            sessions: sessions,
            summary: summary
        )
    }

    @discardableResult
    func saveStrengthSession(
        _ session: StrengthSessionRow,
        sets: [StrengthSetRow]
    ) async throws -> StrengthSessionSnapshot {
        guard let store = await storeHandle() else {
            throw StrengthTrainingRepositoryError.storeUnavailable
        }
        let saved = try await store.saveStrengthSession(session, sets: sets)
        NotificationCenter.default.post(name: .strengthTrainingChanged, object: nil)
        return saved
    }

    @discardableResult
    func saveStrengthRoutine(
        _ routine: StrengthRoutineRow,
        exercises: [StrengthRoutineExerciseRow]
    ) async throws -> StrengthRoutineSnapshot {
        guard let store = await storeHandle() else {
            throw StrengthTrainingRepositoryError.storeUnavailable
        }
        let saved = try await store.saveStrengthRoutine(routine, exercises: exercises)
        NotificationCenter.default.post(name: .strengthTrainingChanged, object: nil)
        return saved
    }

    @discardableResult
    func removeStrengthSession(id: String) async throws -> Bool {
        guard let store = await storeHandle() else {
            throw StrengthTrainingRepositoryError.storeUnavailable
        }
        let removed = try await store.deleteStrengthSession(id: id)
        if removed {
            NotificationCenter.default.post(name: .strengthTrainingChanged, object: nil)
        }
        return removed
    }

    func strengthExerciseProgress(exerciseId: String) async throws -> StrengthExerciseProgress {
        guard let store = await storeHandle() else {
            throw StrengthTrainingRepositoryError.storeUnavailable
        }
        return try await store.strengthExerciseProgress(exerciseId: exerciseId)
    }

    /// Start one resumable manual session, optionally from a routine. An existing active session wins,
    /// making repeated WatchConnectivity delivery idempotent.
    @discardableResult
    func startStrengthSession(routineID: String?) async throws -> StrengthSessionSnapshot {
        guard let store = await storeHandle() else {
            throw StrengthTrainingRepositoryError.storeUnavailable
        }
        if let active = try await store.strengthSessions().first(where: {
            $0.session.endedAt == nil
        }) {
            return active
        }
        let routine = try await store.strengthRoutines().first(where: {
            $0.routine.id == routineID
        })
        if routineID != nil, routine == nil {
            throw StrengthTrainingContract.ValidationError.invalidRoutineExercise
        }

        let now = Int(Date().timeIntervalSince1970)
        let sessionID = UUID().uuidString.lowercased()
        let session = StrengthSessionRow(
            id: sessionID,
            routineId: routine?.routine.id,
            name: routine?.routine.name,
            startedAt: now,
            createdAt: now,
            updatedAt: now
        )
        let sets = routine?.exercises.flatMap { prescription in
            (0..<prescription.targetSets).map { setPosition in
                StrengthSetRow(
                    id: UUID().uuidString.lowercased(),
                    sessionId: sessionID,
                    exerciseId: prescription.exerciseId,
                    exercisePosition: prescription.position,
                    setPosition: setPosition,
                    restSeconds: prescription.restSeconds,
                    createdAt: now,
                    updatedAt: now
                )
            }
        } ?? []
        let saved = try await store.saveStrengthSession(session, sets: sets)
        NotificationCenter.default.post(name: .strengthTrainingChanged, object: nil)
        return saved
    }
}
