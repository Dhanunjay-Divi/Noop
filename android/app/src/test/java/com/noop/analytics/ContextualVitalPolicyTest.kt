package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class ContextualVitalPolicyTest {
    private val today = "2026-08-22"

    @Test
    fun oxygenRequiresTwoDistinctFreshLowDays() {
        val candidate = ContextualVitalPolicy.oxygenCandidate(
            listOf(
                ContextualVitalPolicy.OxygenPoint("2026-08-20", 94.4, 2),
                ContextualVitalPolicy.OxygenPoint("2026-08-21", 93.8, 0),
            ),
            today,
        )

        assertNotNull(candidate)
        assertEquals(ContextualVitalPolicy.Kind.OXYGEN_TREND, candidate?.kind)
        assertNull(
            ContextualVitalPolicy.oxygenCandidate(
                listOf(ContextualVitalPolicy.OxygenPoint("2026-08-21", 93.8, 0)),
                today,
            )
        )
        assertNull(
            ContextualVitalPolicy.oxygenCandidate(
                listOf(
                    ContextualVitalPolicy.OxygenPoint("2026-08-20", 94.4, 2),
                    ContextualVitalPolicy.OxygenPoint("2026-08-21", 97.0, 0),
                ),
                today,
            )
        )
    }

    @Test
    fun oxygenRejectsSameDaySourceConflictAndStalePairs() {
        assertNull(
            ContextualVitalPolicy.oxygenCandidate(
                listOf(
                    ContextualVitalPolicy.OxygenPoint("2026-08-20", 97.0, 2),
                    ContextualVitalPolicy.OxygenPoint("2026-08-20", 92.0, 0),
                    ContextualVitalPolicy.OxygenPoint("2026-08-21", 92.0, 0),
                ),
                today,
            )
        )
        assertNull(
            ContextualVitalPolicy.oxygenCandidate(
                listOf(
                    ContextualVitalPolicy.OxygenPoint("2026-08-17", 92.0, 2),
                    ContextualVitalPolicy.OxygenPoint("2026-08-18", 93.0, 2),
                ),
                today,
            )
        )
    }

    @Test
    fun bodyTemperatureIsFreshAbsoluteConflictAwareAndRecheckOnly() {
        val candidate = ContextualVitalPolicy.bodyTemperatureCandidate(
            listOf(
                ContextualVitalPolicy.BodyTemperaturePoint(
                    "2026-08-22",
                    38.2,
                    "health-connect",
                    1,
                )
            ),
            today,
        )
        assertEquals(ContextualVitalPolicy.Kind.BODY_TEMPERATURE_REVIEW, candidate?.kind)

        assertNull(
            ContextualVitalPolicy.bodyTemperatureCandidate(
                listOf(
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        "2026-08-22", 38.2, "apple-health", 0,
                    ),
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        "2026-08-22", 36.8, "health-connect", 1,
                    ),
                ),
                today,
            )
        )
        assertNull(
            ContextualVitalPolicy.bodyTemperatureCandidate(
                listOf(
                    ContextualVitalPolicy.BodyTemperaturePoint(
                        "2026-08-19", 39.0, "health-connect", 1,
                    )
                ),
                today,
            )
        )
    }

    @Test
    fun vo2RequiresPersistentMeaningfulLongTermChange() {
        val meaningful = ContextualVitalPolicy.vo2Candidate(
            measured = listOf(
                ContextualVitalPolicy.Vo2Point("2026-07-20", 40.0),
                ContextualVitalPolicy.Vo2Point("2026-08-15", 44.0),
                ContextualVitalPolicy.Vo2Point("2026-08-22", 44.5),
            ),
            estimated = emptyList(),
            todayKey = today,
        )
        assertEquals(ContextualVitalPolicy.Kind.VO2_TREND, meaningful?.kind)

        assertNull(
            ContextualVitalPolicy.vo2Candidate(
                measured = listOf(
                    ContextualVitalPolicy.Vo2Point("2026-07-20", 40.0),
                    ContextualVitalPolicy.Vo2Point("2026-08-15", 40.5),
                    ContextualVitalPolicy.Vo2Point("2026-08-22", 45.0),
                ),
                estimated = emptyList(),
                todayKey = today,
            )
        )
    }
}
