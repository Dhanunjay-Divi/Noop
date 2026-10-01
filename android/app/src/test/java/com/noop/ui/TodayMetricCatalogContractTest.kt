package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TodayMetricCatalogContractTest {
    private fun todaySource(): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/TodayScreen.kt"),
            File(root, "app/src/main/java/com/noop/ui/TodayScreen.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/TodayScreen.kt"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("TodayScreen.kt source root is unavailable")
    }

    @Test
    fun editorIsSelectedFirstSearchableGroupedAndHydrationGated() {
        val source = todaySource()
        assertTrue(source.contains("noop.today.metricEditor.selected.\${metric.raw}"))
        assertTrue(source.contains("noop.today.metricEditor.available.\${metric.raw}"))
        assertTrue(source.contains("noop.today.metricEditor.search"))
        assertTrue(source.contains("KeyMetricGroup.entries.forEach"))
        assertTrue(source.contains("metric != KeyMetric.HYDRATION || hydrationEnabled"))
        assertTrue(source.contains("hydrationEnabled = hydrationEnabled"))
    }

    @Test
    fun newMetricsUseTheirExistingTodayDestinations() {
        val source = todaySource()
        assertTrue(source.contains("KeyMetric.SKIN_TEMP -> ({ onOpenMetric(\"skin\") })"))
        assertTrue(source.contains("KeyMetric.STRESS -> onOpenStress"))
        assertTrue(source.contains("KeyMetric.VITALITY -> ({ onOpenMetric(\"vitality\") })"))
        assertTrue(source.contains("KeyMetric.HYDRATION -> onOpenHydration"))
    }

    @Test
    fun fitnessAgeLaneIsTodayOnlyMonthPreciseAndOpensExistingDetail() {
        val source = todaySource()
        assertTrue(source.contains("if (selectedDayOffset == 0)"))
        assertTrue(source.contains("FitnessAgeHeroLane("))
        assertTrue(source.contains("FitnessAgePresentation::value"))
        assertTrue(source.contains("FitnessAgePresentation::localizedSpokenValue"))
        assertTrue(source.contains("onClick = { onOpenMetric(\"fitness_age\") }"))
        assertTrue(source.contains("noop.today.fitnessAgeHero"))
    }

    @Test
    fun skinTemperatureFormattingDistinguishesAbsoluteAndDeviationUnits() {
        assertEquals(
            "33.4 °C",
            skinTemperatureMetricValue(33.4, TemperatureUnit.CELSIUS),
        )
        assertEquals(
            "92.1 °F",
            skinTemperatureMetricValue(33.4, TemperatureUnit.FAHRENHEIT),
        )
        assertEquals(
            "+0.3 °C",
            skinTemperatureMetricValue(0.3, TemperatureUnit.CELSIUS),
        )
        assertEquals(
            "−0.5 °F",
            skinTemperatureMetricValue(-0.3, TemperatureUnit.FAHRENHEIT),
        )
    }
}
