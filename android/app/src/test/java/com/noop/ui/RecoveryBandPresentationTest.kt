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
}
