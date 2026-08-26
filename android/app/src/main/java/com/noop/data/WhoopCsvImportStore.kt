package com.noop.data

/** Stable ownership marker for workouts projected from an official wearable CSV. */
internal const val WHOOP_CSV_IMPORTED_WORKOUT_SOURCE = "my-whoop"

/** One authoritative metric-series range represented by an official CSV export. */
data class WhoopCsvMetricSeriesReplacement(
    val deviceId: String,
    val fromDay: String,
    val toDay: String,
    val managedKeys: List<String>,
    val rows: List<MetricSeriesRow>,
)

/** One authoritative journal range represented by an official CSV export. */
data class WhoopCsvJournalReplacement(
    val deviceId: String,
    val fromDay: String,
    val toDay: String,
    val rows: List<JournalEntry>,
)

/** Inclusive day span owned by one official CSV projection. */
data class WhoopCsvDayRange(
    val deviceId: String,
    val fromDay: String,
    val toDay: String,
)

/** Inclusive timestamp span owned by one official CSV projection. */
data class WhoopCsvTimestampRange(
    val deviceId: String,
    val fromTs: Long,
    val toTs: Long,
)

/** Device row created as part of the same Room commit as its imported archive rows. */
data class WhoopCsvDeviceRegistration(
    val id: String,
    val name: String?,
)

/**
 * Complete relational projection of one parsed CSV bundle.
 *
 * Official cycle rows remain authoritative. Sleep-only and local/approximate daily rows fill null
 * fields and absent rows; other local projections are insert-only because their `-noop` namespace is
 * also owned by on-device analytics.
 */
data class WhoopCsvImportBatch(
    val officialDailyMetrics: List<DailyMetric> = emptyList(),
    val officialDailyMetricRange: WhoopCsvDayRange? = null,
    val fillOnlyDailyMetrics: List<DailyMetric> = emptyList(),
    val officialSleepSessions: List<SleepSession> = emptyList(),
    val officialSleepSessionRange: WhoopCsvTimestampRange? = null,
    val fillOnlySleepSessions: List<SleepSession> = emptyList(),
    val officialMetricSeriesReplacements: List<WhoopCsvMetricSeriesReplacement> = emptyList(),
    val fillOnlyMetricSeries: List<MetricSeriesRow> = emptyList(),
    val journalReplacement: WhoopCsvJournalReplacement? = null,
    val officialWorkouts: List<WorkoutRow> = emptyList(),
    val officialWorkoutRange: WhoopCsvTimestampRange? = null,
    val officialWorkoutSource: String = WHOOP_CSV_IMPORTED_WORKOUT_SOURCE,
    val fillOnlyWorkouts: List<WorkoutRow> = emptyList(),
)

/**
 * Apply an authoritative sleep import without destroying local evidence or a user's corrections.
 *
 * A user edit makes the complete existing row authoritative: bounds, stages, efficiency, vitals,
 * and local evidence stay coherent instead of mixing measurements from a different provider
 * window. Unedited rows may refresh provider fields while retaining locally derived motion/state.
 */
internal fun mergeOfficialSleepSession(
    existing: SleepSession?,
    incoming: SleepSession,
): SleepSession {
    if (existing == null) return incoming
    require(existing.deviceId == incoming.deviceId && existing.startTs == incoming.startTs) {
        "Sleep import merge requires identical natural keys"
    }
    if (existing.userEdited) return existing
    return incoming.copy(
        motionJSON = existing.motionJSON,
        sleepStateJSON = existing.sleepStateJSON,
    )
}

/**
 * Merge approximate daily rows without replacing any non-null value already owned by analytics.
 *
 * [existing] may cover a wider queried range; only natural keys touched by [incoming] are returned.
 * Repeated incoming keys merge cumulatively in source order.
 */
internal fun mergeFillOnlyDailyMetrics(
    existing: List<DailyMetric>,
    incoming: List<DailyMetric>,
): List<DailyMetric> {
    val existingByKey = existing.associateBy { it.deviceId to it.day }
    val mergedByKey = linkedMapOf<Pair<String, String>, DailyMetric>()
    for (row in incoming) {
        val key = row.deviceId to row.day
        val current = mergedByKey[key] ?: existingByKey[key]
        mergedByKey[key] = current?.fillNullFieldsFrom(row) ?: row
    }
    return mergedByKey.values.toList()
}

private fun DailyMetric.fillNullFieldsFrom(incoming: DailyMetric): DailyMetric = copy(
    totalSleepMin = totalSleepMin ?: incoming.totalSleepMin,
    efficiency = efficiency ?: incoming.efficiency,
    deepMin = deepMin ?: incoming.deepMin,
    remMin = remMin ?: incoming.remMin,
    lightMin = lightMin ?: incoming.lightMin,
    disturbances = disturbances ?: incoming.disturbances,
    restingHr = restingHr ?: incoming.restingHr,
    avgHrv = avgHrv ?: incoming.avgHrv,
    recovery = recovery ?: incoming.recovery,
    strain = strain ?: incoming.strain,
    exerciseCount = exerciseCount ?: incoming.exerciseCount,
    spo2Pct = spo2Pct ?: incoming.spo2Pct,
    skinTempDevC = skinTempDevC ?: incoming.skinTempDevC,
    respRateBpm = respRateBpm ?: incoming.respRateBpm,
    steps = steps ?: incoming.steps,
    activeKcalEst = activeKcalEst ?: incoming.activeKcalEst,
    spo2Red = spo2Red ?: incoming.spo2Red,
    spo2Ir = spo2Ir ?: incoming.spo2Ir,
)
