package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Strap-log PII redaction ([redactStrapLogPii]).
 *
 * Regression guard for #421/#453: a scrubber bug must never expose the complete address or throw
 * from the GATT callback path.
 */
class PiiRedactionTest {

    @Test fun removesCompleteMacAddress() {
        // The exact line that triggered #421 (a generic-HR strap's address being logged).
        val out = redactStrapLogPii("HR-strap: connecting to A1:B2:C3:D4:E5:F6")
        assertEquals("HR-strap: connecting to <address>", out)
    }

    @Test fun doesNotThrowOnAnyMac() {
        // The whole bug was a thrown exception, not a wrong string — assert it completes.
        for (mac in listOf("00:11:22:33:44:55", "AA:bb:CC:dd:EE:ff", "de:ad:be:ef:12:34")) {
            val out = redactStrapLogPii("connecting to $mac now")
            assertFalse("middle octets must be masked: $out", out.contains(mac))
        }
    }

    @Test fun masksWhoopSerial() {
        assertEquals("Discovered Band <serial> (rssi=<redacted>)",
            redactStrapLogPii("Discovered WHOOP 4C1594026 (rssi -63)"))
    }

    @Test fun leavesPlainTextAloneAndRedactsModelNumbers() {
        assertEquals(
            "Auto-reconnecting to your saved WHOOP <value>…",
            redactStrapLogPii("Auto-reconnecting to your saved WHOOP 4.0…"),
        )
        assertEquals("Backfill: session ended — reason=HISTORY_COMPLETE",
            redactStrapLogPii("Backfill: session ended — reason=HISTORY_COMPLETE"))
    }

    /**
     * Regression for #453: a WHOOP 5/MG reconnect logs a frame line containing a MAC; redaction must
     * mask it WITHOUT throwing. The $3 bug here crashed the whole app on every Bluetooth-on reconnect.
     */
    @Test fun frameLineWithMacIsRedactedNotCrashed() {
        val out = redactStrapLogPii("handleFrame from AA:BB:CC:DD:EE:FF — 24 bytes")
        assertEquals("handleFrame from <address> — <value> bytes", out)
    }

    @Test fun removesUuidSignalHealthTimestampAndRawFailureText() {
        val out = redactStrapLogPii(
            "device=A1B2C3D4-E5F6-7890-ABCD-EF0123456789 " +
                "rssi=-71 bpm=137 hrv=42 soc=88.5% at 1789831200 error: private detail",
        )
        assertFalse(out.contains("A1B2C3D4-E5F6-7890-ABCD-EF0123456789"))
        assertFalse(out.contains("-71"))
        assertFalse(out.contains("137"))
        assertFalse(out.contains("42"))
        assertFalse(out.contains("88.5"))
        assertFalse(out.contains("1789831200"))
        assertFalse(out.contains("private detail"))
        assertTrue(out.contains("<uuid>"))
        assertTrue(out.contains("rssi=<redacted>"))
        assertTrue(out.contains("bpm=<health>"))
        assertTrue(out.contains("error=<redacted>"))
    }

    @Test fun removesArbitraryDeviceNamesStatusAndUnlabelledRawFrames() {
        val out = redactStrapLogPii(
            "Discovered Bedroom Band " +
                "(A1B2C3D4-E5F6-7890-ABCD-EF0123456789) rssi=-57 status=133 " +
                "candidate raw (12 B): 00112233445566778899aabb",
        )
        assertFalse(out.contains("Bedroom Band"))
        assertFalse(out.contains("A1B2C3D4-E5F6-7890-ABCD-EF0123456789"))
        assertFalse(out.contains("-57"))
        assertFalse(out.contains("133"))
        assertFalse(out.contains("00112233445566778899aabb"))
        assertTrue(out.contains("Discovered <device>", ignoreCase = true))
        assertTrue(out.contains("rssi=<redacted>"))
        assertTrue(out.contains("status=<redacted>"))
        assertTrue(out.contains("<raw-bytes>"))

        val named = redactStrapLogPii(
            "advertising name=Bedroom Band; frame=00112233445566778899aabb",
        )
        assertFalse(named.contains("Bedroom Band"))
        assertFalse(named.contains("00112233445566778899aabb"))
        assertTrue(named.contains("name=<redacted>"))
        assertTrue(named.contains("frame=<redacted>"))
    }

    @Test fun taggedDeviceEvidenceIsReducedToBoundedCategoricalEvents() {
        val battery = "[battery] bank soc=80.0 t=1789831200s"
        val connection =
            "[connection] connect up gen=7 latencyMs=420 uptimeStart=1789831200"

        assertEquals("[battery] bank sample recorded", redactStrapLogPii(battery))
        assertEquals("[connection] connect up observed", redactStrapLogPii(connection))

        val untagged = redactStrapLogPii("bank soc=80.0 t=1789831200s")
        assertFalse(untagged.contains("80.0"))
        assertFalse(untagged.contains("1789831200"))
        val taggedLookalike = redactStrapLogPii(
            "[battery] bank soc=80.0 t=1789831200s owner=private",
        )
        assertFalse(taggedLookalike.contains("80.0"))
        assertFalse(taggedLookalike.contains("1789831200"))
    }

    @Test fun dayKeysAndDynamicSourceIdentifiersNeverEnterTheShareableLog() {
        val out = redactStrapLogPii(
            "[universal] dayOwner day=2026-09-20 readId=band-private " +
                "writeActiveId=account-private sourceId=source-private",
        )
        assertFalse(out.contains("2026-09-20"))
        assertFalse(out.contains("band-private"))
        assertFalse(out.contains("account-private"))
        assertFalse(out.contains("source-private"))
        assertTrue(out.contains("day=<redacted>"))
        assertTrue(out.contains("readId=<redacted>"))
        assertTrue(out.contains("writeActiveId=<redacted>"))
        assertTrue(out.contains("sourceId=<redacted>"))
    }

    @Test fun metricTracesAndExactClockTimesAreFailClosed() {
        val recovery = redactStrapLogPii(
            "charge baseline hrv mean=58.42 spread=7.91 nValid=14 score=83",
        )
        val steps = redactStrapLogPii(
            "stepsRaw day=2026-09-20 firstCounter=1234 lastCounter=2345 kept=17",
        )
        val moment = redactStrapLogPii("Moment marked @ 4:20 PM")

        for (forbidden in listOf("58.42", "7.91", "14", "83")) {
            assertFalse(recovery.contains(forbidden))
        }
        for (forbidden in listOf("2026-09-20", "1234", "2345", "17")) {
            assertFalse(steps.contains(forbidden))
        }
        assertFalse(moment.contains("4:20 PM"))
        assertTrue(recovery.contains("<value>"))
        assertTrue(moment.contains("<time>"))
    }

    @Test fun exportedLinesAreBoundedByUtf8BytesWithoutSplittingSurrogates() {
        val ascii = boundedStrapLogLine("x".repeat(20_000))
        assertTrue(ascii.endsWith(" [truncated]"))
        assertTrue(ascii.toByteArray(Charsets.UTF_8).size <= STRAP_LOG_MAX_LINE_BYTES)

        val unicode = boundedStrapLogLine("heart \uD83D\uDC9A".repeat(2_000))
        assertTrue(unicode.endsWith(" [truncated]"))
        assertTrue(unicode.toByteArray(Charsets.UTF_8).size <= STRAP_LOG_MAX_LINE_BYTES)
        assertFalse(unicode.dropLast(" [truncated]".length).last().isHighSurrogate())
    }

    /** Defense-in-depth (#453): redaction is TOTAL — it never throws, on any input, ever. */
    @Test fun neverThrowsOnAdversarialInput() {
        val nasty = listOf(
            "", "no pii here",
            "literal dollar \$3 and \${0} and \\1 in the text",
            "AA:BB:CC:DD:EE:FF WHOOP 4C1594026 mixed $ \\ ${'$'}{",
            "x".repeat(20000),
            "00:11:22:33:44:55 ".repeat(500),
        )
        for (s in nasty) {
            // The contract is "returns a String, never throws" — assert it completes for every input.
            val out = redactStrapLogPii(s)
            assertTrue("must return a value, got null", out.isNotEmpty() || s.isEmpty())
        }
    }
}
