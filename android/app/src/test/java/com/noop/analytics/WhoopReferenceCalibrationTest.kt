package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.testing.FakeSharedPreferences
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WhoopReferenceCalibrationTest {
    private fun day(offset: Int): String = LocalDate.of(2026, 1, 1).plusDays(offset.toLong()).toString()

    private fun observations(
        count: Int,
        metric: WhoopComparableMetric = WhoopComparableMetric.RECOVERY_SCORE,
        algorithm: String = "charge-v1",
        noop: (Int) -> Double,
        official: (Int) -> Double,
    ): List<ReferenceMetricObservation> = (0 until count).flatMap { index ->
        listOf(
            ReferenceMetricObservation.officialExport(
                day(index),
                metric,
                official(index),
                "whoop-import-v1",
            ),
            ReferenceMetricObservation.noopComputed(
                day(index),
                metric,
                noop(index),
                algorithm,
            ),
        )
    }

    @Test
    fun currentAlgorithmRevisionsMatchAppleContract() {
        assertEquals("noop-charge-v2", NoopScoreAlgorithmRevision.CHARGE)
        assertEquals("noop-effort-v2", NoopScoreAlgorithmRevision.EFFORT)
        assertEquals("noop-rest-v1", NoopScoreAlgorithmRevision.REST)
    }

    @Test
    fun pairsExactDaysAndAuditsUnsafeRows() {
        val rows = observations(
            count = 3,
            noop = { (10 + it).toDouble() },
            official = { (11 + it).toDouble() },
        ).toMutableList()
        rows += ReferenceMetricObservation.officialExport(
            day(0),
            WhoopComparableMetric.RECOVERY_SCORE,
            99.0,
        )
        rows += ReferenceMetricObservation.noopComputed(
            day(1),
            WhoopComparableMetric.RECOVERY_SCORE,
            30.0,
            "charge-v2",
        )
        rows += ReferenceMetricObservation.noopComputed(
            day(2),
            WhoopComparableMetric.REST_SCORE,
            50.0,
            "charge-v1",
        )
        rows += ReferenceMetricObservation.noopComputed(
            "2026-02-31",
            WhoopComparableMetric.RECOVERY_SCORE,
            50.0,
            "charge-v1",
        )
        rows += ReferenceMetricObservation.officialExport(
            day(3),
            WhoopComparableMetric.RECOVERY_SCORE,
            101.0,
        )

        val report = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            rows,
            "charge-v1",
        )

        assertEquals(listOf(day(1), day(2)), report.pairs.map { it.day })
        assertEquals(2, report.audit.pairedDays)
        assertEquals(1, report.audit.duplicateOfficialDays)
        assertEquals(1, report.audit.wrongNoopAlgorithmVersion)
        assertEquals(3, report.audit.invalidOrWrongMetric)
    }

    @Test
    fun statisticsUseNoopMinusOfficialAndSafeCorrelation() {
        val official = listOf(10.0, 20.0, 30.0)
        val noop = listOf(12.0, 18.0, 33.0)
        val stats = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(3, noop = { noop[it] }, official = { official[it] }),
            "charge-v1",
        ).statistics!!

        assertEquals(3, stats.sampleCount)
        assertEquals(1.0, stats.bias, 1e-12)
        assertEquals(7.0 / 3.0, stats.meanAbsoluteError, 1e-12)
        assertEquals(kotlin.math.sqrt(17.0 / 3.0), stats.rootMeanSquaredError, 1e-12)
        assertTrue(requireNotNull(stats.correlation) > 0.95)

        val constant = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(5, noop = { 50.0 }, official = { (40 + it).toDouble() }),
            "charge-v1",
        )
        assertNull(constant.statistics?.correlation)
    }

    @Test
    fun validatedCalibrationUsesChronologicalHoldoutAndPreservesRaw() {
        val report = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(
                count = 40,
                noop = { (20 + it).toDouble() },
                official = { 5.0 + 1.2 * (20 + it) },
            ),
            "charge-v1",
            PersonalCalibrationConfiguration(
                minimumPairs = 30,
                minimumTrainingPairs = 20,
                minimumHoldoutPairs = 8,
                holdoutFraction = 0.25,
                minimumTrainingCorrelation = 0.5,
            ),
        )

        assertEquals(PersonalCalibrationDecision.VALIDATED, report.calibration.decision)
        val validation = requireNotNull(report.calibration.validation)
        assertEquals(30, validation.trainingCount)
        assertEquals(10, validation.holdoutCount)
        assertEquals(day(29), validation.trainingLastDay)
        assertEquals(day(30), validation.holdoutFirstDay)
        assertTrue(validation.calibratedHoldoutMAE < 1e-10)

        val model = requireNotNull(report.calibration.model)
        assertEquals(5.0, model.intercept, 1e-10)
        assertEquals(1.2, model.slope, 1e-10)
        val estimate = requireNotNull(
            model.apply(
                ReferenceMetricObservation.noopComputed(
                    day(50),
                    WhoopComparableMetric.RECOVERY_SCORE,
                    60.0,
                    "charge-v1",
                ),
            ),
        )
        assertEquals(60.0, estimate.rawNoopValue, 0.0)
        assertEquals(77.0, estimate.calibratedValue, 1e-10)
    }

    @Test
    fun chronologicalHoldoutRejectsRelationshipThatBreaksLater() {
        val report = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(
                count = 40,
                noop = { (30 + it).toDouble() },
                official = { if (it < 30) (40 + it).toDouble() else (20 + it).toDouble() },
            ),
            "charge-v1",
            PersonalCalibrationConfiguration(
                minimumPairs = 30,
                minimumTrainingPairs = 20,
                minimumHoldoutPairs = 8,
                holdoutFraction = 0.25,
                minimumTrainingCorrelation = 0.5,
            ),
        )

        assertEquals(
            PersonalCalibrationDecision.FAILED_HOLDOUT_VALIDATION,
            report.calibration.decision,
        )
        assertNull(report.calibration.model)
        val validation = requireNotNull(report.calibration.validation)
        assertTrue(validation.calibratedHoldoutMAE > validation.rawHoldoutMAE)
    }

    @Test
    fun modelCannotCrossMetricRevisionOrPlausibleRange() {
        val model = requireNotNull(
            WhoopReferenceCalibration.report(
                WhoopComparableMetric.RECOVERY_SCORE,
                observations(
                    40,
                    noop = { (20 + it).toDouble() },
                    official = { 5.0 + 1.2 * (20 + it) },
                ),
                "charge-v1",
            ).calibration.model,
        )

        assertNull(
            model.apply(
                ReferenceMetricObservation.noopComputed(
                    day(50),
                    WhoopComparableMetric.REST_SCORE,
                    60.0,
                    "charge-v1",
                ),
            ),
        )
        assertNull(
            model.apply(
                ReferenceMetricObservation.noopComputed(
                    day(50),
                    WhoopComparableMetric.RECOVERY_SCORE,
                    60.0,
                    "charge-v2",
                ),
            ),
        )
        assertNull(
            model.apply(
                ReferenceMetricObservation.noopComputed(
                    day(50),
                    WhoopComparableMetric.RECOVERY_SCORE,
                    101.0,
                    "charge-v1",
                ),
            ),
        )
    }

    @Test
    fun onlyValidatedRevisionBoundModelPersists() {
        val store = PersonalCalibrationModelStore.forTesting(
            FakeSharedPreferences(),
            "test.calibration",
        )
        val valid = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(
                40,
                noop = { (20 + it).toDouble() },
                official = { 5.0 + 1.2 * (20 + it) },
            ),
            "charge-v1",
        )

        assertTrue(store.saveValidated(valid, 1_700_000_000.0))
        val persisted = requireNotNull(
            store.load(WhoopComparableMetric.RECOVERY_SCORE, "charge-v1"),
        )
        assertEquals(59.0, persisted.latestEstimate.rawNoopValue, 1e-12)
        assertEquals(75.8, persisted.latestEstimate.calibratedValue, 1e-10)
        assertNull(store.load(WhoopComparableMetric.RECOVERY_SCORE, "charge-v2"))

        val insufficient = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(
                10,
                noop = { (20 + it).toDouble() },
                official = { (25 + it).toDouble() },
            ),
            "charge-v1",
        )
        assertFalse(store.saveValidated(insufficient))
        assertNull(store.load(WhoopComparableMetric.RECOVERY_SCORE, "charge-v1"))
    }

    @Test
    fun failedPreferenceCommitNeverReportsCalibrationAsPersisted() {
        val store = PersonalCalibrationModelStore.forTesting(
            FakeSharedPreferences(commitResult = false),
            "test.calibration",
        )
        val report = WhoopReferenceCalibration.report(
            WhoopComparableMetric.RECOVERY_SCORE,
            observations(
                40,
                noop = { (20 + it).toDouble() },
                official = { 5.0 + 1.2 * (20 + it) },
            ),
            "charge-v1",
        )

        assertFalse(store.saveValidated(report))
        assertNull(store.load(WhoopComparableMetric.RECOVERY_SCORE, "charge-v1"))
    }

    @Test
    fun dayValidationRejectsImpossibleOrNonCanonicalDates() {
        assertTrue(WhoopReferenceCalibration.validDay("2026-09-07"))
        assertFalse(WhoopReferenceCalibration.validDay("2026-02-29"))
        assertFalse(WhoopReferenceCalibration.validDay("2026-2-09"))
    }

    @Test
    fun calibrationReceiptCanExcludeAggregateOnlyImportedDays() {
        val raw = IntelligenceEngine.Computed(
            day = "2026-09-06",
            recovery = 70.0,
            strain = 40.0,
            sleepMin = 420.0,
            hrv = 55.0,
            rhr = 52,
        )
        val importedOnly = raw.copy(day = "2026-09-07", rawStrapEvidence = false)

        assertEquals(
            setOf("2026-09-06"),
            listOf(raw, importedOnly).filter { it.rawStrapEvidence }.mapTo(linkedSetOf()) { it.day },
        )
    }

    @Test
    fun restDailyFallbackIsComputedOnlyAndNeverOfficialReference() {
        val row = DailyMetric(
            deviceId = "test",
            day = "2026-09-07",
            totalSleepMin = 420.0,
            efficiency = 0.9,
            deepMin = 80.0,
            remMin = 100.0,
            lightMin = 240.0,
            disturbances = 1,
            restingHr = 52,
            avgHrv = 55.0,
            recovery = 70.0,
            strain = 40.0,
            exerciseCount = 1,
        )

        assertNull(WhoopComparableMetric.REST_SCORE.dailyValue(row))
        assertNotNull(WhoopComparableMetric.REST_SCORE.computedDailyValue(row))
    }
}
