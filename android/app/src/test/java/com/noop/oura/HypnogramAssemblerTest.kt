package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HypnogramAssemblerTest {
    private fun phases(stages: List<OuraSleepStage>, rt: Long): List<OuraSleepPhase> =
        stages.mapIndexed { index, stage -> OuraSleepPhase(rt, index, stage) }

    @Test
    fun burstCodesReceiveDistinctThirtySecondPersistenceKeys() {
        val assembler = OuraHypnogramAssembler()
        assertNull(assembler.feed(5_000L, phases(listOf(OuraSleepStage.AWAKE, OuraSleepStage.LIGHT), 5_000L)))
        assertNull(assembler.feed(5_010L, phases(listOf(OuraSleepStage.DEEP, OuraSleepStage.REM), 5_010L)))
        val laid = requireNotNull(assembler.flush()).codesWithTimes(100_000L)
        assertEquals(listOf(99_880L, 99_910L, 99_940L, 99_970L), laid.map { it.ts })
        assertEquals(laid.size, laid.map { it.ts }.toSet().size)
    }

    @Test
    fun erasedMiddlePageCreatesGapWithoutRetimingWrittenCodes() {
        val first = phases(
            listOf(OuraSleepStage.DEEP, OuraSleepStage.LIGHT, OuraSleepStage.REM, OuraSleepStage.AWAKE),
            1_000L,
        )
        val erased = (0 until 4).map {
            OuraSleepPhase(1_001L, it, OuraSleepStage.AWAKE, unwritten = true)
        }
        val last = phases(
            listOf(OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM, OuraSleepStage.LIGHT),
            1_002L,
        )
        val laid = OuraHypnogramBurst(
            listOf(
                OuraHypnogramRecord(1_000L, first),
                OuraHypnogramRecord(1_001L, erased),
                OuraHypnogramRecord(1_002L, last),
            ),
        ).codesWithTimes(10_000L)

        assertEquals(8, laid.size)
        assertTrue(laid.none { it.phase.unwritten })
        assertEquals(listOf(9_640L, 9_670L, 9_700L, 9_730L), laid.take(4).map { it.ts })
        assertEquals(listOf(9_880L, 9_910L, 9_940L, 9_970L), laid.takeLast(4).map { it.ts })
        assertEquals(150L, laid[4].ts - laid[3].ts)
    }

    @Test
    fun allErasedBurstProducesNoStageableNight() {
        val erased = (0 until 8).map {
            OuraSleepPhase(1_000L, it, OuraSleepStage.AWAKE, unwritten = true)
        }
        val burst = OuraHypnogramBurst(listOf(OuraHypnogramRecord(1_000L, erased)))
        assertTrue(burst.codesWithTimes(10_000L).isEmpty())
    }

    @Test
    fun onsetClampCannotEraseWholeWrittenNight() {
        val assembler = OuraHypnogramAssembler()
        assembler.feed(
            1_000L,
            phases(
                listOf(OuraSleepStage.AWAKE, OuraSleepStage.LIGHT, OuraSleepStage.DEEP, OuraSleepStage.REM),
                1_000L,
            ),
        )
        val burst = requireNotNull(assembler.flush())
        assertEquals(listOf(9_910L, 9_940L, 9_970L), burst.codesWithTimes(10_000L, 9_910L).map { it.ts })
        assertEquals(4, burst.codesWithTimes(10_000L, 99_999L).size)
    }
}
