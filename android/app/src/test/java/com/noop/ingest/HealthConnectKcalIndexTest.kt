package com.noop.ingest

import com.noop.ingest.HealthConnectImporter.KcalIndex
import com.noop.ingest.HealthConnectImporter.KcalRecord
import com.noop.ingest.HealthConnectImporter.sumKcalInWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HealthConnectKcalIndexTest {
    private fun corpus(): List<KcalRecord> {
        val records = ArrayList<KcalRecord>()
        var time = 0L
        var index = 0
        while (time < 40_000L) {
            val source = if (index % 3 == 0) "phone" else "watch"
            val length = when (index % 4) {
                0 -> 900L
                1 -> 300L
                2 -> 1_200L
                else -> 60L
            }
            records += KcalRecord(time, time + length, 10.0 + index % 7, source)
            time += 450L
            index += 1
        }
        return records
    }

    @Test fun indexMatchesFullScanAcrossSweptWindows() {
        val records = corpus()
        val index = KcalIndex(records)
        var checked = 0
        for (width in listOf(1L, 60L, 900L, 3_600L, 10_000L)) {
            var start = -5_000L
            while (start < 45_000L) {
                val expected = sumKcalInWindow(records, start, start + width)
                val actual = index.sumInWindow(start, start + width)
                if (expected == null) assertNull(actual)
                else assertEquals(expected, actual!!, 0.0)
                checked += 1
                start += 137L
            }
        }
        check(checked > 1_000)
    }

    @Test fun unsortedInputRemainsBitExact() {
        val records = ArrayList<KcalRecord>()
        var time = 30_000L
        for (i in 0 until 4_000) {
            records += KcalRecord(
                time,
                time + 700 + (i % 5) * 130L,
                0.1 + (i % 9) * 0.037,
                if (i % 2 == 0) "a" else "b",
            )
            time -= 7L * (i % 11 + 1)
            if (i % 3 == 0) time += 900
        }
        val index = KcalIndex(records)
        var start = 0L
        while (start < 40_000L) {
            for (width in listOf(600L, 3_600L, 20_000L)) {
                val expected = sumKcalInWindow(records, start, start + width)
                val actual = index.sumInWindow(start, start + width)
                if (expected == null) assertNull(actual)
                else assertEquals(expected, actual!!, 0.0)
            }
            start += 91L
        }
    }

    @Test fun spanningRecordFallbackMatchesScan() {
        val records = ArrayList<KcalRecord>()
        var time = 0L
        repeat(2_000) {
            records += KcalRecord(time, time + 900, 12.0, "watch")
            time += 900
        }
        records += KcalRecord(0, time, 100.0, "phone")
        val index = KcalIndex(records)
        var start = 0L
        while (start < time) {
            assertEquals(
                sumKcalInWindow(records, start, start + 3_600)!!,
                index.sumInWindow(start, start + 3_600)!!,
                0.0,
            )
            start += 45_000L
        }
    }

    @Test fun longRecordAndBoundaryCasesMatchScan() {
        val records = listOf(
            KcalRecord(0, 86_400, 864.0, "phone"),
            KcalRecord(80_000, 80_600, 10.0, "watch"),
        )
        val index = KcalIndex(records)
        assertEquals(
            sumKcalInWindow(records, 80_000, 80_600)!!,
            index.sumInWindow(80_000, 80_600)!!,
            0.0,
        )
        assertNull(KcalIndex(emptyList()).sumInWindow(0, 100))
        assertNull(index.sumInWindow(500, 500))
        assertNull(index.sumInWindow(500_000, 510_000))
        val touching = listOf(KcalRecord(0, 100, 50.0, "phone"))
        assertNull(KcalIndex(touching).sumInWindow(100, 200))
    }

    @Test fun sourceDeOverlapAndTotalLessBasalArePreserved() {
        val duplicate = listOf(
            KcalRecord(100, 200, 300.0, "phone"),
            KcalRecord(100, 200, 290.0, "watch"),
        )
        assertEquals(300.0, sumKcalInWindow(duplicate, 100, 200)!!, 0.0)

        val hour = 3_600L
        val active = listOf(KcalRecord(0, 86_400, 240.0, "phone"))
        val total = listOf(KcalRecord(10_000, 10_000 + hour, 700.0, "bike"))
        assertEquals(
            630.0,
            HealthConnectImporter.workoutKcal(active, total, 1_680.0, 10_000, 10_000 + hour)!!,
            0.0,
        )
    }
}
