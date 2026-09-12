package com.noop.ingest

import com.noop.data.HealthConnectSyncStateRow
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectBmiLocalProjectionTest {
    private data class Fixture(
        val repository: WhoopRepository,
        val rows: ConcurrentHashMap<Triple<String, String, String>, MetricSeriesRow>,
        val states: ConcurrentHashMap<String, HealthConnectSyncStateRow>,
    )

    private fun fixture(seed: List<MetricSeriesRow>): Fixture {
        val rows = ConcurrentHashMap(
            seed.associateBy { Triple(it.deviceId, it.day, it.key) },
        )
        val states = ConcurrentHashMap<String, HealthConnectSyncStateRow>()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "metricSeries" -> {
                    val values = args!!
                    val source = values[0] as String
                    val key = values[1] as String
                    val from = values[2] as String
                    val to = values[3] as String
                    rows.values
                        .filter {
                            it.deviceId == source &&
                                it.key == key &&
                                it.day in from..to
                        }
                        .sortedBy { it.day }
                }
                "replaceMetricSeriesRange" -> {
                    val values = args!!
                    val source = values[0] as String
                    val from = values[1] as String
                    val to = values[2] as String
                    @Suppress("UNCHECKED_CAST")
                    val keys = (values[3] as List<String>).toSet()
                    @Suppress("UNCHECKED_CAST")
                    val incoming = values[4] as List<MetricSeriesRow>
                    rows.entries.removeIf { (_, row) ->
                        row.deviceId == source && row.day in from..to && row.key in keys
                    }
                    incoming.forEach { row ->
                        rows[Triple(row.deviceId, row.day, row.key)] = row
                    }
                    Unit
                }
                "upsertHealthConnectSyncStates" -> {
                    @Suppress("UNCHECKED_CAST")
                    val incoming = args!![0] as List<HealthConnectSyncStateRow>
                    incoming.forEach { states[it.recordType] = it }
                    Unit
                }
                else -> throw UnsupportedOperationException(
                    "BMI projection must not call ${method.name}",
                )
            }
        } as WhoopDao
        return Fixture(WhoopRepository(dao), rows, states)
    }

    @Test
    fun confirmedHeightRebuildsFromStoredHealthConnectWeightAndPreservesOtherSources() = runBlocking {
        val fixture = fixture(
            listOf(
                MetricSeriesRow(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "weight", 80.0),
                MetricSeriesRow(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "bmi", 25.25),
                MetricSeriesRow("manual", "2026-09-09", "bmi", 23.4),
            ),
        )
        val fingerprint = HealthConnectSyncStateRow(
            HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE,
            HealthConnectBmiProjectionFingerprint.forHeight(170.0),
            123L,
        )

        val count = fixture.repository.reconcileHealthConnectDerivedBmi(fingerprint) { weight ->
            HealthConnectImporter.derivedBmi(weight.value, 170.0)?.let { bmi ->
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    weight.day,
                    "bmi",
                    bmi,
                )
            }
        }

        assertEquals(1, count)
        assertEquals(
            27.68,
            fixture.rows.getValue(
                Triple(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "bmi"),
            ).value,
            0.0,
        )
        assertEquals(
            23.4,
            fixture.rows.getValue(Triple("manual", "2026-09-09", "bmi")).value,
            0.0,
        )
        assertEquals(
            fingerprint,
            fixture.states[HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE],
        )
    }

    @Test
    fun removedHeightDeletesOnlyDerivedBmiAndCommitsUnconfirmedFingerprint() = runBlocking {
        val fixture = fixture(
            listOf(
                MetricSeriesRow(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "weight", 80.0),
                MetricSeriesRow(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "bmi", 25.25),
                MetricSeriesRow("manual", "2026-09-09", "bmi", 23.4),
            ),
        )
        val fingerprint = HealthConnectSyncStateRow(
            HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE,
            HealthConnectBmiProjectionFingerprint.UNCONFIRMED,
            456L,
        )

        val count = fixture.repository.reconcileHealthConnectDerivedBmi(fingerprint) { weight ->
            HealthConnectImporter.derivedBmi(weight.value, 0.0)?.let { bmi ->
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    weight.day,
                    "bmi",
                    bmi,
                )
            }
        }

        assertEquals(0, count)
        assertFalse(
            fixture.rows.containsKey(
                Triple(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "bmi"),
            ),
        )
        assertTrue(fixture.rows.containsKey(Triple("manual", "2026-09-09", "bmi")))
        assertEquals(
            fingerprint,
            fixture.states[HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE],
        )
    }

    @Test
    fun localCorrectionWithoutFingerprintLeavesPriorDependencyStateForRetry() = runBlocking {
        val fixture = fixture(
            listOf(
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    "2026-09-09",
                    "weight",
                    80.0,
                ),
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    "2026-09-09",
                    "bmi",
                    25.25,
                ),
            ),
        )
        val priorFingerprint = HealthConnectSyncStateRow(
            HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE,
            HealthConnectBmiProjectionFingerprint.forHeight(178.0),
            100L,
        )
        fixture.states[priorFingerprint.recordType] = priorFingerprint

        fixture.repository.reconcileHealthConnectDerivedBmi { weight ->
            HealthConnectImporter.derivedBmi(weight.value, 170.0)?.let { bmi ->
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    weight.day,
                    "bmi",
                    bmi,
                )
            }
        }

        assertEquals(
            27.68,
            fixture.rows.getValue(
                Triple(WhoopRepository.HEALTH_CONNECT_SOURCE, "2026-09-09", "bmi"),
            ).value,
            0.0,
        )
        assertEquals(priorFingerprint, fixture.states[priorFingerprint.recordType])
    }

    @Test
    fun cancellationBeforeCommitPreservesExistingProjectionAndFingerprint() = runBlocking {
        val existingBmi = MetricSeriesRow(
            WhoopRepository.HEALTH_CONNECT_SOURCE,
            "2026-09-09",
            "bmi",
            25.25,
        )
        val fixture = fixture(
            listOf(
                MetricSeriesRow(
                    WhoopRepository.HEALTH_CONNECT_SOURCE,
                    "2026-09-09",
                    "weight",
                    80.0,
                ),
                existingBmi,
            ),
        )
        val priorFingerprint = HealthConnectSyncStateRow(
            HealthConnectBmiProjectionFingerprint.STATE_RECORD_TYPE,
            HealthConnectBmiProjectionFingerprint.forHeight(178.0),
            100L,
        )
        fixture.states[priorFingerprint.recordType] = priorFingerprint
        val nextFingerprint = priorFingerprint.copy(
            changesToken = HealthConnectBmiProjectionFingerprint.forHeight(170.0),
            updatedAt = 200L,
        )
        val cancellation = CancellationException("synthetic cancellation")

        try {
            fixture.repository.reconcileHealthConnectDerivedBmi(nextFingerprint) {
                throw cancellation
            }
        } catch (caught: CancellationException) {
            assertSame(cancellation, caught)
            assertEquals(
                existingBmi,
                fixture.rows[
                    Triple(
                        WhoopRepository.HEALTH_CONNECT_SOURCE,
                        "2026-09-09",
                        "bmi",
                    )
                ],
            )
            assertEquals(priorFingerprint, fixture.states[priorFingerprint.recordType])
            return@runBlocking
        }
        throw AssertionError("expected cancellation")
    }
}
