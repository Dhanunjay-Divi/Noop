package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

/** Mirror of the Swift FitnessAgeEngineTests — identical inputs and expected numbers (parity guard). */
class FitnessAgeEngineTest {

    @Test fun orchestratorRejectsUnconfirmedSeedProfile() {
        val days = (1..4).map { i ->
            DailyMetric(
                deviceId = "test", day = "2026-08-0$i", totalSleepMin = 420.0,
                efficiency = 0.9, deepMin = 80.0, remMin = 100.0, lightMin = 240.0,
                disturbances = 1, restingHr = 60, avgHrv = 55.0,
                recovery = null, strain = 55.0, exerciseCount = 1,
            )
        }
        val profile = UserProfile(
            age = 30.0, sex = "male", ageInputConfirmed = false, sexInputConfirmed = false,
        )
        assertTrue(IntelligenceEngine.fitnessAgeRows(
            days, profile, "test-noop", "2026-08-08",
        ).isEmpty())
    }

    @Test fun vo2maxMen() =
        assertEquals(46.275, FitnessAgeEngine.estimateVO2max(40.0, "male", 90.0, 65.0, 5.0), 1e-3)

    @Test fun vo2maxWomen() =
        assertEquals(37.72, FitnessAgeEngine.estimateVO2max(40.0, "female", 80.0, 65.0, 5.0), 1e-3)

    @Test fun supportedSexNormalizationUsesTheSameCoefficients() {
        assertEquals(
            FitnessAgeEngine.compute(40.0, "female", 65.0, 5.0, 80.0),
            FitnessAgeEngine.compute(40.0, "  FEMALE\n", 65.0, 5.0, 80.0),
        )
    }

    @Test fun bmiHelper() =
        assertEquals(25.249, FitnessAgeEngine.bmi(80.0, 178.0), 1e-3)

    @Test fun referenceFitPersonEqualsChronoAge() {
        assertEquals(40.0, FitnessAgeEngine.fitnessAge(40.0, "male", 65.0, 5.0), 1e-9)
        assertEquals(55.0, FitnessAgeEngine.fitnessAge(55.0, "female", 65.0, 5.0), 1e-9)
    }

    @Test fun fitterIsYounger() =
        assertEquals(28.33, FitnessAgeEngine.fitnessAge(40.0, "male", 50.0, 10.0), 0.05)

    @Test fun unfitterIsOlder() =
        assertEquals(50.15, FitnessAgeEngine.fitnessAge(40.0, "male", 80.0, 2.0), 0.05)

    @Test fun clampHigh() = assertEquals(80.0, FitnessAgeEngine.fitnessAge(75.0, "male", 120.0, 0.0), 1e-9)
    @Test fun clampLow() = assertEquals(20.0, FitnessAgeEngine.fitnessAge(25.0, "male", 35.0, 15.0), 1e-9)

    @Test fun paiSedentary() = assertEquals(0.0, FitnessAgeEngine.physicalActivityIndex(0, 0.0, 0.0), 1e-9)
    @Test fun paiHigh() = assertEquals(15.0, FitnessAgeEngine.physicalActivityIndex(7, 75.0, 0.8), 1e-9)
    @Test fun paiModerate() = assertEquals(3.75, FitnessAgeEngine.physicalActivityIndex(3, 40.0, 0.3), 1e-9)

    @Test fun paiFromStrain() {
        assertEquals(0.0, FitnessAgeEngine.physicalActivityIndexFromStrain(0, 0.0), 1e-9)
        assertEquals(15.0, FitnessAgeEngine.physicalActivityIndexFromStrain(7, 90.0), 1e-9)
        assertEquals(3.75, FitnessAgeEngine.physicalActivityIndexFromStrain(3, 45.0), 1e-9)
        assertEquals(5.0, FitnessAgeEngine.physicalActivityIndexFromStrain(4, 60.0), 1e-9)
    }

    @Test fun computeReferencePerson() {
        val r = FitnessAgeEngine.compute(40.0, "male", 65.0, 5.0)
        assertNotNull(r)
        assertEquals(40.0, r!!.fitnessAge, 1e-9)
        assertEquals(0.0, r.deltaYears, 1e-9)
        assertNull(r.vo2max)
        assertFalse(r.lowerConfidence)
    }

    @Test fun computeWithWaistFillsVO2max() {
        val r = FitnessAgeEngine.compute(40.0, "male", 65.0, 5.0, waistCm = 90.0)
        assertEquals(46.275, r!!.vo2max!!, 1e-3)
    }

    @Test fun computeUnsupportedSexUnavailable() =
        assertNull(FitnessAgeEngine.compute(40.0, "nonbinary", 60.0, 6.0))

    @Test fun computeOutsideValidatedAgeRangeUnavailable() {
        assertNull(FitnessAgeEngine.compute(19.0, "male", 60.0, 6.0))
        assertNull(FitnessAgeEngine.compute(81.0, "female", 60.0, 6.0))
    }

    @Test fun computeNilNoRhr() = assertNull(FitnessAgeEngine.compute(40.0, "male", 0.0, 7.5))

    @Test fun computeRejectsCorruptPhysiologyAndActivityInputs() {
        assertNull(FitnessAgeEngine.compute(40.0, "male", 1.0, 7.5))
        assertNull(FitnessAgeEngine.compute(40.0, "male", Double.NaN, 7.5))
        assertNull(FitnessAgeEngine.compute(40.0, "male", 60.0, -1.0))
        assertNull(FitnessAgeEngine.compute(40.0, "male", 60.0, Double.POSITIVE_INFINITY))
    }

    @Test fun invalidWaistDoesNotBlockHeadlineOrProduceVo2max() {
        val result = FitnessAgeEngine.compute(40.0, "male", 60.0, 5.0, 1.0)
        assertNotNull(result)
        assertNull(result?.vo2max)
    }

    // Readiness checklist
    @Test fun readinessAllPresentIsReady() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 7, 7, true)
        assertEquals(FitnessAgeConfidence.READY, r.confidence)
        assertTrue(r.canCompute)
        assertTrue(r.items.all { it.status == FitnessReadinessStatus.SATISFIED })
        assertEquals(5, r.items.size)
    }

    @Test fun readinessMissingRhrIsNotReady() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 0, 7, true)
        assertEquals(FitnessAgeConfidence.NOT_READY, r.confidence)
        assertFalse(r.canCompute)
        assertEquals(FitnessReadinessStatus.MISSING, r.items.first { it.key == "rhr" }.status)
    }

    @Test fun readinessPartialIsEstimate() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 5, 4, false)
        assertEquals(FitnessAgeConfidence.ESTIMATE, r.confidence)
        assertTrue(r.canCompute)
        val waist = r.items.first { it.key == "waist" }
        assertEquals(FitnessReadinessStatus.MISSING, waist.status)
        assertEquals(FitnessReadinessRole.UNLOCKS_VO2MAX, waist.role)
        assertFalse(waist.required)
    }

    @Test fun readinessMissingActivityIsNotReady() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 7, 0, true)
        assertEquals(FitnessAgeConfidence.NOT_READY, r.confidence)
        assertFalse(r.canCompute)
        val activity = r.items.first { it.key == "activity" }
        assertTrue(activity.required)
        assertEquals(FitnessReadinessStatus.MISSING, activity.status)
    }

    @Test fun readinessMissingAgeIsNotReady() {
        assertEquals(FitnessAgeConfidence.NOT_READY,
            FitnessAgeEngine.assessReadiness(false, true, 7, 7, true).confidence)
    }

    @Test fun readinessNoBodyMetricsStillReady() {
        assertEquals(FitnessAgeConfidence.READY,
            FitnessAgeEngine.assessReadiness(true, true, 7, 6, false).confidence)
    }

    @Test fun coverageDaysUntilReadyTracksEitherRequiredSignal() {
        assertEquals(4, FitnessAgeEngine.coverageDaysUntilReady(0))
        assertEquals(2, FitnessAgeEngine.coverageDaysUntilReady(2))
        assertEquals(0, FitnessAgeEngine.coverageDaysUntilReady(4))
        assertEquals(0, FitnessAgeEngine.coverageDaysUntilReady(7))
    }
}
