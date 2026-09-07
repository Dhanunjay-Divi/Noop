package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import java.time.LocalDate
import java.time.format.DateTimeParseException
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.sqrt

/**
 * Explicit revisions for NOOP's current transparent score families.
 *
 * A personal presentation transform is never reused across revisions.
 */
object NoopScoreAlgorithmRevision {
    const val CHARGE = "noop-charge-v2"
    const val EFFORT = "noop-effort-v2"
    const val REST = "noop-rest-v1"
}

/**
 * Metrics that can be compared without changing units or pretending a provider's private formula is
 * known. Skin temperature is deliberately absent: the imported value is absolute temperature while
 * NOOP stores a personal-baseline deviation.
 */
enum class WhoopComparableMetric(
    val seriesKey: String,
    val minimum: Double,
    val maximum: Double,
) {
    RECOVERY_SCORE("recovery", 0.0, 100.0),
    EFFORT_SCORE("strain", 0.0, 100.0),
    REST_SCORE("sleep_performance", 0.0, 100.0),
    RESTING_HEART_RATE("rhr", 25.0, 250.0),
    HRV_RMSSD("hrv", 1.0, 500.0),
    RESPIRATORY_RATE("resp_rate", 4.0, 60.0),
    BLOOD_OXYGEN_PERCENT("spo2", 50.0, 100.0),
    TOTAL_SLEEP_MINUTES("sleep_total_min", 0.0, 1_440.0),
    DEEP_SLEEP_MINUTES("sleep_deep_min", 0.0, 1_440.0),
    REM_SLEEP_MINUTES("sleep_rem_min", 0.0, 1_440.0),
    LIGHT_SLEEP_MINUTES("sleep_light_min", 0.0, 1_440.0),
    SLEEP_EFFICIENCY_PERCENT("sleep_efficiency", 0.0, 100.0);

    fun plausible(value: Double): Boolean = value.isFinite() && value in minimum..maximum

    internal fun dailyValue(row: DailyMetric): Double? = when (this) {
        RECOVERY_SCORE -> row.recovery
        EFFORT_SCORE -> row.strain
        // An imported DailyMetric contains sleep inputs, not an official Sleep Performance outcome.
        // Keep the official fallback missing unless the importer wrote the dedicated metric-series row.
        REST_SCORE -> null
        RESTING_HEART_RATE -> row.restingHr?.toDouble()
        HRV_RMSSD -> row.avgHrv
        RESPIRATORY_RATE -> row.respRateBpm
        BLOOD_OXYGEN_PERCENT -> row.spo2Pct
        TOTAL_SLEEP_MINUTES -> row.totalSleepMin
        DEEP_SLEEP_MINUTES -> row.deepMin
        REM_SLEEP_MINUTES -> row.remMin
        LIGHT_SLEEP_MINUTES -> row.lightMin
        SLEEP_EFFICIENCY_PERCENT -> row.efficiency?.times(100.0)
    }

    /** Independent current-score projection. Rest is deterministically derived only on the NOOP side. */
    internal fun computedDailyValue(row: DailyMetric): Double? =
        if (this == REST_SCORE) RestScorer.restFromDaily(row) else dailyValue(row)

    internal fun storedSeriesValue(value: Double): Double =
        if (this == SLEEP_EFFICIENCY_PERCENT) value * 100.0 else value
}

sealed interface ReferenceMetricProvenance {
    data class OfficialExport(val schemaRevision: String?) : ReferenceMetricProvenance
    data class NoopOnDevice(val algorithmVersion: String) : ReferenceMetricProvenance
    data class NoopPersonalCalibration(
        val modelVersion: String,
        val basedOnAlgorithmVersion: String,
    ) : ReferenceMetricProvenance
}

@ConsistentCopyVisibility
data class ReferenceMetricObservation private constructor(
    val day: String,
    val metric: WhoopComparableMetric,
    val value: Double,
    val provenance: ReferenceMetricProvenance,
) {
    companion object {
        fun officialExport(
            day: String,
            metric: WhoopComparableMetric,
            value: Double,
            schemaRevision: String? = null,
        ) = ReferenceMetricObservation(
            day,
            metric,
            value,
            ReferenceMetricProvenance.OfficialExport(schemaRevision),
        )

        fun noopComputed(
            day: String,
            metric: WhoopComparableMetric,
            value: Double,
            algorithmVersion: String,
        ) = ReferenceMetricObservation(
            day,
            metric,
            value,
            ReferenceMetricProvenance.NoopOnDevice(algorithmVersion),
        )
    }
}

data class PairedReferenceDay(
    val day: String,
    val metric: WhoopComparableMetric,
    val official: ReferenceMetricObservation,
    val noop: ReferenceMetricObservation,
)

data class ReferencePairingAudit(
    val suppliedObservations: Int,
    val pairedDays: Int,
    val invalidOrWrongMetric: Int,
    val wrongNoopAlgorithmVersion: Int,
    val duplicateOfficialDays: Int,
    val duplicateNoopDays: Int,
    val unpairedOfficialDays: Int,
    val unpairedNoopDays: Int,
    val unverifiedStoredOfficialDays: Int,
    val unverifiedStoredNoopDays: Int,
)

/** Error is always `NOOP - official`; positive bias means the raw NOOP value is higher. */
data class ReferenceComparisonStatistics(
    val sampleCount: Int,
    val firstDay: String,
    val lastDay: String,
    val officialMean: Double,
    val noopMean: Double,
    val bias: Double,
    val meanAbsoluteError: Double,
    val rootMeanSquaredError: Double,
    val correlation: Double?,
)

enum class PersonalCalibrationDecision {
    INSUFFICIENT_DATA,
    DEGENERATE_TRAINING_DATA,
    UNSTABLE_RELATIONSHIP,
    FAILED_HOLDOUT_VALIDATION,
    VALIDATED,
}

enum class PersonalCalibrationConfidence {
    NONE,
    VALIDATED,
    STRONG,
}

data class PersonalCalibrationValidation(
    val trainingCount: Int,
    val holdoutCount: Int,
    val trainingFirstDay: String,
    val trainingLastDay: String,
    val holdoutFirstDay: String,
    val holdoutLastDay: String,
    val trainingCorrelation: Double?,
    val rawHoldoutMAE: Double,
    val calibratedHoldoutMAE: Double,
    val rawHoldoutRMSE: Double,
    val calibratedHoldoutRMSE: Double,
    val relativeMAEImprovement: Double,
)

/**
 * A validated personal affine presentation transform: `official-like = intercept + slope * raw`.
 *
 * This is not a recovered proprietary formula. The raw score remains untouched.
 */
@ConsistentCopyVisibility
data class PersonalCalibrationModel internal constructor(
    val metric: WhoopComparableMetric,
    val basedOnNoopAlgorithmVersion: String,
    val intercept: Double,
    val slope: Double,
    val trainingCount: Int,
    val trainedThroughDay: String,
    val modelVersion: String = MODEL_VERSION,
) {
    fun apply(observation: ReferenceMetricObservation): CalibratedMetricEstimate? {
        val raw = observation.provenance as? ReferenceMetricProvenance.NoopOnDevice ?: return null
        if (observation.metric != metric ||
            raw.algorithmVersion != basedOnNoopAlgorithmVersion ||
            !metric.plausible(observation.value)
        ) {
            return null
        }
        val transformed = intercept + slope * observation.value
        if (!transformed.isFinite()) return null
        return CalibratedMetricEstimate(
            day = observation.day,
            metric = metric,
            rawNoopValue = observation.value,
            calibratedValue = transformed.coerceIn(metric.minimum, metric.maximum),
            rawProvenance = observation.provenance,
            calibratedProvenance = ReferenceMetricProvenance.NoopPersonalCalibration(
                modelVersion = modelVersion,
                basedOnAlgorithmVersion = basedOnNoopAlgorithmVersion,
            ),
        )
    }

    companion object {
        const val MODEL_VERSION = "noop-personal-affine-v1"
    }
}

data class CalibratedMetricEstimate(
    val day: String,
    val metric: WhoopComparableMetric,
    val rawNoopValue: Double,
    val calibratedValue: Double,
    val rawProvenance: ReferenceMetricProvenance,
    val calibratedProvenance: ReferenceMetricProvenance,
)

data class PersonalCalibrationResult(
    val decision: PersonalCalibrationDecision,
    val confidence: PersonalCalibrationConfidence,
    val reason: String,
    val model: PersonalCalibrationModel?,
    val validation: PersonalCalibrationValidation?,
)

data class PersonalCalibrationConfiguration(
    val minimumPairs: Int = 28,
    val minimumTrainingPairs: Int = 21,
    val minimumHoldoutPairs: Int = 7,
    val holdoutFraction: Double = 0.25,
    val minimumTrainingCorrelation: Double = 0.35,
    val minimumRelativeMAEImprovement: Double = 0.05,
    val minimumSlope: Double = 0.25,
    val maximumSlope: Double = 4.0,
    val strongConfidencePairs: Int = 90,
    val strongConfidenceCorrelation: Double = 0.75,
    val strongConfidenceMAEImprovement: Double = 0.10,
)

data class WhoopReferenceComparisonReport(
    val metric: WhoopComparableMetric,
    val noopAlgorithmVersion: String,
    val pairs: List<PairedReferenceDay>,
    val audit: ReferencePairingAudit,
    val statistics: ReferenceComparisonStatistics?,
    val calibration: PersonalCalibrationResult,
    val latestVerifiedNoopObservation: ReferenceMetricObservation?,
)

enum class WhoopReferenceCalibrationError {
    SOURCE_NAMESPACES_MUST_BE_DISTINCT,
    MISSING_SOURCE_IDENTIFIER,
    MISSING_NOOP_ALGORITHM_VERSION,
}

class WhoopReferenceCalibrationException(
    val reason: WhoopReferenceCalibrationError,
) : IllegalArgumentException(reason.name)

/** Pure comparison/calibration engine plus a bounded local-store loader. */
object WhoopReferenceCalibration {
    fun report(
        metric: WhoopComparableMetric,
        observations: List<ReferenceMetricObservation>,
        noopAlgorithmVersion: String,
        configuration: PersonalCalibrationConfiguration = PersonalCalibrationConfiguration(),
    ): WhoopReferenceComparisonReport {
        var invalid = 0
        var wrongVersion = 0
        val officialByDay = LinkedHashMap<String, ReferenceMetricObservation>()
        val noopByDay = LinkedHashMap<String, ReferenceMetricObservation>()
        val duplicateOfficial = linkedSetOf<String>()
        val duplicateNoop = linkedSetOf<String>()

        for (observation in observations) {
            if (observation.metric != metric ||
                !validDay(observation.day) ||
                !metric.plausible(observation.value)
            ) {
                invalid += 1
                continue
            }
            when (val provenance = observation.provenance) {
                is ReferenceMetricProvenance.OfficialExport -> {
                    if (officialByDay.put(observation.day, observation) != null) {
                        duplicateOfficial += observation.day
                    }
                }
                is ReferenceMetricProvenance.NoopOnDevice -> {
                    if (provenance.algorithmVersion.isBlank() ||
                        noopAlgorithmVersion.isBlank() ||
                        provenance.algorithmVersion != noopAlgorithmVersion
                    ) {
                        wrongVersion += 1
                        continue
                    }
                    if (noopByDay.put(observation.day, observation) != null) {
                        duplicateNoop += observation.day
                    }
                }
                is ReferenceMetricProvenance.NoopPersonalCalibration -> invalid += 1
            }
        }

        duplicateOfficial.forEach(officialByDay::remove)
        duplicateNoop.forEach(noopByDay::remove)

        val pairs = officialByDay.keys
            .intersect(noopByDay.keys)
            .sorted()
            .map { day ->
                PairedReferenceDay(
                    day = day,
                    metric = metric,
                    official = requireNotNull(officialByDay[day]),
                    noop = requireNotNull(noopByDay[day]),
                )
            }
        val audit = ReferencePairingAudit(
            suppliedObservations = observations.size,
            pairedDays = pairs.size,
            invalidOrWrongMetric = invalid,
            wrongNoopAlgorithmVersion = wrongVersion,
            duplicateOfficialDays = duplicateOfficial.size,
            duplicateNoopDays = duplicateNoop.size,
            unpairedOfficialDays = officialByDay.keys.count { it !in noopByDay },
            unpairedNoopDays = noopByDay.keys.count { it !in officialByDay },
            unverifiedStoredOfficialDays = 0,
            unverifiedStoredNoopDays = 0,
        )
        return WhoopReferenceComparisonReport(
            metric = metric,
            noopAlgorithmVersion = noopAlgorithmVersion,
            pairs = pairs,
            audit = audit,
            statistics = statistics(pairs),
            calibration = calibration(metric, pairs, noopAlgorithmVersion, configuration),
            latestVerifiedNoopObservation = noopByDay.keys.maxOrNull()?.let(noopByDay::get),
        )
    }

    /**
     * Load official and computed namespaces independently, accepting only days proven by the current
     * importer manifest and the current completed raw-stream score receipt.
     */
    suspend fun report(
        repo: WhoopRepository,
        metric: WhoopComparableMetric,
        importedDeviceId: String,
        computedDeviceId: String,
        from: String,
        to: String,
        noopAlgorithmVersion: String,
        verifiedOfficialReferenceDays: Set<String>,
        verifiedCurrentNoopDays: Set<String>,
        whoopImportSchemaRevision: String? = null,
        configuration: PersonalCalibrationConfiguration = PersonalCalibrationConfiguration(),
    ): WhoopReferenceComparisonReport {
        if (importedDeviceId.isBlank() || computedDeviceId.isBlank()) {
            throw WhoopReferenceCalibrationException(
                WhoopReferenceCalibrationError.MISSING_SOURCE_IDENTIFIER,
            )
        }
        if (importedDeviceId == computedDeviceId) {
            throw WhoopReferenceCalibrationException(
                WhoopReferenceCalibrationError.SOURCE_NAMESPACES_MUST_BE_DISTINCT,
            )
        }
        if (noopAlgorithmVersion.isBlank()) {
            throw WhoopReferenceCalibrationException(
                WhoopReferenceCalibrationError.MISSING_NOOP_ALGORITHM_VERSION,
            )
        }

        val storedOfficial = loadValues(
            repo,
            importedDeviceId,
            metric,
            from,
            to,
            useComputedDailyValues = false,
        )
        val storedNoop = loadValues(
            repo,
            computedDeviceId,
            metric,
            from,
            to,
            useComputedDailyValues = true,
        )
        val validOfficialDays = verifiedOfficialReferenceDays.filterTo(linkedSetOf(), ::validDay)
        val validNoopDays = verifiedCurrentNoopDays.filterTo(linkedSetOf(), ::validDay)
        val official = storedOfficial.filter { it.first in validOfficialDays }
        val noop = storedNoop.filter { it.first in validNoopDays }
        val observations = buildList {
            official.forEach { (day, value) ->
                add(
                    ReferenceMetricObservation.officialExport(
                        day,
                        metric,
                        value,
                        whoopImportSchemaRevision,
                    ),
                )
            }
            noop.forEach { (day, value) ->
                add(
                    ReferenceMetricObservation.noopComputed(
                        day,
                        metric,
                        value,
                        noopAlgorithmVersion,
                    ),
                )
            }
        }
        val base = report(metric, observations, noopAlgorithmVersion, configuration)
        return base.copy(
            audit = base.audit.copy(
                unverifiedStoredOfficialDays =
                    storedOfficial.map { it.first }.toSet().minus(validOfficialDays).size,
                unverifiedStoredNoopDays =
                    storedNoop.map { it.first }.toSet().minus(validNoopDays).size,
            ),
        )
    }

    private suspend fun loadValues(
        repo: WhoopRepository,
        deviceId: String,
        metric: WhoopComparableMetric,
        from: String,
        to: String,
        useComputedDailyValues: Boolean,
    ): List<Pair<String, Double>> {
        if (useComputedDailyValues) {
            return repo.dailyMetrics(deviceId, from, to)
                .mapNotNull { row ->
                    metric.computedDailyValue(row)?.let { value -> row.day to value }
                }
                .sortedBy(Pair<String, Double>::first)
        }

        val byDay = LinkedHashMap<String, Double>()
        repo.metricSeries(deviceId, metric.seriesKey, from, to).forEach { row ->
            byDay[row.day] = metric.storedSeriesValue(row.value)
        }
        repo.dailyMetrics(deviceId, from, to).forEach { row ->
            if (row.day !in byDay) {
                metric.dailyValue(row)?.let { byDay[row.day] = it }
            }
        }
        return byDay.entries.sortedBy(Map.Entry<String, Double>::key).map { it.key to it.value }
    }

    private fun statistics(pairs: List<PairedReferenceDay>): ReferenceComparisonStatistics? {
        if (pairs.isEmpty()) return null
        val official = pairs.map { it.official.value }
        val noop = pairs.map { it.noop.value }
        val errors = noop.zip(official) { raw, reference -> raw - reference }
        val n = pairs.size.toDouble()
        return ReferenceComparisonStatistics(
            sampleCount = pairs.size,
            firstDay = pairs.first().day,
            lastDay = pairs.last().day,
            officialMean = official.sum() / n,
            noopMean = noop.sum() / n,
            bias = errors.sum() / n,
            meanAbsoluteError = errors.sumOf(::abs) / n,
            rootMeanSquaredError = sqrt(errors.sumOf { it * it } / n),
            correlation = pearson(noop, official),
        )
    }

    private fun calibration(
        metric: WhoopComparableMetric,
        pairs: List<PairedReferenceDay>,
        noopAlgorithmVersion: String,
        c: PersonalCalibrationConfiguration,
    ): PersonalCalibrationResult {
        val minimum = maxOf(c.minimumPairs, c.minimumTrainingPairs + c.minimumHoldoutPairs)
        if (pairs.size < minimum) {
            return PersonalCalibrationResult(
                PersonalCalibrationDecision.INSUFFICIENT_DATA,
                PersonalCalibrationConfidence.NONE,
                "Needs at least $minimum paired days; ${pairs.size} are available.",
                null,
                null,
            )
        }
        val fraction = c.holdoutFraction.coerceIn(0.05, 0.5)
        val holdoutCount = maxOf(c.minimumHoldoutPairs, ceil(pairs.size * fraction).toInt())
        val trainingCount = pairs.size - holdoutCount
        if (trainingCount < c.minimumTrainingPairs || holdoutCount <= 0) {
            return PersonalCalibrationResult(
                PersonalCalibrationDecision.INSUFFICIENT_DATA,
                PersonalCalibrationConfidence.NONE,
                "The chronological split leaves too few training or holdout days.",
                null,
                null,
            )
        }

        val training = pairs.take(trainingCount)
        val holdout = pairs.takeLast(holdoutCount)
        val trainX = training.map { it.noop.value }
        val trainY = training.map { it.official.value }
        val fit = affineFit(trainX, trainY) ?: return PersonalCalibrationResult(
            PersonalCalibrationDecision.DEGENERATE_TRAINING_DATA,
            PersonalCalibrationConfidence.NONE,
            "Training values do not vary enough to fit a stable personal transform.",
            null,
            null,
        )
        val trainCorrelation = pearson(trainX, trainY)
        if (trainCorrelation == null ||
            trainCorrelation < c.minimumTrainingCorrelation ||
            fit.second !in c.minimumSlope..c.maximumSlope
        ) {
            return PersonalCalibrationResult(
                PersonalCalibrationDecision.UNSTABLE_RELATIONSHIP,
                PersonalCalibrationConfidence.NONE,
                "Training relationship is too weak or the fitted slope is outside the safety gate.",
                null,
                null,
            )
        }

        val model = PersonalCalibrationModel(
            metric = metric,
            basedOnNoopAlgorithmVersion = noopAlgorithmVersion,
            intercept = fit.first,
            slope = fit.second,
            trainingCount = trainingCount,
            trainedThroughDay = training.last().day,
        )
        val holdoutOfficial = holdout.map { it.official.value }
        val holdoutRaw = holdout.map { it.noop.value }
        val holdoutCalibrated = holdoutRaw.map {
            (fit.first + fit.second * it).coerceIn(metric.minimum, metric.maximum)
        }
        val rawMae = meanAbsoluteError(holdoutRaw, holdoutOfficial)
        val calibratedMae = meanAbsoluteError(holdoutCalibrated, holdoutOfficial)
        val rawRmse = rootMeanSquaredError(holdoutRaw, holdoutOfficial)
        val calibratedRmse = rootMeanSquaredError(holdoutCalibrated, holdoutOfficial)
        val improvement = if (rawMae > 1e-12) (rawMae - calibratedMae) / rawMae else 0.0
        val validation = PersonalCalibrationValidation(
            trainingCount = trainingCount,
            holdoutCount = holdoutCount,
            trainingFirstDay = training.first().day,
            trainingLastDay = training.last().day,
            holdoutFirstDay = holdout.first().day,
            holdoutLastDay = holdout.last().day,
            trainingCorrelation = trainCorrelation,
            rawHoldoutMAE = rawMae,
            calibratedHoldoutMAE = calibratedMae,
            rawHoldoutRMSE = rawRmse,
            calibratedHoldoutRMSE = calibratedRmse,
            relativeMAEImprovement = improvement,
        )
        if (improvement < c.minimumRelativeMAEImprovement || calibratedRmse > rawRmse) {
            return PersonalCalibrationResult(
                PersonalCalibrationDecision.FAILED_HOLDOUT_VALIDATION,
                PersonalCalibrationConfidence.NONE,
                "The transform did not improve unseen chronological holdout days enough.",
                null,
                validation,
            )
        }
        val strong = pairs.size >= c.strongConfidencePairs &&
            trainCorrelation >= c.strongConfidenceCorrelation &&
            improvement >= c.strongConfidenceMAEImprovement
        return PersonalCalibrationResult(
            PersonalCalibrationDecision.VALIDATED,
            if (strong) PersonalCalibrationConfidence.STRONG
            else PersonalCalibrationConfidence.VALIDATED,
            "Validated on $holdoutCount later days that were not used for fitting.",
            model,
            validation,
        )
    }

    private fun affineFit(x: List<Double>, y: List<Double>): Pair<Double, Double>? {
        if (x.size != y.size || x.size < 2) return null
        val meanX = x.average()
        val meanY = y.average()
        var covariance = 0.0
        var varianceX = 0.0
        x.indices.forEach { index ->
            val dx = x[index] - meanX
            covariance += dx * (y[index] - meanY)
            varianceX += dx * dx
        }
        if (varianceX <= 1e-12) return null
        val slope = covariance / varianceX
        val intercept = meanY - slope * meanX
        return if (slope.isFinite() && intercept.isFinite()) intercept to slope else null
    }

    private fun pearson(x: List<Double>, y: List<Double>): Double? {
        if (x.size != y.size || x.size < 3) return null
        val meanX = x.average()
        val meanY = y.average()
        var numerator = 0.0
        var sx = 0.0
        var sy = 0.0
        x.indices.forEach { index ->
            val dx = x[index] - meanX
            val dy = y[index] - meanY
            numerator += dx * dy
            sx += dx * dx
            sy += dy * dy
        }
        if (sx <= 1e-12 || sy <= 1e-12) return null
        return (numerator / sqrt(sx * sy)).coerceIn(-1.0, 1.0)
    }

    private fun meanAbsoluteError(predicted: List<Double>, actual: List<Double>): Double {
        if (predicted.size != actual.size || predicted.isEmpty()) return 0.0
        return predicted.indices.sumOf { abs(predicted[it] - actual[it]) } / predicted.size
    }

    private fun rootMeanSquaredError(predicted: List<Double>, actual: List<Double>): Double {
        if (predicted.size != actual.size || predicted.isEmpty()) return 0.0
        return sqrt(
            predicted.indices.sumOf {
                val delta = predicted[it] - actual[it]
                delta * delta
            } / predicted.size,
        )
    }

    internal fun validDay(day: String): Boolean = try {
        LocalDate.parse(day)
        day.length == 10
    } catch (_: DateTimeParseException) {
        false
    }
}
