package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class WhoopLiveCapabilitiesTest {
    @Test
    fun liveCapabilitiesWithholdUnvalidatedStepsForEveryGeneration() {
        assertEquals(
            setOf(Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad),
            WhoopLiveCapabilities.metrics("4.0"),
        )
        val five = WhoopLiveCapabilities.metrics("5.0 MG")
        assertFalse(five.contains(Metric.steps))
        assertFalse(five.contains(Metric.spo2))
    }

    @Test
    fun encodingAndRuntimeSanitizerWithholdUnvalidatedMetrics() {
        assertEquals("hr,hrv,skinTemp,sleep,strainLoad", WhoopLiveCapabilities.encoded("4.0"))
        assertEquals("hr,hrv,skinTemp,sleep,strainLoad", WhoopLiveCapabilities.encoded("5.0 MG"))
        assertEquals("hr,hrv,skinTemp,sleep,strainLoad", WhoopLiveCapabilities.encoded("WHOOP 5.0"))
        assertEquals("hr,hrv,skinTemp,sleep,strainLoad", WhoopLiveCapabilities.encoded("WHOOP MG"))
        assertEquals(
            "unknown labels must not acquire 5/MG-only steps from a stray digit",
            "hr,hrv,skinTemp,sleep,strainLoad",
            WhoopLiveCapabilities.encoded("serial-5-unknown"),
        )
        assertEquals(
            "hr,hrv,skinTemp,sleep,strainLoad",
            WhoopLiveCapabilities.stripUnvalidatedLiveTokens(
                "hr,hrv,spo2,skinTemp,sleep,steps,strainLoad",
            ),
        )
        assertEquals(
            setOf(Metric.hr, Metric.strainLoad),
            WhoopLiveCapabilities.withoutUnvalidatedLiveMetrics(
                setOf(Metric.hr, Metric.spo2, Metric.steps, Metric.strainLoad),
            ),
        )
    }

    @Test
    fun dataOnlyMigrationIsVersioned() {
        assertEquals(26, WhoopDatabase.MIGRATION_26_27.startVersion)
        assertEquals(27, WhoopDatabase.MIGRATION_26_27.endVersion)
    }
}
