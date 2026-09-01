package com.noop.data

/**
 * NOOP-owned movement vocabulary for the native exercise demonstrator.
 *
 * These are semantic motion profiles, not third-party media identifiers. Compose and SwiftUI
 * render matching offline animations from this contract.
 */
enum class StrengthExerciseMotionProfile {
    SQUAT,
    LEG_PRESS,
    DEADLIFT,
    HIP_THRUST,
    LUNGE,
    BENCH_PRESS,
    PUSH_UP,
    CHEST_FLY,
    OVERHEAD_PRESS,
    LATERAL_RAISE,
    REAR_DELT_FLY,
    ROW,
    PULL_UP,
    LAT_PULLDOWN,
    BAND_PULL_APART,
    CURL,
    TRICEPS_PUSHDOWN,
    TRICEPS_EXTENSION,
    SKULL_CRUSHER,
    DIP,
    LEG_EXTENSION,
    LEG_CURL,
    CALF_RAISE,
    PLANK,
    SIDE_PLANK,
    HANGING_LEG_RAISE,
    CABLE_CRUNCH,
    AB_ROLLOUT,
    CARRY,
    KETTLEBELL_SWING,
    BACK_EXTENSION,
    RUN,
    CYCLE,
    ROWING_ERGOMETER,
    STAIR_CLIMB,
    GENERIC,
}

data class StrengthExerciseGuide(
    val profile: StrengthExerciseMotionProfile,
    val cycleDurationSeconds: Float,
    val isExerciseSpecific: Boolean,
)

object StrengthExerciseGuidance {
    fun guide(exercise: StrengthExerciseRow): StrengthExerciseGuide {
        val profile = if (exercise.isCustom) fallbackProfile(exercise) else builtInProfile(exercise)
        return StrengthExerciseGuide(
            profile = profile,
            cycleDurationSeconds = cycleDuration(profile),
            isExerciseSpecific = !exercise.isCustom &&
                profile != StrengthExerciseMotionProfile.GENERIC,
        )
    }

    private fun builtInProfile(exercise: StrengthExerciseRow): StrengthExerciseMotionProfile =
        when (exercise.id) {
            "barbell_back_squat", "barbell_front_squat", "goblet_squat", "hack_squat" ->
                StrengthExerciseMotionProfile.SQUAT
            "leg_press" -> StrengthExerciseMotionProfile.LEG_PRESS
            "conventional_deadlift", "romanian_deadlift" ->
                StrengthExerciseMotionProfile.DEADLIFT
            "barbell_hip_thrust", "glute_bridge" ->
                StrengthExerciseMotionProfile.HIP_THRUST
            "dumbbell_lunge", "bulgarian_split_squat", "walking_lunge" ->
                StrengthExerciseMotionProfile.LUNGE
            "barbell_bench_press", "incline_barbell_bench_press",
            "dumbbell_bench_press", "machine_chest_press" ->
                StrengthExerciseMotionProfile.BENCH_PRESS
            "push_up" -> StrengthExerciseMotionProfile.PUSH_UP
            "chest_fly", "cable_crossover" -> StrengthExerciseMotionProfile.CHEST_FLY
            "overhead_press", "dumbbell_shoulder_press" ->
                StrengthExerciseMotionProfile.OVERHEAD_PRESS
            "lateral_raise" -> StrengthExerciseMotionProfile.LATERAL_RAISE
            "rear_delt_fly", "face_pull" -> StrengthExerciseMotionProfile.REAR_DELT_FLY
            "bent_over_row", "one_arm_dumbbell_row", "seated_cable_row",
            "chest_supported_row", "resistance_band_row" ->
                StrengthExerciseMotionProfile.ROW
            "pull_up", "chin_up" -> StrengthExerciseMotionProfile.PULL_UP
            "lat_pulldown" -> StrengthExerciseMotionProfile.LAT_PULLDOWN
            "band_pull_apart" -> StrengthExerciseMotionProfile.BAND_PULL_APART
            "biceps_curl", "hammer_curl", "preacher_curl" ->
                StrengthExerciseMotionProfile.CURL
            "triceps_pushdown" -> StrengthExerciseMotionProfile.TRICEPS_PUSHDOWN
            "overhead_triceps_extension" -> StrengthExerciseMotionProfile.TRICEPS_EXTENSION
            "skull_crusher" -> StrengthExerciseMotionProfile.SKULL_CRUSHER
            "parallel_bar_dip" -> StrengthExerciseMotionProfile.DIP
            "leg_extension" -> StrengthExerciseMotionProfile.LEG_EXTENSION
            "lying_leg_curl" -> StrengthExerciseMotionProfile.LEG_CURL
            "standing_calf_raise", "seated_calf_raise" ->
                StrengthExerciseMotionProfile.CALF_RAISE
            "plank" -> StrengthExerciseMotionProfile.PLANK
            "side_plank" -> StrengthExerciseMotionProfile.SIDE_PLANK
            "hanging_leg_raise" -> StrengthExerciseMotionProfile.HANGING_LEG_RAISE
            "cable_crunch" -> StrengthExerciseMotionProfile.CABLE_CRUNCH
            "ab_wheel_rollout" -> StrengthExerciseMotionProfile.AB_ROLLOUT
            "farmers_carry" -> StrengthExerciseMotionProfile.CARRY
            "kettlebell_swing" -> StrengthExerciseMotionProfile.KETTLEBELL_SWING
            "back_extension" -> StrengthExerciseMotionProfile.BACK_EXTENSION
            "treadmill_run" -> StrengthExerciseMotionProfile.RUN
            "indoor_cycling" -> StrengthExerciseMotionProfile.CYCLE
            "rowing_ergometer" -> StrengthExerciseMotionProfile.ROWING_ERGOMETER
            "stair_climber" -> StrengthExerciseMotionProfile.STAIR_CLIMB
            else -> fallbackProfile(exercise)
        }

    private fun fallbackProfile(exercise: StrengthExerciseRow): StrengthExerciseMotionProfile =
        when (exercise.movementPattern) {
            "squat" -> StrengthExerciseMotionProfile.SQUAT
            "hinge" -> StrengthExerciseMotionProfile.DEADLIFT
            "lunge" -> StrengthExerciseMotionProfile.LUNGE
            "horizontal_push" -> if (exercise.equipment == "bodyweight") {
                StrengthExerciseMotionProfile.PUSH_UP
            } else {
                StrengthExerciseMotionProfile.BENCH_PRESS
            }
            "vertical_push" -> StrengthExerciseMotionProfile.OVERHEAD_PRESS
            "horizontal_pull" -> StrengthExerciseMotionProfile.ROW
            "vertical_pull" -> if (exercise.equipment == "bodyweight") {
                StrengthExerciseMotionProfile.PULL_UP
            } else {
                StrengthExerciseMotionProfile.LAT_PULLDOWN
            }
            "carry" -> StrengthExerciseMotionProfile.CARRY
            "cardio" -> StrengthExerciseMotionProfile.RUN
            else -> StrengthExerciseMotionProfile.GENERIC
        }

    private fun cycleDuration(profile: StrengthExerciseMotionProfile): Float = when (profile) {
        StrengthExerciseMotionProfile.RUN,
        StrengthExerciseMotionProfile.CYCLE,
        StrengthExerciseMotionProfile.ROWING_ERGOMETER,
        StrengthExerciseMotionProfile.STAIR_CLIMB,
        StrengthExerciseMotionProfile.CARRY,
        -> 1.6f
        StrengthExerciseMotionProfile.KETTLEBELL_SWING -> 2.0f
        StrengthExerciseMotionProfile.PLANK,
        StrengthExerciseMotionProfile.SIDE_PLANK,
        -> 3.2f
        StrengthExerciseMotionProfile.GENERIC -> 3.0f
        else -> 2.6f
    }
}
