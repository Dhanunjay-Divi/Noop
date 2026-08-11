package com.noop.data

import com.noop.protocol.DeviceFamily
import com.noop.protocol.WhoopRegistryIdentity

/** Honest metrics produced by NOOP's live WHOOP path. Calibrated SpO2 is import-only. */
object WhoopLiveCapabilities {
    val base: Set<Metric> = setOf(Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad)

    fun isFiveOrMG(model: String): Boolean =
        WhoopRegistryIdentity.positivelyIdentifiedFamily(model) == DeviceFamily.WHOOP5

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
