package com.noop.analytics

import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import java.lang.reflect.Proxy
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test

class EffortRescoreMigrationTest {
    @Test
    fun `first upgrade observation preserves existing effort and leaves migration retryable`() =
        runBlocking {
            val dao = Proxy.newProxyInstance(
                WhoopDao::class.java.classLoader,
                arrayOf(WhoopDao::class.java),
            ) { _, method, _ ->
                error("zero safe civil days must not touch persistence: ${method.name}")
            } as WhoopDao
            val repository = WhoopRepository(dao)
            val zone = ZoneId.of("America/New_York")
            val observation = LocalDate.of(2026, 9, 15)
                .atTime(LocalTime.NOON)
                .atZone(zone)
                .toEpochSecond()
            val snapshot = AnalysisTimeZoneHistory.forTesting(
                object : AnalysisTimeZoneHistory.Persistence {
                    private var bytes: ByteArray? = null

                    override fun read(): AnalysisTimeZoneHistory.ReadResult =
                        bytes?.let {
                            AnalysisTimeZoneHistory.ReadResult.Available(it.copyOf())
                        } ?: AnalysisTimeZoneHistory.ReadResult.Missing

                    override fun write(bytes: ByteArray): Boolean {
                        this.bytes = bytes.copyOf()
                        return true
                    }
                },
            ).observe(observation, zone)
            assertNotNull(snapshot)
            var completed = false

            IntelligenceEngine.runEffortRescoreIfNeeded(
                repo = repository,
                flagGet = { false },
                flagSet = { completed = true },
                timeZoneHistory = snapshot!!,
            )

            assertFalse(completed)
        }
}
