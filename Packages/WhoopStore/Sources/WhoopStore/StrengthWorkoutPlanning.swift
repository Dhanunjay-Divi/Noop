import Foundation

public enum StrengthProgressionReason: String, Codable, Sendable {
    case firstSession
    case repeatLoad
    case repRangeAdvanced
    case linearAdvanced
    case timeAdvanced
    case bodyweightRepProgress
}

public struct StrengthPlannedSet: Equatable, Sendable {
    public let setType: String
    public let reps: Int?
    public let loadKg: Double?
    public let durationS: Int?
    public let restSecondsAfter: Int?
}

public struct StrengthWorkoutPrescription: Equatable, Sendable {
    public let sets: [StrengthPlannedSet]
    public let reason: StrengthProgressionReason
    public let previousSessionAt: Int?
}

public struct StrengthEstimatedMaximum: Equatable, Sendable {
    public let exerciseId: String
    public let kilograms: Double
    public let sourceLoadKg: Double
    public let sourceReps: Int
    public let sessionId: String
    public let recordedAt: Int
}

public enum StrengthWorkoutPlanner {
    public static func prescription(
        exercise: StrengthExerciseRow,
        prescription: StrengthRoutineExerciseRow,
        history: [StrengthSessionSnapshot]
    ) -> StrengthWorkoutPrescription {
        let plan = StrengthTrainingContract.exercisePlan(from: prescription.planJSON)
        let previous = history
            .filter { $0.session.endedAt != nil }
            .sorted {
                if $0.session.startedAt != $1.session.startedAt {
                    return $0.session.startedAt > $1.session.startedAt
                }
                return $0.session.id < $1.session.id
            }
            .first { snapshot in
                snapshot.sets.contains {
                    $0.exerciseId == exercise.id
                        && $0.completedAt != nil
                        && progressionSetTypes.contains($0.setType)
                }
            }
        let previousSets = previous?.sets
            .filter {
                $0.exerciseId == exercise.id
                    && $0.completedAt != nil
                    && progressionSetTypes.contains($0.setType)
            }
            .sorted { $0.setPosition < $1.setPosition } ?? []

        let lower = max(1, prescription.targetRepsMin ?? 8)
        let upper = max(lower, prescription.targetRepsMax ?? lower)
        let priorLoad = previousSets.compactMap(\.loadKg).max()
        var workLoad = priorLoad ?? plan.targetLoadKg
        let compared = Array(previousSets.prefix(prescription.targetSets))
        var workRepTargets = (0..<prescription.targetSets).map { index in
            guard compared.indices.contains(index), let reps = compared[index].reps else {
                return lower
            }
            return min(max(reps, lower), upper)
        }
        var duration = compared.compactMap(\.durationS).max() ?? plan.targetDurationS
        var reason: StrengthProgressionReason = previous == nil ? .firstSession : .repeatLoad

        switch plan.progression {
        case "double_progression":
            if !compared.isEmpty,
                compared.count >= prescription.targetSets,
               compared.allSatisfy({ ($0.reps ?? 0) >= upper }) {
                if let current = workLoad {
                    if let advanced = progressedLoad(
                        current: current,
                        configuredStep: plan.loadStepKg
                    ) {
                        workLoad = advanced
                        workRepTargets = Array(repeating: lower, count: prescription.targetSets)
                        reason = .repRangeAdvanced
                    }
                } else {
                    let step = plan.repsPerSide ? 2 : 1
                    let completedFloor = compared.compactMap(\.reps).min() ?? upper
                    let advanced = min(
                        StrengthTrainingContract.maxReps,
                        max(upper, completedFloor) + step
                    )
                    workRepTargets = Array(
                        repeating: advanced,
                        count: prescription.targetSets
                    )
                    if advanced > completedFloor { reason = .bodyweightRepProgress }
                }
            } else if !compared.isEmpty {
                let step = plan.repsPerSide ? 2 : 1
                workRepTargets = (0..<prescription.targetSets).map { index in
                    guard compared.indices.contains(index), let reps = compared[index].reps else {
                        return lower
                    }
                    return min(upper, max(lower, reps) + step)
                }
            }
        case "linear":
            if !compared.isEmpty,
               compared.count >= prescription.targetSets,
               compared.allSatisfy({ ($0.reps ?? 0) >= lower }),
               let current = workLoad {
                if let advanced = progressedLoad(
                    current: current,
                    configuredStep: plan.loadStepKg
                ) {
                    workLoad = advanced
                    reason = .linearAdvanced
                }
            }
        case "time":
            let target = max(
                plan.targetDurationS ?? 30,
                compared.compactMap(\.durationS).max() ?? 0
            )
            if !compared.isEmpty,
               compared.count >= prescription.targetSets,
               compared.allSatisfy({ ($0.durationS ?? 0) >= target }) {
                let advanced = min(StrengthTrainingContract.maxDurationSeconds, target + 5)
                duration = advanced
                if advanced > target { reason = .timeAdvanced }
            } else {
                duration = target
            }
        default:
            break
        }

        if exercise.equipment == "bodyweight", plan.targetLoadKg == nil, priorLoad == nil {
            workLoad = nil
        }
        let isTimed = plan.mode == "timed" || exercise.movementPattern == "cardio"
        let warmups = warmupRows(
            count: isTimed ? 0 : plan.warmupSets,
            workLoad: workLoad,
            workReps: workRepTargets.first ?? lower
        )
        var work = (0..<prescription.targetSets).map { index in
            return StrengthPlannedSet(
                setType: exercise.equipment == "bodyweight" && workLoad == nil
                    ? "bodyweight"
                    : "working",
                reps: isTimed ? nil : workRepTargets[index],
                loadKg: workLoad,
                durationS: isTimed ? (duration ?? 30) : nil,
                restSecondsAfter: nil
            )
        }
        if !isTimed, plan.setStyle == "drop", let workLoad {
            let dropLoad = roundedLoad(workLoad * (1 - Double(plan.dropPercent) / 100))
            if !work.isEmpty, dropLoad > 0, dropLoad < workLoad {
                work[work.count - 1] = StrengthPlannedSet(
                    setType: work[work.count - 1].setType,
                    reps: work[work.count - 1].reps,
                    loadKg: work[work.count - 1].loadKg,
                    durationS: nil,
                    restSecondsAfter: 0
                )
                work.append(StrengthPlannedSet(
                    setType: "drop",
                    reps: workRepTargets.last ?? lower,
                    loadKg: dropLoad,
                    durationS: nil,
                    restSecondsAfter: nil
                ))
            }
        } else if !isTimed, plan.setStyle == "rest_pause", !work.isEmpty {
            work[work.count - 1] = StrengthPlannedSet(
                setType: work[work.count - 1].setType,
                reps: work[work.count - 1].reps,
                loadKg: work[work.count - 1].loadKg,
                durationS: nil,
                restSecondsAfter: plan.restPauseSeconds
            )
            work.append(StrengthPlannedSet(
                setType: "rest_pause",
                reps: nil,
                loadKg: workLoad,
                durationS: nil,
                restSecondsAfter: nil
            ))
        }
        return StrengthWorkoutPrescription(
            sets: warmups + work,
            reason: reason,
            previousSessionAt: previous?.session.startedAt
        )
    }

    /// Resolve the timer after a planned set. Warm-ups keep their own prescription rest, while
    /// working sets inside a superset wait only after the last movement in the round.
    public static func resolvedRestSeconds(
        for target: StrengthPlannedSet,
        prescriptionRestSeconds: Int,
        continuesSuperset: Bool
    ) -> Int {
        if target.setType == "warmup" { return prescriptionRestSeconds }
        return target.restSecondsAfter ?? (continuesSuperset ? 0 : prescriptionRestSeconds)
    }

    /// Epley estimate, bounded to low-repetition completed work where the estimate remains useful.
    public static func estimatedOneRepMaximum(loadKg: Double, reps: Int) -> Double? {
        guard loadKg.isFinite, loadKg > 0, reps >= 1, reps <= 10 else { return nil }
        if reps == 1 { return loadKg }
        return loadKg * (1 + Double(reps) / 30)
    }

    public static func bestEstimatedMaximum(
        exerciseId: String,
        sessions: [StrengthSessionSnapshot]
    ) -> StrengthEstimatedMaximum? {
        sessions
            .filter { $0.session.endedAt != nil }
            .flatMap { snapshot in
                snapshot.sets.compactMap { set -> StrengthEstimatedMaximum? in
                    guard set.exerciseId == exerciseId, set.completedAt != nil,
                          ["working", "failure"].contains(set.setType),
                          let load = set.loadKg, let reps = set.reps,
                          let estimate = estimatedOneRepMaximum(loadKg: load, reps: reps)
                    else { return nil }
                    return StrengthEstimatedMaximum(
                        exerciseId: exerciseId,
                        kilograms: estimate,
                        sourceLoadKg: load,
                        sourceReps: reps,
                        sessionId: snapshot.session.id,
                        recordedAt: snapshot.session.startedAt
                    )
                }
            }
            .max {
                if $0.kilograms != $1.kilograms { return $0.kilograms < $1.kilograms }
                return $0.recordedAt < $1.recordedAt
            }
    }

    private static func warmupRows(
        count: Int,
        workLoad: Double?,
        workReps: Int
    ) -> [StrengthPlannedSet] {
        guard count > 0, let workLoad else { return [] }
        let ladders: [Int: [(loadFraction: Double, reps: Int)]] = [
            1: [(0.6, 5)],
            2: [(0.5, 5), (0.75, 3)],
            3: [(0.4, 5), (0.6, 3), (0.8, 2)],
            4: [(0.35, 5), (0.5, 4), (0.65, 3), (0.8, 2)],
            5: [(0.3, 5), (0.45, 4), (0.6, 3), (0.72, 2), (0.84, 1)],
        ]
        return (ladders[min(5, count)] ?? []).compactMap { step in
            let load = roundedLoad(workLoad * step.loadFraction)
            guard load > 0, load < workLoad else { return nil }
            return StrengthPlannedSet(
                setType: "warmup",
                reps: max(1, min(workReps, step.reps)),
                loadKg: load,
                durationS: nil,
                restSecondsAfter: nil
            )
        }
    }

    private static func roundedLoad(_ kilograms: Double) -> Double {
        (kilograms * 2).rounded() / 2
    }

    private static let progressionSetTypes: Set<String> = ["working", "failure", "bodyweight"]

    /// ACSM recommends a 2–10% load increase after the target is exceeded. Respect the configured
    /// increment while capping it at 10%; if the available 0.5 kg resolution would exceed that cap,
    /// hold the current load instead of inventing a larger jump.
    private static func progressedLoad(current: Double, configuredStep: Double) -> Double? {
        guard current.isFinite, current > 0, configuredStep.isFinite, configuredStep > 0 else {
            return nil
        }
        let maximumIncrease = current * 0.10
        let unrounded = current + min(configuredStep, maximumIncrease)
        var candidate = roundedLoad(unrounded)
        if candidate - current > maximumIncrease + 0.000_001 {
            candidate = floor(unrounded * 2) / 2
        }
        return candidate > current ? candidate : nil
    }

}
