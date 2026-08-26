package com.noop.ingest

import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectWriteGateTest {
    @Test
    fun concurrentCallsNeverOverlap() = runTest {
        val active = AtomicInteger(0)
        val maximum = AtomicInteger(0)
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()

        val first = launch {
            HealthConnectWriteGate.serialize {
                val now = active.incrementAndGet()
                maximum.updateAndGet { maxOf(it, now) }
                firstEntered.complete(Unit)
                try {
                    releaseFirst.await()
                } finally {
                    active.decrementAndGet()
                }
            }
        }
        firstEntered.await()
        val second = launch {
            HealthConnectWriteGate.serialize {
                val now = active.incrementAndGet()
                maximum.updateAndGet { maxOf(it, now) }
                active.decrementAndGet()
            }
        }

        runCurrent()
        assertEquals(1, active.get())
        releaseFirst.complete(Unit)
        joinAll(first, second)
        assertEquals(1, maximum.get())
        assertEquals(0, active.get())
    }

    @Test
    fun cancelledWaiterNeverEntersAndDoesNotPoisonGate() = runTest {
        val holderEntered = CompletableDeferred<Unit>()
        val releaseHolder = CompletableDeferred<Unit>()
        var waiterEntered = false

        val holder = launch {
            HealthConnectWriteGate.serialize {
                holderEntered.complete(Unit)
                releaseHolder.await()
            }
        }
        holderEntered.await()
        val waiter = launch {
            HealthConnectWriteGate.serialize {
                waiterEntered = true
            }
        }
        runCurrent()
        waiter.cancelAndJoin()
        assertFalse(waiterEntered)

        releaseHolder.complete(Unit)
        holder.join()
        HealthConnectWriteGate.serialize { waiterEntered = true }
        assertTrue(waiterEntered)
    }

    @Test
    fun absorbedDeleteFailurePropagates() = runTest {
        var attemptedIds: List<String>? = null
        val failure = runCatching {
            deleteAbsorbedSleepRecords(listOf("b", "a", "b")) { ids ->
                attemptedIds = ids
                throw IOException("provider failed")
            }
        }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertEquals(listOf("b", "a"), attemptedIds)
    }

    @Test
    fun migrationInsertsEveryReplacementBeforeDeletingOnlyOrphans() = runTest {
        val events = mutableListOf<String>()

        val written = insertSleepRecordsThenDeleteOrphans(
            existingClientRecordIds = listOf("noop-sleep-keep", "noop-sleep-stale"),
            desiredClientRecordIds = listOf("noop-sleep-keep", "noop-sleep-new"),
            absorbedClientRecordIds = listOf("noop-sleep-absorbed", "noop-sleep-keep"),
            insertDesired = {
                events += "insert"
                2
            },
            deleteByClientRecordId = { ids -> events += "delete:${ids.joinToString()}" },
        )

        assertEquals(2, written)
        assertEquals(
            listOf("insert", "delete:noop-sleep-stale, noop-sleep-absorbed"),
            events,
        )
    }

    @Test
    fun failedReplacementNeverDeletesExistingHistory() = runTest {
        var deleteCalled = false

        val failure = runCatching {
            insertSleepRecordsThenDeleteOrphans(
                existingClientRecordIds = listOf("noop-sleep-old"),
                desiredClientRecordIds = listOf("noop-sleep-new"),
                absorbedClientRecordIds = emptyList(),
                insertDesired = { throw IOException("insert failed") },
                deleteByClientRecordId = { deleteCalled = true },
            )
        }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertFalse(deleteCalled)
    }

    @Test
    fun orphanCleanupIsBoundedByDeleteBatchSize() = runTest {
        val batches = mutableListOf<List<String>>()

        insertSleepRecordsThenDeleteOrphans(
            existingClientRecordIds = (1..5).map { "noop-sleep-$it" },
            desiredClientRecordIds = emptyList(),
            absorbedClientRecordIds = emptyList(),
            deleteBatchSize = 2,
            insertDesired = { 0 },
            deleteByClientRecordId = { batches += it },
        )

        assertEquals(listOf(2, 2, 1), batches.map { it.size })
    }
}
