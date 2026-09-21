package com.noop.analytics

import com.noop.data.AnalysisInputGenerationClaim
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AnalysisTimeZoneHistoryTest {
    private class MemoryPersistence(
        var bytes: ByteArray? = null,
        var failRead: Boolean = false,
        var failWrite: Boolean = false,
    ) : AnalysisTimeZoneHistory.Persistence {
        var writeCount: Int = 0

        override fun read(): AnalysisTimeZoneHistory.ReadResult = when {
            failRead -> AnalysisTimeZoneHistory.ReadResult.Failed
            bytes == null -> AnalysisTimeZoneHistory.ReadResult.Missing
            else -> AnalysisTimeZoneHistory.ReadResult.Available(bytes!!.copyOf())
        }

        override fun write(bytes: ByteArray): Boolean {
            writeCount += 1
            if (failWrite) return false
            this.bytes = bytes.copyOf()
            return true
        }
    }

    private val newYork = ZoneId.of("America/New_York")
    private val losAngeles = ZoneId.of("America/Los_Angeles")

    private fun epoch(
        date: LocalDate,
        time: LocalTime,
        zone: ZoneId,
    ): Long = LocalDateTime.of(date, time).atZone(zone).toEpochSecond()

    private fun claim(at: Long) = AnalysisInputGenerationClaim(
        deviceId = "band-a",
        generation = 1L,
        earliestAffectedTs = at,
        latestAffectedTs = at,
    )

    @Test
    fun `first observation does not rebucket legacy history`() {
        val history = AnalysisTimeZoneHistory.forTesting(MemoryPersistence())
        val now = epoch(LocalDate.of(2026, 9, 15), LocalTime.of(14, 0), newYork)
        val snapshot = history.observe(now, newYork)!!
        val priorDay = epoch(LocalDate.of(2026, 9, 14), LocalTime.NOON, newYork)

        assertEquals(
            AnalysisTimeZoneHistory.Resolution.Uncertain(
                AnalysisTimeZoneHistory.Uncertainty.TRUNCATED_HISTORY,
            ),
            snapshot.resolve(priorDay),
        )
        assertTrue(
            snapshot.resolve(now + 5L) is AnalysisTimeZoneHistory.Resolution.Exact,
        )

        val windows = IntelligenceEngine.observedCivilDayWindows(
            maxDays = 3,
            referenceNowSeconds = now,
            snapshot = snapshot,
            historicalCatchUp = false,
        )
        assertTrue(windows.isEmpty())

        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 3,
            claims = listOf(claim(priorDay)),
            nowSeconds = now,
            timeZoneHistory = snapshot,
        )
        assertFalse(plan.shouldAnalyze)
        assertFalse(plan.scanCoverage.covers(claim(priorDay)))
        assertEquals(
            AnalysisTimeZoneHistory.Uncertainty.TRUNCATED_HISTORY,
            plan.terminalUnknownRange?.reason,
        )
        assertTrue(priorDay in plan.terminalUnknownRange!!)
        assertTrue(now in plan.terminalUnknownRange!!)
    }

    @Test
    fun `new york to los angeles leaves an unresolved travel gap and separate exact segments`() {
        val persistence = MemoryPersistence()
        val history = AnalysisTimeZoneHistory.forTesting(persistence)
        val nyStart = epoch(LocalDate.of(2026, 6, 1), LocalTime.NOON, newYork)
        val nyLast = epoch(LocalDate.of(2026, 6, 5), LocalTime.of(8, 0), newYork)
        val laFirst = epoch(LocalDate.of(2026, 6, 5), LocalTime.NOON, losAngeles)
        val laLast = epoch(LocalDate.of(2026, 9, 1), LocalTime.NOON, losAngeles)

        assertNotNull(history.observe(nyStart, newYork))
        assertNotNull(history.observe(nyLast, newYork))
        assertNotNull(history.observe(laFirst, losAngeles))
        history.observe(laLast, losAngeles)!!
        val snapshot = AnalysisTimeZoneHistory.forTesting(persistence).load()!!

        assertEquals(
            listOf(newYork, losAngeles),
            snapshot.exactSegments().map { it.zoneId },
        )
        val gapSecond = nyLast + (laFirst - nyLast) / 2L
        assertEquals(
            AnalysisTimeZoneHistory.Resolution.Uncertain(
                AnalysisTimeZoneHistory.Uncertainty.RECORDED_ZONE_BOUNDARY,
            ),
            snapshot.resolve(gapSecond),
        )

        val laReference = epoch(LocalDate.of(2026, 6, 7), LocalTime.NOON, losAngeles)
        val laWindows = IntelligenceEngine.observedCivilDayWindows(
            maxDays = 10,
            referenceNowSeconds = laReference,
            snapshot = snapshot,
            historicalCatchUp = true,
        )
        assertEquals(listOf("2026-06-07", "2026-06-06"), laWindows.map { it.dayKey })
        assertTrue(laWindows.all { it.provenanceStartTs == laFirst })
        assertTrue(laWindows.none { it.startTs <= nyLast })

        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = listOf(claim(laReference)),
            nowSeconds = laLast,
            timeZoneHistory = snapshot,
        )
        assertEquals(IntelligenceEngine.AnalysisPassKind.HISTORICAL, plan.passKind)
        assertTrue(plan.scanCoverage.covers(claim(laReference)))
        assertTrue(plan.civilDayWindows.all { it.provenanceStartTs == laFirst })
        assertTrue(plan.calibrationCivilDayWindows.all { it.provenanceStartTs == laFirst })
        assertTrue(plan.civilDayWindows.none { it.startTs <= nyLast })
        assertTrue(plan.calibrationCivilDayWindows.none { it.startTs <= nyLast })
    }

    @Test
    fun `claim inside recorded travel boundary defers with empty coverage`() {
        val history = AnalysisTimeZoneHistory.forTesting(MemoryPersistence())
        val nyStart = epoch(LocalDate.of(2026, 6, 1), LocalTime.NOON, newYork)
        val nyLast = epoch(LocalDate.of(2026, 6, 5), LocalTime.of(8, 0), newYork)
        val laFirst = epoch(LocalDate.of(2026, 6, 5), LocalTime.NOON, losAngeles)
        val laLast = epoch(LocalDate.of(2026, 9, 1), LocalTime.of(21, 0), losAngeles)
        history.observe(nyStart, newYork)
        history.observe(nyLast, newYork)
        history.observe(laFirst, losAngeles)
        val snapshot = history.observe(laLast, losAngeles)!!
        val boundaryClaim = claim(nyLast + (laFirst - nyLast) / 2L)

        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = listOf(boundaryClaim),
            nowSeconds = laLast,
            timeZoneHistory = snapshot,
        )

        assertEquals(IntelligenceEngine.AnalysisPassKind.DEFERRED, plan.passKind)
        assertEquals(
            IntelligenceEngine.AnalysisDeferralReason.TERMINAL_TIMEZONE_UNKNOWN,
            plan.deferralReason,
        )
        assertEquals(
            AnalysisTimeZoneHistory.Uncertainty.RECORDED_ZONE_BOUNDARY,
            plan.terminalUnknownRange?.reason,
        )
        assertFalse(plan.resolvableHistorySatisfied)
        assertTrue(boundaryClaim.latestAffectedTs!! in plan.terminalUnknownRange!!)
        assertTrue(
            epoch(LocalDate.of(2026, 6, 5), LocalTime.NOON, newYork) in
                plan.terminalUnknownRange!!,
        )
        assertFalse(plan.scanCoverage.covers(boundaryClaim))
        assertTrue(plan.civilDayWindows.isEmpty())
    }

    @Test
    fun `same new york segment uses exact spring and fall DST day lengths`() {
        val history = AnalysisTimeZoneHistory.forTesting(MemoryPersistence())
        val first = epoch(LocalDate.of(2026, 3, 1), LocalTime.NOON, newYork)
        val last = epoch(LocalDate.of(2026, 11, 4), LocalTime.NOON, newYork)
        history.observe(first, newYork)
        val snapshot = history.observe(last, newYork)!!

        assertEquals(1, snapshot.exactSegments().size)
        val springWindows = IntelligenceEngine.observedCivilDayWindows(
            maxDays = 5,
            referenceNowSeconds =
                epoch(LocalDate.of(2026, 3, 10), LocalTime.NOON, newYork),
            snapshot = snapshot,
            historicalCatchUp = true,
        )
        val fallWindows = IntelligenceEngine.observedCivilDayWindows(
            maxDays = 5,
            referenceNowSeconds =
                epoch(LocalDate.of(2026, 11, 3), LocalTime.NOON, newYork),
            snapshot = snapshot,
            historicalCatchUp = true,
        )

        assertEquals(
            23L * 3_600L,
            springWindows.single { it.dayKey == "2026-03-08" }.durationSeconds,
        )
        assertEquals(
            25L * 3_600L,
            fallWindows.single { it.dayKey == "2026-11-01" }.durationSeconds,
        )
    }

    @Test
    fun `persistence round trip is bounded and legacy before retained history stays uncertain`() {
        val persistence = MemoryPersistence()
        val history = AnalysisTimeZoneHistory.forTesting(
            persistence = persistence,
            maxObservations = 3,
        )
        val zones = listOf(
            ZoneId.of("UTC"),
            ZoneId.of("UTC+01:00"),
            ZoneId.of("UTC+02:00"),
            ZoneId.of("UTC+03:00"),
        )
        zones.forEachIndexed { index, zone ->
            assertNotNull(history.observe(1_000L + index * 100L, zone))
        }

        val reloaded = AnalysisTimeZoneHistory.forTesting(
            persistence = persistence,
            maxObservations = 3,
        ).load()!!
        assertEquals(listOf(1_100L, 1_200L, 1_300L), reloaded.observations.map {
            it.observedAtEpochSeconds
        })
        assertEquals(
            AnalysisTimeZoneHistory.Resolution.Uncertain(
                AnalysisTimeZoneHistory.Uncertainty.TRUNCATED_HISTORY,
            ),
            reloaded.resolve(1_099L),
        )
        assertTrue(persistence.bytes!!.size < 1_024)
    }

    @Test
    fun `corrupt persistence is preserved and fails closed`() {
        val original = byteArrayOf(1, 2, 3, 4)
        val corrupt = MemoryPersistence(bytes = original.copyOf())
        val corruptStore = AnalysisTimeZoneHistory.forTesting(corrupt)
        assertNull(corruptStore.load())
        assertNull(corruptStore.observe(1_000L, ZoneId.of("UTC")))
        assertTrue(corrupt.bytes!!.contentEquals(original))
        assertEquals(0, corrupt.writeCount)

        val failedWrite = MemoryPersistence(failWrite = true)
        val failedStore = AnalysisTimeZoneHistory.forTesting(failedWrite)
        assertNull(failedStore.observe(1_000L, ZoneId.of("UTC")))
        assertNull(failedWrite.bytes)
    }

    @Test
    fun `unsupported future schema is preserved and rejected`() {
        val bytes = ByteArrayOutputStream().also { buffer ->
            DataOutputStream(buffer).use { output ->
                output.writeInt(0x4E545A48)
                output.writeInt(999)
            }
        }.toByteArray()
        val persistence = MemoryPersistence(bytes = bytes.copyOf())
        val history = AnalysisTimeZoneHistory.forTesting(persistence)

        assertNull(history.load())
        assertNull(history.observe(1_000L, ZoneId.of("UTC")))
        assertTrue(persistence.bytes!!.contentEquals(bytes))
        assertEquals(0, persistence.writeCount)
    }

    @Test
    fun `stored observation survives a timezone rules revision`() {
        val bytes = ByteArrayOutputStream().also { buffer ->
            DataOutputStream(buffer).use { output ->
                output.writeInt(0x4E545A48)
                output.writeInt(2)
                output.writeLong(1_000L)
                output.writeInt(1)
                output.writeLong(1_000L)
                output.writeUTF("UTC")
                output.writeInt(3_600)
            }
        }.toByteArray()

        val snapshot = AnalysisTimeZoneHistory.forTesting(
            MemoryPersistence(bytes = bytes),
        ).load()

        assertNotNull(snapshot)
        assertEquals(3_600, snapshot!!.observations.single().offsetSeconds)
    }

    @Test
    fun `epoch values outside java time range are rejected without throwing`() {
        val persistence = MemoryPersistence()
        val history = AnalysisTimeZoneHistory.forTesting(persistence)

        assertNull(history.observe(Long.MAX_VALUE, ZoneId.of("UTC")))
        assertNull(persistence.bytes)
    }

    @Test
    fun `recent coverage keeps the eighteen hundred cap inside the current exact segment`() {
        val history = AnalysisTimeZoneHistory.forTesting(MemoryPersistence())
        val first = epoch(LocalDate.of(2026, 8, 1), LocalTime.NOON, losAngeles)
        val now = epoch(LocalDate.of(2026, 9, 1), LocalTime.of(21, 0), losAngeles)
        history.observe(first, losAngeles)
        val snapshot = history.observe(now, losAngeles)!!
        val beforeCap = claim(epoch(LocalDate.of(2026, 9, 1), LocalTime.of(17, 0), losAngeles))
        val afterCap = claim(epoch(LocalDate.of(2026, 9, 1), LocalTime.of(20, 0), losAngeles))

        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 21,
            claims = listOf(beforeCap, afterCap),
            nowSeconds = now,
            timeZoneHistory = snapshot,
        )

        assertEquals(IntelligenceEngine.AnalysisPassKind.RECENT, plan.passKind)
        assertTrue(plan.scanCoverage.covers(beforeCap))
        assertFalse(plan.scanCoverage.covers(afterCap))
        assertTrue(plan.civilDayWindows.all {
            it.provenanceStartTs == first && it.provenanceEndTs == null
        })
    }

    @Test
    fun `explicit fixed offset remains deterministic without timezone history`() {
        val now = 1_780_000_000L
        val plan = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 3,
            claims = emptyList(),
            nowSeconds = now,
            timezoneOffsetSeconds = 5L * 3_600L + 30L * 60L,
        )

        assertEquals(IntelligenceEngine.AnalysisPassKind.RECENT, plan.passKind)
        assertEquals(3, plan.civilDayWindows.size)
        assertEquals(5L * 3_600L + 30L * 60L, plan.timezoneOffsetSeconds)
        assertTrue(plan.civilDayWindows.all {
            it.provenanceStartTs == null && it.provenanceEndTs == null
        })
    }

    @Test
    fun `rest formula traversal covers every resolvable timezone segment`() {
        val history = AnalysisTimeZoneHistory.forTesting(MemoryPersistence())
        val utc = ZoneId.of("UTC")
        val gmt = ZoneId.of("GMT")
        val etcGmt = ZoneId.of("Etc/GMT")
        val firstStart = epoch(LocalDate.of(2026, 9, 1), LocalTime.MIDNIGHT, utc)
        val firstEnd = epoch(LocalDate.of(2026, 9, 2), LocalTime.MAX, utc)
        val secondStart = epoch(LocalDate.of(2026, 9, 4), LocalTime.MIDNIGHT, gmt)
        val secondEnd = epoch(LocalDate.of(2026, 9, 5), LocalTime.MAX, gmt)
        val latestStart = epoch(LocalDate.of(2026, 9, 7), LocalTime.MIDNIGHT, etcGmt)
        val now = epoch(LocalDate.of(2026, 9, 8), LocalTime.NOON, etcGmt)
        history.observe(firstStart, utc)
        history.observe(firstEnd, utc)
        history.observe(secondStart, gmt)
        history.observe(secondEnd, gmt)
        history.observe(latestStart, etcGmt)
        val snapshot = history.observe(now, etcGmt)!!

        val latest = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 4_000,
            claims = emptyList(),
            nowSeconds = now,
            force = true,
            timeZoneHistory = snapshot,
            traverseResolvableHistory = true,
        )
        val middle = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 4_000,
            claims = emptyList(),
            nowSeconds = now,
            force = true,
            timeZoneHistory = snapshot,
            traverseResolvableHistory = true,
            resolvableHistoryAnchor = latest.nextResolvableHistoryAnchor!!,
        )
        val oldest = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 4_000,
            claims = emptyList(),
            nowSeconds = now,
            force = true,
            timeZoneHistory = snapshot,
            traverseResolvableHistory = true,
            resolvableHistoryAnchor = middle.nextResolvableHistoryAnchor!!,
        )

        assertEquals(etcGmt, latest.timeZone)
        assertEquals(gmt, middle.timeZone)
        assertEquals(utc, oldest.timeZone)
        assertEquals(2, latest.civilDayWindows.size)
        assertEquals(2, middle.civilDayWindows.size)
        assertEquals(2, oldest.civilDayWindows.size)
        assertFalse(latest.resolvableHistorySatisfied)
        assertFalse(middle.resolvableHistorySatisfied)
        assertTrue(oldest.resolvableHistorySatisfied)
        assertNull(oldest.nextResolvableHistoryAnchor)
    }

    @Test
    fun `rest formula traversal keeps true truncation pending`() {
        val history = AnalysisTimeZoneHistory.forTesting(MemoryPersistence())
        val utc = ZoneId.of("UTC")
        val start = epoch(LocalDate.of(2026, 9, 1), LocalTime.MIDNIGHT, utc)
        val now = epoch(LocalDate.of(2026, 9, 5), LocalTime.NOON, utc)
        history.observe(start, utc)
        val snapshot = history.observe(now, utc)!!

        val first = IntelligenceEngine.analysisScoringPlan(
            requestedMaxDays = 2,
            claims = emptyList(),
            nowSeconds = now,
            force = true,
            timeZoneHistory = snapshot,
            traverseResolvableHistory = true,
        )

        assertEquals(2, first.civilDayWindows.size)
        assertTrue(first.requestedWindowSatisfied)
        assertFalse(first.resolvableHistorySatisfied)
        assertNotNull(first.nextResolvableHistoryAnchor)
        assertTrue(
            first.nextResolvableHistoryAnchor!! <
                first.civilDayWindows.last().startTs,
        )
    }
}
