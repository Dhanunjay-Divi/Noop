package com.noop.data

/**
 * Honest metrics produced by NOOP's live compatible-band path.
 *
 * Calibrated SpO2 is import-only, and the reverse-engineered motion counter is not a validated
 * pedometer. Neither may be advertised as a live capability.
 */
object WhoopLiveCapabilities {
    val base: Set<Metric> = setOf(Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad)

    fun metrics(@Suppress("UNUSED_PARAMETER") model: String): Set<Metric> = base

    fun encoded(model: String): String = metrics(model).map { it.name }.sorted().joinToString(",")

    fun withoutUnvalidatedLiveMetrics(capabilities: Set<Metric>): Set<Metric> =
        capabilities - setOf(Metric.spo2, Metric.steps)

    /** Retained for the historical migration that removed only the SpO2 token. */
    fun withoutCalibratedSpo2(capabilities: Set<Metric>): Set<Metric> = capabilities - Metric.spo2

    fun stripUnvalidatedLiveTokens(encoded: String): String = encoded.split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() && it != Metric.spo2.name && it != Metric.steps.name }
        .joinToString(",")

    /** Retained for the historical migration that removed only the SpO2 token. */
    fun stripSpo2Token(encoded: String): String = encoded.split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() && it != Metric.spo2.name }
        .joinToString(",")
}
