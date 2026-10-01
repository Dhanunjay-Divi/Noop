package com.noop.ui

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SparklineGeometryTest {
    @Test
    fun monotoneCurveStaysInsideEachMeasuredSegment() {
        val points = listOf(
            Offset(0f, 20f),
            Offset(20f, 4f),
            Offset(40f, 17f),
            Offset(60f, 7f),
            Offset(80f, 14f),
        )

        val segments = monotoneSparklineSegments(points)

        assertEquals(points.size - 1, segments.size)
        segments.forEach { segment ->
            val low = minOf(segment.start.y, segment.end.y)
            val high = maxOf(segment.start.y, segment.end.y)
            assertTrue(segment.control1.y in low..high)
            assertTrue(segment.control2.y in low..high)
        }
    }

    @Test
    fun flatCurveRemainsFlat() {
        val segments = monotoneSparklineSegments(
            listOf(
                Offset(0f, 12f),
                Offset(20f, 12f),
                Offset(40f, 12f),
            ),
        )

        assertEquals(2, segments.size)
        segments.forEach { segment ->
            assertEquals(12f, segment.control1.y, 0.0001f)
            assertEquals(12f, segment.control2.y, 0.0001f)
        }
    }

    @Test
    fun invalidPointOrderFailsClosed() {
        val segments = monotoneSparklineSegments(
            listOf(
                Offset(20f, 4f),
                Offset(20f, 8f),
            ),
        )

        assertTrue(segments.isEmpty())
    }
}
