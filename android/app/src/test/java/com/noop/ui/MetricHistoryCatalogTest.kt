package com.noop.ui

import com.noop.analytics.HydrationStore
import com.noop.data.WhoopRepository
import com.noop.ingest.HealthConnectImporter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MetricHistoryCatalogTest {

    @Test
    fun catalogIdsAreUniqueAndPreserveDuplicateProviderKeys() {
        val ids = AndroidMetricHistoryCatalog.all.map { it.id }

        assertEquals(ids.size, ids.distinct().size)
        assertNotNull(AndroidMetricHistoryCatalog.byId("apple-health:steps"))
        assertNotNull(AndroidMetricHistoryCatalog.byId("health-connect:steps"))
        assertNotNull(AndroidMetricHistoryCatalog.byId("my-whoop:recovery"))
        assertNotNull(AndroidMetricHistoryCatalog.byId("my-whoop-noop:recovery"))
    }

    @Test
    fun catalogCoversEveryAppleHealthFlattenedHistoryKey() {
        val expected = setOf(
            "resting_hr",
            "hrv",
            "spo2",
            "resp_rate",
            "avg_hr",
            "max_hr",
            "walking_hr",
            "steps",
            "active_kcal",
            "basal_kcal",
            "vo2max",
            "weight",
            "body_fat",
            "lean_mass",
            "bmi",
            "asleep_min",
            "deep_min",
            "rem_min",
            "core_min",
            "awake_min",
            "in_bed_min",
        )
        val actual = AndroidMetricHistoryCatalog.all
            .filter { it.source == WhoopRepository.APPLE_HEALTH_SOURCE }
            .mapTo(linkedSetOf()) { it.key }

        assertTrue(actual.containsAll(expected))
    }

    @Test
    fun catalogCoversHealthConnectStoredAndDailyHistoryKeys() {
        val expected = setOf(
            "resting_hr",
            "hrv",
            "spo2",
            "resp_rate",
            "avg_hr",
            "steps",
            "active_kcal",
            "basal_kcal",
            "vo2max",
            "weight",
            "body_fat",
            "lean_mass",
            "bmi",
            HealthConnectImporter.BODY_TEMPERATURE_KEY,
            HealthConnectImporter.BASAL_BODY_TEMPERATURE_KEY,
            HydrationStore.KEY,
            "asleep_min",
        )
        val actual = AndroidMetricHistoryCatalog.all
            .filter { it.source == WhoopRepository.HEALTH_CONNECT_SOURCE }
            .mapTo(linkedSetOf()) { it.key }

        assertEquals(expected, actual)
    }

    @Test
    fun logicalDirectAndNoopSourcesRouteToSeparatePhysicalPartitions() {
        val active = "veepoo-test"

        assertEquals(
            listOf(active, WhoopRepository.WHOOP_SOURCE),
            metricHistoryPhysicalSources(AndroidMetricHistoryCatalog.DIRECT_SOURCE, active),
        )
        assertEquals(
            listOf("$active-noop", "${WhoopRepository.WHOOP_SOURCE}-noop"),
            metricHistoryPhysicalSources(AndroidMetricHistoryCatalog.NOOP_SOURCE, active),
        )
        assertEquals(
            listOf(WhoopRepository.APPLE_HEALTH_SOURCE),
            metricHistoryPhysicalSources(WhoopRepository.APPLE_HEALTH_SOURCE, active),
        )
    }

    @Test
    fun weekWindowUsesCalendarCutoffRatherThanLastSevenRecords() {
        val points = listOf(
            SeriesPoint("2026-01-01", 1.0),
            SeriesPoint("2026-01-10", 2.0),
            SeriesPoint("2026-01-20", 3.0),
            SeriesPoint("2026-01-26", 4.0),
            SeriesPoint("2026-02-01", 5.0),
        )

        assertEquals(
            listOf("2026-01-26", "2026-02-01"),
            calendarDayWindow(points, days = 7).map { it.day },
        )
    }

    @Test
    fun calendarWindowAnchorsLatestValidObservationAndDropsInvalidRows() {
        val points = listOf(
            SeriesPoint("invalid", 999.0),
            SeriesPoint("2026-03-02", 2.0),
            SeriesPoint("2026-03-01", 1.0),
            SeriesPoint("2026-03-03", Double.NaN),
        )

        assertEquals(
            listOf("2026-03-01", "2026-03-02"),
            calendarDayWindow(points, days = null).map { it.day },
        )
    }
}
