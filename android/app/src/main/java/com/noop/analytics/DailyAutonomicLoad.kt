package com.noop.analytics

import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Causal daily autonomic-load proxy shared with the Apple implementation.
 *
 * Every target is scored only against strictly earlier days. A signal contributes only when it has
 * enough personal history and non-zero spread; two contributing signals are required for a reliable
 * calendar value.
 */
internal object DailyAutonomicLoad {
    const val BASELINE_WINDOW_DAYS = 30
    const val MINIMUM_BASELINE_DAYS = 7
    const val MINIMUM_USABLE_SPREAD = 0.0001

    data class Day(
        val day: String,
        val restingHeartRate: Double? = null,
        val hrv: Double? = null,
    )

    enum class Signal {
        RESTING_HEART_RATE,
        HEART_RATE_VARIABILITY,
    }

    enum class Band {
        LOW,
        MODERATE,
        HIGH;

        companion object {
            fun from(value: Double): Band = when {
                value < 1.0 -> LOW
                value < 2.0 -> MODERATE
                else -> HIGH
            }
        }
    }

    enum class Confidence {
        UNAVAILABLE,
        LIMITED,
        RELIABLE,
    }

    enum class Limitation {
        TARGET_SIGNALS_MISSING,
        RESTING_HEART_RATE_MISSING,
        HEART_RATE_VARIABILITY_MISSING,
        RESTING_HEART_RATE_HISTORY_INSUFFICIENT,
        HEART_RATE_VARIABILITY_HISTORY_INSUFFICIENT,
        RESTING_HEART_RATE_BASELINE_HAS_NO_SPREAD,
        HEART_RATE_VARIABILITY_BASELINE_HAS_NO_SPREAD,
        SINGLE_SIGNAL_ESTIMATE,
        STALE_SOURCE_DAY,
        EXPERIMENTAL_NON_CLINICAL_PROXY,
    }

    data class Readout(
        val value: Double?,
        val band: Band?,
        val confidence: Confidence,
        val asOf: String?,
        val baselineDays: Int,
        val observedSignals: List<Signal>,
        val limitations: List<Limitation>,
    )

    fun readout(days: List<Day>, requestedAsOf: String? = null): Readout {
        val normalized = normalize(days)
        val requested = requestedAsOf ?: normalized.lastOrNull()?.day
            ?: return unavailable(null)
        val eligible = normalized.filter { it.day <= requested }
        val target = eligible.lastOrNull(::hasObservation) ?: return unavailable(null)
        val prior = eligible.filter { it.day < target.day }.takeLast(BASELINE_WINDOW_DAYS)
        val result = evaluate(target, prior)
        return if (target.day < requested) {
            result.copy(limitations = result.limitations + Limitation.STALE_SOURCE_DAY)
        } else {
            result
        }
    }

    fun causalTrend(days: List<Day>): List<Readout> {
        val normalized = normalize(days)
        return normalized.filter(::hasObservation).map { target ->
            val prior = normalized
                .filter { it.day < target.day }
                .takeLast(BASELINE_WINDOW_DAYS)
            evaluate(target, prior)
        }
    }

    private data class UsableTerm(
        val signal: Signal,
        val z: Double,
        val baselineDays: Int,
    )

    private fun evaluate(target: Day, prior: List<Day>): Readout {
        val terms = mutableListOf<UsableTerm>()
        val limitations = mutableListOf<Limitation>()
        val candidateHistoryCounts = mutableListOf<Int>()

        buildTerm(
            target = valid(target.restingHeartRate),
            baseline = prior.mapNotNull { valid(it.restingHeartRate) },
            signal = Signal.RESTING_HEART_RATE,
            missing = Limitation.RESTING_HEART_RATE_MISSING,
            insufficient = Limitation.RESTING_HEART_RATE_HISTORY_INSUFFICIENT,
            noSpread = Limitation.RESTING_HEART_RATE_BASELINE_HAS_NO_SPREAD,
            direction = 1.0,
            terms = terms,
            limitations = limitations,
            candidateHistoryCounts = candidateHistoryCounts,
        )
        buildTerm(
            target = valid(target.hrv),
            baseline = prior.mapNotNull { valid(it.hrv) },
            signal = Signal.HEART_RATE_VARIABILITY,
            missing = Limitation.HEART_RATE_VARIABILITY_MISSING,
            insufficient = Limitation.HEART_RATE_VARIABILITY_HISTORY_INSUFFICIENT,
            noSpread = Limitation.HEART_RATE_VARIABILITY_BASELINE_HAS_NO_SPREAD,
            direction = -1.0,
            terms = terms,
            limitations = limitations,
            candidateHistoryCounts = candidateHistoryCounts,
        )

        if (terms.isEmpty()) {
            if (valid(target.restingHeartRate) == null && valid(target.hrv) == null) {
                limitations.add(0, Limitation.TARGET_SIGNALS_MISSING)
            }
            limitations += Limitation.EXPERIMENTAL_NON_CLINICAL_PROXY
            return Readout(
                value = null,
                band = null,
                confidence = Confidence.UNAVAILABLE,
                asOf = target.day,
                baselineDays = candidateHistoryCounts.maxOrNull() ?: 0,
                observedSignals = emptyList(),
                limitations = limitations,
            )
        }

        if (terms.size == 1) limitations += Limitation.SINGLE_SIGNAL_ESTIMATE
        limitations += Limitation.EXPERIMENTAL_NON_CLINICAL_PROXY
        val value = squash(terms.sumOf(UsableTerm::z))
        return Readout(
            value = value,
            band = Band.from(value),
            confidence = if (terms.size == 2) Confidence.RELIABLE else Confidence.LIMITED,
            asOf = target.day,
            baselineDays = terms.minOf(UsableTerm::baselineDays),
            observedSignals = terms.map(UsableTerm::signal),
            limitations = limitations,
        )
    }

    private fun buildTerm(
        target: Double?,
        baseline: List<Double>,
        signal: Signal,
        missing: Limitation,
        insufficient: Limitation,
        noSpread: Limitation,
        direction: Double,
        terms: MutableList<UsableTerm>,
        limitations: MutableList<Limitation>,
        candidateHistoryCounts: MutableList<Int>,
    ) {
        if (target == null) {
            limitations += missing
            return
        }
        candidateHistoryCounts += baseline.size
        if (baseline.size < MINIMUM_BASELINE_DAYS) {
            limitations += insufficient
            return
        }
        val mean = baseline.average()
        val variance = baseline.sumOf { (it - mean) * (it - mean) } / baseline.size
        val spread = sqrt(variance)
        if (!spread.isFinite() || spread <= MINIMUM_USABLE_SPREAD) {
            limitations += noSpread
            return
        }
        val z = direction * (target - mean) / spread
        if (!z.isFinite()) {
            limitations += noSpread
            return
        }
        terms += UsableTerm(signal, z, baseline.size)
    }

    private fun squash(raw: Double): Double =
        (3.0 / (1.0 + exp(-raw))).coerceIn(0.0, 3.0)

    private fun valid(value: Double?): Double? =
        value?.takeIf { it.isFinite() && it > 0.0 }

    private fun hasObservation(day: Day): Boolean =
        valid(day.restingHeartRate) != null || valid(day.hrv) != null

    private fun normalize(days: List<Day>): List<Day> {
        val byDay = linkedMapOf<String, Day>()
        days.filter { it.day.isNotEmpty() }.forEach { day ->
            val existing = byDay[day.day]
            byDay[day.day] = Day(
                day = day.day,
                restingHeartRate = valid(day.restingHeartRate)
                    ?: existing?.restingHeartRate?.let(::valid),
                hrv = valid(day.hrv) ?: existing?.hrv?.let(::valid),
            )
        }
        return byDay.values.sortedBy(Day::day)
    }

    private fun unavailable(asOf: String?): Readout = Readout(
        value = null,
        band = null,
        confidence = Confidence.UNAVAILABLE,
        asOf = asOf,
        baselineDays = 0,
        observedSignals = emptyList(),
        limitations = listOf(
            Limitation.TARGET_SIGNALS_MISSING,
            Limitation.EXPERIMENTAL_NON_CLINICAL_PROXY,
        ),
    )
}
