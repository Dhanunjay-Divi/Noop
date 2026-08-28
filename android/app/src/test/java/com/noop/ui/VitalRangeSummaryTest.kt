package com.noop.ui

import androidx.compose.ui.graphics.Color
import com.noop.analytics.VitalBands
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class VitalRangeSummaryTest {

    @Test
    fun excludesMissingAndRawReadings() {
        val summary = summarizeVitalRanges(
            listOf(
                vital("resp", 15.0, VitalBands.Band.IN_RANGE),
                vital("spo2", 92.0, VitalBands.Band.OUT_OF_RANGE),
                vital("spo2raw", 12_000.0, VitalBands.Band.IN_RANGE),
                vital("hrv", null, VitalBands.Band.NO_DATA),
            ),
        )

        assertEquals(1, summary.inRangeCount)
        assertEquals(2, summary.availableCount)
        assertFalse(summary.allAvailableInRange)
    }

    @Test
    fun absenceIsNotCountedAsOutsideRange() {
        val summary = summarizeVitalRanges(
            listOf(
                vital("spo2raw", 12_000.0, VitalBands.Band.IN_RANGE),
                vital("hrv", null, VitalBands.Band.NO_DATA),
            ),
        )

        assertEquals(VitalRangeSummary(inRangeCount = 0, availableCount = 0), summary)
    }

    private fun vital(
        key: String,
        value: Double?,
        band: VitalBands.Band,
    ) = Vital(
        key = key,
        label = key,
        unit = "",
        value = value,
        format = { it.toString() },
        missingCaption = "Missing",
        banding = VitalBands.Result(band, VitalBands.Basis.POPULATION, 0),
        metricColor = Color.Blue,
    )
}
