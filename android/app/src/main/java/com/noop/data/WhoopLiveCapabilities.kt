package com.noop.data

/** Honest metrics produced by NOOP's live WHOOP path. Calibrated SpO2 is import-only. */
object WhoopLiveCapabilities {
    val base: Set<Metric> = setOf(Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad)

    fun isFiveOrMG(model: String): Boolean {
        val value = model.lowercase()
        return value.contains("5") || value.contains("mg")
    }

    fun metrics(model: String): Set<Metric> = base.toMutableSet().apply {
        if (isFiveOrMG(model)) add(Metric.steps)
    }

    fun encoded(model: String): String = metrics(model).map { it.name }.sorted().joinToString(",")

    fun withoutCalibratedSpo2(capabilities: Set<Metric>): Set<Metric> = capabilities - Metric.spo2

    fun stripSpo2Token(encoded: String): String = encoded.split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() && it != Metric.spo2.name }
        .joinToString(",")
}
