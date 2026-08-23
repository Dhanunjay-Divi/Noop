package com.noop.analytics

import com.noop.data.DailyMetric
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Heart-rate variability.
 *
 * Ported verbatim from `AppModel.rmssd` in the hardware-verified Swift reference
 * (`Strand/App/AppModel.swift`). RMSSD = root-mean-square of successive R-R
 * interval differences (milliseconds in, milliseconds out).
 */
object Hrv {
    /**
     * Root mean square of successive differences over a list of R-R intervals (ms).
     *
     * Returns 0.0 when fewer than two intervals are available (matching the Swift
     * guard `rr.count >= 2`).
     */
    fun rmssd(rr: List<Int>): Double {
        if (rr.size < 2) return 0.0
        var sum = 0.0
        var n = 0
        for (i in 1 until rr.size) {
            val d = (rr[i] - rr[i - 1]).toDouble()
            sum += d * d
            n += 1
        }
        return if (n > 0) sqrt(sum / n.toDouble()) else 0.0
    }
}

/**
 * Heart-rate training zones.
 *
 * Ported from the zone ladder in `AppModel.coachZone` (`Strand/App/AppModel.swift`):
 * pct >= 0.9 → 5, >= 0.8 → 4, >= 0.7 → 3, >= 0.6 → 2, else 1.
 */
object Zones {
    /**
     * Zone (1..5) for a heart rate given an estimated maximum heart rate.
     *
     * Mirrors the Swift `pct = hr / maxHR` ladder. If [hrMax] is non-positive the
     * percentage is undefined, so we fall back to the lowest zone.
     */
    fun zone(hr: Int, hrMax: Int): Int {
        if (hrMax <= 0) return 1
        val pct = hr.toDouble() / hrMax.toDouble()
        return when {
            pct >= 0.9 -> 5
            pct >= 0.8 -> 4
            pct >= 0.7 -> 3
            pct >= 0.6 -> 2
            else -> 1
        }
    }

    /**
     * Tanaka maximum-heart-rate estimate: round(208 - 0.7 * age).
     */
    fun hrMaxTanaka(age: Int): Int = (208.0 - 0.7 * age).roundToInt()
}

/** Shared Android adapter for the calendar-aware multi-signal wellness check. */
object IllnessWatch {
    data class Assessment(
        val prepared: IllnessSignalPipeline.Prepared,
        val result: IllnessSignalEngine.Result,
        val distance: IllnessDistance.Result?,
    )

    fun assess(
        days: List<DailyMetric>,
        todayKey: String,
        context: IllnessSignalEngine.Context = IllnessSignalEngine.Context(),
    ): Assessment {
        val prepared = IllnessSignalPipeline.prepare(days, todayKey)
        val result = IllnessSignalEngine.evaluate(
            inputs = prepared.inputs,
            context = context.copy(baselineTrusted = prepared.baselineTrusted),
            firedLabels = prepared.firedLabels,
        )
        return Assessment(
            prepared = prepared,
            result = result,
            distance = IllnessDistance.evaluate(prepared.distanceFeatures, correlation = null),
        )
    }

    fun banner(result: IllnessSignalEngine.Result): String? =
        result.copy.takeIf {
            result.level == IllnessSignalEngine.Level.RAISED ||
                result.level == IllnessSignalEngine.Level.ALREADY_UNWELL
        }

    /** Production callers must pass the actual local day so stale imports cannot look current. */
    fun evaluate(
        days: List<DailyMetric>,
        todayKey: String,
        context: IllnessSignalEngine.Context = IllnessSignalEngine.Context(),
    ): String? = banner(assess(days, todayKey, context).result)

    /**
     * Source-compatible pure helper for historical tests and tools. It anchors to the newest supplied
     * civil day; app and service code deliberately use the explicit-today overload above.
     */
    fun evaluate(days: List<DailyMetric>): String? {
        val newest = days.maxOfOrNull { it.day } ?: return null
        return evaluate(days, newest)
    }
}
