package com.noop.analytics

import java.time.Instant
import java.time.ZoneOffset
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Evidence-gated daily guidance. This is the Kotlin twin of AdaptiveDayGuidance.swift.
 *
 * It ranks observations but never infers why a routine changed. Missing or stale evidence fails closed.
 */
object AdaptiveDayGuidance {
    const val MINIMUM_ROUTINE_NIGHTS = 5
    const val STRONG_ROUTINE_NIGHTS = 7
    const val ROUTINE_LOOKBACK_DAYS = 21
    const val LATEST_SLEEP_MAXIMUM_AGE_SECONDS = 30 * 60 * 60
    const val SHORT_SLEEP_THRESHOLD_MINUTES = 60
    const val LATE_ROUTINE_THRESHOLD_MINUTES = 90
    const val ROUTINE_DURATION_DROP_MINUTES = 45
    const val MAXIMUM_FRAGMENT_GAP_SECONDS = 90L * 60L
    const val TRAVEL_THRESHOLD_SECONDS = 2 * 60 * 60
    const val TRAVEL_MAXIMUM_AGE_SECONDS = 36 * 60 * 60

    enum class Kind { TRAVEL_ADJUSTMENT, ROUTINE_RECOVERY, SLEEP_RECOVERY }
    enum class Confidence { BUILDING, STRONG }

    data class SleepDay(val day: String, val totalSleepMinutes: Double?)
    data class SleepWindow(val startSec: Long, val endSec: Long)
    data class TimeZoneChange(
        val previousOffsetSec: Int,
        val currentOffsetSec: Int,
        val observedAtSec: Long,
    )

    data class Input(
        val today: String,
        val nowSec: Long,
        val currentTimeZoneOffsetSec: Int,
        val sleepTargetMinutes: Int,
        val sleepTargetIsExplicit: Boolean,
        val sleepDays: List<SleepDay>,
        val sleepWindows: List<SleepWindow>,
        val timeZoneChange: TimeZoneChange?,
        val routineHistoryStartSec: Long? = null,
    )

    data class Recommendation(
        val kind: Kind,
        val observedAtSec: Long,
        val maximumAgeSeconds: Int,
        val confidence: Confidence,
        val fingerprint: String,
        val evidence: List<String>,
    )

    fun recommendation(input: Input): Recommendation? {
        travelRecommendation(input)?.let { return it }
        val windows = eligibleWindows(input)
        routineRecommendation(input, windows)?.let { return it }
        return sleepRecommendation(input, windows)
    }

    private fun travelRecommendation(input: Input): Recommendation? {
        val change = input.timeZoneChange ?: return null
        val age = input.nowSec - change.observedAtSec
        val delta = normalizedTravelDeltaSeconds(
            previousOffsetSec = change.previousOffsetSec,
            currentOffsetSec = change.currentOffsetSec,
        )
        if (
            age !in (-5 * 60L)..TRAVEL_MAXIMUM_AGE_SECONDS.toLong() ||
            abs(change.previousOffsetSec) > 14 * 60 * 60 ||
            abs(change.currentOffsetSec) > 14 * 60 * 60 ||
            abs(delta) < TRAVEL_THRESHOLD_SECONDS
        ) return null
        return Recommendation(
            kind = Kind.TRAVEL_ADJUSTMENT,
            observedAtSec = change.observedAtSec,
            maximumAgeSeconds = TRAVEL_MAXIMUM_AGE_SECONDS,
            confidence = Confidence.STRONG,
            fingerprint =
                "travel:${change.previousOffsetSec}:${change.currentOffsetSec}:${change.observedAtSec / 3600L}",
            evidence = listOf(if (delta > 0) "timezone-east" else "timezone-west", "offset-change"),
        )
    }

    /**
     * Shortest wall-clock shift between two UTC offsets. A raw 22-hour Date Line change is the same
     * circadian shift as two hours; a raw 24-hour change leaves the local clock unchanged.
     */
    fun normalizedTravelDeltaSeconds(previousOffsetSec: Int, currentOffsetSec: Int): Int {
        val day = 24 * 60 * 60
        val halfDay = day / 2
        val raw = currentOffsetSec - previousOffsetSec
        return ((raw + halfDay) % day + day) % day - halfDay
    }

    private data class SleepObservation(
        val primaryStartSec: Long,
        val endSec: Long,
        val totalDurationSeconds: Long,
    )

    private fun eligibleWindows(input: Input): List<SleepObservation> {
        val oldest = input.nowSec - ROUTINE_LOOKBACK_DAYS * 24L * 60L * 60L
        val seen = mutableSetOf<String>()
        val candidates = input.sleepWindows
            .filter { window ->
                val duration = window.endSec - window.startSec
                window.startSec >= oldest &&
                    (input.routineHistoryStartSec?.let { window.startSec >= it } != false) &&
                    window.endSec <= input.nowSec &&
                    duration in 1L..(14 * 60 * 60L) &&
                    seen.add("${window.startSec}:${window.endSec}")
            }
            .sortedWith(compareBy<SleepWindow> { it.startSec }.thenBy { it.endSec })

        // Merge short, nearby fragments before the three-hour night threshold. Distant sleep remains a
        // separate cluster, and only one cluster can represent a noon-to-noon sleep night.
        return candidates
            .groupBy { sleepNightKey(it.startSec, input.currentTimeZoneOffsetSec) }
            .values
            .mapNotNull { windows ->
                fragmentClusters(windows)
                    .mapNotNull { cluster ->
                        val startSec = cluster.minOfOrNull { it.startSec }
                            ?: return@mapNotNull null
                        if (!isOvernightOnset(startSec, input.currentTimeZoneOffsetSec)) {
                            return@mapNotNull null
                        }
                        val totalDuration = mergedDurationSeconds(cluster)
                        if (totalDuration !in (3L * 60L * 60L)..(14L * 60L * 60L)) {
                            return@mapNotNull null
                        }
                        SleepObservation(
                            primaryStartSec = startSec,
                            endSec = cluster.maxOf { it.endSec },
                            totalDurationSeconds = totalDuration,
                        )
                    }
                    .maxWithOrNull(
                        compareBy<SleepObservation> { it.totalDurationSeconds }.thenBy { it.endSec },
                    )
            }
            .sortedBy { it.endSec }
    }

    private fun routineRecommendation(
        input: Input,
        windows: List<SleepObservation>,
    ): Recommendation? {
        val latest = windows.lastOrNull() ?: return null
        if (input.nowSec - latest.endSec > LATEST_SLEEP_MAXIMUM_AGE_SECONDS) return null
        val history = windows.dropLast(1).takeLast(14)
        if (history.size < MINIMUM_ROUTINE_NIGHTS) return null

        val baselineOnset = median(
            history.map {
                bedtimeCoordinate(it.primaryStartSec, input.currentTimeZoneOffsetSec)
            },
        )
        val latestOnset = bedtimeCoordinate(
            latest.primaryStartSec,
            input.currentTimeZoneOffsetSec,
        )
        val delay = latestOnset - baselineOnset
        val baselineDuration = median(history.map { it.totalDurationSeconds / 60.0 })
        val latestDuration = latest.totalDurationSeconds / 60.0
        val shortened = latestDuration <= baselineDuration - ROUTINE_DURATION_DROP_MINUTES
        if (delay < LATE_ROUTINE_THRESHOLD_MINUTES || !shortened) return null

        return Recommendation(
            kind = Kind.ROUTINE_RECOVERY,
            observedAtSec = latest.endSec,
            maximumAgeSeconds = 18 * 60 * 60,
            confidence = if (history.size >= STRONG_ROUTINE_NIGHTS) {
                Confidence.STRONG
            } else {
                Confidence.BUILDING
            },
            fingerprint =
                "routine:${latest.primaryStartSec / 900L}:${latest.endSec / 900L}:" +
                    "${latest.totalDurationSeconds / 900L}",
            evidence = listOf("personal-sleep-timing", "later-onset", "shorter-sleep"),
        )
    }

    private fun sleepRecommendation(
        input: Input,
        windows: List<SleepObservation>,
    ): Recommendation? {
        if (!input.sleepTargetIsExplicit) return null
        val target = input.sleepTargetMinutes.coerceIn(5 * 60, 11 * 60).toDouble()
        val freshWindows = windows.asReversed().filter { window ->
            input.nowSec - window.endSec in
                (-5 * 60L)..LATEST_SLEEP_MAXIMUM_AGE_SECONDS.toLong() &&
                localDayKey(window.endSec, input.currentTimeZoneOffsetSec) == input.today
        }
        val current = input.sleepDays.lastOrNull { it.day == input.today }
        val minutes = current?.totalSleepMinutes
        val matchedWindow = if (
            minutes != null &&
            minutes.isFinite() &&
            minutes in 120.0..900.0 &&
            target - minutes >= SHORT_SLEEP_THRESHOLD_MINUTES
        ) {
            freshWindows.firstOrNull { window ->
                DailyActionPlanner.matchedSleepObservationEndSec(
                    aggregateMinutes = minutes,
                    sessionDurationMinutes = window.totalDurationSeconds / 60.0,
                    sessionEndSec = window.endSec,
                    nowSec = input.nowSec,
                    maximumAgeSeconds = LATEST_SLEEP_MAXIMUM_AGE_SECONDS,
                ) != null
            }
        } else {
            null
        }
        if (
            minutes != null &&
            matchedWindow != null
        ) {
            return Recommendation(
                kind = Kind.SLEEP_RECOVERY,
                observedAtSec = matchedWindow.endSec,
                maximumAgeSeconds = 18 * 60 * 60,
                confidence = Confidence.STRONG,
                fingerprint = "sleep:${input.today}:${minutes.roundToInt()}",
                evidence = listOf("current-sleep", "below-explicit-target"),
            )
        }

        val latest = freshWindows.firstOrNull() ?: return null
        val duration = latest.totalDurationSeconds / 60.0
        if (target - duration < SHORT_SLEEP_THRESHOLD_MINUTES) return null
        return Recommendation(
            kind = Kind.SLEEP_RECOVERY,
            observedAtSec = latest.endSec,
            maximumAgeSeconds = 18 * 60 * 60,
            confidence = Confidence.BUILDING,
            fingerprint =
                "sleep-window:${latest.primaryStartSec / 900L}:${latest.endSec / 900L}:" +
                    "${latest.totalDurationSeconds / 900L}",
            evidence = listOf("recent-sleep-window", "below-explicit-target"),
        )
    }

    private fun fragmentClusters(windows: List<SleepWindow>): List<List<SleepWindow>> {
        val sorted = windows.sortedWith(compareBy<SleepWindow> { it.startSec }.thenBy { it.endSec })
        val clusters = mutableListOf<MutableList<SleepWindow>>()
        for (window in sorted) {
            val last = clusters.lastOrNull()
            val clusterEnd = last?.maxOfOrNull { it.endSec }
            if (last == null || clusterEnd == null ||
                window.startSec - clusterEnd > MAXIMUM_FRAGMENT_GAP_SECONDS
            ) {
                clusters += mutableListOf(window)
            } else {
                last += window
            }
        }
        return clusters
    }

    private fun mergedDurationSeconds(windows: List<SleepWindow>): Long {
        val sorted = windows.sortedWith(compareBy<SleepWindow> { it.startSec }.thenBy { it.endSec })
        val first = sorted.firstOrNull() ?: return 0L
        var currentStart = first.startSec
        var currentEnd = first.endSec
        var total = 0L
        for (window in sorted.drop(1)) {
            if (window.startSec <= currentEnd) {
                currentEnd = maxOf(currentEnd, window.endSec)
            } else {
                total += currentEnd - currentStart
                currentStart = window.startSec
                currentEnd = window.endSec
            }
        }
        return total + currentEnd - currentStart
    }

    private fun localDayKey(epochSec: Long, offsetSec: Int): String =
        Instant.ofEpochSecond(epochSec + offsetSec)
            .atOffset(ZoneOffset.UTC)
            .toLocalDate()
            .toString()

    private fun isOvernightOnset(epochSec: Long, offsetSec: Int): Boolean {
        val minute = localMinute(epochSec, offsetSec)
        return minute >= 18 * 60 || minute < 6 * 60
    }

    private fun sleepNightKey(epochSec: Long, offsetSec: Int): Long =
        Math.floorDiv(epochSec + offsetSec - 12L * 60L * 60L, 24L * 60L * 60L)

    private fun bedtimeCoordinate(epochSec: Long, offsetSec: Int): Double {
        val minute = localMinute(epochSec, offsetSec)
        return (if (minute < 12 * 60) minute + 24 * 60 else minute).toDouble()
    }

    private fun localMinute(epochSec: Long, offsetSec: Int): Int {
        val day = 24 * 60 * 60L
        val local = ((epochSec + offsetSec) % day + day) % day
        return (local / 60L).toInt()
    }

    private fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        if (sorted.isEmpty()) return 0.0
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            sorted[mid]
        }
    }
}
