package com.noop.ui

import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Test

class RecoveryBandPresentationTest {
    @Test
    fun presentationUsesTheScoringEnginesPinnedBandEdges() {
        assertEquals(RecoveryBandLevel.LOW, RecoveryBandPresentation.level(33.999))
        assertEquals(RecoveryBandLevel.STEADY, RecoveryBandPresentation.level(34.0))
        assertEquals(RecoveryBandLevel.STEADY, RecoveryBandPresentation.level(66.999))
        assertEquals(RecoveryBandLevel.STRONG, RecoveryBandPresentation.level(67.0))
    }

    @Test
    fun labelsUseLocalizedResourcesAcrossSummarySurfaces() {
        assertEquals(R.string.appwide_calendar_legend_low, RecoveryBandPresentation.labelRes(10.0))
        assertEquals(R.string.today_trend_direction_steady, RecoveryBandPresentation.labelRes(41.0))
        assertEquals(R.string.appwide_calendar_legend_strong, RecoveryBandPresentation.labelRes(82.0))
    }

    @Test
    fun unscoredRecoveryUsesNeutralVisualStates() {
        assertEquals(
            TodayRecoveryHeroTone.LEARNING,
            todayRecoveryHeroTone(recovery = null, calibrationNights = 0),
        )
        assertEquals(
            TodayRecoveryHeroTone.UNAVAILABLE,
            todayRecoveryHeroTone(recovery = null, calibrationNights = null),
        )
        assertEquals(
            TodayRecoveryHeroTone.BASELINE_READY,
            todayRecoveryHeroTone(
                recovery = null,
                calibrationNights = com.noop.analytics.Baselines.minNightsSeed,
            ),
        )
        assertEquals(
            TodayRecoveryHeroTone.RECOVERY,
            todayRecoveryHeroTone(recovery = 72.0, calibrationNights = null),
        )
    }
}
