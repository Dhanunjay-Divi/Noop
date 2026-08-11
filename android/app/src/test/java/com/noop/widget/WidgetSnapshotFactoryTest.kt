package com.noop.widget

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetSnapshotFactoryTest {
    @Test
    fun mapsOneAnchorIntoScoresVitalsAndHonestProvenance() {
        val row = DailyMetric(
            deviceId = "my-whoop-noop",
            day = "2026-08-10",
            totalSleepMin = 462.4,
            efficiency = 0.91,
            deepMin = 82.0,
            remMin = 104.0,
            restingHr = 52,
            avgHrv = 63.6,
            recovery = 72.4,
            strain = 31.2,
        )

        val snap = WidgetSnapshotFactory.make(
            anchorRow = row,
            heartRate = 74,
            batteryPct = 86,
            connected = true,
            updatedAtMs = 12_000L,
        )

        assertEquals(72, snap.recoveryPct)
        assertTrue(snap.restPct != null)
        assertEquals(31, snap.effortPct)
        assertEquals(64, snap.hrvMs)
        assertEquals(52, snap.restingHr)
        assertEquals(462, snap.sleepMinutes)
        assertEquals("2026-08-10", snap.scoreDay)
        assertEquals(WidgetScoreSource.NOOP.storageKey, snap.scoreSource)
        assertEquals("2026-08-10", snap.vitalsDay)
        assertEquals(WidgetScoreSource.NOOP.storageKey, snap.vitalsSource)
        assertEquals(12_000L, snap.liveUpdatedAtMs)
    }

    @Test
    fun missingAnchorNeverFabricatesMetricsOrSource() {
        val snap = WidgetSnapshotFactory.make(
            anchorRow = null,
            heartRate = null,
            batteryPct = 40,
            connected = false,
            updatedAtMs = 9_000L,
        )

        assertNull(snap.recoveryPct)
        assertNull(snap.restPct)
        assertNull(snap.hrvMs)
        assertNull(snap.scoreDay)
        assertNull(snap.scoreSource)
        assertEquals(40, snap.batteryPct)
    }

    @Test
    fun classifiesStableSourceKeysWithoutUsingDisplayCopy() {
        fun row(source: String) = DailyMetric(deviceId = source, day = "2026-08-10")

        assertEquals(WidgetScoreSource.NOOP, WidgetSnapshotFactory.sourceFor(row("ring-1-noop")))
        assertEquals(WidgetScoreSource.HEALTH_CONNECT, WidgetSnapshotFactory.sourceFor(row("health-connect")))
        assertEquals(WidgetScoreSource.APPLE_HEALTH, WidgetSnapshotFactory.sourceFor(row("apple-health")))
        assertEquals(WidgetScoreSource.ACTIVITY_FILE, WidgetSnapshotFactory.sourceFor(row("activity-file")))
        assertEquals(WidgetScoreSource.WEARABLE, WidgetSnapshotFactory.sourceFor(row("my-whoop")))
        assertNull(WidgetSnapshotFactory.sourceFor(null))
    }

    @Test
    fun olderSnapshotDefaultsRemainBackwardCompatible() {
        val oldShape = WidgetSnapshot(recoveryPct = 55, updatedAtMs = 1_000L)

        assertNull(oldShape.hrvMs)
        assertNull(oldShape.restingHr)
        assertNull(oldShape.sleepMinutes)
        assertNull(oldShape.scoreDay)
        assertNull(oldShape.scoreSource)
        assertNull(oldShape.vitalsDay)
        assertNull(oldShape.vitalsSource)
        assertEquals(0L, oldShape.liveUpdatedAtMs)
    }

    @Test
    fun vitalsCanComeFromAnUnscoredNightWithoutFabricatingRecovery() {
        val days = listOf(
            DailyMetric(deviceId = "my-whoop-noop", day = "2026-08-09", recovery = 70.0, avgHrv = 51.0),
            DailyMetric(
                deviceId = "my-whoop",
                day = "2026-08-10",
                recovery = null,
                avgHrv = 60.0,
                restingHr = 54,
                totalSleepMin = 440.0,
            ),
        )

        val vitals = WidgetSnapshotFactory.vitalsRow(
            days,
            logicalKey = "2026-08-10",
            localKey = "2026-08-10",
        )
        val snap = WidgetSnapshotFactory.make(
            anchorRow = days.first(),
            vitalsRow = vitals,
            heartRate = null,
            batteryPct = null,
            connected = false,
            updatedAtMs = 1L,
        )

        assertEquals(70, snap.recoveryPct)
        assertEquals("2026-08-09", snap.scoreDay)
        assertEquals(60, snap.hrvMs)
        assertEquals(54, snap.restingHr)
        assertEquals(440, snap.sleepMinutes)
        assertEquals("2026-08-10", snap.vitalsDay)
        assertEquals(WidgetScoreSource.WEARABLE.storageKey, snap.vitalsSource)
    }

    @Test
    fun freshnessDistinguishesLiveRecentStaleAndEmpty() {
        val now = 100_000_000L
        assertEquals(
            WidgetFreshness.LIVE,
            WidgetSnapshot(connected = true, updatedAtMs = now, liveUpdatedAtMs = now - 1_000L)
                .freshness(now),
        )
        assertEquals(
            WidgetFreshness.RECENT,
            WidgetSnapshot(connected = false, updatedAtMs = now - 60_000L).freshness(now),
        )
        assertEquals(
            WidgetFreshness.STALE,
            WidgetSnapshot(updatedAtMs = now - 7 * 60 * 60_000L).freshness(now),
        )
        assertEquals(WidgetFreshness.EMPTY, WidgetSnapshot().freshness(now))
        assertFalse(
            WidgetSnapshot(connected = true, updatedAtMs = now, liveUpdatedAtMs = now + 1L)
                .freshness(now) == WidgetFreshness.LIVE,
        )
    }
}
