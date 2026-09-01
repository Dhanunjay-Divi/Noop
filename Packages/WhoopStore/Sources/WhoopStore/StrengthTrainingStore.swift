import Foundation
import GRDB

// MARK: - Strength training source of truth (v40+)

/// Optional routine-level prescription details that do not belong on a completed set.
///
/// The JSON envelope keeps the normalized routine table stable while allowing the native clients
/// to add planning features without turning historical workout rows into configuration storage.
public struct StrengthExercisePlan: Codable, Equatable, Sendable {
    public static let modes = ["reps", "timed"]
    public static let progressions = ["none", "double_progression", "linear", "time"]
    public static let setStyles = ["straight", "drop", "rest_pause"]

    public var mode: String
    public var targetLoadKg: Double?
    public var targetDurationS: Int?
    public var progression: String
    public var loadStepKg: Double
    public var warmupSets: Int
    public var supersetGroup: Int?
    public var repsPerSide: Bool
    public var setStyle: String
    public var dropPercent: Int
    public var restPauseSeconds: Int

    public init(
        mode: String = "reps",
        targetLoadKg: Double? = nil,
        targetDurationS: Int? = nil,
        progression: String = "double_progression",
        loadStepKg: Double = 2.5,
        warmupSets: Int = 0,
        supersetGroup: Int? = nil,
        repsPerSide: Bool = false,
        setStyle: String = "straight",
        dropPercent: Int = 20,
        restPauseSeconds: Int = 15
    ) {
        self.mode = mode
        self.targetLoadKg = targetLoadKg
        self.targetDurationS = targetDurationS
        self.progression = progression
        self.loadStepKg = loadStepKg
        self.warmupSets = warmupSets
        self.supersetGroup = supersetGroup
        self.repsPerSide = repsPerSide
        self.setStyle = setStyle
        self.dropPercent = dropPercent
        self.restPauseSeconds = restPauseSeconds
    }
}

/// Stable cross-platform rules for the local-first strength log.
///
/// Imported/cardio workouts remain in `workout`. Strength exercise detail lives in normalized tables
/// because a session can contain several exercises and many independently editable sets. Load is always
/// stored in kilograms; display conversion is an app-layer concern.
public enum StrengthTrainingContract {
    public static let maxNameCharacters = 80
    public static let maxNoteCharacters = 500
    public static let maxLoadKg = 2_000.0
    public static let maxReps = 1_000
    public static let maxDurationSeconds = 86_400
    public static let maxRestSeconds = 3_600
    public static let maxTargetSets = 20

    public static let muscles = [
        "chest", "back", "shoulders", "biceps", "triceps", "forearms", "core",
        "quadriceps", "hamstrings", "glutes", "calves", "full_body", "other",
    ]
    public static let equipment = [
        "barbell", "dumbbell", "kettlebell", "cable", "machine", "bodyweight",
        "band", "other",
    ]
    public static let movementPatterns = [
        "squat", "hinge", "lunge", "horizontal_push", "vertical_push",
        "horizontal_pull", "vertical_pull", "carry", "rotation", "isolation", "cardio", "other",
    ]
    public static let setTypes = [
        "warmup", "working", "drop", "rest_pause", "failure", "bodyweight",
    ]

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidID
        case invalidName
        case invalidMuscle
        case invalidSecondaryMuscles
        case invalidEquipment
        case invalidMovementPattern
        case invalidTimestamps
        case invalidRoutineExercise
        case invalidSession
        case invalidSet
        case invalidLoad
        case invalidReps
        case invalidDuration
        case invalidRPE

        public var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Add a short name before saving."
            case .invalidLoad:
                return "Enter a load between 0 and 2,000 kg."
            case .invalidReps:
                return "Enter between 1 and 1,000 reps."
            case .invalidDuration:
                return "Enter a duration between 1 second and 24 hours."
            case .invalidRPE:
                return "RPE must be between 1 and 10."
            case .invalidSet:
                return "A completed set needs reps or a duration."
            default:
                return "NOOP couldn’t validate this strength entry. Please review it and try again."
            }
        }
    }

    /// Owned starter catalog. Stable ids are the storage contract; names and categories can be
    /// presented differently later without rewriting historical sets. Names and classifications are
    /// factual metadata authored for NOOP; no third-party exercise media is bundled.
    public static let builtInExercises: [StrengthExerciseRow] = [
        .builtIn(id: "barbell_back_squat", name: "Back Squat", primary: "quadriceps",
                 secondary: ["glutes", "hamstrings"], equipment: "barbell", pattern: "squat"),
        .builtIn(id: "barbell_bench_press", name: "Bench Press", primary: "chest",
                 secondary: ["triceps", "shoulders"], equipment: "barbell",
                 pattern: "horizontal_push"),
        .builtIn(id: "conventional_deadlift", name: "Deadlift", primary: "hamstrings",
                 secondary: ["glutes", "back"], equipment: "barbell", pattern: "hinge"),
        .builtIn(id: "overhead_press", name: "Overhead Press", primary: "shoulders",
                 secondary: ["triceps"], equipment: "barbell", pattern: "vertical_push"),
        .builtIn(id: "bent_over_row", name: "Bent-over Row", primary: "back",
                 secondary: ["biceps"], equipment: "barbell", pattern: "horizontal_pull"),
        .builtIn(id: "pull_up", name: "Pull-up", primary: "back",
                 secondary: ["biceps"], equipment: "bodyweight", pattern: "vertical_pull"),
        .builtIn(id: "lat_pulldown", name: "Lat Pulldown", primary: "back",
                 secondary: ["biceps"], equipment: "cable", pattern: "vertical_pull"),
        .builtIn(id: "leg_press", name: "Leg Press", primary: "quadriceps",
                 secondary: ["glutes"], equipment: "machine", pattern: "squat"),
        .builtIn(id: "romanian_deadlift", name: "Romanian Deadlift", primary: "hamstrings",
                 secondary: ["glutes", "back"], equipment: "barbell", pattern: "hinge"),
        .builtIn(id: "dumbbell_lunge", name: "Dumbbell Lunge", primary: "quadriceps",
                 secondary: ["glutes", "hamstrings"], equipment: "dumbbell", pattern: "lunge"),
        .builtIn(id: "biceps_curl", name: "Biceps Curl", primary: "biceps",
                 secondary: ["forearms"], equipment: "dumbbell", pattern: "isolation"),
        .builtIn(id: "triceps_pushdown", name: "Triceps Pushdown", primary: "triceps",
                 secondary: [], equipment: "cable", pattern: "isolation"),
        .builtIn(id: "plank", name: "Plank", primary: "core",
                 secondary: ["shoulders"], equipment: "bodyweight", pattern: "isolation"),
        .builtIn(id: "barbell_front_squat", name: "Front Squat", primary: "quadriceps",
                 secondary: ["glutes", "core"], equipment: "barbell", pattern: "squat"),
        .builtIn(id: "goblet_squat", name: "Goblet Squat", primary: "quadriceps",
                 secondary: ["glutes", "core"], equipment: "dumbbell", pattern: "squat"),
        .builtIn(id: "hack_squat", name: "Hack Squat", primary: "quadriceps",
                 secondary: ["glutes"], equipment: "machine", pattern: "squat"),
        .builtIn(id: "leg_extension", name: "Leg Extension", primary: "quadriceps",
                 secondary: [], equipment: "machine", pattern: "isolation"),
        .builtIn(id: "lying_leg_curl", name: "Lying Leg Curl", primary: "hamstrings",
                 secondary: ["calves"], equipment: "machine", pattern: "isolation"),
        .builtIn(id: "barbell_hip_thrust", name: "Hip Thrust", primary: "glutes",
                 secondary: ["hamstrings"], equipment: "barbell", pattern: "hinge"),
        .builtIn(id: "glute_bridge", name: "Glute Bridge", primary: "glutes",
                 secondary: ["hamstrings"], equipment: "bodyweight", pattern: "hinge"),
        .builtIn(id: "bulgarian_split_squat", name: "Bulgarian Split Squat",
                 primary: "quadriceps", secondary: ["glutes", "hamstrings"],
                 equipment: "dumbbell", pattern: "lunge"),
        .builtIn(id: "walking_lunge", name: "Walking Lunge", primary: "quadriceps",
                 secondary: ["glutes", "hamstrings"], equipment: "dumbbell", pattern: "lunge"),
        .builtIn(id: "standing_calf_raise", name: "Standing Calf Raise", primary: "calves",
                 secondary: [], equipment: "machine", pattern: "isolation"),
        .builtIn(id: "seated_calf_raise", name: "Seated Calf Raise", primary: "calves",
                 secondary: [], equipment: "machine", pattern: "isolation"),
        .builtIn(id: "incline_barbell_bench_press", name: "Incline Bench Press", primary: "chest",
                 secondary: ["shoulders", "triceps"], equipment: "barbell",
                 pattern: "horizontal_push"),
        .builtIn(id: "dumbbell_bench_press", name: "Dumbbell Bench Press", primary: "chest",
                 secondary: ["shoulders", "triceps"], equipment: "dumbbell",
                 pattern: "horizontal_push"),
        .builtIn(id: "push_up", name: "Push-up", primary: "chest",
                 secondary: ["shoulders", "triceps", "core"], equipment: "bodyweight",
                 pattern: "horizontal_push"),
        .builtIn(id: "chest_fly", name: "Chest Fly", primary: "chest",
                 secondary: ["shoulders"], equipment: "dumbbell", pattern: "isolation"),
        .builtIn(id: "cable_crossover", name: "Cable Crossover", primary: "chest",
                 secondary: ["shoulders"], equipment: "cable", pattern: "isolation"),
        .builtIn(id: "machine_chest_press", name: "Machine Chest Press", primary: "chest",
                 secondary: ["shoulders", "triceps"], equipment: "machine",
                 pattern: "horizontal_push"),
        .builtIn(id: "one_arm_dumbbell_row", name: "One-arm Dumbbell Row", primary: "back",
                 secondary: ["biceps", "forearms"], equipment: "dumbbell",
                 pattern: "horizontal_pull"),
        .builtIn(id: "seated_cable_row", name: "Seated Cable Row", primary: "back",
                 secondary: ["biceps"], equipment: "cable", pattern: "horizontal_pull"),
        .builtIn(id: "chest_supported_row", name: "Chest-supported Row", primary: "back",
                 secondary: ["biceps"], equipment: "dumbbell", pattern: "horizontal_pull"),
        .builtIn(id: "chin_up", name: "Chin-up", primary: "back",
                 secondary: ["biceps", "forearms"], equipment: "bodyweight",
                 pattern: "vertical_pull"),
        .builtIn(id: "face_pull", name: "Face Pull", primary: "shoulders",
                 secondary: ["back"], equipment: "cable", pattern: "horizontal_pull"),
        .builtIn(id: "dumbbell_shoulder_press", name: "Dumbbell Shoulder Press",
                 primary: "shoulders", secondary: ["triceps"], equipment: "dumbbell",
                 pattern: "vertical_push"),
        .builtIn(id: "lateral_raise", name: "Lateral Raise", primary: "shoulders",
                 secondary: [], equipment: "dumbbell", pattern: "isolation"),
        .builtIn(id: "rear_delt_fly", name: "Rear Delt Fly", primary: "shoulders",
                 secondary: ["back"], equipment: "dumbbell", pattern: "isolation"),
        .builtIn(id: "hammer_curl", name: "Hammer Curl", primary: "biceps",
                 secondary: ["forearms"], equipment: "dumbbell", pattern: "isolation"),
        .builtIn(id: "preacher_curl", name: "Preacher Curl", primary: "biceps",
                 secondary: ["forearms"], equipment: "barbell", pattern: "isolation"),
        .builtIn(id: "skull_crusher", name: "Skull Crusher", primary: "triceps",
                 secondary: [], equipment: "barbell", pattern: "isolation"),
        .builtIn(id: "overhead_triceps_extension", name: "Overhead Triceps Extension",
                 primary: "triceps", secondary: [], equipment: "dumbbell", pattern: "isolation"),
        .builtIn(id: "parallel_bar_dip", name: "Dip", primary: "triceps",
                 secondary: ["chest", "shoulders"], equipment: "bodyweight",
                 pattern: "vertical_push"),
        .builtIn(id: "hanging_leg_raise", name: "Hanging Leg Raise", primary: "core",
                 secondary: ["forearms"], equipment: "bodyweight", pattern: "isolation"),
        .builtIn(id: "cable_crunch", name: "Cable Crunch", primary: "core",
                 secondary: [], equipment: "cable", pattern: "isolation"),
        .builtIn(id: "side_plank", name: "Side Plank", primary: "core",
                 secondary: ["shoulders"], equipment: "bodyweight", pattern: "isolation"),
        .builtIn(id: "ab_wheel_rollout", name: "Ab Wheel Rollout", primary: "core",
                 secondary: ["shoulders", "back"], equipment: "other", pattern: "isolation"),
        .builtIn(id: "farmers_carry", name: "Farmer's Carry", primary: "full_body",
                 secondary: ["forearms", "core", "shoulders"], equipment: "dumbbell",
                 pattern: "carry"),
        .builtIn(id: "kettlebell_swing", name: "Kettlebell Swing", primary: "full_body",
                 secondary: ["glutes", "hamstrings", "core"], equipment: "kettlebell",
                 pattern: "hinge"),
        .builtIn(id: "back_extension", name: "Back Extension", primary: "back",
                 secondary: ["glutes", "hamstrings"], equipment: "bodyweight", pattern: "hinge"),
        .builtIn(id: "band_pull_apart", name: "Band Pull-apart", primary: "shoulders",
                 secondary: ["back"], equipment: "band", pattern: "horizontal_pull"),
        .builtIn(id: "resistance_band_row", name: "Resistance Band Row", primary: "back",
                 secondary: ["biceps"], equipment: "band", pattern: "horizontal_pull"),
        .builtIn(id: "treadmill_run", name: "Treadmill Run", primary: "full_body",
                 secondary: ["quadriceps", "hamstrings", "calves"], equipment: "other",
                 pattern: "cardio"),
        .builtIn(id: "indoor_cycling", name: "Indoor Cycling", primary: "quadriceps",
                 secondary: ["glutes", "hamstrings", "calves"], equipment: "other",
                 pattern: "cardio"),
        .builtIn(id: "rowing_ergometer", name: "Rowing Ergometer", primary: "full_body",
                 secondary: ["back", "quadriceps", "biceps"], equipment: "other",
                 pattern: "cardio"),
        .builtIn(id: "stair_climber", name: "Stair Climber", primary: "quadriceps",
                 secondary: ["glutes", "calves"], equipment: "machine", pattern: "cardio"),
    ]

    public static func scheduledWeekdays(from json: String?) -> [Int] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([Int].self, from: data)
        else { return [] }
        return Array(Set(values.filter { (1...7).contains($0) })).sorted()
    }

    public static func encodeScheduledWeekdays(_ values: [Int]) -> String? {
        let clean = Array(Set(values.filter { (1...7).contains($0) })).sorted()
        guard !clean.isEmpty, let data = try? JSONEncoder().encode(clean) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func exercisePlan(from json: String?) -> StrengthExercisePlan {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StrengthExercisePlan.self, from: data),
              isValid(decoded)
        else { return StrengthExercisePlan() }
        return decoded
    }

    public static func encodeExercisePlan(_ plan: StrengthExercisePlan) -> String? {
        guard isValid(plan) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func validated(_ row: StrengthExerciseRow) throws -> StrengthExerciseRow {
        var clean = row
        clean.id = try validatedID(clean.id)
        clean.name = try validatedName(clean.name)
        guard muscles.contains(clean.primaryMuscle) else { throw ValidationError.invalidMuscle }
        guard equipment.contains(clean.equipment) else { throw ValidationError.invalidEquipment }
        guard movementPatterns.contains(clean.movementPattern) else {
            throw ValidationError.invalidMovementPattern
        }
        guard secondaryMuscles(from: clean.secondaryMusclesJSON) != nil else {
            throw ValidationError.invalidSecondaryMuscles
        }
        guard clean.createdAt > 0, clean.updatedAt >= clean.createdAt,
              clean.archivedAt == nil || clean.archivedAt! >= clean.createdAt
        else { throw ValidationError.invalidTimestamps }
        return clean
    }

    public static func validated(_ row: StrengthRoutineRow) throws -> StrengthRoutineRow {
        var clean = row
        clean.id = try validatedID(clean.id)
        clean.name = try validatedName(clean.name)
        clean.note = boundedText(clean.note, max: maxNoteCharacters, singleLine: false)
        if clean.scheduledWeekdaysJSON != nil {
            guard !scheduledWeekdays(from: clean.scheduledWeekdaysJSON).isEmpty else {
                throw ValidationError.invalidRoutineExercise
            }
            clean.scheduledWeekdaysJSON = encodeScheduledWeekdays(
                scheduledWeekdays(from: clean.scheduledWeekdaysJSON)
            )
        }
        guard clean.createdAt > 0, clean.updatedAt >= clean.createdAt,
              clean.archivedAt == nil || clean.archivedAt! >= clean.createdAt
        else { throw ValidationError.invalidTimestamps }
        return clean
    }

    public static func validated(_ row: StrengthRoutineExerciseRow) throws -> StrengthRoutineExerciseRow {
        var clean = row
        clean.id = try validatedID(clean.id)
        clean.routineId = try validatedID(clean.routineId)
        clean.exerciseId = try validatedID(clean.exerciseId)
        clean.note = boundedText(clean.note, max: maxNoteCharacters, singleLine: false)
        guard clean.position >= 0,
              (1...maxTargetSets).contains(clean.targetSets),
              (0...maxRestSeconds).contains(clean.restSeconds),
              clean.createdAt > 0, clean.updatedAt >= clean.createdAt
        else { throw ValidationError.invalidRoutineExercise }
        if let min = clean.targetRepsMin {
            guard (1...maxReps).contains(min) else { throw ValidationError.invalidReps }
        }
        if let max = clean.targetRepsMax {
            guard (1...maxReps).contains(max) else { throw ValidationError.invalidReps }
        }
        if let min = clean.targetRepsMin, let max = clean.targetRepsMax, min > max {
            throw ValidationError.invalidRoutineExercise
        }
        if let planJSON = clean.planJSON {
            guard let data = planJSON.data(using: .utf8),
                  let plan = try? JSONDecoder().decode(StrengthExercisePlan.self, from: data),
                  isValid(plan)
            else { throw ValidationError.invalidRoutineExercise }
            clean.planJSON = encodeExercisePlan(plan)
        }
        try validateRPE(clean.targetRPE)
        return clean
    }

    public static func validated(_ row: StrengthSessionRow) throws -> StrengthSessionRow {
        var clean = row
        clean.id = try validatedID(clean.id)
        if let routineId = clean.routineId { clean.routineId = try validatedID(routineId) }
        clean.name = boundedText(clean.name, max: maxNameCharacters, singleLine: true)
        clean.note = boundedText(clean.note, max: maxNoteCharacters, singleLine: false)
        guard clean.startedAt > 0,
              clean.endedAt == nil || (clean.endedAt! >= clean.startedAt
                  && clean.endedAt! - clean.startedAt <= maxDurationSeconds),
              clean.createdAt > 0, clean.updatedAt >= clean.createdAt
        else { throw ValidationError.invalidSession }
        return clean
    }

    public static func validated(_ row: StrengthSetRow) throws -> StrengthSetRow {
        var clean = row
        clean.id = try validatedID(clean.id)
        clean.sessionId = try validatedID(clean.sessionId)
        clean.exerciseId = try validatedID(clean.exerciseId)
        clean.note = boundedText(clean.note, max: maxNoteCharacters, singleLine: false)
        guard clean.exercisePosition >= 0, clean.setPosition >= 0,
              setTypes.contains(clean.setType),
              clean.createdAt > 0, clean.updatedAt >= clean.createdAt,
              clean.completedAt == nil || clean.completedAt! > 0
        else { throw ValidationError.invalidSet }
        if let restSeconds = clean.restSeconds,
           !(0...maxRestSeconds).contains(restSeconds) {
            throw ValidationError.invalidSet
        }
        if let reps = clean.reps, !(1...maxReps).contains(reps) {
            throw ValidationError.invalidReps
        }
        if let load = clean.loadKg, (!load.isFinite || load <= 0 || load > maxLoadKg) {
            throw ValidationError.invalidLoad
        }
        if let duration = clean.durationS, !(1...maxDurationSeconds).contains(duration) {
            throw ValidationError.invalidDuration
        }
        try validateRPE(clean.rpe)
        if clean.completedAt != nil, clean.reps == nil, clean.durationS == nil {
            throw ValidationError.invalidSet
        }
        return clean
    }

    public static func secondaryMuscles(from json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data),
              values.allSatisfy({ muscles.contains($0) })
        else { return nil }
        return values
    }

    static func encodeMuscles(_ values: [String]) -> String {
        let data = try? JSONEncoder().encode(values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func validatedID(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 128 else { throw ValidationError.invalidID }
        return clean
    }

    private static func validatedName(_ value: String) throws -> String {
        guard let clean = boundedText(value, max: maxNameCharacters, singleLine: true) else {
            throw ValidationError.invalidName
        }
        return clean
    }

    private static func validateRPE(_ value: Double?) throws {
        guard let value else { return }
        guard value.isFinite, value >= 1, value <= 10 else { throw ValidationError.invalidRPE }
    }

    private static func isValid(_ plan: StrengthExercisePlan) -> Bool {
        guard StrengthExercisePlan.modes.contains(plan.mode),
              StrengthExercisePlan.progressions.contains(plan.progression),
              StrengthExercisePlan.setStyles.contains(plan.setStyle)
        else { return false }
        let progressionMatchesMode = plan.mode == "timed"
            ? ["none", "time"].contains(plan.progression)
            : plan.progression != "time"
        guard progressionMatchesMode else { return false }
        if let load = plan.targetLoadKg,
           (!load.isFinite || load <= 0 || load > maxLoadKg) {
            return false
        }
        if let duration = plan.targetDurationS,
           !(1...maxDurationSeconds).contains(duration) {
            return false
        }
        return plan.loadStepKg.isFinite
            && plan.loadStepKg > 0
            && plan.loadStepKg <= 100
            && (0...5).contains(plan.warmupSets)
            && (plan.supersetGroup == nil || (1...20).contains(plan.supersetGroup!))
            && (5...50).contains(plan.dropPercent)
            && (5...60).contains(plan.restPauseSeconds)
    }

    private static func boundedText(_ value: String?, max: Int, singleLine: Bool) -> String? {
        guard var text = value else { return nil }
        if singleLine {
            text = text.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        text = text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || (!singleLine && $0 == "\n") }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(max))
    }
}

public struct StrengthExerciseRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var primaryMuscle: String
    public var secondaryMusclesJSON: String
    public var equipment: String
    public var movementPattern: String
    public var isCustom: Bool
    public var archivedAt: Int?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String, name: String, primaryMuscle: String, secondaryMusclesJSON: String = "[]",
        equipment: String, movementPattern: String, isCustom: Bool,
        archivedAt: Int? = nil, createdAt: Int, updatedAt: Int
    ) {
        self.id = id
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.secondaryMusclesJSON = secondaryMusclesJSON
        self.equipment = equipment
        self.movementPattern = movementPattern
        self.isCustom = isCustom
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func builtIn(
        id: String, name: String, primary: String, secondary: [String],
        equipment: String, pattern: String
    ) -> StrengthExerciseRow {
        StrengthExerciseRow(
            id: id, name: name, primaryMuscle: primary,
            secondaryMusclesJSON: StrengthTrainingContract.encodeMuscles(secondary),
            equipment: equipment, movementPattern: pattern, isCustom: false,
            createdAt: 1, updatedAt: 1
        )
    }

    static func decode(_ row: Row) -> StrengthExerciseRow {
        StrengthExerciseRow(
            id: row["id"], name: row["name"], primaryMuscle: row["primaryMuscle"],
            secondaryMusclesJSON: row["secondaryMusclesJSON"], equipment: row["equipment"],
            movementPattern: row["movementPattern"], isCustom: row["isCustom"],
            archivedAt: row["archivedAt"], createdAt: row["createdAt"], updatedAt: row["updatedAt"]
        )
    }
}

public struct StrengthRoutineRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var note: String?
    public var scheduledWeekdaysJSON: String?
    public var archivedAt: Int?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String, name: String, note: String? = nil, scheduledWeekdaysJSON: String? = nil,
        archivedAt: Int? = nil,
        createdAt: Int, updatedAt: Int
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.scheduledWeekdaysJSON = scheduledWeekdaysJSON
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> StrengthRoutineRow {
        StrengthRoutineRow(
            id: row["id"], name: row["name"], note: row["note"],
            scheduledWeekdaysJSON: row["scheduledWeekdaysJSON"], archivedAt: row["archivedAt"],
            createdAt: row["createdAt"], updatedAt: row["updatedAt"]
        )
    }
}

public struct StrengthRoutineExerciseRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var routineId: String
    public var exerciseId: String
    public var position: Int
    public var targetSets: Int
    public var targetRepsMin: Int?
    public var targetRepsMax: Int?
    public var targetRPE: Double?
    public var restSeconds: Int
    public var note: String?
    public var planJSON: String?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String, routineId: String, exerciseId: String, position: Int,
        targetSets: Int = 3, targetRepsMin: Int? = nil, targetRepsMax: Int? = nil,
        targetRPE: Double? = nil, restSeconds: Int = 120, note: String? = nil,
        planJSON: String? = nil,
        createdAt: Int, updatedAt: Int
    ) {
        self.id = id
        self.routineId = routineId
        self.exerciseId = exerciseId
        self.position = position
        self.targetSets = targetSets
        self.targetRepsMin = targetRepsMin
        self.targetRepsMax = targetRepsMax
        self.targetRPE = targetRPE
        self.restSeconds = restSeconds
        self.note = note
        self.planJSON = planJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> StrengthRoutineExerciseRow {
        StrengthRoutineExerciseRow(
            id: row["id"], routineId: row["routineId"], exerciseId: row["exerciseId"],
            position: row["position"], targetSets: row["targetSets"],
            targetRepsMin: row["targetRepsMin"], targetRepsMax: row["targetRepsMax"],
            targetRPE: row["targetRPE"], restSeconds: row["restSeconds"], note: row["note"],
            planJSON: row["planJSON"],
            createdAt: row["createdAt"], updatedAt: row["updatedAt"]
        )
    }
}

public struct StrengthSessionRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var routineId: String?
    public var name: String?
    public var startedAt: Int
    public var endedAt: Int?
    public var note: String?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String, routineId: String? = nil, name: String? = nil, startedAt: Int,
        endedAt: Int? = nil, note: String? = nil, createdAt: Int, updatedAt: Int
    ) {
        self.id = id
        self.routineId = routineId
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> StrengthSessionRow {
        StrengthSessionRow(
            id: row["id"], routineId: row["routineId"], name: row["name"],
            startedAt: row["startedAt"], endedAt: row["endedAt"], note: row["note"],
            createdAt: row["createdAt"], updatedAt: row["updatedAt"]
        )
    }
}

public struct StrengthSetRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var exerciseId: String
    public var exercisePosition: Int
    public var setPosition: Int
    public var setType: String
    public var reps: Int?
    public var loadKg: Double?
    public var durationS: Int?
    public var rpe: Double?
    public var restSeconds: Int?
    public var completedAt: Int?
    public var note: String?
    public var createdAt: Int
    public var updatedAt: Int

    public init(
        id: String, sessionId: String, exerciseId: String, exercisePosition: Int,
        setPosition: Int, setType: String = "working", reps: Int? = nil,
        loadKg: Double? = nil, durationS: Int? = nil, rpe: Double? = nil,
        restSeconds: Int? = nil, completedAt: Int? = nil, note: String? = nil,
        createdAt: Int, updatedAt: Int
    ) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.exercisePosition = exercisePosition
        self.setPosition = setPosition
        self.setType = setType
        self.reps = reps
        self.loadKg = loadKg
        self.durationS = durationS
        self.rpe = rpe
        self.restSeconds = restSeconds
        self.completedAt = completedAt
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var volumeKg: Double? {
        guard completedAt != nil, let reps, let loadKg else { return nil }
        return loadKg * Double(reps)
    }

    static func decode(_ row: Row) -> StrengthSetRow {
        StrengthSetRow(
            id: row["id"], sessionId: row["sessionId"], exerciseId: row["exerciseId"],
            exercisePosition: row["exercisePosition"], setPosition: row["setPosition"],
            setType: row["setType"], reps: row["reps"], loadKg: row["loadKg"],
            durationS: row["durationS"], rpe: row["rpe"], restSeconds: row["restSeconds"],
            completedAt: row["completedAt"], note: row["note"],
            createdAt: row["createdAt"], updatedAt: row["updatedAt"]
        )
    }
}

public struct StrengthRoutineSnapshot: Equatable, Sendable {
    public let routine: StrengthRoutineRow
    public let exercises: [StrengthRoutineExerciseRow]
}

public struct StrengthSessionSnapshot: Equatable, Sendable {
    public let session: StrengthSessionRow
    public let sets: [StrengthSetRow]

    public init(session: StrengthSessionRow, sets: [StrengthSetRow]) {
        self.session = session
        self.sets = sets
    }
}

public struct StrengthSummary: Equatable, Sendable {
    public let sessionCount: Int
    public let completedSetCount: Int
    public let totalReps: Int
    public let loadedVolumeKg: Double
    public let loadedVolumeSetCount: Int
}

public struct StrengthExerciseProgress: Equatable, Sendable {
    public let exerciseId: String
    public let completedSetCount: Int
    public let maxLoadKg: Double?
    public let maxReps: Int?
    public let bestSetVolumeKg: Double?
}

extension WhoopStore {
    @discardableResult
    public func upsertStrengthExercises(_ rows: [StrengthExerciseRow]) async throws -> Int {
        let clean = try rows.map(StrengthTrainingContract.validated)
        return try syncWrite { db in
            var changed = 0
            for row in clean {
                try db.execute(sql: """
                    INSERT INTO strengthExercise
                        (id, name, primaryMuscle, secondaryMusclesJSON, equipment, movementPattern,
                         isCustom, archivedAt, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        primaryMuscle = excluded.primaryMuscle,
                        secondaryMusclesJSON = excluded.secondaryMusclesJSON,
                        equipment = excluded.equipment,
                        movementPattern = excluded.movementPattern,
                        isCustom = excluded.isCustom,
                        archivedAt = excluded.archivedAt,
                        updatedAt = excluded.updatedAt
                    """, arguments: [
                        row.id, row.name, row.primaryMuscle, row.secondaryMusclesJSON, row.equipment,
                        row.movementPattern, row.isCustom, row.archivedAt, row.createdAt, row.updatedAt,
                    ])
                changed += db.changesCount
            }
            return changed
        }
    }

    public func strengthExercises(includeArchived: Bool = false) async throws -> [StrengthExerciseRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM strengthExercise
                \(includeArchived ? "" : "WHERE archivedAt IS NULL")
                ORDER BY isCustom ASC, name COLLATE NOCASE ASC, id ASC
                """).map(StrengthExerciseRow.decode)
        }
    }

    /// Save a routine and replace its ordered exercise prescription in one transaction.
    @discardableResult
    public func saveStrengthRoutine(
        _ routine: StrengthRoutineRow,
        exercises: [StrengthRoutineExerciseRow]
    ) async throws -> StrengthRoutineSnapshot {
        let cleanRoutine = try StrengthTrainingContract.validated(routine)
        let cleanExercises = try exercises.map(StrengthTrainingContract.validated)
        guard cleanExercises.allSatisfy({ $0.routineId == cleanRoutine.id }) else {
            throw StrengthTrainingContract.ValidationError.invalidRoutineExercise
        }
        return try syncWrite { db in
            try ensureStrengthExerciseIDsExist(db, ids: cleanExercises.map(\.exerciseId))
            try db.execute(sql: """
                INSERT INTO strengthRoutine
                    (id, name, note, scheduledWeekdaysJSON, archivedAt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    note = excluded.note,
                    scheduledWeekdaysJSON = excluded.scheduledWeekdaysJSON,
                    archivedAt = excluded.archivedAt,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    cleanRoutine.id, cleanRoutine.name, cleanRoutine.note,
                    cleanRoutine.scheduledWeekdaysJSON, cleanRoutine.archivedAt,
                    cleanRoutine.createdAt, cleanRoutine.updatedAt,
                ])
            try db.execute(sql: "DELETE FROM strengthRoutineExercise WHERE routineId = ?",
                           arguments: [cleanRoutine.id])
            for row in cleanExercises.sorted(by: { ($0.position, $0.id) < ($1.position, $1.id) }) {
                try insertStrengthRoutineExercise(db, row: row)
            }
            return StrengthRoutineSnapshot(routine: cleanRoutine, exercises: cleanExercises)
        }
    }

    public func strengthRoutines(includeArchived: Bool = false) async throws -> [StrengthRoutineSnapshot] {
        try syncRead { db in
            let routines = try Row.fetchAll(db, sql: """
                SELECT * FROM strengthRoutine
                \(includeArchived ? "" : "WHERE archivedAt IS NULL")
                ORDER BY updatedAt DESC, name COLLATE NOCASE ASC, id ASC
                """).map(StrengthRoutineRow.decode)
            return try routines.map { routine in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM strengthRoutineExercise
                    WHERE routineId = ? ORDER BY position ASC, id ASC
                    """, arguments: [routine.id]).map(StrengthRoutineExerciseRow.decode)
                return StrengthRoutineSnapshot(routine: routine, exercises: rows)
            }
        }
    }

    /// Save or edit a session and replace its draft/completed sets atomically. A nil `endedAt` keeps the
    /// session resumable after an app restart; completing a set never relies on background execution.
    @discardableResult
    public func saveStrengthSession(
        _ session: StrengthSessionRow,
        sets: [StrengthSetRow]
    ) async throws -> StrengthSessionSnapshot {
        let cleanSession = try StrengthTrainingContract.validated(session)
        let cleanSets = try sets.map(StrengthTrainingContract.validated)
        guard cleanSets.allSatisfy({ $0.sessionId == cleanSession.id }) else {
            throw StrengthTrainingContract.ValidationError.invalidSet
        }
        return try syncWrite { db in
            try ensureStrengthExerciseIDsExist(db, ids: cleanSets.map(\.exerciseId))
            if let routineId = cleanSession.routineId {
                guard try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM strengthRoutine WHERE id = ?",
                    arguments: [routineId]
                ) == 1 else { throw StrengthTrainingContract.ValidationError.invalidSession }
            }
            try db.execute(sql: """
                INSERT INTO strengthSession
                    (id, routineId, name, startedAt, endedAt, note, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    routineId = excluded.routineId,
                    name = excluded.name,
                    startedAt = excluded.startedAt,
                    endedAt = excluded.endedAt,
                    note = excluded.note,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    cleanSession.id, cleanSession.routineId, cleanSession.name,
                    cleanSession.startedAt, cleanSession.endedAt, cleanSession.note,
                    cleanSession.createdAt, cleanSession.updatedAt,
                ])
            try db.execute(sql: "DELETE FROM strengthSet WHERE sessionId = ?",
                           arguments: [cleanSession.id])
            for row in cleanSets.sorted(by: {
                ($0.exercisePosition, $0.setPosition, $0.id)
                    < ($1.exercisePosition, $1.setPosition, $1.id)
            }) {
                try insertStrengthSet(db, row: row)
            }
            return StrengthSessionSnapshot(session: cleanSession, sets: cleanSets)
        }
    }

    public func strengthSessions(
        from: Int = 0,
        to: Int = Int.max,
        includeInProgress: Bool = true
    ) async throws -> [StrengthSessionSnapshot] {
        try syncRead { db in
            let sessions = try Row.fetchAll(db, sql: """
                SELECT * FROM strengthSession
                WHERE startedAt >= ? AND startedAt <= ?
                  \(includeInProgress ? "" : "AND endedAt IS NOT NULL")
                ORDER BY startedAt DESC, id ASC
                """, arguments: [from, to]).map(StrengthSessionRow.decode)
            return try sessions.map { session in
                let sets = try Row.fetchAll(db, sql: """
                    SELECT * FROM strengthSet WHERE sessionId = ?
                    ORDER BY exercisePosition ASC, setPosition ASC, id ASC
                    """, arguments: [session.id]).map(StrengthSetRow.decode)
                return StrengthSessionSnapshot(session: session, sets: sets)
            }
        }
    }

    @discardableResult
    public func deleteStrengthSession(id: String) async throws -> Bool {
        try syncWrite { db in
            guard try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM strengthSession WHERE id = ?", arguments: [id]
            ) == 1 else { return false }
            try db.execute(sql: "DELETE FROM strengthSet WHERE sessionId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM strengthSession WHERE id = ?", arguments: [id])
            return true
        }
    }

    /// Honest range summary. `loadedVolumeKg` includes only completed sets that contain BOTH reps and
    /// external load. Bodyweight/timed sets still count as sets/reps but do not fabricate tonnage.
    public func strengthSummary(from: Int, to: Int) async throws -> StrengthSummary {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(DISTINCT s.id) AS sessionCount,
                    COUNT(st.id) AS completedSetCount,
                    COALESCE(SUM(st.reps), 0) AS totalReps,
                    COALESCE(SUM(CASE WHEN st.loadKg IS NOT NULL AND st.reps IS NOT NULL
                                      THEN st.loadKg * st.reps ELSE 0 END), 0) AS loadedVolumeKg,
                    COALESCE(SUM(CASE WHEN st.loadKg IS NOT NULL AND st.reps IS NOT NULL
                                      THEN 1 ELSE 0 END), 0) AS loadedVolumeSetCount
                FROM strengthSession s
                LEFT JOIN strengthSet st ON st.sessionId = s.id
                    AND st.completedAt IS NOT NULL AND st.setType <> 'warmup'
                WHERE s.startedAt >= ? AND s.startedAt <= ? AND s.endedAt IS NOT NULL
                """, arguments: [from, to])
            return StrengthSummary(
                sessionCount: row?["sessionCount"] ?? 0,
                completedSetCount: row?["completedSetCount"] ?? 0,
                totalReps: row?["totalReps"] ?? 0,
                loadedVolumeKg: row?["loadedVolumeKg"] ?? 0,
                loadedVolumeSetCount: row?["loadedVolumeSetCount"] ?? 0
            )
        }
    }

    /// Factual per-exercise records only: heaviest external load, most reps, and largest loaded set
    /// volume. This deliberately does not claim an estimated one-rep max.
    public func strengthExerciseProgress(exerciseId: String) async throws -> StrengthExerciseProgress {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS completedSetCount,
                    MAX(loadKg) AS maxLoadKg,
                    MAX(reps) AS maxReps,
                    MAX(CASE WHEN loadKg IS NOT NULL AND reps IS NOT NULL
                             THEN loadKg * reps END) AS bestSetVolumeKg
                FROM strengthSet
                WHERE exerciseId = ? AND completedAt IS NOT NULL AND setType <> 'warmup'
                """, arguments: [exerciseId])
            return StrengthExerciseProgress(
                exerciseId: exerciseId,
                completedSetCount: row?["completedSetCount"] ?? 0,
                maxLoadKg: row?["maxLoadKg"],
                maxReps: row?["maxReps"],
                bestSetVolumeKg: row?["bestSetVolumeKg"]
            )
        }
    }

    private func ensureStrengthExerciseIDsExist(_ db: Database, ids: [String]) throws {
        for id in Set(ids) {
            guard try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM strengthExercise WHERE id = ?", arguments: [id]
            ) == 1 else { throw StrengthTrainingContract.ValidationError.invalidSet }
        }
    }

    private func insertStrengthRoutineExercise(_ db: Database, row: StrengthRoutineExerciseRow) throws {
        try db.execute(sql: """
            INSERT INTO strengthRoutineExercise
                (id, routineId, exerciseId, position, targetSets, targetRepsMin, targetRepsMax,
                 targetRPE, restSeconds, note, planJSON, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                row.id, row.routineId, row.exerciseId, row.position, row.targetSets,
                row.targetRepsMin, row.targetRepsMax, row.targetRPE, row.restSeconds, row.note,
                row.planJSON, row.createdAt, row.updatedAt,
            ])
    }

    private func insertStrengthSet(_ db: Database, row: StrengthSetRow) throws {
        try db.execute(sql: """
            INSERT INTO strengthSet
                (id, sessionId, exerciseId, exercisePosition, setPosition, setType, reps,
                 loadKg, durationS, rpe, restSeconds, completedAt, note, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                row.id, row.sessionId, row.exerciseId, row.exercisePosition, row.setPosition,
                row.setType, row.reps, row.loadKg, row.durationS, row.rpe, row.restSeconds,
                row.completedAt, row.note, row.createdAt, row.updatedAt,
            ])
    }
}
