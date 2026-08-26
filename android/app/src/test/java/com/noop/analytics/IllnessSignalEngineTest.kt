package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of the Swift IllnessSignalEngineTests — identical inputs and expected outputs (parity guard). */
class IllnessSignalEngineTest {

    private val labels = mapOf(
        "restingHR" to "RHR +6",
        "skinTemp" to "skin temp +0.7 °C",
        "hrv" to "HRV −22%",
        "respiration" to "respiration up",
    )

    private fun reading(z: Double) = IllnessSignalEngine.SignalReading(z)

    @Test fun classicThreeSignalPatternRaises() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(IllnessSignalEngine.Level.RAISED, r.level)
        assertTrue(r.score >= IllnessSignalEngine.raiseThreshold)
        assertEquals(3, r.signalCount)
        assertEquals(3, r.trustedSignalCount)
        assertEquals(IllnessSignalEngine.DisplayState.ALERT, r.displayState)
        assertEquals(listOf("RHR +6", "skin temp +0.7 °C", "HRV −22%"), r.firedSignals)
        assertTrue(r.suppressedBy.isEmpty())
        assertTrue(r.copy.contains("not a diagnosis"))
    }

    @Test fun alcoholTagDoesNotSuppress() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val raised = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        val contextual = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(alcohol = true), labels)
        assertEquals(IllnessSignalEngine.Level.RAISED, contextual.level)
        assertEquals(listOf("alcohol"), contextual.suppressedBy)
        assertEquals(raised.score, contextual.score, 1e-9)
        assertTrue(contextual.copy.contains("alcohol"))
        assertTrue(contextual.copy.contains("does not rule out"))
        assertTrue(contextual.copy.contains("not a diagnosis"))
    }

    @Test fun stressSaunaTravelRemainRaisedWithReason() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val stress = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(stress = true), labels)
        assertEquals(IllnessSignalEngine.Level.RAISED, stress.level)
        assertEquals(listOf("stress"), stress.suppressedBy)

        val sauna = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(sauna = true), labels)
        assertEquals(listOf("sauna"), sauna.suppressedBy)

        val travel = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(travelPhaseJump = true), labels)
        assertEquals(listOf("travel"), travel.suppressedBy)
        assertTrue(travel.copy.contains("travel"))
    }

    @Test fun multipleConfoundersJoinNaturally() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(alcohol = true, stress = true), labels)
        assertEquals(listOf("alcohol", "stress"), r.suppressedBy)
        assertTrue(r.copy.contains("alcohol and stress"))
    }

    @Test fun recentMedicationChangeIsContextOnly() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val raw = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        val contextual = IllnessSignalEngine.evaluate(
            inputs,
            IllnessSignalEngine.Context(recentMedicationChange = true),
            labels,
        )
        assertEquals(raw.level, contextual.level)
        assertEquals(raw.score, contextual.score, 1e-9)
        assertEquals(raw.signalCount, contextual.signalCount)
        assertEquals(listOf("a recent medication change"), contextual.suppressedBy)
        assertTrue(contextual.copy.contains("recent medication change"))
        assertTrue(contextual.copy.contains("does not rule out"))
    }

    @Test fun alreadyUnwellSwitchesCopy() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(alreadyUnwell = true), labels)
        assertEquals(IllnessSignalEngine.Level.ALREADY_UNWELL, r.level)
        assertTrue(r.copy.contains("feeling unwell"))
        assertTrue(r.copy.contains("signals also shifted"))
        assertTrue(r.copy.contains("cannot assess severity"))
        assertFalse(r.copy.contains("Heads-up"))
    }

    @Test fun singleSignalDoesNotRaise() {
        val inputs = IllnessSignalEngine.Inputs(restingHR = reading(4.0))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(IllnessSignalEngine.Level.QUIET, r.level)
        assertEquals(1, r.signalCount)
        assertEquals(1, r.trustedSignalCount)
        assertEquals(IllnessSignalEngine.DisplayState.BUILDING, r.displayState)
    }

    @Test fun untrustedBaselineStaysSilent() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(
            inputs, IllnessSignalEngine.Context(baselineTrusted = false), labels)
        assertEquals(IllnessSignalEngine.Level.QUIET, r.level)
        assertEquals(0, r.trustedSignalCount)
        assertEquals(IllnessSignalEngine.DisplayState.BUILDING, r.displayState)
        assertFalse(r.copy.contains("Heads-up"))
        assertTrue(r.copy.contains("Missing data is not a healthy result"))
    }

    @Test fun alreadyUnwellOverridesUntrustedBaselineAndMissingSignals() {
        val r = IllnessSignalEngine.evaluate(
            IllnessSignalEngine.Inputs(),
            IllnessSignalEngine.Context(alreadyUnwell = true, baselineTrusted = false),
            labels,
        )
        assertEquals(IllnessSignalEngine.Level.ALREADY_UNWELL, r.level)
        assertTrue(r.copy.contains("cannot rule out"))
        assertTrue(r.copy.contains("severe or worsening"))
    }

    @Test fun belowThresholdSignalsAreMildNotRaised() {
        val inputs = IllnessSignalEngine.Inputs(restingHR = reading(2.6), skinTemp = reading(2.6))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(2, r.signalCount)
        assertEquals(IllnessSignalEngine.Level.MILD, r.level)
        assertEquals(IllnessSignalEngine.DisplayState.WATCH, r.displayState)
        assertTrue(r.score < IllnessSignalEngine.raiseThreshold)
        assertTrue(r.score >= IllnessSignalEngine.mildThreshold)
    }

    @Test fun absentSignalsDoNotCount() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2),
            skinTemp = IllnessSignalEngine.SignalReading(9.0, present = false),
            hrv = reading(3.5))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertEquals(2, r.signalCount)
        assertFalse(r.firedSignals.contains("skin temp +0.7 °C"))
    }

    @Test fun nonFiniteSignalsDoNotCountOrPoisonScore() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(Double.NaN),
            skinTemp = reading(Double.POSITIVE_INFINITY),
            hrv = reading(3.5),
            respiration = reading(3.2),
        )
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        assertTrue(r.score.isFinite())
        assertEquals(2, r.signalCount)
        assertEquals(listOf("HRV −22%", "respiration up"), r.firedSignals)
    }

    @Test fun quietCopyDoesNotClaimHealthOrNormality() {
        val r = IllnessSignalEngine.evaluate(
            IllnessSignalEngine.Inputs(restingHR = reading(0.0), hrv = reading(0.0)),
            IllnessSignalEngine.Context(),
            labels,
        )
        assertEquals(IllnessSignalEngine.Level.QUIET, r.level)
        assertEquals(2, r.trustedSignalCount)
        assertEquals(IllnessSignalEngine.DisplayState.STEADY, r.displayState)
        assertTrue(r.copy.contains("does not assess overall health"))
        assertFalse(r.copy.lowercase().contains("normal"))
    }

    @Test fun copyNeverNamesACondition() {
        val inputs = IllnessSignalEngine.Inputs(
            restingHR = reading(3.2), skinTemp = reading(3.0), hrv = reading(3.5))
        val banned = listOf("covid", "flu", "fever", "infection", "sick with", "illness with", "disease")
        val ctxs = listOf(
            IllnessSignalEngine.Context(),
            IllnessSignalEngine.Context(alcohol = true),
            IllnessSignalEngine.Context(alreadyUnwell = true))
        for (ctx in ctxs) {
            val copy = IllnessSignalEngine.evaluate(inputs, ctx, labels).copy.lowercase()
            for (b in banned) assertFalse("copy contained $b: $copy", copy.contains(b))
        }
    }

    @Test fun scorePerSignalCapping() {
        val inputs = IllnessSignalEngine.Inputs(restingHR = reading(100.0), skinTemp = reading(2.5))
        val r = IllnessSignalEngine.evaluate(inputs, IllnessSignalEngine.Context(), labels)
        val expectedSkin = IllnessSignalEngine.kZToScore * (2.5 - IllnessSignalEngine.signalZThreshold)
        assertEquals(IllnessSignalEngine.perSignalCap + expectedSkin, r.score, 1e-9)
    }

    @Test fun dailySignalStatusRequiresSolidCurrentEvidence() {
        val aligned = ReadinessEngine.Readiness(
            level = ReadinessEngine.Level.PRIMED,
            headline = "Aligned",
            summary = "Available signals are aligned.",
            signals = emptyList(),
            effortVariety = null,
            asOfDay = "2026-08-23",
            confidence = ScoreConfidence.SOLID,
        )
        val thin = aligned.copy(confidence = ScoreConfidence.BUILDING)
        val quiet = IllnessSignalEngine.evaluate(
            IllnessSignalEngine.Inputs(restingHR = reading(0.0), hrv = reading(0.0)),
            IllnessSignalEngine.Context(),
            labels,
        )
        val raised = IllnessSignalEngine.evaluate(
            IllnessSignalEngine.Inputs(restingHR = reading(3.5), hrv = reading(3.5)),
            IllnessSignalEngine.Context(),
            labels,
        )

        assertEquals(DailySignalStatus.STEADY, DailySignalStatus.resolve(aligned, quiet))
        assertEquals(DailySignalStatus.BUILDING, DailySignalStatus.resolve(thin, quiet))
        assertEquals(DailySignalStatus.ALERT, DailySignalStatus.resolve(aligned, raised))
        assertEquals(DailySignalStatus.BUILDING, DailySignalStatus.resolve(thin, null))
    }
}
