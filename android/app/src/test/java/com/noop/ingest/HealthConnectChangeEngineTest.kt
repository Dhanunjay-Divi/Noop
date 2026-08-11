package com.noop.ingest

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthConnectChangeEngineTest {
    private class Feed(
        private val fresh: MutableMap<String, String> = mutableMapOf(),
        private val pages: MutableMap<String, HealthConnectChangePage> = mutableMapOf(),
    ) : HealthConnectChangeFeed {
        val requestedTokens = mutableListOf<String>()
        val requestedPages = mutableListOf<String>()

        override suspend fun createToken(recordType: String): String {
            requestedTokens += recordType
            return fresh.getValue(recordType)
        }

        override suspend fun changes(token: String): HealthConnectChangePage {
            requestedPages += token
            return pages.getValue(token)
        }
    }

    private class Store(initial: Map<String, String> = emptyMap()) : HealthConnectTokenStore {
        val tokens = initial.toMutableMap()
        var saves = 0
        var savedAt = -1L

        override suspend fun load(recordTypes: Set<String>): Map<String, String> =
            tokens.filterKeys { it in recordTypes }

        override suspend fun save(tokens: Map<String, String>, updatedAtMs: Long) {
            saves += 1
            savedAt = updatedAtMs
            this.tokens.putAll(tokens)
        }
    }

    @Test
    fun missingTypeBootstrapsThenSavesOnlyAfterRebuild() = runTest {
        val feed = Feed(fresh = mutableMapOf("Steps" to "steps-0"))
        val store = Store()
        var rebuilt = false
        var rebuildRequest: HealthConnectRebuildRequest? = null
        val result = HealthConnectChangeEngine(
            feed,
            store,
            rebuild = { request ->
                assertEquals(0, store.saves)
                rebuildRequest = request
                rebuilt = true
                true
            },
            nowMs = { 123L },
        ).reconcile(setOf("Steps"))

        assertEquals(HealthConnectReconcileResult.Success(true, 1, 0, 0), result)
        assertTrue(rebuilt)
        assertEquals(setOf("Steps"), rebuildRequest?.affectedRecordTypes)
        assertEquals(
            HealthConnectRebuildRequest.Horizon.FULL_SUPPORTED_HISTORY,
            rebuildRequest?.horizon,
        )
        assertEquals(null, rebuildRequest?.lookbackDays)
        assertEquals(mapOf("Steps" to "steps-0"), store.tokens)
        assertEquals(123L, store.savedAt)
    }

    @Test
    fun deletionOlderThanAutomaticWindowForcesOneFullHistoryRebuild() = runTest {
        // Health Connect omits the deleted record timestamp. This event represents a provider record
        // originally written 90 days ago; it must not be reconciled with the 35-day fast path.
        val feed = Feed(pages = mutableMapOf(
            "a" to HealthConnectChangePage("b", hasMore = true, tokenExpired = false, upsertions = 2),
            "b" to HealthConnectChangePage("c", hasMore = false, tokenExpired = false, deletions = 1),
        ))
        val store = Store(mapOf("Sleep" to "a"))
        var rebuilds = 0
        var rebuildRequest: HealthConnectRebuildRequest? = null
        val result = HealthConnectChangeEngine(feed, store, rebuild = { request ->
            rebuilds += 1
            rebuildRequest = request
            true
        })
            .reconcile(setOf("Sleep"))

        assertEquals(HealthConnectReconcileResult.Success(true, 0, 2, 1), result)
        assertEquals(listOf("a", "b"), feed.requestedPages)
        assertEquals(1, rebuilds)
        assertEquals(setOf("Sleep"), rebuildRequest?.affectedRecordTypes)
        assertEquals(
            HealthConnectRebuildRequest.Horizon.FULL_SUPPORTED_HISTORY,
            rebuildRequest?.horizon,
        )
        assertEquals(null, rebuildRequest?.lookbackDays)
        assertEquals("c", store.tokens["Sleep"])
    }

    @Test
    fun upsertionsUseBoundedAutomaticWindow() = runTest {
        val feed = Feed(pages = mutableMapOf(
            "old" to HealthConnectChangePage(
                "new",
                hasMore = false,
                tokenExpired = false,
                upsertions = 1,
            ),
        ))
        val store = Store(mapOf("Steps" to "old"))
        var rebuildRequest: HealthConnectRebuildRequest? = null
        val result = HealthConnectChangeEngine(feed, store, rebuild = { request ->
            rebuildRequest = request
            true
        }).reconcile(setOf("Steps"))

        assertEquals(HealthConnectReconcileResult.Success(true, 0, 1, 0), result)
        assertEquals(setOf("Steps"), rebuildRequest?.affectedRecordTypes)
        assertEquals(
            HealthConnectRebuildRequest.Horizon.AUTOMATIC_WINDOW,
            rebuildRequest?.horizon,
        )
        assertEquals(HealthConnectImporter.AUTOMATIC_LOOKBACK_DAYS, rebuildRequest?.lookbackDays)
        assertEquals("new", store.tokens["Steps"])
    }

    @Test
    fun historicalUpsertionUsesFullSupportedHistory() = runTest {
        val feed = Feed(pages = mutableMapOf(
            "old" to HealthConnectChangePage(
                "new",
                hasMore = false,
                tokenExpired = false,
                upsertions = 1,
                upsertionsOutsideAutomaticWindow = true,
            ),
        ))
        val store = Store(mapOf("Weight" to "old"))
        var rebuildRequest: HealthConnectRebuildRequest? = null
        val result = HealthConnectChangeEngine(feed, store, rebuild = { request ->
            rebuildRequest = request
            true
        }).reconcile(setOf("Weight"))

        assertEquals(HealthConnectReconcileResult.Success(true, 0, 1, 0), result)
        assertEquals(
            HealthConnectRebuildRequest.Horizon.FULL_SUPPORTED_HISTORY,
            rebuildRequest?.horizon,
        )
        assertEquals(null, rebuildRequest?.lookbackDays)
        assertEquals("new", store.tokens["Weight"])
    }

    @Test
    fun expiredTokenUsesFreshCursorAndRequiresRebuild() = runTest {
        val feed = Feed(
            fresh = mutableMapOf("HRV" to "fresh"),
            pages = mutableMapOf(
                "expired" to HealthConnectChangePage("ignored", false, tokenExpired = true),
            ),
        )
        val store = Store(mapOf("HRV" to "expired"))
        var rebuildRequest: HealthConnectRebuildRequest? = null
        val result = HealthConnectChangeEngine(feed, store, rebuild = { request ->
            rebuildRequest = request
            true
        })
            .reconcile(setOf("HRV"))

        assertEquals(HealthConnectReconcileResult.Success(true, 0, 0, 0), result)
        assertEquals(
            HealthConnectRebuildRequest.Horizon.FULL_SUPPORTED_HISTORY,
            rebuildRequest?.horizon,
        )
        assertEquals("fresh", store.tokens["HRV"])
    }

    @Test
    fun failedRebuildDoesNotAdvanceAnyToken() = runTest {
        val feed = Feed(pages = mutableMapOf(
            "old" to HealthConnectChangePage("new", false, tokenExpired = false, deletions = 1),
        ))
        val store = Store(mapOf("Weight" to "old"))
        val result = HealthConnectChangeEngine(feed, store, rebuild = { false })
            .reconcile(setOf("Weight"))

        assertTrue(result is HealthConnectReconcileResult.RetryableFailure)
        assertEquals("old", store.tokens["Weight"])
        assertEquals(0, store.saves)
    }

    @Test
    fun unchangedFeedAdvancesCursorWithoutRebuild() = runTest {
        val feed = Feed(pages = mutableMapOf(
            "one" to HealthConnectChangePage("two", false, tokenExpired = false),
        ))
        val store = Store(mapOf("Steps" to "one"))
        var rebuilt = false
        val result = HealthConnectChangeEngine(feed, store, rebuild = { rebuilt = true; true })
            .reconcile(setOf("Steps"))

        assertEquals(HealthConnectReconcileResult.Success(false, 0, 0, 0), result)
        assertFalse(rebuilt)
        assertEquals("two", store.tokens["Steps"])
    }

    @Test
    fun nonAdvancingPagedCursorRetriesWithoutSaving() = runTest {
        val feed = Feed(pages = mutableMapOf(
            "same" to HealthConnectChangePage("same", true, tokenExpired = false, upsertions = 1),
        ))
        val store = Store(mapOf("Exercise" to "same"))
        val result = HealthConnectChangeEngine(feed, store, rebuild = { true })
            .reconcile(setOf("Exercise"))

        assertTrue(result is HealthConnectReconcileResult.RetryableFailure)
        assertEquals(0, store.saves)
        assertEquals("same", store.tokens["Exercise"])
    }
}
