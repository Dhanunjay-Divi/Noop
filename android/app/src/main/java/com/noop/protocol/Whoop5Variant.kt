package com.noop.protocol

/**
 * Whoop5Variant — WHOOP MG vs plain WHOOP 5.0 hardware discrimination (#520).
 *
 * DELIBERATELY ORTHOGONAL to [DeviceFamily]. `DeviceFamily.WHOOP5` describes the WIRE PROTOCOL
 * (CRC16-Modbus header, puffin packet types) and MG and 5.0 are byte-identical there — every
 * framing/interpreter branch must keep treating them as one family. This type describes the
 * HARDWARE instead: an MG carries the ECG-conductive clasp, a 5.0 does not. Keeping the two apart
 * means a capability gate (ECG, and later BP) can never accidentally change how a frame is parsed.
 *
 * Pure: no Android, no I/O. Faithful twin of WhoopProtocol/Whoop5Variant.swift — keep them
 * byte-identical (same resolution order, same unknown-over-guess rule).
 *
 * Provenance: these serial prefixes and hardware-revision tokens are protocol facts read from the
 * standard BLE Device Information Service. `MGB` + `WS50_r03` are additionally attested by the user's
 * physical WHOOP Life/MG; independent community hardware mapping identifies WS50 as MG and WG50 as 5.0.
 */
enum class Whoop5Variant(val label: String) {
    /** WHOOP MG — has the ECG-conductive clasp. */
    MG("MG"),
    /** WHOOP 5.0 — no ECG electrodes. */
    FIVE_ZERO("5.0"),
    /** Not identified yet, contradictory evidence, or a non-WHOOP strap. NEVER a guess. */
    UNKNOWN("—");

    /** True only for a POSITIVELY identified MG, so an MG-only feature stays gated off otherwise. */
    val isMG: Boolean get() = this == MG

    companion object {
        /** Current serial prefix attesting an MG (BLE DIS Serial Number String, 0x2A25). */
        const val MG_SERIAL_PREFIX = "MGB"
        /** Legacy MG serial prefix retained for already-shipped hardware. */
        const val LEGACY_MG_SERIAL_PREFIX = "5AM"
        /** Serial prefix attesting a plain 5.0. */
        const val FIVE_ZERO_SERIAL_PREFIX = "5AG"
        /** MG Hardware Revision String token (0x2A27), e.g. `WS50_r03`. */
        const val MG_HARDWARE_ID_TOKEN = "WS50"
        /** Plain 5.0 Hardware Revision String token, e.g. `WG50_r52`. */
        const val FIVE_ZERO_HARDWARE_ID_TOKEN = "WG50"

        /**
         * Resolve the variant from the strap's Device Information Service strings.
         *
         * [serial] is the DIS Serial Number String (0x2A25) or the advertised name (a leading
         * "WHOOP " is tolerated). [hardwareRevision] is the DIS Hardware Revision String (0x2A27).
         *
         * Serial and hardware evidence are resolved independently. If both are known and disagree (or
         * one hardware string contains both known tokens), the answer is [UNKNOWN]. Otherwise either
         * positive signal may identify the variant. Anything unrecognised fails closed; a stray digit or
         * product name is never treated as evidence (#772).
         */
        fun from(serial: String?, hardwareRevision: String? = null): Whoop5Variant {
            var s = normalize(serial)
            if (s.startsWith("WHOOP")) s = s.removePrefix("WHOOP")
            val hw = normalize(hardwareRevision)

            val serialVariant = when {
                s.startsWith(MG_SERIAL_PREFIX) || s.startsWith(LEGACY_MG_SERIAL_PREFIX) -> MG
                s.startsWith(FIVE_ZERO_SERIAL_PREFIX) -> FIVE_ZERO
                else -> null
            }

            val hardwareSaysMg = hw.contains(MG_HARDWARE_ID_TOKEN)
            val hardwareSaysFiveZero = hw.contains(FIVE_ZERO_HARDWARE_ID_TOKEN)
            if (hardwareSaysMg && hardwareSaysFiveZero) return UNKNOWN
            val hardwareVariant = when {
                hardwareSaysMg -> MG
                hardwareSaysFiveZero -> FIVE_ZERO
                else -> null
            }

            if (serialVariant != null && hardwareVariant != null && serialVariant != hardwareVariant) {
                return UNKNOWN
            }
            return hardwareVariant ?: serialVariant ?: UNKNOWN
        }

        /** Case- and whitespace-insensitive evidence comparison; no punctuation/digit guessing. */
        private fun normalize(value: String?): String = (value ?: "")
            .uppercase()
            .filterNot { it.isWhitespace() }
    }
}
