package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OuraSleepSessionMappingTest {
    @Test
    fun stagesMergeButErasedPageGapDoesNot() {
        val t0 = 1_700_000_000L
        val session = requireNotNull(
            OuraSleepSessionMapping.session(
                (0 until 10).map { (t0 + it * 30L) to OuraSleepStage.DEEP } +
                    (0 until 10).map { (t0 + 360L + it * 30L) to OuraSleepStage.LIGHT },
            ),
        )
        assertEquals(t0, session.startTs)
        assertEquals(t0 + 660, session.endTs)
        assertNull(session.efficiency)
        assertEquals(
            "[{\"start\":$t0,\"end\":${t0 + 300},\"stage\":\"deep\",\"source\":\"oura\"}," +
                "{\"start\":${t0 + 360},\"end\":${t0 + 660},\"stage\":\"light\",\"source\":\"oura\"}]",
            session.stagesJson,
        )
        assertEquals(true, OuraSleepSessionMapping.hasOuraProvenance(session.stagesJson))
    }

    @Test fun emptyInputCreatesNoSession() {
        assertNull(OuraSleepSessionMapping.session(emptyList()))
    }

    @Test fun allAwakeFragmentIsNotPromoted() {
        assertNull(
            OuraSleepSessionMapping.session(
                listOf(1_000L to OuraSleepStage.AWAKE, 1_030L to OuraSleepStage.AWAKE),
            ),
        )
    }

    @Test fun completeCoverageComputesEfficiency() {
        val codes = (0 until 20).map { index ->
            (1_000L + index * 30L) to
                if (index < 16) OuraSleepStage.DEEP else OuraSleepStage.AWAKE
        }
        val session = requireNotNull(
            OuraSleepSessionMapping.session(codes),
        )
        assertEquals(0.8, session.efficiency!!, 1e-9)
    }

    @Test fun shortMostlyAsleepFragmentIsNotPromoted() {
        val codes = (0 until 10).map { (1_000L + it * 30L) to OuraSleepStage.LIGHT }
        assertNull(OuraSleepSessionMapping.session(codes))
    }
}
