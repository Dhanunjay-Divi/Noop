package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Upgrade coverage for removing un-sourced @57 steps from Vitality / Wellness Age. */
class VitalityUpgradeInvalidationTest {
    private data class Fixture(
        val repo: WhoopRepository,
        val rows: MutableMap<Triple<String, String, String>, MetricSeriesRow>,
        val deletions: MutableList<Pair<String, String>>,
    )

    private fun fixture(
        seed: List<MetricSeriesRow>,
        daily: List<DailyMetric> = emptyList(),
    ): Fixture {
        val rows = seed.associateByTo(linkedMapOf()) { Triple(it.deviceId, it.day, it.key) }
        val deletions = mutableListOf<Pair<String, String>>()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "days" -> daily.filter { it.deviceId == args!![0] as String }
                "editedSleepSessions" -> emptyList<Any>()
                "latestMetricSeriesRow" -> {
                    val source = args!![0] as String
                    val key = args[1] as String
                    rows.values
                        .filter { it.deviceId == source && it.key == key }
                        .maxByOrNull { it.day }
                }
                "deleteMetricSeries" -> {
                    val source = args!![0] as String
                    val key = args[1] as String
                    deletions += source to key
                    val doomed = rows.filterKeys { it.first == source && it.third == key }.keys
                    doomed.forEach(rows::remove)
                    doomed.size
                }
                "upsertMetricSeries" -> {
                    @Suppress("UNCHECKED_CAST")
                    val incoming = args!![0] as List<MetricSeriesRow>
                    incoming.forEach { rows[Triple(it.deviceId, it.day, it.key)] = it }
                    Unit
                }
                else -> throw UnsupportedOperationException("Vitality persistence must not call ${method.name}")
            }
        } as WhoopDao
        return Fixture(WhoopRepository(dao), rows, deletions)
    }

    private fun point(source: String, key: String, value: Double, day: String = "2026-07-25") =
        MetricSeriesRow(deviceId = source, day = day, key = key, value = value)

    private fun day(index: Int, includeHrv: Boolean) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = "2026-07-%02d".format(index),
        totalSleepMin = 450.0,
        restingHr = 55,
        avgHrv = 42.0.takeIf { includeHrv },
        steps = 54_321,
    )

    @Test
    fun stepsEraScoreIsPurgedWhenSafeInputsNoLongerSpanThreeDomains() = runBlocking {
        val computed = "my-whoop-noop"
        val imported = "my-whoop"
        val vendor = "health-connect"
        val f = fixture(
            seed = listOf(
                point(computed, "vitality", 88.0),
                point(computed, "body_age", 32.0),
                point(computed, AgeMetricProfile.LEGACY_VITALITY_KEY, 40.0),
                // Same keys outside the computed allow-list prove the upgrade does not erase source data.
                point(imported, "vitality", 77.0),
                point(vendor, "body_age", 44.0),
                point(vendor, AgeMetricProfile.LEGACY_VITALITY_KEY, 99.0),
            ),
            daily = (1..14).map { day(it, includeHrv = false).copy(deviceId = imported) },
        )
        val now = LocalDate.of(2026, 7, 14)
            .atTime(12, 0)
            .atZone(ZoneId.systemDefault())
            .toEpochSecond()

        IntelligenceEngine.recomputeVitalityOnly(
            repo = f.repo,
            profile = UserProfile(age = 40.0, ageInputConfirmed = true),
            importedDeviceId = imported,
            nowSeconds = now,
        )

        assertNull(f.rows[Triple(computed, "2026-07-25", "vitality")])
        assertNull(f.rows[Triple(computed, "2026-07-25", "body_age")])
        assertNull(f.rows[Triple(computed, "2026-07-25", AgeMetricProfile.LEGACY_VITALITY_KEY)])
        assertFalse(f.rows.keys.any { it.first == computed && it.third == AgeMetricProfile.VITALITY_KEY })
        assertEquals(computed to AgeMetricProfile.VITALITY_KEY, f.deletions.first())
        assertEquals(77.0, f.rows[Triple(imported, "2026-07-25", "vitality")]?.value)
        assertEquals(44.0, f.rows[Triple(vendor, "2026-07-25", "body_age")]?.value)
        assertEquals(
            99.0,
            f.rows[Triple(vendor, "2026-07-25", AgeMetricProfile.LEGACY_VITALITY_KEY)]?.value,
        )
    }

    @Test
    fun eligibleUpgradeReplacesLegacyMarkerWithV2AndFreshSafeScore() = runBlocking {
        val imported = "whoop-ABC123"
        val computed = "$imported-noop"
        val canonicalComputed = "my-whoop-noop"
        val f = fixture(listOf(
            // A valid v2 marker on the active source must not mask a legacy v1 row on the canonical
            // computed sibling. Detecting either source forces union-wide cleanup before the fresh write.
            point(computed, AgeMetricProfile.VITALITY_KEY, 40.0),
            point(canonicalComputed, "vitality", 88.0),
            point(canonicalComputed, "body_age", 32.0),
            point(canonicalComputed, AgeMetricProfile.LEGACY_VITALITY_KEY, 40.0),
        ))

        IntelligenceEngine.persistVitalityOrInvalidate(
            repo = f.repo,
            profile = UserProfile(age = 40.0, ageInputConfirmed = true),
            days = (1..14).map { day(it, includeHrv = true) },
            importedDeviceId = imported,
            computedId = computed,
            newestDay = "2026-07-25",
        )

        assertFalse(f.rows.keys.any { it.third == AgeMetricProfile.LEGACY_VITALITY_KEY })
        assertFalse(f.rows.keys.any {
            it.first == canonicalComputed && it.third in setOf("vitality", "body_age")
        })
        assertEquals(
            listOf(
                computed to AgeMetricProfile.VITALITY_KEY,
                canonicalComputed to AgeMetricProfile.VITALITY_KEY,
            ),
            f.deletions.take(2),
        )
        assertNotNull(f.rows[Triple(computed, "2026-07-25", "vitality")])
        assertNotNull(f.rows[Triple(computed, "2026-07-25", "body_age")])
        assertEquals(
            AgeMetricProfile.vitalityToken(40.0),
            f.rows[Triple(computed, "2026-07-25", AgeMetricProfile.VITALITY_KEY)]?.value,
        )
        assertTrue(f.rows.values.none { it.deviceId == computed && it.key == "vitality" && it.value == 88.0 })
    }
}
