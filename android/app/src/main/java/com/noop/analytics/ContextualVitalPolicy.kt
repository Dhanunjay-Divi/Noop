package com.noop.analytics

import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Conservative, calendar-aware policies for optional vital trend reviews.
 *
 * These candidates never produce a health verdict. Oxygen requires two fresh low days, body
 * temperature accepts only explicit absolute readings, and VO2 max requires a persistent longer-term
 * change. Skin temperature remains exclusively in the corroborated personal-baseline illness pipeline.
 */
object ContextualVitalPolicy {
    enum class Kind {
        OXYGEN_TREND,
        BODY_TEMPERATURE_REVIEW,
        VO2_TREND,
    }

    data class Candidate(
        val kind: Kind,
        val observedDay: String,
        val maximumAgeDays: Long,
        val fingerprint: String,
    )

    data class OxygenPoint(
        val day: String,
        val value: Double,
        val sourcePriority: Int,
    )

    data class BodyTemperaturePoint(
        val day: String,
        val valueC: Double,
        val source: String,
        val sourcePriority: Int,
    )

    data class Vo2Point(val day: String, val value: Double)

    const val OXYGEN_REVIEW_THRESHOLD_PCT = 95.0
    const val OXYGEN_SAME_DAY_CONFLICT_PCT = 3.0
    const val BODY_TEMPERATURE_SAME_DAY_CONFLICT_C = 0.8

    private val bodyTemperaturePlausibleRangeC = 30.0..45.0
    private val bodyTemperatureReviewRangeC = 35.0..38.0

    fun oxygenCandidate(
        points: List<OxygenPoint>,
        todayKey: String,
    ): Candidate? {
        val today = parseDay(todayKey) ?: return null
        val byDay = points
            .filter { point ->
                point.value.isFinite() &&
                    point.value in 70.0..100.0 &&
                    ageDays(point.day, today)?.let { it in 0L..3L } == true
            }
            .groupBy { it.day }
            .mapNotNull { (day, candidates) ->
                val low = candidates.minOfOrNull { it.value } ?: return@mapNotNull null
                val high = candidates.maxOfOrNull { it.value } ?: return@mapNotNull null
                if (high - low >= OXYGEN_SAME_DAY_CONFLICT_PCT) return@mapNotNull null
                candidates.minByOrNull { it.sourcePriority }?.let { day to it.value }
            }
            .sortedBy { it.first }
        if (byDay.size < 2) return null

        val pair = byDay.takeLast(2)
        if (pair.any { it.second >= OXYGEN_REVIEW_THRESHOLD_PCT }) return null
        val first = parseDay(pair[0].first) ?: return null
        val latest = parseDay(pair[1].first) ?: return null
        val separation = ChronoUnit.DAYS.between(first, latest)
        val latestAge = ChronoUnit.DAYS.between(latest, today)
        if (separation !in 1L..2L || latestAge !in 0L..1L) return null

        return Candidate(
            kind = Kind.OXYGEN_TREND,
            observedDay = pair[1].first,
            maximumAgeDays = 3,
            fingerprint = pair.joinToString("|") {
                "${it.first}:${(it.second * 10.0).roundToInt()}"
            },
        )
    }

    fun bodyTemperatureCandidate(
        points: List<BodyTemperaturePoint>,
        todayKey: String,
    ): Candidate? {
        val today = parseDay(todayKey) ?: return null
        val resolved = points
            .filter { point ->
                point.valueC.isFinite() &&
                    point.valueC in bodyTemperaturePlausibleRangeC &&
                    ageDays(point.day, today)?.let { it in 0L..1L } == true
            }
            .groupBy { it.day }
            .mapNotNull { (_, candidates) ->
                val low = candidates.minOfOrNull { it.valueC } ?: return@mapNotNull null
                val high = candidates.maxOfOrNull { it.valueC } ?: return@mapNotNull null
                if (high - low >= BODY_TEMPERATURE_SAME_DAY_CONFLICT_C) return@mapNotNull null
                candidates.minWithOrNull(compareBy({ it.sourcePriority }, { it.source }))
            }
        val latest = resolved.maxByOrNull { it.day } ?: return null
        if (latest.valueC in bodyTemperatureReviewRangeC) return null

        return Candidate(
            kind = Kind.BODY_TEMPERATURE_REVIEW,
            observedDay = latest.day,
            maximumAgeDays = 2,
            fingerprint = "${latest.day}:${(latest.valueC * 10.0).roundToInt()}",
        )
    }

    fun vo2Candidate(
        measured: List<Vo2Point>,
        estimated: List<Vo2Point>,
        todayKey: String,
    ): Candidate? {
        val today = parseDay(todayKey) ?: return null
        val measuredClean = cleanVo2(measured, today)
        val estimatedClean = cleanVo2(estimated, today)
        val selected: List<Vo2Point>
        val sourceToken: String
        if (measuredClean.size >= 3) {
            selected = measuredClean
            sourceToken = "measured"
        } else {
            selected = estimatedClean
            sourceToken = "estimated"
        }
        if (selected.size < 3) return null

        val shifted = selected.takeLast(2)
        val firstShiftDay = parseDay(shifted[0].day) ?: return null
        val latestDay = parseDay(shifted[1].day) ?: return null
        val persistenceGap = ChronoUnit.DAYS.between(firstShiftDay, latestDay)
        if (persistenceGap !in 1L..14L) return null

        val reference = selected.lastOrNull { point ->
            val day = parseDay(point.day) ?: return@lastOrNull false
            day < firstShiftDay && ChronoUnit.DAYS.between(day, firstShiftDay) >= 21
        } ?: return null
        if (reference.value <= 0.0) return null

        val changes = shifted.map { it.value - reference.value }
        if (changes.any { abs(it) < 3.0 || abs(it) / reference.value < 0.08 }) return null
        if ((changes[0] > 0.0) != (changes[1] > 0.0)) return null

        return Candidate(
            kind = Kind.VO2_TREND,
            observedDay = shifted[1].day,
            maximumAgeDays = 8,
            fingerprint = "$sourceToken:${shifted[1].day}:" +
                (shifted[1].value * 10.0).roundToInt(),
        )
    }

    private fun cleanVo2(points: List<Vo2Point>, today: LocalDate): List<Vo2Point> {
        val byDay = LinkedHashMap<String, Vo2Point>()
        for (point in points) {
            val age = ageDays(point.day, today) ?: continue
            if (!point.value.isFinite() || point.value !in 10.0..90.0 || age !in 0L..400L) continue
            byDay[point.day] = point
        }
        val sorted = byDay.values.sortedBy { it.day }
        val latest = sorted.lastOrNull() ?: return emptyList()
        val latestAge = ageDays(latest.day, today) ?: return emptyList()
        return if (latestAge <= 7) sorted else emptyList()
    }

    private fun ageDays(day: String, today: LocalDate): Long? =
        parseDay(day)?.let { ChronoUnit.DAYS.between(it, today) }

    private fun parseDay(day: String): LocalDate? =
        runCatching { LocalDate.parse(day) }.getOrNull()
}
