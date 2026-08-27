package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RingGenProductInfoTest {
    @Test
    fun recogniseRequiresAnExplicitGenerationToken() {
        assertEquals(OuraRingGen.GEN3, OuraRingGen.recognise("Oura Ring Gen3"))
        assertEquals(OuraRingGen.GEN4, OuraRingGen.recognise("Oura Ring 4"))
        assertEquals(OuraRingGen.GEN5, OuraRingGen.recognise("OURA RING GEN5"))
        assertEquals(OuraRingGen.GEN3, OuraRingGen.recognise("Oura Horizon"))
        assertNull(OuraRingGen.recognise("Oura 2H3B2405003655"))
        assertNull(OuraRingGen.recognise("WHOOP 5.0"))
        assertNull(OuraRingGen.recognise(null))
    }

    @Test
    fun hardwareIdMapsKnownGenerationsOnly() {
        assertEquals(OuraRingGen.GEN3, OuraRingGen.fromHardwareId("BLB_03"))
        assertEquals(OuraRingGen.GEN4, OuraRingGen.fromHardwareId("BLB_04"))
        assertEquals(OuraRingGen.GEN5, OuraRingGen.fromHardwareId("BLB_05"))
        assertNull(OuraRingGen.fromHardwareId("2H3B2405003655"))
        assertNull(OuraRingGen.fromHardwareId("BLB_09"))
        assertNull(OuraRingGen.fromHardwareId("BLB_"))
    }

    @Test
    fun productInfoStringSkipsStatusAndStopsAtNull() {
        val hardware = intArrayOf(0x00, 0x42, 0x4C, 0x42, 0x5F, 0x30, 0x33, 0x00, 0x00)
        val serial = intArrayOf(
            0x00, 0x32, 0x48, 0x33, 0x42, 0x32, 0x34, 0x30, 0x35,
            0x30, 0x30, 0x33, 0x36, 0x35, 0x35, 0x00,
        )
        assertEquals("BLB_03", OuraDecoders.productInfoString(hardware))
        assertEquals("2H3B2405003655", OuraDecoders.productInfoString(serial))
        assertEquals(
            OuraRingGen.GEN3,
            OuraDecoders.productInfoString(hardware)?.let(OuraRingGen::fromHardwareId),
        )
        assertNull(OuraDecoders.productInfoString(serial)?.let(OuraRingGen::fromHardwareId))
        assertNull(OuraDecoders.productInfoString(intArrayOf(0x01, 0x42, 0x4C, 0x42, 0x5F, 0x30, 0x35)))
        assertNull(OuraDecoders.productInfoString(intArrayOf()))
        assertNull(OuraDecoders.productInfoString(intArrayOf(0x00, 0x00)))
    }
}
