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

public struct StrengthExerciseGuide: Equatable, Sendable {
    public let profile: StrengthExerciseMotionProfile
    public let cycleDuration: TimeInterval
    public let isExerciseSpecific: Bool

    public init(
        profile: StrengthExerciseMotionProfile,
        cycleDuration: TimeInterval,
        isExerciseSpecific: Bool
    ) {
        self.profile = profile
        self.cycleDuration = cycleDuration
        self.isExerciseSpecific = isExerciseSpecific
    }
}

public enum StrengthExerciseGuidance {
    public static func guide(for exercise: StrengthExerciseRow) -> StrengthExerciseGuide {
        let profile = exercise.isCustom
            ? fallbackProfile(for: exercise)
            : builtInProfile(for: exercise)
        return StrengthExerciseGuide(
            profile: profile,
            cycleDuration: cycleDuration(for: profile),
            isExerciseSpecific: !exercise.isCustom && profile != .generic
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
