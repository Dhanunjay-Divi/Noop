package com.noop.data

/**
 * Which independently-owned Health Connect projections may be replaced in one reconciliation.
 * A false flag means the user did not grant that record type; the existing local value is preserved.
 */
data class HealthConnectProjectionScope(
    val steps: Boolean = false,
    val totalCalories: Boolean = false,
    val activeCalories: Boolean = false,
    val heartRate: Boolean = false,
    val restingHeartRate: Boolean = false,
    val hrv: Boolean = false,
    val sleep: Boolean = false,
    val oxygenSaturation: Boolean = false,
    val respiratoryRate: Boolean = false,
    val vo2Max: Boolean = false,
    val weight: Boolean = false,
    val bodyFat: Boolean = false,
    val leanBodyMass: Boolean = false,
    val bodyTemperature: Boolean = false,
    val basalBodyTemperature: Boolean = false,
    val exercise: Boolean = false,
    val distance: Boolean = false,
) {
    val seriesKeys: Set<String>
        get() = buildSet {
            if (weight) addAll(listOf("weight", "bmi"))
            if (bodyFat) add("body_fat")
            if (leanBodyMass) add("lean_mass")
            if (bodyTemperature) add("body_temp")
            if (basalBodyTemperature) add("basal_body_temp")
        }
}

/** Pure, deterministic merge used by the Room transaction and JVM tests. */
internal object HealthConnectProjectionMerge {
    /** Manual imports are additive: a missing field never erases a value imported earlier. */
    fun appleDailyAdditive(
        existing: List<AppleDaily>,
        incoming: List<AppleDaily>,
    ): List<AppleDaily> {
        val oldByDay = existing.associateBy { it.day }
        return incoming.map { fresh ->
            val old = oldByDay[fresh.day]
            fresh.copy(
                steps = fresh.steps ?: old?.steps,
                activeKcal = fresh.activeKcal ?: old?.activeKcal,
                basalKcal = fresh.basalKcal ?: old?.basalKcal,
                vo2max = fresh.vo2max ?: old?.vo2max,
                avgHr = fresh.avgHr ?: old?.avgHr,
                maxHr = fresh.maxHr ?: old?.maxHr,
                walkingHr = fresh.walkingHr ?: old?.walkingHr,
                weightKg = fresh.weightKg ?: old?.weightKg,
            )
        }
    }

    /** Manual imports are additive: a sparse day never nulls another granted or ungranted signal. */
    fun dailyMetricsAdditive(
        existing: List<DailyMetric>,
        incoming: List<DailyMetric>,
    ): List<DailyMetric> {
        val oldByDay = existing.associateBy { it.day }
        return incoming.map { fresh ->
            val old = oldByDay[fresh.day]
            fresh.copy(
                totalSleepMin = fresh.totalSleepMin ?: old?.totalSleepMin,
                efficiency = fresh.efficiency ?: old?.efficiency,
                deepMin = fresh.deepMin ?: old?.deepMin,
                remMin = fresh.remMin ?: old?.remMin,
                lightMin = fresh.lightMin ?: old?.lightMin,
                disturbances = fresh.disturbances ?: old?.disturbances,
                restingHr = fresh.restingHr ?: old?.restingHr,
                avgHrv = fresh.avgHrv ?: old?.avgHrv,
                recovery = fresh.recovery ?: old?.recovery,
                strain = fresh.strain ?: old?.strain,
                exerciseCount = fresh.exerciseCount ?: old?.exerciseCount,
                spo2Pct = fresh.spo2Pct ?: old?.spo2Pct,
                skinTempDevC = fresh.skinTempDevC ?: old?.skinTempDevC,
                respRateBpm = fresh.respRateBpm ?: old?.respRateBpm,
                steps = fresh.steps ?: old?.steps,
                activeKcalEst = fresh.activeKcalEst ?: old?.activeKcalEst,
                spo2Red = fresh.spo2Red ?: old?.spo2Red,
                spo2Ir = fresh.spo2Ir ?: old?.spo2Ir,
            )
        }
    }

    fun appleDaily(
        source: String,
        existing: List<AppleDaily>,
        incoming: List<AppleDaily>,
        scope: HealthConnectProjectionScope,
    ): List<AppleDaily> {
        val oldByDay = existing.associateBy { it.day }
        val newByDay = incoming.associateBy { it.day }
        return (oldByDay.keys + newByDay.keys).sorted().mapNotNull { day ->
            val old = oldByDay[day]
            val fresh = newByDay[day]
            val row = AppleDaily(
                deviceId = source,
                day = day,
                steps = if (scope.steps) fresh?.steps else old?.steps,
                activeKcal = if (scope.activeCalories) fresh?.activeKcal else old?.activeKcal,
                // Basal is total-active. Replacing it from a partial permission set can fabricate a
                // value, so it is refreshed only when both inputs were readable.
                basalKcal = if (scope.totalCalories && scope.activeCalories) fresh?.basalKcal else old?.basalKcal,
                vo2max = if (scope.vo2Max) fresh?.vo2max else old?.vo2max,
                avgHr = if (scope.heartRate) fresh?.avgHr else old?.avgHr,
                maxHr = old?.maxHr,
                walkingHr = old?.walkingHr,
                weightKg = if (scope.weight) fresh?.weightKg else old?.weightKg,
            )
            row.takeIf {
                it.steps != null || it.activeKcal != null || it.basalKcal != null || it.vo2max != null ||
                    it.avgHr != null || it.maxHr != null || it.walkingHr != null || it.weightKg != null
            }
        }
    }

    fun dailyMetrics(
        source: String,
        existing: List<DailyMetric>,
        incoming: List<DailyMetric>,
        scope: HealthConnectProjectionScope,
    ): List<DailyMetric> {
        val oldByDay = existing.associateBy { it.day }
        val newByDay = incoming.associateBy { it.day }
        return (oldByDay.keys + newByDay.keys).sorted().mapNotNull { day ->
            val old = oldByDay[day]
            val fresh = newByDay[day]
            val row = DailyMetric(
                deviceId = source,
                day = day,
                totalSleepMin = if (scope.sleep) fresh?.totalSleepMin else old?.totalSleepMin,
                efficiency = old?.efficiency,
                deepMin = old?.deepMin,
                remMin = old?.remMin,
                lightMin = old?.lightMin,
                disturbances = old?.disturbances,
                restingHr = if (scope.restingHeartRate) fresh?.restingHr else old?.restingHr,
                avgHrv = if (scope.hrv) fresh?.avgHrv else old?.avgHrv,
                recovery = old?.recovery,
                strain = old?.strain,
                exerciseCount = if (scope.exercise) fresh?.exerciseCount else old?.exerciseCount,
                spo2Pct = if (scope.oxygenSaturation) fresh?.spo2Pct else old?.spo2Pct,
                skinTempDevC = old?.skinTempDevC,
                respRateBpm = if (scope.respiratoryRate) fresh?.respRateBpm else old?.respRateBpm,
                steps = old?.steps,
                activeKcalEst = old?.activeKcalEst,
                spo2Red = old?.spo2Red,
                spo2Ir = old?.spo2Ir,
            )
            row.takeIf {
                listOf(
                    it.totalSleepMin, it.efficiency, it.deepMin, it.remMin, it.lightMin,
                    it.disturbances, it.restingHr, it.avgHrv, it.recovery, it.strain,
                    it.exerciseCount, it.spo2Pct, it.skinTempDevC, it.respRateBpm,
                    it.steps, it.activeKcalEst, it.spo2Red, it.spo2Ir,
                ).any { value -> value != null }
            }
        }
    }

    fun workouts(
        existing: List<WorkoutRow>,
        incoming: List<WorkoutRow>,
        scope: HealthConnectProjectionScope,
    ): List<WorkoutRow> {
        if (!scope.exercise) return existing
        val oldByKey = existing.associateBy { it.startTs to it.sport }
        return incoming.map { fresh ->
            val old = oldByKey[fresh.startTs to fresh.sport]
            fresh.copy(
                // Total energy alone includes basal expenditure; only Active Calories permission owns
                // the workout-energy projection. Total can refine a value when active is also present.
                energyKcal = if (scope.activeCalories) fresh.energyKcal else old?.energyKcal,
                avgHr = if (scope.heartRate) fresh.avgHr else old?.avgHr,
                maxHr = if (scope.heartRate) fresh.maxHr else old?.maxHr,
                distanceM = if (scope.distance) fresh.distanceM else old?.distanceM,
                strain = fresh.strain ?: old?.strain,
                zonesJSON = fresh.zonesJSON ?: old?.zonesJSON,
                routePolyline = fresh.routePolyline ?: old?.routePolyline,
                steps = fresh.steps ?: old?.steps,
            )
        }
    }

    /** Manual imports update sessions without erasing enrichment absent from this particular read. */
    fun workoutsAdditive(
        existing: List<WorkoutRow>,
        incoming: List<WorkoutRow>,
    ): List<WorkoutRow> {
        val oldByKey = existing.associateBy { it.startTs to it.sport }
        return incoming.map { fresh ->
            val old = oldByKey[fresh.startTs to fresh.sport]
            fresh.copy(
                durationS = fresh.durationS ?: old?.durationS,
                energyKcal = fresh.energyKcal ?: old?.energyKcal,
                avgHr = fresh.avgHr ?: old?.avgHr,
                maxHr = fresh.maxHr ?: old?.maxHr,
                strain = fresh.strain ?: old?.strain,
                distanceM = fresh.distanceM ?: old?.distanceM,
                zonesJSON = fresh.zonesJSON ?: old?.zonesJSON,
                notes = fresh.notes ?: old?.notes,
                routePolyline = fresh.routePolyline ?: old?.routePolyline,
                steps = fresh.steps ?: old?.steps,
            )
        }
    }
}
