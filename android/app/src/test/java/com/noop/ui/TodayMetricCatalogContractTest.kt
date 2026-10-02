package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TodayMetricCatalogContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun todaySource(): String {
        return listOf(
            File(root(), "src/main/java/com/noop/ui/TodayScreen.kt"),
            File(root(), "app/src/main/java/com/noop/ui/TodayScreen.kt"),
            File(root(), "android/app/src/main/java/com/noop/ui/TodayScreen.kt"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("TodayScreen.kt source root is unavailable")
    }

    private fun stringsResource(folder: String): String {
        return listOf(
            File(root(), "src/main/res/$folder/strings.xml"),
            File(root(), "app/src/main/res/$folder/strings.xml"),
            File(root(), "android/app/src/main/res/$folder/strings.xml"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("$folder/strings.xml is unavailable")
    }

    @Test
    fun editorIsSelectedFirstSearchableGroupedAndHydrationGated() {
        val source = todaySource()
        assertTrue(source.contains("noop.today.metricEditor.selected.\${metric.raw}"))
        assertTrue(source.contains("noop.today.metricEditor.available.\${metric.raw}"))
        assertTrue(source.contains("noop.today.metricEditor.search"))
        assertTrue(source.contains("KeyMetricOrigin.entries.forEach"))
        assertTrue(source.contains("keyMetricOriginDetail(origin)"))
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
        assertTrue(source.contains("KeyMetric.AVERAGE_HR -> ({ onOpenMetric(\"avg_hr\") })"))
        assertTrue(source.contains("KeyMetric.MAX_HR -> ({ onOpenMetric(\"max_hr\") })"))
        assertTrue(source.contains("KeyMetric.ASLEEP_TIME -> ({ onOpenMetric(\"sleep_total_min\") })"))
        assertTrue(source.contains("KeyMetric.VO2_MAX -> ({ onOpenMetric(\"vo2max\") })"))
    }

    @Test
    fun directHeartAndVo2TilesUseResolvedMeasuredSeries() {
        val source = todaySource()
        assertTrue(source.contains("\"avg_hr\",\n                \"my-whoop\""))
        assertTrue(source.contains("\"max_hr\",\n                \"my-whoop\""))
        assertTrue(source.contains("\"vo2max\",\n                \"apple-health\""))
        assertTrue(source.contains("never falls back to NOOP's separate `vo2max_est`"))
    }

    @Test
    fun fitnessAgeLaneIsTodayOnlyMonthPreciseAndOpensExistingDetail() {
        val source = todaySource()
        assertTrue(source.contains("if (selectedDayOffset == 0)"))
        assertTrue(source.contains("FitnessAgeCompactLane("))
        assertTrue(source.contains("FitnessAgePresentation::value"))
        assertTrue(source.contains("FitnessAgePresentation::localizedSpokenValue"))
        assertTrue(source.contains("onClick = { onOpenMetric(\"fitness_age\") }"))
        assertTrue(source.contains("noop.today.fitnessAgeHero"))
    }

    @Test
    fun composedEditorCopyUsesFormattedResourcesInEverySupportedLocale() {
        val source = todaySource()
        val keys = setOf(
            "key_metrics_fitness_age_accessibility",
            "key_metrics_remove_from_today",
            "key_metrics_hydration_tracking_off",
        )
        assertTrue(source.contains("R.string.key_metrics_fitness_age_accessibility"))
        assertTrue(source.contains("R.string.key_metrics_remove_from_today"))
        assertTrue(source.contains("R.string.key_metrics_hydration_tracking_off"))
        assertFalse(
            source.contains(
                "\"${'$'}title, ${'$'}spokenValue, ${'$'}weekly, ${'$'}detail\"",
            ),
        )

        for (folder in listOf(
            "values",
            "values-de",
            "values-es",
            "values-fr",
            "values-it",
            "values-pt-rPT",
            "values-ru",
            "values-zh",
            "values-zh-rTW",
        )) {
            val resource = stringsResource(folder)
            for (key in keys) {
                assertTrue("$folder is missing $key", resource.contains("name=\"$key\""))
            }
        }
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
