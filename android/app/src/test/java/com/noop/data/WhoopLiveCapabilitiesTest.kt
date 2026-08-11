package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WhoopLiveCapabilitiesTest {
    @Test
    fun generationCapabilitiesExcludeUncalibratedSpo2() {
        assertEquals(
            setOf(Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad),
            WhoopLiveCapabilities.metrics("4.0"),
        )
        val five = WhoopLiveCapabilities.metrics("5.0 MG")
        assertTrue(five.contains(Metric.steps))
        assertFalse(five.contains(Metric.spo2))
    }

    @Test
    fun encodingAndLegacyTokenStripAreStable() {
        assertEquals("hr,hrv,skinTemp,sleep,strainLoad", WhoopLiveCapabilities.encoded("4.0"))
        assertEquals("hr,hrv,skinTemp,sleep,steps,strainLoad", WhoopLiveCapabilities.encoded("5.0 MG"))
        assertEquals("hr,hrv,skinTemp,sleep,steps,strainLoad", WhoopLiveCapabilities.encoded("WHOOP 5.0"))
        assertEquals("hr,hrv,skinTemp,sleep,steps,strainLoad", WhoopLiveCapabilities.encoded("WHOOP MG"))
        assertEquals(
            "unknown labels must not acquire 5/MG-only steps from a stray digit",
            "hr,hrv,skinTemp,sleep,strainLoad",
            WhoopLiveCapabilities.encoded("serial-5-unknown"),
        )
        assertEquals(
            "hr,hrv,skinTemp,sleep,strainLoad",
            WhoopLiveCapabilities.stripSpo2Token("hr,hrv,spo2,skinTemp,sleep,strainLoad"),
        )
    }

    @Test
    fun dataOnlyMigrationIsVersioned() {
        assertEquals(26, WhoopDatabase.MIGRATION_26_27.startVersion)
        assertEquals(27, WhoopDatabase.MIGRATION_26_27.endVersion)
    }
}
