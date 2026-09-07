package com.noop.analytics

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import kotlin.math.abs

data class PersistedPersonalCalibration(
    val model: PersonalCalibrationModel,
    val validation: PersonalCalibrationValidation,
    val confidence: PersonalCalibrationConfidence,
    val latestEstimate: CalibratedMetricEstimate,
    val savedAtUnixSeconds: Double,
)

/**
 * Tiny local persistence for validated presentation transforms.
 *
 * Every load fully validates revision, coefficients, holdout evidence, provenance, and the stored
 * estimate. Invalid or stale records are deleted instead of being applied.
 */
class PersonalCalibrationModelStore private constructor(
    private val preferences: SharedPreferences,
    private val namespace: String = "noop.personalCalibration.v1",
) {
    fun saveValidated(
        report: WhoopReferenceComparisonReport,
        savedAtUnixSeconds: Double = System.currentTimeMillis() / 1_000.0,
    ): Boolean {
        val calibration = report.calibration
        val model = calibration.model
        val validation = calibration.validation
        val raw = report.latestVerifiedNoopObservation
        val estimate = if (model != null && raw != null) model.apply(raw) else null
        if (calibration.decision != PersonalCalibrationDecision.VALIDATED ||
            calibration.confidence == PersonalCalibrationConfidence.NONE ||
            model == null ||
            validation == null ||
            estimate == null
        ) {
            remove(report.metric, report.noopAlgorithmVersion)
            return false
        }
        val record = PersistedPersonalCalibration(
            model,
            validation,
            calibration.confidence,
            estimate,
            savedAtUnixSeconds,
        )
        if (!isValid(record, report.metric, report.noopAlgorithmVersion)) {
            remove(report.metric, report.noopAlgorithmVersion)
            return false
        }
        val storageKey = key(report.metric, report.noopAlgorithmVersion)
        // Invalidate first so a crash or disk failure can only remove calibration, never leave an older
        // same-revision model eligible after new evidence failed to persist.
        if (!preferences.edit().remove(storageKey).commit()) return false
        val committed = preferences.edit()
            .putString(storageKey, encode(record).toString())
            .commit()
        if (!committed) {
            preferences.edit().remove(storageKey).commit()
        }
        return committed
    }

    fun load(
        metric: WhoopComparableMetric,
        noopAlgorithmVersion: String,
    ): PersistedPersonalCalibration? {
        val storageKey = key(metric, noopAlgorithmVersion)
        val raw = preferences.getString(storageKey, null) ?: return null
        val record = runCatching { decode(JSONObject(raw)) }.getOrNull()
        if (record == null || !isValid(record, metric, noopAlgorithmVersion)) {
            preferences.edit().remove(storageKey).commit()
            return null
        }
        return record
    }

    fun remove(metric: WhoopComparableMetric, noopAlgorithmVersion: String): Boolean =
        preferences.edit().remove(key(metric, noopAlgorithmVersion)).commit()

    private fun key(metric: WhoopComparableMetric, algorithm: String) =
        "$namespace.${metric.name}.$algorithm"

    private fun encode(record: PersistedPersonalCalibration): JSONObject {
        val model = record.model
        val validation = record.validation
        val estimate = record.latestEstimate
        return JSONObject()
            .put("metric", model.metric.name)
            .put("algorithm", model.basedOnNoopAlgorithmVersion)
            .put("model_version", model.modelVersion)
            .put("intercept", model.intercept)
            .put("slope", model.slope)
            .put("training_count", model.trainingCount)
            .put("trained_through", model.trainedThroughDay)
            .put("validation", JSONObject()
                .put("training_count", validation.trainingCount)
                .put("holdout_count", validation.holdoutCount)
                .put("training_first", validation.trainingFirstDay)
                .put("training_last", validation.trainingLastDay)
                .put("holdout_first", validation.holdoutFirstDay)
                .put("holdout_last", validation.holdoutLastDay)
                .put("training_correlation", validation.trainingCorrelation)
                .put("raw_mae", validation.rawHoldoutMAE)
                .put("calibrated_mae", validation.calibratedHoldoutMAE)
                .put("raw_rmse", validation.rawHoldoutRMSE)
                .put("calibrated_rmse", validation.calibratedHoldoutRMSE)
                .put("relative_mae_improvement", validation.relativeMAEImprovement))
            .put("confidence", record.confidence.name)
            .put("estimate", JSONObject()
                .put("day", estimate.day)
                .put("raw", estimate.rawNoopValue)
                .put("calibrated", estimate.calibratedValue))
            .put("saved_at", record.savedAtUnixSeconds)
    }

    private fun decode(json: JSONObject): PersistedPersonalCalibration {
        val metric = WhoopComparableMetric.valueOf(json.getString("metric"))
        val algorithm = json.getString("algorithm")
        val modelVersion = json.getString("model_version")
        val validationJson = json.getJSONObject("validation")
        val trainingCorrelation = validationJson.getDouble("training_correlation")
        val validation = PersonalCalibrationValidation(
            trainingCount = validationJson.getInt("training_count"),
            holdoutCount = validationJson.getInt("holdout_count"),
            trainingFirstDay = validationJson.getString("training_first"),
            trainingLastDay = validationJson.getString("training_last"),
            holdoutFirstDay = validationJson.getString("holdout_first"),
            holdoutLastDay = validationJson.getString("holdout_last"),
            trainingCorrelation = trainingCorrelation,
            rawHoldoutMAE = validationJson.getDouble("raw_mae"),
            calibratedHoldoutMAE = validationJson.getDouble("calibrated_mae"),
            rawHoldoutRMSE = validationJson.getDouble("raw_rmse"),
            calibratedHoldoutRMSE = validationJson.getDouble("calibrated_rmse"),
            relativeMAEImprovement =
                validationJson.getDouble("relative_mae_improvement"),
        )
        val model = PersonalCalibrationModel(
            metric = metric,
            basedOnNoopAlgorithmVersion = algorithm,
            intercept = json.getDouble("intercept"),
            slope = json.getDouble("slope"),
            trainingCount = json.getInt("training_count"),
            trainedThroughDay = json.getString("trained_through"),
            modelVersion = modelVersion,
        )
        val estimateJson = json.getJSONObject("estimate")
        val estimate = CalibratedMetricEstimate(
            day = estimateJson.getString("day"),
            metric = metric,
            rawNoopValue = estimateJson.getDouble("raw"),
            calibratedValue = estimateJson.getDouble("calibrated"),
            rawProvenance = ReferenceMetricProvenance.NoopOnDevice(algorithm),
            calibratedProvenance = ReferenceMetricProvenance.NoopPersonalCalibration(
                modelVersion,
                algorithm,
            ),
        )
        return PersistedPersonalCalibration(
            model = model,
            validation = validation,
            confidence = PersonalCalibrationConfidence.valueOf(json.getString("confidence")),
            latestEstimate = estimate,
            savedAtUnixSeconds = json.getDouble("saved_at"),
        )
    }

    private fun isValid(
        record: PersistedPersonalCalibration,
        metric: WhoopComparableMetric,
        noopAlgorithmVersion: String,
    ): Boolean {
        val model = record.model
        val validation = record.validation
        val estimate = record.latestEstimate
        val rawProvenance =
            estimate.rawProvenance as? ReferenceMetricProvenance.NoopOnDevice ?: return false
        val calibratedProvenance =
            estimate.calibratedProvenance as? ReferenceMetricProvenance.NoopPersonalCalibration
                ?: return false
        if (model.modelVersion != PersonalCalibrationModel.MODEL_VERSION ||
            model.metric != metric ||
            model.basedOnNoopAlgorithmVersion != noopAlgorithmVersion ||
            !model.intercept.isFinite() ||
            abs(model.intercept) > 400.0 ||
            !model.slope.isFinite() ||
            model.slope !in 0.25..4.0 ||
            model.trainingCount < 21 ||
            model.trainingCount != validation.trainingCount ||
            model.trainedThroughDay != validation.trainingLastDay ||
            validation.holdoutCount < 7 ||
            validation.trainingCorrelation == null ||
            !validation.trainingCorrelation.isFinite() ||
            validation.trainingCorrelation < 0.35 ||
            listOf(
                validation.rawHoldoutMAE,
                validation.calibratedHoldoutMAE,
                validation.rawHoldoutRMSE,
                validation.calibratedHoldoutRMSE,
                validation.relativeMAEImprovement,
            ).any { !it.isFinite() || it < 0.0 } ||
            validation.relativeMAEImprovement < 0.05 ||
            validation.calibratedHoldoutMAE > validation.rawHoldoutMAE ||
            validation.calibratedHoldoutRMSE > validation.rawHoldoutRMSE ||
            !WhoopReferenceCalibration.validDay(validation.trainingFirstDay) ||
            !WhoopReferenceCalibration.validDay(validation.trainingLastDay) ||
            !WhoopReferenceCalibration.validDay(validation.holdoutFirstDay) ||
            !WhoopReferenceCalibration.validDay(validation.holdoutLastDay) ||
            validation.trainingFirstDay > validation.trainingLastDay ||
            validation.trainingLastDay >= validation.holdoutFirstDay ||
            validation.holdoutFirstDay > validation.holdoutLastDay ||
            estimate.metric != metric ||
            !metric.plausible(estimate.rawNoopValue) ||
            !metric.plausible(estimate.calibratedValue) ||
            rawProvenance.algorithmVersion != noopAlgorithmVersion ||
            calibratedProvenance.modelVersion != model.modelVersion ||
            calibratedProvenance.basedOnAlgorithmVersion != noopAlgorithmVersion ||
            !WhoopReferenceCalibration.validDay(estimate.day) ||
            estimate.day < model.trainedThroughDay ||
            record.confidence == PersonalCalibrationConfidence.NONE ||
            !record.savedAtUnixSeconds.isFinite() ||
            record.savedAtUnixSeconds <= 0.0
        ) {
            return false
        }
        val expected = (model.intercept + model.slope * estimate.rawNoopValue)
            .coerceIn(metric.minimum, metric.maximum)
        return abs(expected - estimate.calibratedValue) <= 1e-9
    }

    companion object {
        private const val PREFERENCES_NAME = "noop.personal-calibration"

        fun from(context: Context): PersonalCalibrationModelStore =
            PersonalCalibrationModelStore(
                context.applicationContext.getSharedPreferences(
                    PREFERENCES_NAME,
                    Context.MODE_PRIVATE,
                ),
            )

        internal fun forTesting(
            preferences: SharedPreferences,
            namespace: String = "noop.personalCalibration.v1",
        ) = PersonalCalibrationModelStore(preferences, namespace)
    }
}
