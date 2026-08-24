package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * #836/#1196 — [WhoopRepository.analysisFingerprint] is the cheap whole-history scoring-input
 * change-detector used by post-offload and idle rescoring. The DAO aggregates every raw stream consumed
 * by daily analysis. Stubbed through a Proxy [WhoopDao] to pin the repository contract without Room.
 */
class HrFingerprintTest {
    private val sourceId = "noop-band"

    private fun repo(count: Int, maxTs: Long): WhoopRepository {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "countAnalysisFingerprintRows" -> count
                "maxAnalysisFingerprintTs" -> maxTs
                else -> throw UnsupportedOperationException("analysisFingerprint must not call ${method.name}")
            }
        } as WhoopDao
        return WhoopRepository(dao)
    }

    @Test fun combinesCountAndMaxTs() = runBlocking {
        assertEquals("9:noop-band:42:1700", repo(count = 42, maxTs = 1700L).analysisFingerprint(sourceId))
    }

    // An empty store is a stable, non-null "0:0" (COALESCE), so a first run still differs from the unset
    // (null) watermark and scores; two empty reads match, so a genuinely empty store doesn't churn.
    @Test fun emptyStoreIsZeroZero() = runBlocking {
        assertEquals("9:noop-band:0:0", repo(count = 0, maxTs = 0L).analysisFingerprint(sourceId))
    }

    // A new sample (count up, later maxTs) moves the fingerprint, so the idle tick rescores.
    @Test fun newSampleMovesTheFingerprint() = runBlocking {
        val before = repo(count = 10, maxTs = 1000L).analysisFingerprint(sourceId)
        val after = repo(count = 11, maxTs = 1060L).analysisFingerprint(sourceId)
        assertEquals("9:noop-band:10:1000", before)
        assertEquals("9:noop-band:11:1060", after)
    }

    // Equal aggregate rows from a newly selected band must still trigger a pass for that source.
    @Test fun activeSourceIdentityMovesTheFingerprint() = runBlocking {
        val repository = repo(count = 42, maxTs = 1700L)
        val before = repository.analysisFingerprint("noop-a")
        val after = repository.analysisFingerprint("noop-band")
        assertEquals("6:noop-a:42:1700", before)
        assertEquals("9:noop-band:42:1700", after)
    }

    // A PPG-only WHOOP 5/MG offload is included by the DAO aggregates and therefore presents the same
    // observable contract as any other newly persisted HR input.
    @Test fun ppgOnlyNightMovesTheAggregateFingerprint() = runBlocking {
        val before = repo(count = 0, maxTs = 0L).analysisFingerprint(sourceId)
        val after = repo(count = 25_200, maxTs = 86_400L).analysisFingerprint(sourceId)
        assertEquals("9:noop-band:0:0", before)
        assertEquals("9:noop-band:25200:86400", after)
    }
}
