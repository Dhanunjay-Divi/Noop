package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors WhoopProtocolTests/Whoop5VariantTests.swift — same fixtures, same expected outputs, so the
 * twin resolvers cannot drift.
 */
class Whoop5VariantTest {

    @Test fun currentAndLegacySerialPrefixesIdentifyMg() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("MGB12345678"))
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("5AM12345678"))
        assertTrue(Whoop5Variant.from("MGB12345678").isMG)
    }

    @Test fun serialPrefixIdentifiesFiveZero() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678"))
        assertFalse(Whoop5Variant.from("5AG12345678").isMG)
    }

    @Test fun hardwareRevisionIsDeviceAttestedFiveZero() {
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from(null, "WG50_r52"))
    }

    @Test fun realLifeMgHardwareRevisionIdentifiesMg() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from(null, "WS50_r03"))
        assertTrue(Whoop5Variant.from("MGB12345678", "WS50_r03").isMG)
    }

    @Test fun advertisedNamePrefixTolerated() {
        // Callers may pass the advertised name instead of the DIS serial.
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("WHOOP MGB12345678"))
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("  whoop 5ag12345678  "))
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("  whoop   mgb12345678 ", " ws50_r03 "))
    }

    @Test fun contradictionYieldsUnknownRatherThanAGuess() {
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("MGB12345678", "WG50_r52"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5AM12345678", "WG50_r52"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5AG12345678", "WS50_r03"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null, "WS50_WG50_r03"))
    }

    @Test fun agreeingSignalsResolve() {
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("MGB12345678", "WS50_r03"))
        assertEquals(Whoop5Variant.MG, Whoop5Variant.from("5AM12345678", "WS50_r03"))
        assertEquals(Whoop5Variant.FIVE_ZERO, Whoop5Variant.from("5AG12345678", "WG50_r52"))
    }

    @Test fun unattestedInputsAreUnknownNeverInferred() {
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(""))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("WHOOP"))
        // A stray digit in the name must NOT imply a generation (#772 — the bug that read a
        // serial's "5" as Gen5 on a Gen3 ring; same failure mode, different product).
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("WHOOP 4.0"))
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from("5XX99999999"))
        // Similar-looking but unattested tokens remain unknown.
        assertEquals(Whoop5Variant.UNKNOWN, Whoop5Variant.from(null, "WGMG_r01"))
    }

    @Test fun labels() {
        assertEquals("MG", Whoop5Variant.MG.label)
        assertEquals("5.0", Whoop5Variant.FIVE_ZERO.label)
        assertEquals("-", Whoop5Variant.UNKNOWN.label)
    }
}
