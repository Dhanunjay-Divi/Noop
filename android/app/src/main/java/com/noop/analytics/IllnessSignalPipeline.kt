package com.noop.analytics

import com.noop.data.DailyMetric

/**
 * Calendar-aware adapter from cached daily rows to [IllnessSignalEngine].
 *
 * Each signal gets its own freshness and baseline check. Missing calendar days stay missing, a stale
 * metric cannot borrow freshness from another metric, and an untrusted metric cannot contribute to the
 * score. This is a wellness pattern detector, not a health-status or diagnostic assessment.
 */
object IllnessSignalPipeline {
    const val MAXIMUM_SIGNAL_AGE_DAYS = 2
    const val RECENT_WINDOW_DAYS = 2
    const val BASELINE_GAP_DAYS = 1
    const val BASELINE_WINDOW_DAYS = 28

    data class MetricAssessment(
        val reading: IllnessSignalEngine.SignalReading,
        val baselineTrusted: Boolean,
        val latestDay: String,
        val recentMean: Double,
        val baseline: Double?,
        val delta: Double?,
        val ratio: Double?,
    )

    data class Prepared(
        val restingHR: MetricAssessment?,
        val skinTemp: VitalBands.SkinTempIllnessAssessment?,
        val skinTempLatestDay: String?,
        val hrv: MetricAssessment?,
        val respiration: MetricAssessment?,
    ) {
        val inputs: IllnessSignalEngine.Inputs
            get() = IllnessSignalEngine.Inputs(
                restingHR = restingHR?.reading,
                skinTemp = skinTemp?.let {
                    IllnessSignalEngine.SignalReading(
                        zIllnessward = it.reading.zIllnessward,
                        present = it.reading.present && it.baselineTrusted,
                    )
                },
                hrv = hrv?.reading,
                respiration = respiration?.reading,
            )

        /** Fresh signals backed by their own trusted baseline, independent of anomaly direction. */
        val trustedSignalCount: Int
            get() = listOf(
                restingHR?.reading?.present == true,
                skinTemp?.reading?.present == true && skinTemp.baselineTrusted,
                hrv?.reading?.present == true,
                respiration?.reading?.present == true,
            ).count { it }

        val baselineTrusted: Boolean
            get() = trustedSignalCount >= IllnessSignalEngine.minCorroboratingSignals

        val firedLabels: Map<String, String>
            get() = buildMap {
                restingHR?.takeIf { it.reading.present && (it.delta ?: 0.0) > 0.0 }?.let {
                    put("restingHR", "RHR +${kotlin.math.round(it.delta!!).toInt()}")
                }
                skinTemp?.takeIf {
                    it.reading.present && it.baselineTrusted && (it.deltaFromBaselineC ?: 0.0) > 0.0
                }?.let {
                    put(
                        "skinTemp",
                        String.format(java.util.Locale.US, "skin temp +%.1f °C", it.deltaFromBaselineC),
                    )
                }
                hrv?.takeIf { it.reading.present && (it.ratio ?: 0.0) < 0.0 }?.let {
                    put("hrv", "HRV -${kotlin.math.round(-it.ratio!! * 100.0).toInt()}%")
                }
                if (respiration?.reading?.present == true) put("respiration", "respiration up")
            }

        val distanceFeatures: IllnessDistance.FeatureVector
            get() = IllnessDistance.FeatureVector(
                restingHR = restingHR?.reading?.takeIf { it.present }?.zIllnessward,
                rmssd = hrv?.reading?.takeIf { it.present }?.zIllnessward,
                skinTemp = skinTemp?.takeIf { it.reading.present && it.baselineTrusted }
                    ?.reading?.zIllnessward,
                respiration = respiration?.reading?.takeIf { it.present }?.zIllnessward,
            )
    }

    fun prepare(days: List<DailyMetric>, todayKey: String): Prepared {
        val today = Baselines.isoEpochDay(todayKey)
            ?: return Prepared(null, null, null, null, null)
        val rowsByEpoch = LinkedHashMap<Int, DailyMetric>()
        for (row in days) {
            val epoch = Baselines.isoEpochDay(row.day) ?: continue
            if (epoch <= today) rowsByEpoch[epoch] = row
        }

        val restingHR = metricAssessment(
            rowsByEpoch, today, { it.restingHr?.toDouble() },
            Baselines.restingHRCfg, illnessUp = true,
        )
        val hrv = metricAssessment(
            rowsByEpoch, today, { it.avgHrv },
            Baselines.hrvCfg, illnessUp = false,
        )
        val respiration = metricAssessment(
            rowsByEpoch, today, { it.respRateBpm },
            Baselines.respCfg, illnessUp = true,
        )
        val skin = skinAssessment(rowsByEpoch, today)
        return Prepared(restingHR, skin?.first, skin?.second, hrv, respiration)
    }

    private fun metricAssessment(
        rowsByEpoch: Map<Int, DailyMetric>,
        today: Int,
        selector: (DailyMetric) -> Double?,
        cfg: MetricCfg,
        illnessUp: Boolean,
    ): MetricAssessment? {
        val latest = latestRawValue(rowsByEpoch, today, selector) ?: return null
        if (today - latest.epoch > MAXIMUM_SIGNAL_AGE_DAYS ||
            !latest.value.isFinite() || latest.value !in cfg.minVal..cfg.maxVal
        ) return null

        val recent = (latest.epoch - RECENT_WINDOW_DAYS + 1..latest.epoch)
            .mapNotNull { epoch -> validValue(rowsByEpoch[epoch]?.let(selector), cfg) }
        if (recent.isEmpty()) return null
        val recentMean = recent.average()

        val baselineEnd = latest.epoch - RECENT_WINDOW_DAYS - BASELINE_GAP_DAYS
        val baselineStart = baselineEnd - BASELINE_WINDOW_DAYS + 1
        val history = (baselineStart..baselineEnd).map { epoch ->
            validValue(rowsByEpoch[epoch]?.let(selector), cfg)
        }
        val state = Baselines.foldHistory(history, cfg)
        if (!state.usable) {
            return MetricAssessment(
                IllnessSignalEngine.SignalReading(0.0, present = false),
                baselineTrusted = false,
                latestDay = latest.day,
                recentMean = recentMean,
                baseline = null,
                delta = null,
                ratio = null,
            )
        }

        val deviation = Baselines.deviation(recentMean, state)
        if (!deviation.z.isFinite() || !deviation.delta.isFinite() || !deviation.ratio.isFinite()) {
            return null
        }
        return MetricAssessment(
            reading = IllnessSignalEngine.SignalReading(
                if (illnessUp) deviation.z else -deviation.z,
                present = state.trusted,
            ),
            baselineTrusted = state.trusted,
            latestDay = latest.day,
            recentMean = recentMean,
            baseline = state.baseline,
            delta = deviation.delta,
            ratio = deviation.ratio,
        )
    }

    private fun skinAssessment(
        rowsByEpoch: Map<Int, DailyMetric>,
        today: Int,
    ): Pair<VitalBands.SkinTempIllnessAssessment, String>? {
        val latest = latestRawValue(rowsByEpoch, today) { it.skinTempDevC } ?: return null
        if (today - latest.epoch > MAXIMUM_SIGNAL_AGE_DAYS || !validSkinValue(latest.value)) return null

        val recent = (latest.epoch - RECENT_WINDOW_DAYS + 1..latest.epoch)
            .map { rowsByEpoch[it]?.skinTempDevC }
        val baselineEnd = latest.epoch - RECENT_WINDOW_DAYS - BASELINE_GAP_DAYS
        val baselineStart = baselineEnd - BASELINE_WINDOW_DAYS + 1
        val baseline = (baselineStart..baselineEnd).map { rowsByEpoch[it]?.skinTempDevC }
        val assessment = VitalBands.skinTempIllnessAssessment(recent, baseline) ?: return null
        return assessment to latest.day
    }

    private data class RawValue(val epoch: Int, val day: String, val value: Double)

    private fun latestRawValue(
        rowsByEpoch: Map<Int, DailyMetric>,
        today: Int,
        selector: (DailyMetric) -> Double?,
    ): RawValue? {
        for (epoch in rowsByEpoch.keys.filter { it <= today }.sortedDescending()) {
            val row = rowsByEpoch[epoch] ?: continue
            val value = selector(row) ?: continue
            return RawValue(epoch, row.day, value)
        }
        return null
    }

    private fun validValue(value: Double?, cfg: MetricCfg): Double? =
        value?.takeIf { it.isFinite() && it in cfg.minVal..cfg.maxVal }

    private fun validSkinValue(value: Double): Boolean {
        if (!value.isFinite()) return false
        return if (VitalBands.isAbsoluteSkinTemp(value)) {
            val cfg = Baselines.metricCfg.getValue("skin_temp")
            value in cfg.minVal..cfg.maxVal
        } else {
            VitalBands.skinTempDeviation(value) != null
        }
    }
}
