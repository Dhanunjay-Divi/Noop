import Foundation

/// One completed session's factual record for an exercise.
public struct StrengthExerciseHistoryPoint: Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let startedAt: Int
    public let completedSetCount: Int
    public let totalReps: Int
    public let maxReps: Int?
    public let maxLoadKg: Double?
    public let bestSetVolumeKg: Double?

    public var id: String { sessionId }
}

/// Completed manual work inside an explicit time window.
public struct StrengthWeeklyProgress: Equatable, Sendable {
    public let sessionCount: Int
    public let completedSetCount: Int
    public let totalReps: Int
    public let loadedVolumeKg: Double
}

/// Set exposure by catalog muscle. Primary muscles receive one set of credit and secondary muscles
/// receive half a set. This is a training-log distribution, not a physiological load estimate.
public struct StrengthMuscleFocus: Equatable, Sendable, Identifiable {
    public let muscle: String
    public let directSetCount: Int
    public let supportingSetCount: Int
    public let weightedSetExposure: Double

    public var id: String { muscle }
}

/// Pure progress views over the normalized strength log. The Kotlin mirror must stay value-for-value.
public enum StrengthProgressCalculator {
    public static func exerciseHistory(
        exerciseId: String,
        sessions: [StrengthSessionSnapshot]
    ) -> [StrengthExerciseHistoryPoint] {
        sessions.compactMap { snapshot in
            guard snapshot.session.endedAt != nil else { return nil }
            let sets = snapshot.sets.filter {
                $0.exerciseId == exerciseId
                    && $0.completedAt != nil
                    && $0.setType != "warmup"
            }
            guard !sets.isEmpty else { return nil }
            let loadedVolumes = sets.compactMap(\.volumeKg)
            return StrengthExerciseHistoryPoint(
                sessionId: snapshot.session.id,
                startedAt: snapshot.session.startedAt,
                completedSetCount: sets.count,
                totalReps: sets.compactMap(\.reps).reduce(0, +),
                maxReps: sets.compactMap(\.reps).max(),
                maxLoadKg: sets.compactMap(\.loadKg).max(),
                bestSetVolumeKg: loadedVolumes.max()
            )
        }
        .sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.sessionId < $1.sessionId
        }
    }

    public static func weeklyProgress(
        sessions: [StrengthSessionSnapshot],
        from: Int,
        to: Int
    ) -> StrengthWeeklyProgress {
        guard to >= from else {
            return StrengthWeeklyProgress(
                sessionCount: 0,
                completedSetCount: 0,
                totalReps: 0,
                loadedVolumeKg: 0
            )
        }
        let included = sessions.filter {
            $0.session.endedAt != nil
                && $0.session.startedAt >= from
                && $0.session.startedAt <= to
        }
        let sets = included.flatMap(\.sets).filter {
            $0.completedAt != nil && $0.setType != "warmup"
        }
        return StrengthWeeklyProgress(
            sessionCount: included.count,
            completedSetCount: sets.count,
            totalReps: sets.compactMap(\.reps).reduce(0, +),
            loadedVolumeKg: sets.compactMap(\.volumeKg).reduce(0, +)
        )
    }

    public static func muscleFocus(
        exercises: [StrengthExerciseRow],
        sessions: [StrengthSessionSnapshot],
        from: Int,
        to: Int
    ) -> [StrengthMuscleFocus] {
        guard to >= from else { return [] }
        let exerciseByID = Dictionary(
            exercises.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var direct: [String: Int] = [:]
        var supporting: [String: Int] = [:]

        for snapshot in sessions where snapshot.session.endedAt != nil
            && snapshot.session.startedAt >= from
            && snapshot.session.startedAt <= to {
            for set in snapshot.sets where set.completedAt != nil && set.setType != "warmup" {
                guard let exercise = exerciseByID[set.exerciseId] else { continue }
                direct[exercise.primaryMuscle, default: 0] += 1
                let secondary = StrengthTrainingContract.secondaryMuscles(
                    from: exercise.secondaryMusclesJSON
                ) ?? []
                for muscle in Set(secondary) where muscle != exercise.primaryMuscle {
                    supporting[muscle, default: 0] += 1
                }
            }
        }

        return Set(direct.keys).union(supporting.keys).map { muscle in
            let directSets = direct[muscle, default: 0]
            let supportingSets = supporting[muscle, default: 0]
            return StrengthMuscleFocus(
                muscle: muscle,
                directSetCount: directSets,
                supportingSetCount: supportingSets,
                weightedSetExposure: Double(directSets) + Double(supportingSets) * 0.5
            )
        }
        .sorted {
            if $0.weightedSetExposure != $1.weightedSetExposure {
                return $0.weightedSetExposure > $1.weightedSetExposure
            }
            return $0.muscle < $1.muscle
        }
    }
}
