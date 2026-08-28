package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiquidFramePacerTest {
    @Test
    fun capsHighRefreshDisplaysAtRequestedBudgets() {
        assertTrue(acceptedFrames(displayHz = 120, targetFps = 60, seconds = 1) in 59..60)
        assertTrue(acceptedFrames(displayHz = 120, targetFps = 30, seconds = 1) in 29..30)
        assertTrue(acceptedFrames(displayHz = 120, targetFps = 20, seconds = 1) in 19..20)
    }

    @Test
    fun preservesSixtyFpsOnARegularDisplay() {
        assertEquals(60, acceptedFrames(displayHz = 60, targetFps = 60, seconds = 1))
    }

    @Test
    fun carriedBudgetHandlesNinetyHertzWithoutFallingToFortyFive() {
        val accepted = acceptedFrames(displayHz = 90, targetFps = 60, seconds = 3)
        assertTrue("expected about 180 updates, got $accepted", accepted in 178..181)
    }

    @Test
    fun neverExceedsBudgetOnOneHundredFortyFourHertzDisplays() {
        val accepted = acceptedFrames(displayHz = 144, targetFps = 60, seconds = 10)
        assertTrue("expected 599-600 updates, got $accepted", accepted in 599..600)
    }

    @Test
    fun backgroundSizedGapIsNotAppliedToLiquidPhysics() {
        val pacer = LiquidFramePacer(60)
        val frame = 1_000_000_000L
        assertNull(pacer.advanceSeconds(frame))
        assertEquals(1.0 / 60.0, pacer.advanceSeconds(frame + 16_666_666L)!!, 0.001)
        assertNull(pacer.advanceSeconds(frame + 1_016_666_666L))
    }

    @Test
    fun moderateStallDoesNotCreateAHighRefreshCatchUpBurst() {
        val pacer = LiquidFramePacer(60)
        var frame = 1_000_000_000L
        assertNull(pacer.advanceSeconds(frame))
        frame += 400_000_000L
        assertEquals(0.4, pacer.advanceSeconds(frame)!!, 0.001)

        var accepted = 0
        repeat(12) {
            frame += 8_333_333L
            if (pacer.advanceSeconds(frame) != null) accepted++
        }
        assertTrue("60fps budget must resume without a 120Hz burst", accepted in 5..6)
    }

    private fun acceptedFrames(displayHz: Int, targetFps: Int, seconds: Int): Int {
        val pacer = LiquidFramePacer(targetFps)
        val step = 1_000_000_000L / displayHz
        var frame = 1_000_000_000L
        pacer.advanceSeconds(frame)
        var accepted = 0
        repeat(displayHz * seconds) {
            frame += step
            if (pacer.advanceSeconds(frame) != null) accepted++
        }
        return accepted
    }
}
