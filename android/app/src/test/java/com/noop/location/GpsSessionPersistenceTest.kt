package com.noop.location

import com.noop.analytics.RouteMath.LatLng
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GpsSessionPersistenceTest {
    private val now = 1_800_000_000_000L

    @Test fun activeRouteRoundTripsAcrossProcessRestart() {
        val original = GpsSession.State(
            active = true,
            startMs = now - 20 * 60_000L,
            sportName = "Outdoor Run",
            track = listOf(LatLng(40.7128, -74.0060), LatLng(40.7134, -74.0048)),
        )
        val restored = GpsSessionPersistence.decode(GpsSessionPersistence.encode(original), now)
        requireNotNull(restored)
        assertTrue(restored.active)
        assertEquals(original.startMs, restored.startMs)
        assertEquals(original.sportName, restored.sportName)
        assertEquals(original.track.size, restored.track.size)
        assertEquals(original.track.size, restored.pointCount)
        assertTrue(restored.distanceM > 0.0)
        assertTrue(restored.paceSecPerKm != null)
    }

    @Test fun appendJournal_restoresCompletePointsAndToleratesOnlyATornTail() {
        val header = GpsSessionPersistence.encodeHeader(
            GpsSession.State(active = true, startMs = now - 60_000L, sportName = "Run"),
        )!!
        val a = GpsSessionPersistence.encodePoint(LatLng(40.0, -73.0))!!
        val b = GpsSessionPersistence.encodePoint(LatLng(40.001, -73.002))!!

        val restored = GpsSessionPersistence.decode(header + a + b + "40.00", now)
        assertEquals(2, restored?.pointCount)
        assertTrue((restored?.distanceM ?: 0.0) > 0.0)

        // Corruption in the middle is not treated as a harmless process-killed final append.
        assertNull(GpsSessionPersistence.decode(header + a + "bad\n" + b, now))
    }

    @Test fun journalHeaderIsConstantSizeRegardlessOfRouteLength() {
        val base = GpsSession.State(active = true, startMs = now - 60_000L, sportName = "Long Ride")
        val huge = base.copy(track = List(10_000) { LatLng(40.0 + it / 1_000_000.0, -73.0) })
        assertEquals(
            GpsSessionPersistence.encodeHeader(base),
            GpsSessionPersistence.encodeHeader(huge),
        )
        assertNull(GpsSessionPersistence.encodePoint(LatLng(95.0, 0.0)))
    }

    @Test fun liveAccumulatorPublishesConstantSizeTotalsButEndReturnsTheCompleteRoute() {
        GpsSession.stop() // isolate the process singleton from any prior test
        try {
            GpsSession.start(now - 60_000L, "Run")
            GpsSession.append(LatLng(40.0, -73.0))
            GpsSession.append(LatLng(40.001, -73.002))

            assertEquals(2, GpsSession.state.value.pointCount)
            assertEquals(2, GpsSession.snapshotTrack().size)
            assertTrue(GpsSession.state.value.distanceM > 0.0)
            assertEquals(2, GpsSession.stop().size)
            assertFalse(GpsSession.state.value.active)
        } finally {
            GpsSession.stop()
        }
    }

    @Test fun inactiveOrMalformedSnapshotsFailClosed() {
        assertNull(GpsSessionPersistence.encode(GpsSession.State()))
        assertNull(GpsSessionPersistence.decode(null, now))
        assertNull(GpsSessionPersistence.decode("not-a-checkpoint", now))
        assertNull(GpsSessionPersistence.decode("v1\nnope\nRun\n", now))
    }

    @Test fun staleAndFutureSnapshotsDoNotRevive() {
        fun raw(start: Long) = "v1\n$start\nRun\n"
        assertNull(GpsSessionPersistence.decode(raw(now - GpsSessionPersistence.maxSessionAgeMs - 1), now))
        assertNull(GpsSessionPersistence.decode(raw(now + GpsSessionPersistence.maxFutureSkewMs + 1), now))
        assertFalse(GpsSessionPersistence.decode(raw(now - 60_000L), now) == null)
    }

    @Test fun impossibleCoordinatesFailClosed() {
        // Encoded polyline for an impossible latitude is accepted by the codec but rejected by the
        // checkpoint's geographic bounds before it can reach the live map.
        val impossible = com.noop.analytics.RouteMath.encode(listOf(LatLng(95.0, 0.0)))
        assertNull(GpsSessionPersistence.decode("v1\n${now - 60_000L}\nRun\n$impossible", now))
    }
}
