package com.noop.data

import com.noop.analytics.IntelligenceEngine
import java.lang.reflect.Proxy
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AnalysisInputGateTest {
    private class GateFixture(
        initialGenerations: Map<String, Long>,
        initialAcknowledged: Map<String, Long> = emptyMap(),
        initialBounds: Map<String, Pair<Long?, Long?>> = initialGenerations.mapValues { (source, _) ->
            if (source == AnalysisInvalidationSource.OWNERSHIP) null to null else 100L to 100L
        },
        initialScoreBearingHistory: Set<String> = initialGenerations.keys
            .filterTo(linkedSetOf()) { it != AnalysisInvalidationSource.OWNERSHIP },
        private val claimFailure: Throwable? = null,
        private val acknowledgeFailure: Throwable? = null,
    ) {
        val generations = initialGenerations.toMutableMap()
        val acknowledged = initialAcknowledged.toMutableMap()
        val earliestAffected = initialBounds.mapValues { it.value.first }.toMutableMap()
        val latestAffected = initialBounds.mapValues { it.value.second }.toMutableMap()
        val scoreBearingHistory = initialScoreBearingHistory.toMutableSet()
        var claimCalls = 0
        var acknowledgeCalls = 0

        private val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, arguments ->
            when (method.name) {
                "pendingAnalysisInputClaims" -> {
                    claimCalls += 1
                    claimFailure?.let { throw it }
                    val requested = (arguments?.firstOrNull() as? List<*>)
                        .orEmpty()
                        .filterIsInstance<String>()
                    requested
                        .distinct()
                        .sorted()
                        .mapNotNull { deviceId ->
                            val generation = generations[deviceId] ?: return@mapNotNull null
                            val ack = acknowledged[deviceId] ?: 0L
                            generation
                                .takeIf { it > ack }
                                ?.let {
                                    AnalysisInputGenerationClaim(
                                        deviceId = deviceId,
                                        generation = it,
                                        earliestAffectedTs = earliestAffected[deviceId],
                                        latestAffectedTs = latestAffected[deviceId],
                                    )
                                }
                        }
                }
                "hasScoreBearingHistory" ->
                    (arguments?.get(0) as String) in scoreBearingHistory
                "hasAnyScoreBearingHistory" -> scoreBearingHistory.isNotEmpty()
                "acknowledgeExactAnalysisInputGeneration" -> {
                    acknowledgeCalls += 1
                    acknowledgeFailure?.let { throw it }
                    val deviceId = arguments?.get(0) as String
                    val claimedGeneration = arguments[1] as Long
                    val expectedEarliest = arguments[2] as Long?
                    val expectedLatest = arguments[3] as Long?
                    val generation = generations[deviceId]
                    val prior = acknowledged[deviceId] ?: 0L
                    if (generation == claimedGeneration &&
                        claimedGeneration > prior &&
                        earliestAffected[deviceId] == expectedEarliest &&
                        latestAffected[deviceId] == expectedLatest
                    ) {
                        acknowledged[deviceId] = claimedGeneration
                        earliestAffected[deviceId] = null
                        latestAffected[deviceId] = null
                        1
                    } else {
                        0
                    }
                }
                "shrinkExactAnalysisInputNewestTail" -> {
                    acknowledgeCalls += 1
                    acknowledgeFailure?.let { throw it }
                    val deviceId = arguments?.get(0) as String
                    val claimedGeneration = arguments[1] as Long
                    val expectedEarliest = arguments[2] as Long
                    val expectedLatest = arguments[3] as Long
                    val newLatest = arguments[4] as Long
                    val generation = generations[deviceId]
                    val prior = acknowledged[deviceId] ?: 0L
                    if (generation == claimedGeneration &&
                        claimedGeneration > prior &&
                        earliestAffected[deviceId] == expectedEarliest &&
                        latestAffected[deviceId] == expectedLatest &&
                        newLatest in expectedEarliest until expectedLatest
                    ) {
                        latestAffected[deviceId] = newLatest
                        1
                    } else {
                        0
                    }
                }
                else -> throw UnsupportedOperationException(
                    "analysis input gate must not call ${method.name}",
                )
            }
        } as WhoopDao

        fun repository(): WhoopRepository = WhoopRepository(dao)

        fun write(deviceId: String, affectedTs: Long = 200L) {
            scoreBearingHistory += deviceId
            generations[deviceId] = (generations[deviceId] ?: 0L) + 1L
            earliestAffected[deviceId] = minOf(
                earliestAffected[deviceId] ?: affectedTs,
                affectedTs,
            )
            latestAffected[deviceId] = maxOf(
                latestAffected[deviceId] ?: affectedTs,
                affectedTs,
            )
        }
    }

    private fun claim(
        deviceId: String,
        generation: Long,
        earliest: Long,
        latest: Long = earliest,
    ) = AnalysisInputGenerationClaim(
        deviceId = deviceId,
        generation = generation,
        earliestAffectedTs = earliest,
        latestAffectedTs = latest,
    )

    private fun AnalysisInputConsumption.completeCoverage(
        sourceIds: Collection<String>,
        startTs: Long = 0L,
        endTs: Long = 1_000L,
    ) {
        markSourcesEvaluatedForOwnership(sourceIds, startTs, endTs)
    }

    @Test
    fun claimSnapshotsWithoutClearingAndSurvivesRepositoryRecreation() = runBlocking {
        val fixture = GateFixture(initialGenerations = mapOf("band-a" to 3L))
        val firstClaim = fixture.repository().claimAnalysisInput(listOf("band-a"), force = false)

        assertEquals(
            listOf(claim("band-a", 3L, 100L)),
            firstClaim?.claims,
        )
        assertEquals(0L, fixture.acknowledged["band-a"] ?: 0L)

        // Simulated process death: a new repository sees the same unacknowledged durable snapshot.
        val restartedClaim = fixture.repository().claimAnalysisInput(listOf("band-a"), force = false)
        assertEquals(firstClaim?.claims, restartedClaim?.claims)
        assertEquals(0L, fixture.acknowledged["band-a"] ?: 0L)
    }

    @Test
    fun successfulPassAcknowledgesExactGenerationAndBecomesOneShot() = runBlocking {
        val fixture = GateFixture(initialGenerations = mapOf("band-a" to 2L))
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a"), force = false)!!

        val result = repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourceConsumed("band-a")
            consumption.completeCoverage(listOf("band-a"))
            "persisted"
        }

        assertEquals("persisted", result)
        assertEquals(2L, fixture.acknowledged["band-a"])
        assertNull(repository.claimAnalysisInput(listOf("band-a"), force = false))
        assertEquals(1, fixture.acknowledgeCalls)
    }

    @Test
    fun concurrentWriteOnEvaluatedNonSelectedSourceRemainsDirtyAfterExactAcknowledgement() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 1L, "band-b" to 3L),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a", "band-b"), force = false)!!

        fixture.write("band-b", affectedTs = 200L)
        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourceConsumed("band-a")
            consumption.completeCoverage(listOf("band-a", "band-b"))
        }

        assertEquals(1L, fixture.generations["band-a"])
        assertEquals(1L, fixture.acknowledged["band-a"])
        assertEquals(4L, fixture.generations["band-b"])
        assertEquals(0L, fixture.acknowledged["band-b"] ?: 0L)
        assertEquals(
            listOf(claim("band-b", 4L, 100L, 200L)),
            repository.claimAnalysisInput(listOf("band-a", "band-b"), force = false)?.claims,
        )
    }

    @Test
    fun partialFailureAndCancellationNeverAcknowledge() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 4L, "band-b" to 7L),
        )
        val repository = fixture.repository()
        val failedLease = repository.claimAnalysisInput(
            listOf("band-a", "band-b"),
            force = false,
        )!!
        val expectedFailure = IllegalStateException("persistence failed")

        try {
            repository.runClaimedAnalysis(failedLease) { consumption ->
                consumption.markSourceConsumed("band-a")
                throw expectedFailure
            }
            fail("expected analysis failure")
        } catch (actual: IllegalStateException) {
            assertSame(expectedFailure, actual)
        }
        assertTrue(fixture.acknowledged.isEmpty())

        val canceledLease = repository.claimAnalysisInput(listOf("band-a"), force = false)!!
        val expectedCancellation = CancellationException("owner stopped")
        try {
            repository.runClaimedAnalysis(canceledLease) { consumption ->
                consumption.markSourceConsumed("band-a")
                throw expectedCancellation
            }
            fail("expected cancellation")
        } catch (actual: CancellationException) {
            assertSame(expectedCancellation, actual)
        }
        assertTrue(fixture.acknowledged.isEmpty())
        assertEquals(0, fixture.acknowledgeCalls)
    }

    @Test
    fun acknowledgementFailureLeavesGenerationPendingForRestart() = runBlocking {
        val expected = IllegalStateException("database unavailable")
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 5L),
            acknowledgeFailure = expected,
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a"), force = false)!!
        var persisted = false

        try {
            repository.runClaimedAnalysis(lease) { consumption ->
                consumption.markSourceConsumed("band-a")
                consumption.completeCoverage(listOf("band-a"))
                persisted = true
            }
            fail("expected acknowledgement failure")
        } catch (actual: IllegalStateException) {
            assertSame(expected, actual)
        }

        assertTrue(persisted)
        assertEquals(0L, fixture.acknowledged["band-a"] ?: 0L)
        assertNotNull(fixture.repository().claimAnalysisInput(listOf("band-a"), force = false))
    }

    @Test
    fun forcedFormulaPassRunsWithoutClaimsOrManufacturingDirtyState() = runBlocking {
        val fixture = GateFixture(initialGenerations = emptyMap())
        val repository = fixture.repository()
        val forced = repository.claimAnalysisInput(
            sourceIds = listOf("band-a", "", "   "),
            force = true,
        )

        assertNotNull(forced)
        assertTrue(forced!!.claims.isEmpty())
        var analyses = 0
        repository.runClaimedAnalysis(forced) { analyses += 1 }

        assertEquals(1, analyses)
        assertTrue(fixture.generations.isEmpty())
        assertTrue(fixture.acknowledged.isEmpty())
        assertEquals(0, fixture.acknowledgeCalls)
    }

    @Test
    fun ordinaryGateFailureFailsOpenWithoutAcknowledgement() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 1L),
            claimFailure = IllegalStateException("database temporarily unavailable"),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a"), force = false)

        assertNotNull(lease)
        assertFalse(lease!!.dirtyGateSucceeded)
        assertTrue(lease.claims.isEmpty())
        var analyses = 0
        repository.runClaimedAnalysis(lease) { analyses += 1 }

        assertEquals(1, analyses)
        assertEquals(0L, fixture.acknowledged["band-a"] ?: 0L)
        assertEquals(0, fixture.acknowledgeCalls)
    }

    @Test
    fun gateCancellationPropagatesWithoutAcknowledgement() = runBlocking {
        val expected = CancellationException("owner cancelled")
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 1L),
            claimFailure = expected,
        )

        try {
            fixture.repository().claimAnalysisInput(listOf("band-a"), force = false)
            fail("expected claim cancellation")
        } catch (actual: CancellationException) {
            assertSame(expected, actual)
        }

        assertEquals(0L, fixture.acknowledged["band-a"] ?: 0L)
        assertEquals(0, fixture.acknowledgeCalls)
    }

    @Test
    fun sourceCandidatesIncludeReadIdsAndExcludeArchivedOrBlankDevices() {
        val ids = GateFixture(emptyMap()).repository().analysisDirtySourceIds(
            activeSourceId = "band-active",
            registeredDevices = listOf(
                paired("band-active", DeviceStatus.active),
                paired("band-paired", DeviceStatus.paired),
                paired("band-archived", DeviceStatus.archived),
                paired("\t", DeviceStatus.paired),
            ),
        )

        assertEquals(
            listOf(
                AnalysisInvalidationSource.OWNERSHIP,
                "band-active",
                "band-paired",
                WhoopRepository.WHOOP_SOURCE,
            ),
            ids,
        )
    }

    @Test
    fun archivedCanonicalIsExcludedAndCannotRetriggerForegroundAnalysis() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf(
                WhoopRepository.WHOOP_SOURCE to 8L,
            ),
        )
        val repository = fixture.repository()
        val sourceIds = repository.analysisDirtySourceIds(
            activeSourceId = "band-active",
            registeredDevices = listOf(
                paired("band-active", DeviceStatus.active),
                paired(WhoopRepository.WHOOP_SOURCE, DeviceStatus.archived),
            ),
        )

        assertEquals(
            listOf(AnalysisInvalidationSource.OWNERSHIP, "band-active"),
            sourceIds,
        )

        assertEquals(0L, fixture.acknowledged[WhoopRepository.WHOOP_SOURCE] ?: 0L)
        assertNull(repository.claimAnalysisInput(sourceIds, force = false))
    }

    @Test
    fun unregisteredActiveAndCanonicalCompatibilityFallbackRemainClaimable() {
        val ids = GateFixture(emptyMap()).repository().analysisDirtySourceIds(
            activeSourceId = "legacy-active",
            registeredDevices = emptyList(),
        )

        assertEquals(
            listOf(
                AnalysisInvalidationSource.OWNERSHIP,
                "legacy-active",
                WhoopRepository.WHOOP_SOURCE,
            ),
            ids,
        )
    }

    @Test
    fun explicitActiveFallbackRemainsClaimableDuringRegistryRepair() {
        val ids = GateFixture(emptyMap()).repository().analysisDirtySourceIds(
            activeSourceId = WhoopRepository.WHOOP_SOURCE,
            registeredDevices = listOf(
                paired(WhoopRepository.WHOOP_SOURCE, DeviceStatus.archived),
            ),
        )

        assertEquals(
            listOf(AnalysisInvalidationSource.OWNERSHIP, WhoopRepository.WHOOP_SOURCE),
            ids,
        )
    }

    @Test
    fun successfulPassAcknowledgesSelectedAndNonSelectedEvaluatedSources() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 2L, "band-b" to 4L),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a", "band-b"), force = false)!!

        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourceConsumed("band-a")
            consumption.completeCoverage(listOf("band-a", "band-b"))
        }

        assertEquals(2L, fixture.acknowledged["band-a"])
        assertEquals(4L, fixture.acknowledged["band-b"])
        assertNull(repository.claimAnalysisInput(listOf("band-a", "band-b"), force = false))
    }

    @Test
    fun sourceOutsideOwnershipEvaluationRemainsPending() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 2L, "ejected-band" to 4L),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(
            listOf("band-a", "ejected-band"),
            force = false,
        )!!

        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourceConsumed("band-a")
            consumption.completeCoverage(listOf("band-a"))
        }

        assertEquals(2L, fixture.acknowledged["band-a"])
        assertEquals(0L, fixture.acknowledged["ejected-band"] ?: 0L)
        assertEquals(
            listOf(claim("ejected-band", 4L, 100L)),
            repository.claimAnalysisInput(listOf("band-a", "ejected-band"), force = false)?.claims,
        )
    }

    @Test
    fun ownershipEvaluationFailureLeavesSelectedAndNonSelectedClaimsPending() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 2L, "band-b" to 4L),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a", "band-b"), force = false)!!

        try {
            repository.runClaimedAnalysis(lease) { consumption ->
                consumption.markSourceConsumed("band-a")
                throw IllegalStateException("ownership read failed")
            }
            fail("expected ownership failure")
        } catch (_: IllegalStateException) {
            // Expected: the terminal ownership-evaluated snapshot was never published.
        }

        assertTrue(fixture.acknowledged.isEmpty())
        assertEquals(
            listOf(
                claim("band-a", 2L, 100L),
                claim("band-b", 4L, 100L),
            ),
            repository.claimAnalysisInput(listOf("band-a", "band-b"), force = false)?.claims,
        )
    }

    @Test
    fun ownershipControlClaimWithNoScoreBearingHistoryAcknowledgesAfterCompletePass() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf(AnalysisInvalidationSource.OWNERSHIP to 3L),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(
            listOf(AnalysisInvalidationSource.OWNERSHIP),
            force = false,
        )!!

        repository.runClaimedAnalysis(lease) { Unit }

        assertEquals(3L, fixture.acknowledged[AnalysisInvalidationSource.OWNERSHIP])
    }

    @Test
    fun legacyUnboundedOwnershipClaimWithScoreBearingHistoryRemainsPending() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf(AnalysisInvalidationSource.OWNERSHIP to 3L),
            initialScoreBearingHistory = setOf("band-a"),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(
            listOf(AnalysisInvalidationSource.OWNERSHIP),
            force = false,
        )!!

        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.completeCoverage(listOf("band-a"), 0L, 1_000L)
        }

        assertEquals(
            0L,
            fixture.acknowledged[AnalysisInvalidationSource.OWNERSHIP] ?: 0L,
        )
        assertNotNull(
            repository.claimAnalysisInput(
                listOf(AnalysisInvalidationSource.OWNERSHIP),
                force = false,
            ),
        )
    }

    @Test
    fun boundedOwnershipClaimWithScoreBearingHistoryAcknowledgesAfterCoverage() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf(AnalysisInvalidationSource.OWNERSHIP to 3L),
            initialBounds = mapOf(
                AnalysisInvalidationSource.OWNERSHIP to (100L to 200L),
            ),
            initialScoreBearingHistory = setOf("band-a"),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(
            listOf(AnalysisInvalidationSource.OWNERSHIP),
            force = false,
        )!!

        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourcesEvaluatedForOwnership(
                listOf("band-a"),
                0L,
                1_000L,
            )
        }

        assertEquals(3L, fixture.acknowledged[AnalysisInvalidationSource.OWNERSHIP])
        assertNull(
            repository.claimAnalysisInput(
                listOf(AnalysisInvalidationSource.OWNERSHIP),
                force = false,
            ),
        )
    }

    @Test
    fun claimOutsideActualScannedCoverageRemainsPending() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("old-band" to 1L),
            initialBounds = mapOf("old-band" to (100L to 120L)),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("old-band"), force = false)!!

        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourceConsumed("old-band")
            consumption.completeCoverage(listOf("old-band"), startTs = 121L, endTs = 1_000L)
        }

        assertEquals(0L, fixture.acknowledged["old-band"] ?: 0L)
        assertEquals(
            listOf(claim("old-band", 1L, 100L, 120L)),
            repository.claimAnalysisInput(listOf("old-band"), force = false)?.claims,
        )
    }

    @Test
    fun invalidBoundsRemainPendingEvenAfterOtherwiseSuccessfulPass() = runBlocking {
        val fixture = GateFixture(
            initialGenerations = mapOf("invalid-band" to 1L),
            initialBounds = mapOf("invalid-band" to (200L to 100L)),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("invalid-band"), force = false)!!

        repository.runClaimedAnalysis(lease) { consumption ->
            consumption.markSourceConsumed("invalid-band")
            consumption.completeCoverage(listOf("invalid-band"), 0L, 1_000L)
        }

        assertEquals(0L, fixture.acknowledged["invalid-band"] ?: 0L)
        assertNotNull(repository.claimAnalysisInput(listOf("invalid-band"), force = false))
    }

    @Test
    fun multiYearHistoricalClaimPlansOnlyOneBoundedAnchoredBatch() {
        val now = 1_780_000_000L
        val oldTs = now - 5L * 365L * 86_400L
        val historical = claim("old-band", 1L, oldTs, oldTs + 3_600L)

        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = listOf(historical),
            nowSeconds = now,
            timezoneOffsetSeconds = 0L,
        )

        assertEquals(IntelligenceEngine.ANALYSIS_INVALIDATION_BATCH_DAYS, plan.maxDays)
        assertEquals(IntelligenceEngine.AnalysisPassKind.HISTORICAL, plan.passKind)
        assertEquals(
            IntelligenceEngine.midnightLocal(historical.latestAffectedTs!!, 0L),
            plan.anchorNowSeconds,
        )
        assertTrue(plan.scanCoverage.covers(historical))
        assertFalse(plan.requestedWindowSatisfied)
    }

    @Test
    fun boundedPassesShrinkNewestTailProgressivelyUntilExactAcknowledgement() = runBlocking {
        val now = 1_780_012_345L
        val midnight = IntelligenceEngine.midnightLocal(now, 0L)
        val earliest = midnight - 59L * 86_400L + 1_000L
        val latest = midnight + 1_000L
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 7L),
            initialBounds = mapOf("band-a" to (earliest to latest)),
        )
        val repository = fixture.repository()
        val passKinds = mutableListOf<IntelligenceEngine.AnalysisPassKind>()
        val pendingNewestEdges = mutableListOf<Long>()

        repeat(4) {
            val lease = repository.claimAnalysisInput(listOf("band-a"), force = false)
                ?: return@repeat
            val plan = IntelligenceEngine.analysisScoringPlan(
                requestedMaxDays = 21,
                claims = lease.claims,
                nowSeconds = now,
                timezoneOffsetSeconds = 0L,
            )
            assertTrue(plan.maxDays <= IntelligenceEngine.ANALYSIS_INVALIDATION_BATCH_DAYS)
            passKinds += plan.passKind
            repository.runClaimedAnalysis(lease) { consumption ->
                consumption.markSourceConsumed("band-a")
                consumption.completeCoverage(
                    listOf("band-a"),
                    plan.scanCoverage.startTs,
                    plan.scanCoverage.endTs,
                )
            }
            fixture.latestAffected["band-a"]?.let(pendingNewestEdges::add)
        }

        assertEquals(
            listOf(
                IntelligenceEngine.AnalysisPassKind.RECENT,
                IntelligenceEngine.AnalysisPassKind.HISTORICAL,
                IntelligenceEngine.AnalysisPassKind.HISTORICAL,
            ),
            passKinds,
        )
        assertTrue(pendingNewestEdges.zipWithNext().all { (older, newer) -> newer < older })
        assertEquals(7L, fixture.acknowledged["band-a"])
        assertNull(repository.claimAnalysisInput(listOf("band-a"), force = false))
    }

    @Test
    fun concurrentWritePreventsPartialTailShrinkAndPreservesExpandedBounds() = runBlocking {
        val now = 1_780_012_345L
        val midnight = IntelligenceEngine.midnightLocal(now, 0L)
        val earliest = midnight - 59L * 86_400L
        val latest = midnight + 1_000L
        val concurrentTs = midnight + 2_000L
        val fixture = GateFixture(
            initialGenerations = mapOf("band-a" to 4L),
            initialBounds = mapOf("band-a" to (earliest to latest)),
        )
        val repository = fixture.repository()
        val lease = repository.claimAnalysisInput(listOf("band-a"), force = false)!!
        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = lease.claims,
            nowSeconds = now,
            timezoneOffsetSeconds = 0L,
        )

        repository.runClaimedAnalysis(lease) { consumption ->
            fixture.write("band-a", concurrentTs)
            consumption.markSourceConsumed("band-a")
            consumption.completeCoverage(
                listOf("band-a"),
                plan.scanCoverage.startTs,
                plan.scanCoverage.endTs,
            )
        }

        assertEquals(5L, fixture.generations["band-a"])
        assertEquals(0L, fixture.acknowledged["band-a"] ?: 0L)
        assertEquals(earliest, fixture.earliestAffected["band-a"])
        assertEquals(concurrentTs, fixture.latestAffected["band-a"])
    }

    private fun paired(id: String, status: DeviceStatus) = PairedDeviceRow(
        id = id,
        brand = "NOOP",
        model = "test",
        nickname = null,
        sourceKind = SourceKind.liveBLE.name,
        capabilities = "",
        status = status.name,
        addedAt = 1L,
        lastSeenAt = 1L,
    )
}
