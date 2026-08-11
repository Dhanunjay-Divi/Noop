package com.noop.analytics

import com.noop.data.SleepSession
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.lang.reflect.Proxy

class IntelligenceSleepHealScopeTest {
    private fun sleep(deviceId: String, start: Long, end: Long, edited: Boolean = false) =
        SleepSession(deviceId = deviceId, startTs = start, endTs = end, userEdited = edited)

    /** Minimal repository-backed sleep store; the production helper reaches only these two DAO calls. */
    private class SleepStoreFixture(
        sessions: List<SleepSession>,
        private val forceZeroDeletes: Boolean = false,
    ) {
        val rows = LinkedHashMap<Pair<String, Long>, SleepSession>().apply {
            sessions.forEach { put(it.deviceId to it.startTs, it) }
        }
        private val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "sleepSessions" -> {
                    val deviceId = args!![0] as String
                    val from = args[1] as Long
                    val to = args[2] as Long
                    val limit = args[3] as Int
                    rows.values.filter {
                        it.deviceId == deviceId && it.startTs in from..to
                    }.sortedBy { it.startTs }.take(limit)
                }
                "deleteSleepSession" -> {
                    if (forceZeroDeletes) {
                        0
                    } else {
                        val key = (args!![0] as String) to (args[1] as Long)
                        if (rows.remove(key) != null) 1 else 0
                    }
                }
                else -> throw UnsupportedOperationException("sleep heal must not call ${method.name}")
            }
        } as WhoopDao
        val repo = WhoopRepository(dao)
    }

    @Test
    fun includesComputedAndEveryRegisteredDevice() {
        val ids = IntelligenceEngine.sleepHealDeviceIds(
            "my-whoop-noop",
            listOf("my-whoop", "oura-ring"),
        )

        assertEquals(listOf("my-whoop", "my-whoop-noop", "oura-ring"), ids)
    }

    @Test
    fun deduplicatesAndSortsDeterministically() {
        val ids = IntelligenceEngine.sleepHealDeviceIds(
            "b-noop",
            listOf("oura-ring", "b-noop", "a-whoop"),
        )

        assertEquals(listOf("a-whoop", "b-noop", "oura-ring"), ids)
    }

    @Test
    fun keepsComputedIdWhenRegistryIsEmpty() {
        assertEquals(
            listOf("my-whoop-noop"),
            IntelligenceEngine.sleepHealDeviceIds("my-whoop-noop", emptyList()),
        )
    }

    @Test
    fun storeBackedRepairIsPerSourcePreservesEditedAndNonOverlapAndIsIdempotent() = runBlocking {
        val store = SleepStoreFixture(
            listOf(
                // Computed: the current pass's fresh start wins its shifted duplicate.
                sleep("computed", 10_000, 20_000),
                sleep("computed", 10_600, 20_300),
                // Oura: longest wins; the later non-overlapping nap remains.
                sleep("oura", 40_000, 60_000),
                sleep("oura", 40_600, 59_000),
                sleep("oura", 62_000, 64_000),
                // Edited source: user correction wins its overlap; separate sleep remains.
                sleep("edited", 70_000, 90_000, edited = true),
                sleep("edited", 70_600, 89_000),
                sleep("edited", 92_000, 95_000),
            ),
        )

        val first = IntelligenceEngine.healBankedSleepSessions(
            repo = store.repo,
            deviceIds = listOf("oura", "computed", "edited", "oura"),
            windowStart = 0,
            windowEnd = 100_000,
            oldestDay = "1970-01-01",
            newestDay = "2100-01-01",
            timezoneOffsetSeconds = 0,
            freshStarts = setOf(10_600),
        )

        assertEquals(3, first.deleted.size)
        assertEquals(0, first.unchangedDeleteCount)
        assertEquals(listOf(10_600L), store.rows.values.filter { it.deviceId == "computed" }.map { it.startTs })
        assertEquals(
            listOf(40_000L, 62_000L),
            store.rows.values.filter { it.deviceId == "oura" }.map { it.startTs },
        )
        val edited = store.rows.values.filter { it.deviceId == "edited" }
        assertEquals(listOf(70_000L, 92_000L), edited.map { it.startTs })
        assertTrue(edited.first().userEdited)

        val second = IntelligenceEngine.healBankedSleepSessions(
            repo = store.repo,
            deviceIds = listOf("computed", "oura", "edited"),
            windowStart = 0,
            windowEnd = 100_000,
            oldestDay = "1970-01-01",
            newestDay = "2100-01-01",
            timezoneOffsetSeconds = 0,
            freshStarts = setOf(10_600),
        )
        assertTrue(second.deleted.isEmpty())
        assertEquals(0, second.unchangedDeleteCount)
    }

    @Test
    fun zeroRowDeleteIsNotCountedAsRemoved() = runBlocking {
        val store = SleepStoreFixture(
            listOf(
                sleep("oura", 10_000, 20_000),
                sleep("oura", 10_600, 19_000),
            ),
            forceZeroDeletes = true,
        )
        val result = IntelligenceEngine.healBankedSleepSessions(
            repo = store.repo,
            deviceIds = listOf("oura"),
            windowStart = 0,
            windowEnd = 30_000,
            oldestDay = "1970-01-01",
            newestDay = "2100-01-01",
            timezoneOffsetSeconds = 0,
            freshStarts = emptySet(),
        )

        assertTrue(result.deleted.isEmpty())
        assertEquals(1, result.unchangedDeleteCount)
        assertEquals(2, store.rows.size)
    }

    /** Source-wiring audit: compilation checks the constructor type; this pins the two named arguments
     * whose omission previously let post-offload scoring advance the watermark after healing one id. */
    @Test
    fun productionPostOffloadPassThreadsTheRegistryOwnerSource() {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        fun source(relative: String): File? = listOf(
            File(userDir, "src/main/java/$relative"),
            File(userDir, "app/src/main/java/$relative"),
            File(userDir, "android/app/src/main/java/$relative"),
        ).firstOrNull { it.isFile }

        val app = source("com/noop/NoopApplication.kt")
        val ble = source("com/noop/ble/WhoopBleClient.kt")
        assumeTrue("Android sources are not reachable from $userDir", app != null && ble != null)
        val appText = app!!.readText()
        val bleText = ble!!.readText()

        assertTrue(
            "the process-wide BLE client must receive the registry-backed source",
            appText.contains("dayOwnerSource = RegistryDayOwnerSource(deviceRegistry)"),
        )
        assertTrue(
            "post-offload analyzeRecent must forward the registry-backed source",
            bleText.contains("ownerSource = dayOwnerSource"),
        )
        assertFalse(
            "the production composition must not pass a null owner source",
            appText.contains("dayOwnerSource = null"),
        )
    }
}
