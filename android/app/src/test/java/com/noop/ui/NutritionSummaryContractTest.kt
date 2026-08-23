package com.noop.ui

import com.noop.data.LabMarkerRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NutritionSummaryContractTest {
    @Test
    fun latestFastingGlucose_ignoresFutureAndQualitativeRows() {
        val numeric = marker("numeric", "2026-08-20", 100, 5.2)
        val qualitative = marker("qualitative", "2026-08-20", 200, null)
        val future = marker("future", "2026-08-22", 300, 5.4)

        val selected = NutritionSummaryContract.latestFastingGlucose(
            listOf(future, qualitative, numeric),
            throughDay = "2026-08-21",
        )

        assertEquals(numeric, selected)
    }

    @Test
    fun latestFastingGlucose_usesLatestNumericTimestamp() {
        val early = marker("early", "2026-08-20", 100, 5.0)
        val late = marker("late", "2026-08-20", 200, 5.3)

        val selected = NutritionSummaryContract.latestFastingGlucose(
            listOf(late, early),
            throughDay = "2026-08-20",
        )

        assertEquals(late, selected)
        assertNull(
            NutritionSummaryContract.latestFastingGlucose(
                listOf(late),
                throughDay = "2026-08-19",
            ),
        )
    }

    @Test
    fun macroDots_areRelativeAndDoNotInventMissingValues() {
        val values = listOf<Double?>(100.0, 200.0, null)

        assertEquals(12, NutritionSummaryContract.relativeMacroDotCount(100.0, values))
        assertEquals(
            NutritionSummaryContract.MACRO_DOT_CAPACITY,
            NutritionSummaryContract.relativeMacroDotCount(200.0, values),
        )
        assertEquals(0, NutritionSummaryContract.relativeMacroDotCount(null, values))
        assertEquals(0, NutritionSummaryContract.relativeMacroDotCount(0.0, values))
        assertNull(
            NutritionSummaryContract.bestEffortLatestFastingGlucose(
                rows = null,
                throughDay = "2026-08-20",
            ),
        )
    }

    private fun marker(
        id: String,
        day: String,
        takenAt: Long,
        value: Double?,
    ) = LabMarkerRow(
        id = id,
        deviceId = NutritionSummaryContract.LAB_BOOK_DEVICE_ID,
        markerKey = NutritionSummaryContract.FASTING_GLUCOSE_KEY,
        category = "bloodPanel",
        day = day,
        takenAt = takenAt,
        value = value,
        valueText = if (value == null) "not recorded" else null,
        unit = "mmol/L",
        source = "manual",
    )
}
