package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import kotlin.math.exp
import kotlin.math.sqrt

/**
 * Evidence-gated overnight autonomic load on the same 0..3 scale as [DaytimeStress].
 *
 * Every published point needs both dense heart rate and a clean R-R-derived RMSSD value.
 * The whole result fails closed unless at least 60% of the sleep window is covered. This is
 * a NOOP estimate, not WHOOP's proprietary Sleep Stress score or a clinical measurement.
 */
object SleepStress {
    const val BUCKET_SECONDS = 300L
    const val MIN_HR_SAMPLES_PER_BUCKET = 60
    const val MIN_COVERED_BUCKETS = 6
    const val MIN_COVERAGE_FRACTION = 0.60
    const val MEDIUM_BAND_FLOOR = 1.0
    const val HIGH_BAND_FLOOR = 2.0

    /** Keeps an ordinary resting window low until HR rises and/or RMSSD falls materially. */
    private const val SLEEP_BASELINE_OFFSET = 2.0

    enum class Band { LOW, MEDIUM, HIGH }

    data class Point(
        val startTs: Long,
        val level: Double,
        val meanHr: Double,
        val rmssd: Double,
    ) {
        val band: Band
            get() = when {
                level >= HIGH_BAND_FLOOR -> Band.HIGH
                level >= MEDIUM_BAND_FLOOR -> Band.MEDIUM
                else -> Band.LOW
            }
    }

    data class Result(
        val points: List<Point>,
        val eligibleBucketCount: Int,
        val coverageFraction: Double,
    ) {
        fun bucketCount(band: Band): Int = points.count { it.band == band }

        fun fraction(band: Band): Double =
            if (points.isEmpty()) 0.0 else bucketCount(band).toDouble() / points.size

        fun durationSeconds(band: Band): Long = bucketCount(band) * BUCKET_SECONDS
    }

    /** Returns null unless the night has enough jointly-covered HR and clean R-R windows. */
    fun analyze(
        hr: List<HrSample>,
        rr: List<RrInterval>,
        startTs: Long,
        endTs: Long,
    ): Result? {
        if (endTs <= startTs) return null
        val eligibleCount = ((endTs - startTs) / BUCKET_SECONDS).toInt()
        if (eligibleCount < MIN_COVERED_BUCKETS) return null

        val hrByBucket = List(eligibleCount) { ArrayList<Double>() }
        val rrByBucket = List(eligibleCount) { ArrayList<Double>() }

        for (sample in hr) {
            if (sample.ts < startTs || sample.ts >= endTs) continue
            val index = ((sample.ts - startTs) / BUCKET_SECONDS).toInt()
            if (index in 0 until eligibleCount) hrByBucket[index].add(sample.bpm.toDouble())
        }
        for (sample in rr) {
            if (sample.ts < startTs || sample.ts >= endTs) continue
            val index = ((sample.ts - startTs) / BUCKET_SECONDS).toInt()
            if (index in 0 until eligibleCount) rrByBucket[index].add(sample.rrMs.toDouble())
        }

        data class Aggregate(val index: Int, val meanHr: Double, val rmssd: Double)

        val aggregates = ArrayList<Aggregate>(eligibleCount)
        for (index in 0 until eligibleCount) {
            val hrs = hrByBucket[index]
            if (hrs.size < MIN_HR_SAMPLES_PER_BUCKET) continue
            val hrv = HrvAnalyzer.analyzeRaw(rrByBucket[index])
            val rmssd = hrv.rmssd
            if (hrv.nClean < HrvAnalyzer.MIN_BEATS || rmssd == null || !rmssd.isFinite()) continue
            val meanHr = hrs.average()
            if (!meanHr.isFinite()) continue
            aggregates.add(Aggregate(index, meanHr, rmssd))
        }

        val coverage = aggregates.size.toDouble() / eligibleCount
        if (aggregates.size < MIN_COVERED_BUCKETS || coverage < MIN_COVERAGE_FRACTION) return null

        val heartRates = aggregates.map { it.meanHr }
        val rmssdValues = aggregates.map { it.rmssd }
        val calmHr = quantile(heartRates.sorted(), 0.25)
        val calmRmssd = quantile(rmssdValues.sorted(), 0.75)
        val sdHr = standardDeviation(heartRates)
        val sdRmssd = standardDeviation(rmssdValues)

        val points = aggregates.map { aggregate ->
            var raw = 0.0
            if (sdHr > 0.0001) raw += (aggregate.meanHr - calmHr) / sdHr
            if (sdRmssd > 0.0001) raw += (calmRmssd - aggregate.rmssd) / sdRmssd
            val level = (3.0 / (1.0 + exp(-(raw - SLEEP_BASELINE_OFFSET)))).coerceIn(0.0, 3.0)
            Point(
                startTs = startTs + aggregate.index * BUCKET_SECONDS,
                level = level,
                meanHr = aggregate.meanHr,
                rmssd = aggregate.rmssd,
            )
        }

        return Result(points, eligibleCount, coverage)
    }

    private fun standardDeviation(values: List<Double>): Double {
        if (values.size <= 1) return 0.0
        val mean = values.average()
        return sqrt(values.sumOf { (it - mean) * (it - mean) } / values.size)
    }

    private fun quantile(sorted: List<Double>, q: Double): Double {
        if (sorted.isEmpty()) return 0.0
        if (sorted.size == 1) return sorted.first()
        val position = q.coerceIn(0.0, 1.0) * (sorted.size - 1)
        val lower = position.toInt()
        val upper = minOf(lower + 1, sorted.lastIndex)
        val fraction = position - lower
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}
