package com.noop.analytics

import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Transparent calendar-day training-load context; the Kotlin twin of `TrainingLoadModel.swift`.
 *
 * Every input must use the same additive unit (for example session-RPE minutes, TRIMP, or
 * MET-minutes). A bounded WHOOP/NOOP strain score is nonlinear and must not be summed as an impulse
 * load. ATL/CTL are descriptive exponentially weighted averages and TSB is exactly `CTL - ATL`;
 * none directly measures fitness, fatigue, readiness, injury risk, or permission to train.
 *
 * Formula and cold-start choices were independently implemented and cross-checked against the MIT
 * OpenStrap analytics implementation at commit `ebe45da6271ec99fbda353067b6deadc757ff2d8`
 * and the MIT `RuochenLyu/apple-health-analyst` project. No source code was copied.
 */
object TrainingLoadModel {
    /** Shared hard ceiling for every day-count/time-horizon configuration and timeline allocation. */
    private const val MAX_CONFIGURED_DAYS = 36_600

    data class Entry(val day: String, val load: Double)
    data class DailyLoad(val day: String, val load: Double)
    data class Aggregation(val days: List<DailyLoad>, val rejectedEntryCount: Int)

    enum class MissingDayPolicy {
        /** Abstain on gaps and restart warm-up; never manufacture zero load. */
        REQUIRE_OBSERVED,

        /** Explicitly use zero for gaps, while marking affected output as estimated. */
        ASSUME_REST,
    }

    data class Configuration(
        val acuteTimeConstantDays: Double = 7.0,
        val chronicTimeConstantDays: Double = 42.0,
        val minimumHistoryDays: Int = 14,
        val seedDays: Int = 7,
        val rampWindowDays: Int = 7,
        val stableRampFraction: Double = 0.10,
        /** Expanded daily timeline bound; 10 years by default, with a hard 100-year ceiling. */
        val maximumCalendarSpanDays: Int = 3_660,
        val missingDayPolicy: MissingDayPolicy = MissingDayPolicy.REQUIRE_OBSERVED,
    ) {
        init {
            require(
                acuteTimeConstantDays > 0 && acuteTimeConstantDays.isFinite() &&
                    acuteTimeConstantDays <= MAX_CONFIGURED_DAYS.toDouble()
            )
            require(
                chronicTimeConstantDays > 0 && chronicTimeConstantDays.isFinite() &&
                    chronicTimeConstantDays <= MAX_CONFIGURED_DAYS.toDouble()
            )
            require(minimumHistoryDays in 1..MAX_CONFIGURED_DAYS)
            require(seedDays in 1..minimumHistoryDays)
            require(rampWindowDays in 1..MAX_CONFIGURED_DAYS)
            require(stableRampFraction >= 0 && stableRampFraction.isFinite())
            require(maximumCalendarSpanDays in 1..MAX_CONFIGURED_DAYS)
        }
    }

    enum class DaySource { OBSERVED, MISSING, ASSUMED_REST }
    enum class Quality { UNAVAILABLE, PROVISIONAL, OBSERVED, ESTIMATED }
    enum class RampDirection { BUILDING, STEADY, EASING, UNAVAILABLE }

    data class Point(
        val day: String,
        val observedLoad: Double?,
        val effectiveLoad: Double?,
        val source: DaySource,
        val atl: Double?,
        val ctl: Double?,
        val tsb: Double?,
        val currentRampWindowLoad: Double?,
        val previousRampWindowLoad: Double?,
        val rampChange: Double?,
        val rampChangeFraction: Double?,
        val rampDirection: RampDirection,
        val observedCoverage: Double,
        val assumedRestDaysInWindow: Int,
        /** Assumptions still folded into the recursive ATL/CTL model state. */
        val assumedRestDaysInModelHistory: Int,
        val consecutiveHistoryDays: Int,
        val quality: Quality,
        val interpretation: String,
    )

    data class Series(
        val observedDays: List<DailyLoad>,
        val points: List<Point>,
        val rejectedEntryCount: Int,
        val status: Status,
    ) {
        enum class Status { COMPLETE, EMPTY, CALENDAR_SPAN_EXCEEDED }
        val latest: Point? get() = points.lastOrNull()
    }

    /** Validate inputs and add all valid load contributions sharing one day. */
    fun aggregate(entries: List<Entry>): Aggregation {
        val totals = mutableMapOf<String, Double>()
        var rejected = 0
        entries.forEach { entry ->
            if (parseDay(entry.day) == null || !entry.load.isFinite() || entry.load < 0) {
                rejected += 1
            } else {
                val total = (totals[entry.day] ?: 0.0) + entry.load
                if (!total.isFinite()) {
                    // Keep the valid total so far and reject only the overflowing contribution.
                    rejected += 1
                } else {
                    totals[entry.day] = total
                }
            }
        }
        val days = totals.keys.sorted().map { day -> DailyLoad(day, totals.getValue(day)) }
        return Aggregation(days, rejected)
    }

    fun evaluate(
        entries: List<Entry>,
        configuration: Configuration = Configuration(),
    ): Series {
        val aggregation = aggregate(entries)
        val empty = Series(aggregation.days, emptyList(), aggregation.rejectedEntryCount, Series.Status.EMPTY)
        val first = aggregation.days.firstOrNull()?.day?.let(::parseDay) ?: return empty
        val last = aggregation.days.lastOrNull()?.day?.let(::parseDay) ?: return empty

        val span = ChronoUnit.DAYS.between(first, last) + 1
        if (span <= 0 || span > configuration.maximumCalendarSpanDays) {
            return Series(
                aggregation.days,
                emptyList(),
                aggregation.rejectedEntryCount,
                Series.Status.CALENDAR_SPAN_EXCEEDED,
            )
        }

        val observedByDay = aggregation.days.associate { it.day to it.load }
        val timeline = buildList {
            var date = first
            while (!date.isAfter(last)) {
                val key = date.toString()
                add(key to observedByDay[key])
                date = date.plusDays(1)
            }
        }

        val acuteAlpha = 1 - exp(-1 / configuration.acuteTimeConstantDays)
        val chronicAlpha = 1 - exp(-1 / configuration.chronicTimeConstantDays)
        val coverageWindow = max(1, configuration.chronicTimeConstantDays.roundToInt())
        val segmentLoads = mutableListOf<Double>()
        var atlState: Double? = null
        var ctlState: Double? = null
        var segmentAssumedDays = 0
        val effectiveLoads = mutableListOf<Double?>()
        val sources = mutableListOf<DaySource>()
        val points = mutableListOf<Point>()

        timeline.forEachIndexed { index, item ->
            val observed = item.second
            val source: DaySource
            val effective: Double?
            if (observed != null) {
                source = DaySource.OBSERVED
                effective = observed
            } else if (configuration.missingDayPolicy == MissingDayPolicy.ASSUME_REST) {
                source = DaySource.ASSUMED_REST
                effective = 0.0
            } else {
                source = DaySource.MISSING
                effective = null
            }
            effectiveLoads += effective
            sources += source

            if (effective != null) {
                segmentLoads += effective
                if (source == DaySource.ASSUMED_REST) segmentAssumedDays += 1
                if (segmentLoads.size == configuration.seedDays) {
                    val seed = finiteMean(segmentLoads)
                    if (seed != null) {
                        atlState = seed
                        ctlState = seed
                    } else {
                        // Never expose a non-finite recursive state as a health/load estimate.
                        segmentLoads.clear()
                        segmentAssumedDays = 0
                        atlState = null
                        ctlState = null
                    }
                } else if (segmentLoads.size > configuration.seedDays) {
                    val nextAtl = atlState?.let { it + acuteAlpha * (effective - it) }
                    val nextCtl = ctlState?.let { it + chronicAlpha * (effective - it) }
                    if (nextAtl != null && nextCtl != null && nextAtl.isFinite() && nextCtl.isFinite()) {
                        atlState = nextAtl
                        ctlState = nextCtl
                    } else {
                        segmentLoads.clear()
                        segmentAssumedDays = 0
                        atlState = null
                        ctlState = null
                    }
                }
            } else {
                // Unknown load makes the exact EWMA unknowable. Strict mode abstains and starts a new
                // warm-up segment rather than silently applying zero or compressing calendar time.
                segmentLoads.clear()
                segmentAssumedDays = 0
                atlState = null
                ctlState = null
            }

            val modelIsWarm = segmentLoads.size >= configuration.minimumHistoryDays
            val candidateAtl = if (modelIsWarm) atlState?.takeIf { it.isFinite() } else null
            val candidateCtl = if (modelIsWarm) ctlState?.takeIf { it.isFinite() } else null
            val candidateTsb = if (candidateCtl != null && candidateAtl != null) {
                (candidateCtl - candidateAtl).takeIf { it.isFinite() }
            } else {
                null
            }
            // ATL/CTL/TSB are one coherent estimate. If any derived member is non-finite, publish none.
            val atl = if (candidateTsb != null) candidateAtl else null
            val ctl = if (candidateTsb != null) candidateCtl else null
            val tsb = candidateTsb
            val ramp = rampContext(
                effectiveLoads,
                configuration.rampWindowDays,
                configuration.stableRampFraction,
            )
            val coverageStart = max(0, index - coverageWindow + 1)
            val coverageSources = sources.subList(coverageStart, index + 1)
            val observedCount = coverageSources.count { it == DaySource.OBSERVED }
            val assumedCount = coverageSources.count { it == DaySource.ASSUMED_REST }
            val coverage = observedCount.toDouble() / coverageSources.size
            val quality = when {
                atl == null || ctl == null -> Quality.UNAVAILABLE
                segmentAssumedDays > 0 -> Quality.ESTIMATED
                segmentLoads.size < coverageWindow -> Quality.PROVISIONAL
                else -> Quality.OBSERVED
            }

            points += Point(
                day = item.first,
                observedLoad = observed,
                effectiveLoad = effective,
                source = source,
                atl = atl,
                ctl = ctl,
                tsb = tsb,
                currentRampWindowLoad = ramp.current,
                previousRampWindowLoad = ramp.previous,
                rampChange = ramp.change,
                rampChangeFraction = ramp.fraction,
                rampDirection = ramp.direction,
                observedCoverage = coverage,
                assumedRestDaysInWindow = assumedCount,
                assumedRestDaysInModelHistory = segmentAssumedDays,
                consecutiveHistoryDays = segmentLoads.size,
                quality = quality,
                interpretation = interpretation(
                    quality, tsb, segmentLoads.size, configuration.minimumHistoryDays, segmentAssumedDays,
                ),
            )
        }

        return Series(aggregation.days, points, aggregation.rejectedEntryCount, Series.Status.COMPLETE)
    }

    private data class RampContext(
        val current: Double? = null,
        val previous: Double? = null,
        val change: Double? = null,
        val fraction: Double? = null,
        val direction: RampDirection = RampDirection.UNAVAILABLE,
    )

    private fun rampContext(
        effectiveLoads: List<Double?>,
        windowDays: Int,
        stableFraction: Double,
    ): RampContext {
        // Division-first avoids `windowDays * 2` overflow even if this helper is reused independently
        // of Configuration's public hard bounds.
        if (windowDays <= 0 || windowDays > effectiveLoads.size / 2) return RampContext()
        val currentStart = effectiveLoads.size - windowDays
        val previousStart = currentStart - windowDays
        val previousSlice = effectiveLoads.subList(previousStart, currentStart)
        val currentSlice = effectiveLoads.subList(currentStart, effectiveLoads.size)
        if (previousSlice.any { it == null } || currentSlice.any { it == null }) return RampContext()
        val previous = finiteSum(previousSlice.filterNotNull()) ?: return RampContext()
        val current = finiteSum(currentSlice.filterNotNull()) ?: return RampContext()
        val change = current - previous
        if (!change.isFinite()) return RampContext()
        if (previous <= 0) {
            return RampContext(
                current, previous, change, null,
                if (current > 0) RampDirection.BUILDING else RampDirection.STEADY,
            )
        }
        val fraction = change / previous
        if (!fraction.isFinite()) {
            return RampContext(current, previous, change, null, RampDirection.UNAVAILABLE)
        }
        val direction = when {
            fraction > stableFraction -> RampDirection.BUILDING
            fraction < -stableFraction -> RampDirection.EASING
            else -> RampDirection.STEADY
        }
        return RampContext(current, previous, change, fraction, direction)
    }

    private fun interpretation(
        quality: Quality,
        tsb: Double?,
        consecutiveDays: Int,
        minimumDays: Int,
        assumedCount: Int,
    ): String {
        if (tsb == null || !tsb.isFinite()) {
            return "Load comparison unavailable: $consecutiveDays of $minimumDays consecutive calendar days recorded."
        }
        if (quality == Quality.ESTIMATED) {
            val suffix = if (assumedCount == 1) "" else "s"
            return "Estimate includes $assumedCount unobserved day$suffix treated as rest; it describes recorded load only."
        }
        val comparison = when {
            tsb < -0.000_001 -> "Recent recorded load is above the longer-term recorded-load baseline."
            tsb > 0.000_001 -> "Recent recorded load is below the longer-term recorded-load baseline."
            else -> "Recent and longer-term recorded load are similar."
        }
        return if (quality == Quality.PROVISIONAL) {
            "Provisional: $comparison This is load context, not a fitness or fatigue measurement."
        } else {
            "$comparison This is load context, not a fitness or fatigue measurement."
        }
    }

    /** Overflow-safe mean for nonnegative finite daily loads. */
    private fun finiteMean(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        var mean = 0.0
        values.forEachIndexed { index, value ->
            if (!value.isFinite() || value < 0) return null
            val next = mean + (value - mean) / (index + 1).toDouble()
            if (!next.isFinite()) return null
            mean = next
        }
        return mean
    }

    /** Return null rather than publishing Infinity when a ramp-window total is unrepresentable. */
    private fun finiteSum(values: List<Double>): Double? {
        var total = 0.0
        for (value in values) {
            if (!value.isFinite() || value < 0) return null
            val next = total + value
            if (!next.isFinite()) return null
            total = next
        }
        return total
    }

    private fun parseDay(value: String): LocalDate? =
        runCatching { LocalDate.parse(value).takeIf { it.toString() == value } }.getOrNull()
}
