import Foundation

public struct StrengthScheduleDay: Equatable, Sendable {
    public let dateKey: String
    public let isoWeekday: Int

    public init(dateKey: String, isoWeekday: Int) {
        self.dateKey = dateKey
        self.isoWeekday = isoWeekday
    }
}

public struct StrengthRoutineCompletion: Equatable, Sendable {
    public let dateKey: String
    public let routineId: String

    public init(dateKey: String, routineId: String) {
        self.dateKey = dateKey
        self.routineId = routineId
    }
}

public enum StrengthTrainingExperience: String, CaseIterable, Codable, Sendable {
    case beginner
    case intermediate
    case experienced
}

public enum StrengthTrainingStyle: String, CaseIterable, Codable, Sendable {
    case balanced
    case strength
    case muscle
    case conditioning
}

public struct StrengthProgramRequest: Equatable, Sendable {
    public let weekdays: [Int]
    public let experience: StrengthTrainingExperience
    public let style: StrengthTrainingStyle
    public let sessionMinutes: Int
    public let focusMuscles: [String]

    public init(
        weekdays: [Int],
        experience: StrengthTrainingExperience = .beginner,
        style: StrengthTrainingStyle = .balanced,
        sessionMinutes: Int = 45,
        focusMuscles: [String] = []
    ) {
        self.weekdays = weekdays
        self.experience = experience
        self.style = style
        self.sessionMinutes = sessionMinutes
        self.focusMuscles = focusMuscles
    }
}

public enum StrengthDayRecommendationReason: String, Equatable, Sendable {
    case scheduled
    case makeUp
    case completed
    case rest
}

public struct StrengthDayRecommendation: Equatable, Sendable {
    public let routineId: String?
    public let reason: StrengthDayRecommendationReason
    public let originallyScheduledDateKey: String?

    public init(
        routineId: String?,
        reason: StrengthDayRecommendationReason,
        originallyScheduledDateKey: String? = nil
    ) {
        self.routineId = routineId
        self.reason = reason
        self.originallyScheduledDateKey = originallyScheduledDateKey
    }
}

public struct StrengthProgramExercise: Equatable, Sendable {
    public let exerciseId: String
    public let targetSets: Int
    public let targetRepsMin: Int?
    public let targetRepsMax: Int?
    public let restSeconds: Int
    public let targetDurationS: Int?
    public let warmupSets: Int
    public let targetRPE: Double

    public init(
        exerciseId: String,
        targetSets: Int,
        targetRepsMin: Int? = nil,
        targetRepsMax: Int? = nil,
        restSeconds: Int,
        targetDurationS: Int? = nil,
        warmupSets: Int = 0,
        targetRPE: Double = 7
    ) {
        self.exerciseId = exerciseId
        self.targetSets = targetSets
        self.targetRepsMin = targetRepsMin
        self.targetRepsMax = targetRepsMax
        self.restSeconds = restSeconds
        self.targetDurationS = targetDurationS
        self.warmupSets = warmupSets
        self.targetRPE = targetRPE
    }

    public var plan: StrengthExercisePlan {
        StrengthExercisePlan(
            mode: targetDurationS == nil ? "reps" : "timed",
            targetDurationS: targetDurationS,
            progression: targetDurationS == nil ? "double_progression" : "time",
            warmupSets: warmupSets
        )
    }
}

public struct StrengthProgramRoutine: Equatable, Sendable {
    public let name: String
    public let isoWeekday: Int
    public let exercises: [StrengthProgramExercise]

    public init(name: String, isoWeekday: Int, exercises: [StrengthProgramExercise]) {
        self.name = name
        self.isoWeekday = isoWeekday
        self.exercises = exercises
    }
}

/// Deterministic, local-only training recommendations. A missed session can move onto the next
/// rest day, but never stacks with another scheduled workout and never advances an uncompleted load.
public enum StrengthAdaptivePlanner {
    public static let maximumMakeUpAgeDays = 3

    public static func recommendation(
        today: StrengthScheduleDay,
        previousDaysNearestFirst: [StrengthScheduleDay],
        routines: [StrengthRoutineSnapshot],
        completions: [StrengthRoutineCompletion]
    ) -> StrengthDayRecommendation {
        let completedToday = completions.filter { $0.dateKey == today.dateKey }
        let todayRoutines = scheduledRoutines(on: today.isoWeekday, routines: routines)
        if let scheduled = todayRoutines.first(where: { routine in
            !completedToday.contains(where: { $0.routineId == routine.routine.id })
        }) {
            return StrengthDayRecommendation(
                routineId: scheduled.routine.id,
                reason: .scheduled,
                originallyScheduledDateKey: today.dateKey
            )
        }
        if !todayRoutines.isEmpty || !completedToday.isEmpty {
            return StrengthDayRecommendation(routineId: nil, reason: .completed)
        }

        let candidates = Array(previousDaysNearestFirst.prefix(maximumMakeUpAgeDays))
        for (index, day) in candidates.enumerated() {
            for routine in scheduledRoutines(on: day.isoWeekday, routines: routines) {
                let routineID = routine.routine.id
                let completedSince = completions.contains {
                    $0.routineId == routineID
                        && $0.dateKey >= day.dateKey
                        && $0.dateKey <= today.dateKey
                }
                let newerOccurrence = candidates.prefix(index).contains { newerDay in
                    StrengthTrainingContract.scheduledWeekdays(
                        from: routine.routine.scheduledWeekdaysJSON
                    ).contains(newerDay.isoWeekday)
                }
                if !completedSince && !newerOccurrence {
                    return StrengthDayRecommendation(
                        routineId: routineID,
                        reason: .makeUp,
                        originallyScheduledDateKey: day.dateKey
                    )
                }
            }
        }
        return StrengthDayRecommendation(routineId: nil, reason: .rest)
    }

    public static func suggestedWeekdays(for dayCount: Int) -> [Int] {
        switch dayCount {
        case 2: return [1, 4]
        case 3: return [1, 3, 5]
        case 4: return [1, 2, 4, 5]
        case 5: return [1, 2, 3, 5, 6]
        case 6: return [1, 2, 3, 4, 5, 6]
        default: return []
        }
    }

    public static func program(for weekdays: [Int]) -> [StrengthProgramRoutine] {
        program(for: StrengthProgramRequest(weekdays: weekdays))
    }

    public static func program(for request: StrengthProgramRequest) -> [StrengthProgramRoutine] {
        let days = Array(Set(request.weekdays)).sorted()
        guard (2...6).contains(days.count), days.allSatisfy({ (1...7).contains($0) }) else {
            return []
        }
        let specs: [(String, [StrengthProgramExercise])]
        switch days.count {
        case 2:
            specs = [
                ("Full Body A", fullBodyA),
                ("Full Body B", fullBodyB),
            ]
        case 3:
            specs = [
                ("Push", pushA),
                ("Pull", pullA),
                ("Legs", legsA),
            ]
        case 4:
            specs = [
                ("Upper A", upperA),
                ("Lower A", lowerA),
                ("Upper B", upperB),
                ("Lower B", lowerB),
            ]
        case 5:
            specs = [
                ("Push", pushA),
                ("Pull", pullA),
                ("Legs", legsA),
                ("Upper", upperB),
                ("Lower", lowerB),
            ]
        default:
            specs = [
                ("Push A", pushA),
                ("Pull A", pullA),
                ("Legs A", legsA),
                ("Push B", pushB),
                ("Pull B", pullB),
                ("Legs B", legsB),
            ]
        }
        return zip(days, specs).enumerated().map { routineIndex, item in
            let (day, spec) = item
            let focused = exercisesPrioritizing(
                request.focusMuscles,
                in: spec.1,
                routineIndex: routineIndex
            )
            let exerciseLimit: Int
            switch normalizedSessionMinutes(request.sessionMinutes) {
            case 30: exerciseLimit = 3
            case 45: exerciseLimit = 4
            case 60: exerciseLimit = 5
            default: exerciseLimit = 6
            }
            let exercises = focused.prefix(exerciseLimit).enumerated().map { index, exercise in
                customized(exercise, position: index, request: request)
            }
            return StrengthProgramRoutine(
                name: spec.0,
                isoWeekday: day,
                exercises: exercises
            )
        }
    }

    public static func focusWorkout(
        exercises: [StrengthExerciseRow],
        experience: StrengthTrainingExperience,
        style: StrengthTrainingStyle,
        sessionMinutes: Int
    ) -> [StrengthProgramExercise] {
        let request = StrengthProgramRequest(
            weekdays: [],
            experience: experience,
            style: style,
            sessionMinutes: sessionMinutes
        )
        let limit: Int
        switch normalizedSessionMinutes(sessionMinutes) {
        case 30: limit = 3
        case 45: limit = 4
        case 60: limit = 5
        default: limit = 6
        }
        return exercises.prefix(limit).enumerated().map { index, exercise in
            customized(
                starterExercise(for: exercise),
                position: index,
                request: request
            )
        }
    }

    private static func scheduledRoutines(
        on isoWeekday: Int,
        routines: [StrengthRoutineSnapshot]
    ) -> [StrengthRoutineSnapshot] {
        routines
            .filter {
                StrengthTrainingContract.scheduledWeekdays(
                    from: $0.routine.scheduledWeekdaysJSON
                ).contains(isoWeekday)
            }
            .sorted {
                ($0.routine.createdAt, $0.routine.id) < ($1.routine.createdAt, $1.routine.id)
            }
    }

    private static func reps(
        _ id: String,
        _ sets: Int,
        _ minimum: Int,
        _ maximum: Int,
        _ rest: Int = 90,
        warmups: Int = 0
    ) -> StrengthProgramExercise {
        StrengthProgramExercise(
            exerciseId: id,
            targetSets: sets,
            targetRepsMin: minimum,
            targetRepsMax: maximum,
            restSeconds: rest,
            warmupSets: warmups
        )
    }

    private static func timed(
        _ id: String,
        _ sets: Int,
        _ seconds: Int,
        _ rest: Int = 60
    ) -> StrengthProgramExercise {
        StrengthProgramExercise(
            exerciseId: id,
            targetSets: sets,
            restSeconds: rest,
            targetDurationS: seconds
        )
    }

    private static func normalizedSessionMinutes(_ minutes: Int) -> Int {
        [30, 45, 60, 75].min {
            abs($0 - minutes) < abs($1 - minutes)
        } ?? 45
    }

    private static func customized(
        _ exercise: StrengthProgramExercise,
        position: Int,
        request: StrengthProgramRequest
    ) -> StrengthProgramExercise {
        let sessionMinutes = normalizedSessionMinutes(request.sessionMinutes)
        let workingSets: Int
        switch request.experience {
        case .beginner:
            workingSets = min(exercise.targetSets, 2)
        case .intermediate:
            workingSets = min(exercise.targetSets, 3)
        case .experienced:
            workingSets = min(
                4,
                exercise.targetSets + (position < 2 && sessionMinutes >= 60 ? 1 : 0)
            )
        }

        var minimum = exercise.targetRepsMin
        var maximum = exercise.targetRepsMax
        var duration = exercise.targetDurationS
        var rest = exercise.restSeconds
        switch request.style {
        case .balanced:
            break
        case .strength:
            if duration == nil {
                minimum = position < 2 ? 4 : 6
                maximum = position < 2 ? 6 : 10
            }
            rest = max(rest, position < 2 ? 180 : 105)
        case .muscle:
            if duration == nil {
                minimum = position < 2 ? 8 : 10
                maximum = position < 2 ? 12 : 15
            }
            rest = min(max(rest, 60), position < 2 ? 120 : 90)
        case .conditioning:
            if duration == nil {
                minimum = 12
                maximum = 15
            } else {
                duration = max(duration ?? 30, 40)
            }
            rest = min(rest, 60)
        }

        let targetRPE: Double
        switch request.experience {
        case .beginner: targetRPE = 6.5
        case .intermediate: targetRPE = 7
        case .experienced: targetRPE = 7.5
        }
        return StrengthProgramExercise(
            exerciseId: exercise.exerciseId,
            targetSets: max(1, workingSets),
            targetRepsMin: minimum,
            targetRepsMax: maximum,
            restSeconds: max(30, rest),
            targetDurationS: duration,
            warmupSets: request.experience == .beginner
                ? min(exercise.warmupSets, 1)
                : exercise.warmupSets,
            targetRPE: targetRPE
        )
    }

    private static func starterExercise(
        for exercise: StrengthExerciseRow
    ) -> StrengthProgramExercise {
        let timedMovement = exercise.movementPattern == "cardio"
        let compound = [
            "squat", "hinge", "lunge", "horizontal_push", "vertical_push",
            "horizontal_pull", "vertical_pull", "carry",
        ].contains(exercise.movementPattern)
        if timedMovement {
            return timed(exercise.id, 3, 45, 60)
        }
        return reps(
            exercise.id,
            3,
            compound ? 6 : 10,
            compound ? 10 : 15,
            compound ? 120 : 75,
            warmups: compound && exercise.equipment != "bodyweight" ? 1 : 0
        )
    }

    private static func exercisesPrioritizing(
        _ requestedMuscles: [String],
        in exercises: [StrengthProgramExercise],
        routineIndex: Int
    ) -> [StrengthProgramExercise] {
        let muscles = Array(Set(requestedMuscles))
            .filter { StrengthTrainingContract.muscles.contains($0) }
            .filter { $0 != "full_body" && $0 != "other" }
            .sorted()
        guard !muscles.isEmpty else { return exercises }

        let catalog = StrengthTrainingContract.builtInExercises
        let existingIDs = Set(exercises.map(\.exerciseId))
        let alreadyFocused = catalog.contains { exercise in
            existingIDs.contains(exercise.id) && muscles.contains(exercise.primaryMuscle)
        }
        guard !alreadyFocused else { return exercises }

        let candidates = catalog.filter {
            muscles.contains($0.primaryMuscle)
                && $0.movementPattern != "cardio"
                && !existingIDs.contains($0.id)
        }
        guard !candidates.isEmpty else { return exercises }
        let selected = candidates[routineIndex % candidates.count]
        var result = exercises
        if result.isEmpty {
            result.append(starterExercise(for: selected))
        } else {
            result[min(2, result.count - 1)] = starterExercise(for: selected)
        }
        return result
    }

    private static let pushA = [
        reps("barbell_bench_press", 3, 6, 8, 150, warmups: 2),
        reps("overhead_press", 3, 6, 8, 120, warmups: 1),
        reps("incline_barbell_bench_press", 3, 8, 10, 120),
        reps("lateral_raise", 3, 12, 15, 60),
        reps("triceps_pushdown", 3, 10, 12, 75),
    ]
    private static let pushB = [
        reps("overhead_press", 3, 6, 8, 150, warmups: 2),
        reps("dumbbell_bench_press", 3, 8, 10, 120, warmups: 1),
        reps("machine_chest_press", 3, 10, 12, 90),
        reps("lateral_raise", 3, 12, 15, 60),
        reps("overhead_triceps_extension", 3, 10, 12, 75),
    ]
    private static let pullA = [
        reps("conventional_deadlift", 3, 4, 6, 180, warmups: 2),
        reps("pull_up", 3, 6, 10, 120),
        reps("bent_over_row", 3, 6, 8, 120, warmups: 1),
        reps("face_pull", 3, 12, 15, 60),
        reps("biceps_curl", 3, 10, 12, 75),
    ]
    private static let pullB = [
        reps("romanian_deadlift", 3, 6, 8, 150, warmups: 2),
        reps("lat_pulldown", 3, 8, 10, 120),
        reps("seated_cable_row", 3, 8, 10, 105),
        reps("rear_delt_fly", 3, 12, 15, 60),
        reps("hammer_curl", 3, 10, 12, 75),
    ]
    private static let legsA = [
        reps("barbell_back_squat", 3, 6, 8, 180, warmups: 2),
        reps("romanian_deadlift", 3, 8, 10, 150, warmups: 1),
        reps("walking_lunge", 3, 8, 10, 90),
        reps("lying_leg_curl", 3, 10, 12, 75),
        reps("standing_calf_raise", 3, 12, 15, 60),
    ]
    private static let legsB = [
        reps("conventional_deadlift", 3, 4, 6, 180, warmups: 2),
        reps("barbell_front_squat", 3, 6, 8, 150, warmups: 1),
        reps("bulgarian_split_squat", 3, 8, 10, 90),
        reps("leg_extension", 3, 10, 12, 75),
        reps("seated_calf_raise", 3, 12, 15, 60),
    ]
    private static let upperA = [
        reps("barbell_bench_press", 3, 6, 8, 150, warmups: 2),
        reps("bent_over_row", 3, 6, 8, 120, warmups: 1),
        reps("overhead_press", 3, 8, 10, 105),
        reps("lat_pulldown", 3, 8, 10, 105),
        reps("triceps_pushdown", 2, 10, 12, 60),
        reps("biceps_curl", 2, 10, 12, 60),
    ]
    private static let upperB = [
        reps("pull_up", 3, 6, 10, 120, warmups: 1),
        reps("incline_barbell_bench_press", 3, 8, 10, 120, warmups: 1),
        reps("seated_cable_row", 3, 8, 10, 105),
        reps("dumbbell_shoulder_press", 3, 8, 10, 105),
        reps("face_pull", 2, 12, 15, 60),
        reps("hammer_curl", 2, 10, 12, 60),
    ]
    private static let lowerA = [
        reps("barbell_back_squat", 3, 6, 8, 180, warmups: 2),
        reps("romanian_deadlift", 3, 8, 10, 150, warmups: 1),
        reps("walking_lunge", 3, 8, 10, 90),
        reps("lying_leg_curl", 3, 10, 12, 75),
        reps("standing_calf_raise", 3, 12, 15, 60),
        timed("plank", 3, 30),
    ]
    private static let lowerB = [
        reps("conventional_deadlift", 3, 4, 6, 180, warmups: 2),
        reps("barbell_front_squat", 3, 6, 8, 150, warmups: 1),
        reps("bulgarian_split_squat", 3, 8, 10, 90),
        reps("leg_extension", 3, 10, 12, 75),
        reps("seated_calf_raise", 3, 12, 15, 60),
        timed("side_plank", 3, 25),
    ]
    private static let fullBodyA = [
        reps("barbell_back_squat", 3, 6, 8, 180, warmups: 2),
        reps("barbell_bench_press", 3, 6, 8, 150, warmups: 2),
        reps("seated_cable_row", 3, 8, 10, 105),
        reps("romanian_deadlift", 3, 8, 10, 150, warmups: 1),
        timed("plank", 3, 30),
    ]
    private static let fullBodyB = [
        reps("conventional_deadlift", 3, 4, 6, 180, warmups: 2),
        reps("overhead_press", 3, 6, 8, 120, warmups: 1),
        reps("lat_pulldown", 3, 8, 10, 105),
        reps("bulgarian_split_squat", 3, 8, 10, 90),
        timed("farmers_carry", 3, 30),
    ]
}
