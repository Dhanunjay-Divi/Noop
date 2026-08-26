package com.noop.data

/**
 * Unit boundary for sleep efficiency.
 *
 * DailyMetric, SleepSession, and the `sleep_efficiency` metric series store a fraction in [0, 1].
 * Wearable exports generally label the source field as a percentage in [0, 100]. Older importers
 * also persisted that percentage directly into the generic series, so reads tolerate and heal that
 * legacy shape. Explicit-percent and persisted-series boundaries reject out-of-range values; only
 * the mixed-scale export boundary uses Apple's documented compatibility clamp.
 */
internal object SleepEfficiencyUnits {
    const val SERIES_KEY = "sleep_efficiency"

    /** Convert an explicitly percentage-scale export field to the stored fraction. */
    fun fractionFromPercent(percent: Double?): Double? {
        val value = percent?.takeIf(Double::isFinite) ?: return null
        if (value !in 0.0..100.0) return null
        return value / 100.0
    }

    /**
     * Normalize parser output whose source API may use either a fraction or a percentage.
     *
     * This intentionally mirrors Apple's established mixed-export contract: values through 1.5 are
     * treated as fractions, larger values as percentages, and the result is clamped to [0, 1].
     * Persisted/legacy series do not use this heuristic; [canonicalFraction] remains strict.
     */
    fun fractionFromFlexibleExport(raw: Double?): Double? {
        val finite = raw?.takeIf { it.isFinite() && it >= 0.0 } ?: return null
        val fraction = if (finite > 1.5) finite / 100.0 else finite
        return fraction.coerceIn(0.0, 1.0)
    }

    /**
     * Normalize a stored value that may use either the current fraction scale or the legacy
     * percentage scale. Values in (1, 100] are legacy percentages.
     */
    fun canonicalFraction(value: Double?): Double? {
        val finite = value?.takeIf(Double::isFinite) ?: return null
        if (finite !in 0.0..100.0) return null
        return if (finite <= 1.0) finite else finite / 100.0
    }

    /** Percentage for presentation while preserving the fraction-only persistence contract. */
    fun displayPercent(value: Double?): Double? = canonicalFraction(value)?.times(100.0)

    /** Normalize the one unit-sensitive generic series; leave every unrelated key unchanged. */
    fun normalizedSeriesRow(row: MetricSeriesRow): MetricSeriesRow? {
        if (row.key != SERIES_KEY) return row
        val value = canonicalFraction(row.value) ?: return null
        return if (value == row.value) row else row.copy(value = value)
    }
}
