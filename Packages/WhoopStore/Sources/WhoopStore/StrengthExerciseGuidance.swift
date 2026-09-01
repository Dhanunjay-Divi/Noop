import Foundation

/// NOOP-owned movement vocabulary for the native exercise demonstrator.
///
/// This intentionally describes motion rather than media filenames. Apple and Android render the
/// same profiles with native drawing, so the workout remains offline and does not depend on the
/// third-party exercise images shipped by OpenGym.
public enum StrengthExerciseMotionProfile: String, CaseIterable, Codable, Sendable {
    case squat
    case legPress
    case deadlift
    case hipThrust
    case lunge
    case benchPress
    case pushUp
    case chestFly
    case overheadPress
    case lateralRaise
    case rearDeltFly
    case row
    case pullUp
    case latPulldown
    case bandPullApart
    case curl
    case tricepsPushdown
    case tricepsExtension
    case skullCrusher
    case dip
    case legExtension
    case legCurl
    case calfRaise
    case plank
    case sidePlank
    case hangingLegRaise
    case cableCrunch
    case abRollout
    case carry
    case kettlebellSwing
    case backExtension
    case run
    case cycle
    case rowingErgometer
    case stairClimb
    case generic
}

/// Stable visual identities for every exercise in NOOP's built-in catalog.
///
/// The raw value deliberately matches the persisted exercise id. Renderers use this identity to
/// specialize stance, equipment, camera angle, and motion while custom exercises continue to use a
/// semantic motion-profile fallback.
public enum StrengthExerciseAnimationVariant: String, CaseIterable, Codable, Sendable {
    case backSquat = "barbell_back_squat"
    case benchPress = "barbell_bench_press"
    case deadlift = "conventional_deadlift"
    case overheadPress = "overhead_press"
    case bentOverRow = "bent_over_row"
    case pullUp = "pull_up"
    case latPulldown = "lat_pulldown"
    case legPress = "leg_press"
    case romanianDeadlift = "romanian_deadlift"
    case dumbbellLunge = "dumbbell_lunge"
    case bicepsCurl = "biceps_curl"
    case tricepsPushdown = "triceps_pushdown"
    case plank
    case frontSquat = "barbell_front_squat"
    case gobletSquat = "goblet_squat"
    case hackSquat = "hack_squat"
    case legExtension = "leg_extension"
    case lyingLegCurl = "lying_leg_curl"
    case hipThrust = "barbell_hip_thrust"
    case gluteBridge = "glute_bridge"
    case bulgarianSplitSquat = "bulgarian_split_squat"
    case walkingLunge = "walking_lunge"
    case standingCalfRaise = "standing_calf_raise"
    case seatedCalfRaise = "seated_calf_raise"
    case inclineBenchPress = "incline_barbell_bench_press"
    case dumbbellBenchPress = "dumbbell_bench_press"
    case pushUp = "push_up"
    case chestFly = "chest_fly"
    case cableCrossover = "cable_crossover"
    case machineChestPress = "machine_chest_press"
    case oneArmDumbbellRow = "one_arm_dumbbell_row"
    case seatedCableRow = "seated_cable_row"
    case chestSupportedRow = "chest_supported_row"
    case chinUp = "chin_up"
    case facePull = "face_pull"
    case dumbbellShoulderPress = "dumbbell_shoulder_press"
    case lateralRaise = "lateral_raise"
    case rearDeltFly = "rear_delt_fly"
    case hammerCurl = "hammer_curl"
    case preacherCurl = "preacher_curl"
    case skullCrusher = "skull_crusher"
    case overheadTricepsExtension = "overhead_triceps_extension"
    case dip = "parallel_bar_dip"
    case hangingLegRaise = "hanging_leg_raise"
    case cableCrunch = "cable_crunch"
    case sidePlank = "side_plank"
    case abWheelRollout = "ab_wheel_rollout"
    case farmersCarry = "farmers_carry"
    case kettlebellSwing = "kettlebell_swing"
    case backExtension = "back_extension"
    case bandPullApart = "band_pull_apart"
    case resistanceBandRow = "resistance_band_row"
    case treadmillRun = "treadmill_run"
    case indoorCycling = "indoor_cycling"
    case rowingErgometer = "rowing_ergometer"
    case stairClimber = "stair_climber"
}

public struct StrengthExerciseGuide: Equatable, Sendable {
    public let profile: StrengthExerciseMotionProfile
    public let animationVariant: StrengthExerciseAnimationVariant?
    public let cycleDuration: TimeInterval
    public let isExerciseSpecific: Bool

    public init(
        profile: StrengthExerciseMotionProfile,
        animationVariant: StrengthExerciseAnimationVariant?,
        cycleDuration: TimeInterval,
        isExerciseSpecific: Bool
    ) {
        self.profile = profile
        self.animationVariant = animationVariant
        self.cycleDuration = cycleDuration
        self.isExerciseSpecific = isExerciseSpecific
    }
}

public enum StrengthExerciseGuidance {
    public static func guide(for exercise: StrengthExerciseRow) -> StrengthExerciseGuide {
        let animationVariant = exercise.isCustom
            ? nil
            : StrengthExerciseAnimationVariant(rawValue: exercise.id)
        let profile = exercise.isCustom
            ? fallbackProfile(for: exercise)
            : builtInProfile(for: exercise)
        return StrengthExerciseGuide(
            profile: profile,
            animationVariant: animationVariant,
            cycleDuration: cycleDuration(for: profile),
            isExerciseSpecific: animationVariant != nil && profile != .generic
        )
    }

    private static func builtInProfile(
        for exercise: StrengthExerciseRow
    ) -> StrengthExerciseMotionProfile {
        switch exercise.id {
        case "barbell_back_squat", "barbell_front_squat", "goblet_squat", "hack_squat":
            return .squat
        case "leg_press":
            return .legPress
        case "conventional_deadlift", "romanian_deadlift":
            return .deadlift
        case "barbell_hip_thrust", "glute_bridge":
            return .hipThrust
        case "dumbbell_lunge", "bulgarian_split_squat", "walking_lunge":
            return .lunge
        case "barbell_bench_press", "incline_barbell_bench_press",
             "dumbbell_bench_press", "machine_chest_press":
            return .benchPress
        case "push_up":
            return .pushUp
        case "chest_fly", "cable_crossover":
            return .chestFly
        case "overhead_press", "dumbbell_shoulder_press":
            return .overheadPress
        case "lateral_raise":
            return .lateralRaise
        case "rear_delt_fly", "face_pull":
            return .rearDeltFly
        case "bent_over_row", "one_arm_dumbbell_row", "seated_cable_row",
             "chest_supported_row", "resistance_band_row":
            return .row
        case "pull_up", "chin_up":
            return .pullUp
        case "lat_pulldown":
            return .latPulldown
        case "band_pull_apart":
            return .bandPullApart
        case "biceps_curl", "hammer_curl", "preacher_curl":
            return .curl
        case "triceps_pushdown":
            return .tricepsPushdown
        case "overhead_triceps_extension":
            return .tricepsExtension
        case "skull_crusher":
            return .skullCrusher
        case "parallel_bar_dip":
            return .dip
        case "leg_extension":
            return .legExtension
        case "lying_leg_curl":
            return .legCurl
        case "standing_calf_raise", "seated_calf_raise":
            return .calfRaise
        case "plank":
            return .plank
        case "side_plank":
            return .sidePlank
        case "hanging_leg_raise":
            return .hangingLegRaise
        case "cable_crunch":
            return .cableCrunch
        case "ab_wheel_rollout":
            return .abRollout
        case "farmers_carry":
            return .carry
        case "kettlebell_swing":
            return .kettlebellSwing
        case "back_extension":
            return .backExtension
        case "treadmill_run":
            return .run
        case "indoor_cycling":
            return .cycle
        case "rowing_ergometer":
            return .rowingErgometer
        case "stair_climber":
            return .stairClimb
        default:
            return fallbackProfile(for: exercise)
        }
    }

    private static func fallbackProfile(
        for exercise: StrengthExerciseRow
    ) -> StrengthExerciseMotionProfile {
        switch exercise.movementPattern {
        case "squat": return .squat
        case "hinge": return .deadlift
        case "lunge": return .lunge
        case "horizontal_push": return exercise.equipment == "bodyweight" ? .pushUp : .benchPress
        case "vertical_push": return .overheadPress
        case "horizontal_pull": return .row
        case "vertical_pull": return exercise.equipment == "bodyweight" ? .pullUp : .latPulldown
        case "carry": return .carry
        case "cardio": return .run
        default: return .generic
        }
    }

    private static func cycleDuration(
        for profile: StrengthExerciseMotionProfile
    ) -> TimeInterval {
        switch profile {
        case .run, .cycle, .rowingErgometer, .stairClimb, .carry:
            return 1.6
        case .kettlebellSwing:
            return 2.0
        case .plank, .sidePlank:
            return 3.2
        case .generic:
            return 3.0
        default:
            return 2.6
        }
    }
}
