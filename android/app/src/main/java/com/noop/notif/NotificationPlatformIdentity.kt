package com.noop.notif

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * App-wide allocation for platform notification and activity PendingIntent identities.
 *
 * Android compares PendingIntents without considering extras. Distinct request codes and actions keep
 * one notification from replacing another notification's route while FLAG_UPDATE_CURRENT is in use.
 */
internal object NotificationPlatformIdentity {
    object NotificationId {
        const val CONNECTION_SERVICE = 4_201
        const val ILLNESS_CHECK_IN = 4_202
        const val INACTIVITY = 4_203
        const val BAND_SMART_ALARM = 4_204
        const val BATTERY_RUNTIME = 4_205
        const val BATTERY_LOW = 4_206
        const val BATTERY_FULL = 4_207
        const val MORNING_REPORT = 4_208
        const val WORKOUT_REPORT = 4_209
        const val STRAIN_TARGET = 4_210
        const val AUTO_WORKOUT = 4_211
        const val CONTEXTUAL_VITAL = 4_212
        const val SAFETY_SOS_RESULT = 4_213
        const val HYDRATION = 4_214
        const val PHONE_SMART_ALARM = 4_307
        const val WIND_DOWN = 4_311
        const val SAFETY_CHECK_IN = 4_315
        const val SAFETY_CONTACT_SETUP = 4_316
        const val COACH_CHECK_IN = 4_318
        const val STALE_SYNC = 4_319
        const val STRESS_BREATHING = 4_320
        const val DAILY_REVIEW_MORNING = 4_321
        const val DAILY_REVIEW_EVENING = 4_322
        const val ADAPTIVE_DAY = 4_323
        const val WORKOUT_CAUTION = 4_324
        const val MANAGED_FRIENDS_POKE = 4_325
        const val MANAGED_SAFETY = 4_326

        internal val all = listOf(
            CONNECTION_SERVICE,
            ILLNESS_CHECK_IN,
            INACTIVITY,
            BAND_SMART_ALARM,
            BATTERY_RUNTIME,
            BATTERY_LOW,
            BATTERY_FULL,
            MORNING_REPORT,
            WORKOUT_REPORT,
            STRAIN_TARGET,
            AUTO_WORKOUT,
            CONTEXTUAL_VITAL,
            SAFETY_SOS_RESULT,
            HYDRATION,
            PHONE_SMART_ALARM,
            WIND_DOWN,
            SAFETY_CHECK_IN,
            SAFETY_CONTACT_SETUP,
            COACH_CHECK_IN,
            STALE_SYNC,
            STRESS_BREATHING,
            DAILY_REVIEW_MORNING,
            DAILY_REVIEW_EVENING,
            ADAPTIVE_DAY,
            WORKOUT_CAUTION,
            MANAGED_FRIENDS_POKE,
            MANAGED_SAFETY,
        )
    }

    data class ActivityIntentIdentity(
        val requestCode: Int,
        val action: String,
    )

    object ActivityIntent {
        val CONNECTION_SERVICE = identity(5_101, "connection")
        val ILLNESS_CHECK_IN = identity(5_102, "illness_check_in")
        val INACTIVITY = identity(5_103, "inactivity")
        val BAND_SMART_ALARM = identity(5_104, "band_smart_alarm")
        val BATTERY_RUNTIME = identity(5_105, "battery_runtime")
        val BATTERY_LOW = identity(5_106, "battery_low")
        val BATTERY_FULL = identity(5_107, "battery_full")
        val MORNING_REPORT = identity(5_108, "morning_report")
        val WORKOUT_REPORT = identity(5_109, "workout_report")
        val STRAIN_TARGET = identity(5_110, "strain_target")
        val AUTO_WORKOUT = identity(5_111, "auto_workout")
        val CONTEXTUAL_VITAL = identity(5_112, "contextual_vital")
        val SAFETY_SOS_RESULT = identity(5_113, "safety_sos_result")
        val HYDRATION = identity(5_114, "hydration")
        val PHONE_SMART_ALARM = identity(5_115, "phone_smart_alarm")
        val PHONE_SMART_ALARM_SCHEDULE = identity(5_116, "phone_smart_alarm_schedule")
        val PHONE_SMART_ALARM_SNOOZE_SCHEDULE =
            identity(5_117, "phone_smart_alarm_snooze_schedule")
        val WIND_DOWN = identity(5_118, "wind_down")
        val SAFETY_CHECK_IN = identity(5_119, "safety_check_in")
        val SAFETY_CONTACT_SETUP = identity(5_120, "safety_contact_setup")
        val COACH_CHECK_IN = identity(5_121, "coach_check_in")
        val STALE_SYNC = identity(5_122, "stale_sync")
        val STRESS_BREATHING = identity(5_123, "stress_breathing")
        val DAILY_REVIEW_MORNING = identity(5_124, "daily_review_morning")
        val DAILY_REVIEW_EVENING = identity(5_125, "daily_review_evening")
        val ADAPTIVE_DAY = identity(5_126, "adaptive_day")
        val WORKOUT_CAUTION = identity(5_127, "workout_caution")
        val MANAGED_FRIENDS_POKE = identity(5_128, "managed_friends_poke")
        val MANAGED_SAFETY = identity(5_129, "managed_safety")

        internal val all = listOf(
            CONNECTION_SERVICE,
            ILLNESS_CHECK_IN,
            INACTIVITY,
            BAND_SMART_ALARM,
            BATTERY_RUNTIME,
            BATTERY_LOW,
            BATTERY_FULL,
            MORNING_REPORT,
            WORKOUT_REPORT,
            STRAIN_TARGET,
            AUTO_WORKOUT,
            CONTEXTUAL_VITAL,
            SAFETY_SOS_RESULT,
            HYDRATION,
            PHONE_SMART_ALARM,
            PHONE_SMART_ALARM_SCHEDULE,
            PHONE_SMART_ALARM_SNOOZE_SCHEDULE,
            WIND_DOWN,
            SAFETY_CHECK_IN,
            SAFETY_CONTACT_SETUP,
            COACH_CHECK_IN,
            STALE_SYNC,
            STRESS_BREATHING,
            DAILY_REVIEW_MORNING,
            DAILY_REVIEW_EVENING,
            ADAPTIVE_DAY,
            WORKOUT_CAUTION,
            MANAGED_FRIENDS_POKE,
            MANAGED_SAFETY,
        )
    }

    fun activityPendingIntent(
        context: Context,
        identity: ActivityIntentIdentity,
        launchIntent: Intent,
        instanceKey: String? = null,
    ): PendingIntent = PendingIntent.getActivity(
        context,
        identity.requestCode,
        launchIntent.setAction(
            instanceKey?.let {
                instanceIdentity(identity, it).action
            } ?: identity.action,
        ),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    internal fun instanceIdentity(
        identity: ActivityIntentIdentity,
        instanceKey: String,
    ): ActivityIntentIdentity {
        require(instanceKey.matches(Regex("^[a-z0-9-]{1,64}$")))
        return identity.copy(action = "${identity.action}.instance.$instanceKey")
    }

    private fun identity(requestCode: Int, name: String) = ActivityIntentIdentity(
        requestCode = requestCode,
        action = "com.noop.notification.action.open.$name",
    )
}
