package com.noop.analytics

import com.noop.data.HrSample

/**
 * Moderate-to-vigorous activity against the WHO/AHA weekly guideline.
 *
 * One vigorous minute receives two credited minutes, matching the published equivalence of
 * 150 minutes moderate or 75 minutes vigorous. Missing sensor time is never filled.
 */
data class ActiveZoneMinutes(
    val moderateMinutes: Double,
    val vigorousMinutes: Double,
    val weeklyTarget: Double,
    val observedMinutes: Double = moderateMinutes + vigorousMinutes,
) {
    val creditedMinutes: Double = moderateMinutes + 2.0 * vigorousMinutes
    val targetFraction: Double
        get() = if (weeklyTarget > 0) creditedMinutes / weeklyTarget else 0.0
    val meetsWeeklyGuideline: Boolean get() = creditedMinutes >= weeklyTarget
}

object ActiveZoneMinutesCalculator {
    const val DEFAULT_WEEKLY_TARGET: Double = 150.0
    const val MODERATE_ZONE: Int = 3
    const val VIGOROUS_ZONE_FLOOR: Int = 4
    const val MAXIMUM_SAMPLE_GAP_SECONDS: Double = 10.0

    const val MODERATE_SERIES_KEY: String = "active_zone_moderate_min"
    const val VIGOROUS_SERIES_KEY: String = "active_zone_vigorous_min"
    const val CREDITED_SERIES_KEY: String = "active_zone_credited_min"
    const val OBSERVED_SERIES_KEY: String = "active_zone_observed_min"
    val MANAGED_SERIES_KEYS: Set<String> = setOf(
        MODERATE_SERIES_KEY,
        VIGOROUS_SERIES_KEY,
        CREDITED_SERIES_KEY,
        OBSERVED_SERIES_KEY,
    )

    fun minutes(
        timeInZone: TimeInZone?,
        weeklyTarget: Double = DEFAULT_WEEKLY_TARGET,
    ): ActiveZoneMinutes? {
        if (!weeklyTarget.isFinite() || weeklyTarget <= 0 ||
            timeInZone == null ||
            !timeInZone.total.isFinite() || timeInZone.total <= 0 ||
            !timeInZone.belowZone1.isFinite() || timeInZone.belowZone1 < 0 ||
            timeInZone.seconds.any { !it.isFinite() || it < 0 }
        ) {
            return null
        }
        val moderateSeconds = timeInZone.secondsInZone(MODERATE_ZONE)
        val vigorousSeconds = (VIGOROUS_ZONE_FLOOR..5).sumOf(timeInZone::secondsInZone)
        return ActiveZoneMinutes(
            moderateMinutes = moderateSeconds / 60.0,
            vigorousMinutes = vigorousSeconds / 60.0,
            weeklyTarget = weeklyTarget,
            observedMinutes = timeInZone.total / 60.0,
        )
    }

    /**
     * Production raw-HR path. Only intervals bounded by two plausible readings no more than
     * [maximumGapSeconds] apart count as observed; no tail or missing interval is inferred.
     */
    fun minutes(
        hr: List<HrSample>,
        zoneSet: HrZoneSet,
        maximumGapSeconds: Double = MAXIMUM_SAMPLE_GAP_SECONDS,
        weeklyTarget: Double = DEFAULT_WEEKLY_TARGET,
    ): ActiveZoneMinutes? {
        if (!maximumGapSeconds.isFinite() || maximumGapSeconds <= 0 ||
            !zoneSet.maxHR.isFinite() || zoneSet.maxHR <= 0
        ) {
            return null
        }
        val samples = hr.asSequence()
            .filter { it.bpm in 25..250 }
            .sortedBy { it.ts }
            .distinctBy { it.ts }
            .toList()
        if (samples.size < 2) return null

        val durations = DoubleArray(samples.size)
        for (index in 0 until samples.lastIndex) {
            val gap = samples[index + 1].ts.toDouble() - samples[index].ts.toDouble()
            if (gap > 0 && gap <= maximumGapSeconds) durations[index] = gap
        }
        return minutes(
            timeInZone = timeInZone(samples, durations.toList(), zoneSet),
            weeklyTarget = weeklyTarget,
        )
    }

    fun weekly(
        periods: List<TimeInZone?>,
        weeklyTarget: Double = DEFAULT_WEEKLY_TARGET,
    ): ActiveZoneMinutes? {
        val measured = periods.mapNotNull { minutes(it, weeklyTarget) }
        if (measured.isEmpty()) return null
        return ActiveZoneMinutes(
            moderateMinutes = measured.sumOf { it.moderateMinutes },
            vigorousMinutes = measured.sumOf { it.vigorousMinutes },
            weeklyTarget = weeklyTarget,
            observedMinutes = measured.sumOf { it.observedMinutes },
        )
    }

    fun seriesValues(minutes: ActiveZoneMinutes?): Map<String, Double> {
        if (minutes == null ||
            !minutes.moderateMinutes.isFinite() || minutes.moderateMinutes < 0 ||
            !minutes.vigorousMinutes.isFinite() || minutes.vigorousMinutes < 0 ||
            !minutes.creditedMinutes.isFinite() || minutes.creditedMinutes < 0 ||
            !minutes.observedMinutes.isFinite() || minutes.observedMinutes <= 0
        ) {
            return emptyMap()
        }
        return mapOf(
            MODERATE_SERIES_KEY to minutes.moderateMinutes,
            VIGOROUS_SERIES_KEY to minutes.vigorousMinutes,
            CREDITED_SERIES_KEY to minutes.creditedMinutes,
            OBSERVED_SERIES_KEY to minutes.observedMinutes,
        )
    }

    /** Duration-aware zone bucketing with no inferred tail. */
    private fun timeInZone(
        hr: List<HrSample>,
        durationsSeconds: List<Double>,
        zoneSet: HrZoneSet,
    ): TimeInZone {
        val zoneSeconds = DoubleArray(5)
        var below = 0.0
        for (index in 0 until minOf(hr.size, durationsSeconds.size)) {
            val duration = durationsSeconds[index]
            if (!duration.isFinite() || duration <= 0) continue
            val zone = zoneSet.zoneNumber(hr[index].bpm.toDouble())
            if (zone >= 1) zoneSeconds[zone - 1] += duration else below += duration
        }
        return TimeInZone(zoneSeconds.toList(), below)
    }
}
