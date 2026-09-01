package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SleepStressTest {
    @Test
    fun failsClosedWithoutJointCoverage() {
        val start = 1_700_000_000L
        val hr = (0 until 3_600).map { HrSample("band", start + it, 60) }

        assertNull(SleepStress.analyze(hr, emptyList(), start, start + 3_600))
    }

    @Test
    fun stableRestingNightPublishesLowStress() {
        val streams = makeStreams(12, emptySet())
        val result = SleepStress.analyze(streams.hr, streams.rr, streams.start, streams.end)

        assertNotNull(result)
        assertEquals(1.0, result!!.coverageFraction, 0.0001)
        assertEquals(12, result.bucketCount(SleepStress.Band.LOW))
        assertEquals(0, result.bucketCount(SleepStress.Band.HIGH))
    }

    @Test
    fun elevatedHrAndSuppressedHrvProduceHighWindows() {
        val streams = makeStreams(12, setOf(10, 11))
        val result = SleepStress.analyze(streams.hr, streams.rr, streams.start, streams.end)

        assertNotNull(result)
        assertTrue(result!!.bucketCount(SleepStress.Band.HIGH) >= 2)
        assertTrue(result.fraction(SleepStress.Band.HIGH) > 0.0)
    }

    @Test
    fun sparseJointCoverageDoesNotPublish() {
        val streams = makeStreams(12, emptySet())
        val cutoff = streams.start + 6 * SleepStress.BUCKET_SECONDS
        assertNull(
            SleepStress.analyze(
                streams.hr.filter { it.ts < cutoff },
                streams.rr.filter { it.ts < cutoff },
                streams.start,
                streams.end,
            )
        )
    }

    private data class Streams(
        val start: Long,
        val end: Long,
        val hr: List<HrSample>,
        val rr: List<RrInterval>,
    )

    private fun makeStreams(bucketCount: Int, stressedBuckets: Set<Int>): Streams {
        val start = 1_700_000_000L
        val end = start + bucketCount * SleepStress.BUCKET_SECONDS
        val hr = ArrayList<HrSample>()
        val rr = ArrayList<RrInterval>()
        for (offset in 0 until (end - start).toInt()) {
            val bucket = offset / SleepStress.BUCKET_SECONDS.toInt()
            val stressed = bucket in stressedBuckets
            hr.add(HrSample("band", start + offset, if (stressed) 100 else 60))
            val calmRr = if (offset % 2 == 0) 900 else 1_000
            val stressedRr = if (offset % 2 == 0) 650 else 660
            rr.add(RrInterval("band", start + offset, if (stressed) stressedRr else calmRr))
        }
        return Streams(start, end, hr, rr)
    }
}
