package com.noop.data

import java.lang.reflect.Proxy
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

class ManualWorkoutStepOwnershipTest {
    private data class Fixture(
        val repository: WhoopRepository,
        val reads: MutableList<String>,
    )

    private fun fixture(
        samplesBySource: Map<String, List<StepSample>>,
        sourceFailures: Map<String, Throwable> = emptyMap(),
    ): Fixture {
        val reads = mutableListOf<String>()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "stepSamples" -> {
                    val source = args!![0] as String
                    reads += source
                    sourceFailures[source]?.let { throw it }
                    samplesBySource[source].orEmpty()
                }
                else -> throw UnsupportedOperationException(
                    "manual workout fixture must not call ${method.name}"
                )
            }
        } as WhoopDao
        val transactor = object : WhoopRepository.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = block()
        }
        return Fixture(WhoopRepository(dao, transactor), reads)
    }

    @Test
    fun activeStationaryEvidenceSuppressesCanonicalFallback() = runBlocking {
        val active = "whoop-active"
        val f = fixture(
            mapOf(
                active to listOf(
                    StepSample(active, 100, 0, 0),
                    StepSample(active, 160, 400, 0),
                ),
                WhoopRepository.WHOOP_SOURCE to listOf(
                    StepSample(WhoopRepository.WHOOP_SOURCE, 100, 0, null),
                    StepSample(WhoopRepository.WHOOP_SOURCE, 160, 100, null),
                ),
            )
        )

        assertNull(f.repository.strapStepTicks(active, 100, 160))
        assertEquals(listOf(active), f.reads)
    }

    @Test
    fun emptyActiveSourceMayReadCanonicalButStillRejectsItsCounter() = runBlocking {
        val active = "whoop-active"
        val f = fixture(
            mapOf(
                active to emptyList(),
                WhoopRepository.WHOOP_SOURCE to listOf(
                    StepSample(WhoopRepository.WHOOP_SOURCE, 100, 0, 1),
                    StepSample(WhoopRepository.WHOOP_SOURCE, 160, 100, 1),
                ),
            )
        )

        assertNull(f.repository.strapStepTicks(active, 100, 160))
        assertEquals(listOf(active, WhoopRepository.WHOOP_SOURCE), f.reads)
    }

    @Test
    fun activeReadFailurePropagatesWithoutFallback() = runBlocking {
        val active = "whoop-active"
        val expected = IllegalStateException("injected step read failure")
        val f = fixture(
            samplesBySource = mapOf(
                WhoopRepository.WHOOP_SOURCE to listOf(
                    StepSample(WhoopRepository.WHOOP_SOURCE, 100, 0, null),
                    StepSample(WhoopRepository.WHOOP_SOURCE, 160, 100, null),
                ),
            ),
            sourceFailures = mapOf(active to expected),
        )

        try {
            f.repository.strapStepTicks(active, 100, 160)
            fail("expected active-source storage failure")
        } catch (actual: IllegalStateException) {
            assertSame(expected, actual)
        }
        assertEquals(listOf(active), f.reads)
    }

    @Test
    fun everyNonemptyAmbiguousActiveWindowSuppressesCanonicalFallback() = runBlocking {
        val active = "whoop-active"
        val scenarios = listOf(
            listOf(
                StepSample(active, 100, 0, 0),
            ),
            listOf(
                StepSample(active, 100, 100, 0),
                StepSample(active, 160, 100, 0),
            ),
            listOf(
                StepSample(active, 100, 0, 0),
                StepSample(active, 160, 700, 1),
            ),
            listOf(
                StepSample(active, 100, 0, 0),
                StepSample(active, 160, 100, null),
            ),
        )

        scenarios.forEach { activeSamples ->
            val f = fixture(
                mapOf(
                    active to activeSamples,
                    WhoopRepository.WHOOP_SOURCE to listOf(
                        StepSample(WhoopRepository.WHOOP_SOURCE, 100, 0, null),
                        StepSample(WhoopRepository.WHOOP_SOURCE, 160, 100, null),
                    ),
                )
            )
            assertNull(f.repository.strapStepTicks(active, 100, 160))
            assertEquals(listOf(active), f.reads)
        }
    }

    @Test
    fun activeReadCancellationPropagatesWithoutFallback() = runBlocking {
        val active = "whoop-active"
        val expected = CancellationException("owner stopped")
        val f = fixture(
            samplesBySource = mapOf(
                WhoopRepository.WHOOP_SOURCE to listOf(
                    StepSample(WhoopRepository.WHOOP_SOURCE, 100, 0, null),
                    StepSample(WhoopRepository.WHOOP_SOURCE, 160, 100, null),
                ),
            ),
            sourceFailures = mapOf(active to expected),
        )

        try {
            f.repository.strapStepTicks(active, 100, 160)
            fail("expected active-source cancellation")
        } catch (actual: CancellationException) {
            assertSame(expected, actual)
        }
        assertEquals(listOf(active), f.reads)
    }
}
