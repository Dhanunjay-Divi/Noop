package com.noop.protocol

/**
 * On-wire enums for the WHOOP protocol. Each constant carries its raw (on-wire) Int value and
 * every enum offers a `fromRaw(Int)` companion lookup that returns null for unknown codes.
 *
 * Values mirror the canonical schema (whoop_protocol.json) and the project SHARED CONTRACT.
 * These are deliberately a curated subset of the full device enum tables — only the codes the
 * offline companion app reads or sends. Unknown codes are surfaced by name elsewhere (see
 * [Framing.enumLabel]); they are not added here so the enums stay small and intentional.
 */

/** Frame packet type (envelope byte at offset 4 for Whoop 4.0). */
enum class PacketType(val rawValue: Int) {
    COMMAND(35),
    COMMAND_RESPONSE(36),
    PUFFIN_COMMAND(37),
    PUFFIN_COMMAND_RESPONSE(38),
    REALTIME_DATA(40),
    REALTIME_RAW_DATA(43),
    HISTORICAL_DATA(47),
    EVENT(48),
    METADATA(49),
    CONSOLE_LOGS(50),
    REALTIME_IMU_DATA_STREAM(51),
    HISTORICAL_IMU_DATA_STREAM(52);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): PacketType? = byRaw[raw]
    }
}

/** METADATA frame sub-type (historical-offload state machine). */
enum class MetadataType(val rawValue: Int) {
    HISTORY_START(1),
    HISTORY_END(2),
    HISTORY_COMPLETE(3);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): MetadataType? = byRaw[raw]
    }
}

/** EVENT frame event code (offset 6 in an EVENT frame). */
enum class EventNumber(val rawValue: Int) {
    BATTERY_LEVEL(3),
    CHARGING_ON(7),
    CHARGING_OFF(8),
    WRIST_ON(9),
    WRIST_OFF(10),
    DOUBLE_TAP(14),
    TEMPERATURE_LEVEL(17),
    BLE_BONDED(23),
    BLE_REALTIME_HR_ON(33),
    BLE_REALTIME_HR_OFF(34),
    STRAP_DRIVEN_ALARM_EXECUTED(57),
    APP_DRIVEN_ALARM_EXECUTED(58),
    HAPTICS_FIRED(60),
    HIGH_FREQ_SYNC_PROMPT(96),
    HIGH_FREQ_SYNC_ENABLED(97),
    HIGH_FREQ_SYNC_DISABLED(98);

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): EventNumber? = byRaw[raw]
    }
}

/**
 * Curated, SAFE command codes for *sending* to the strap. Destructive commands
 * (reboot / firmware load / force-trim / ship-mode / power-cycle / fuel-gauge reset / BLE DFU)
 * are deliberately excluded so the in-app sender can never brick or wipe the device.
 */
enum class CommandNumber(val rawValue: Int) {
    TOGGLE_REALTIME_HR(3),
    // REPORT_VERSION_INFO (7): WHOOP 4.0 firmware/version read. The strap answers with the bundled
    // component versions (`fw_harvard` a.b.c.d, `fw_boylston` a.b.c.d). A documented READ command,
    // separate from the firmware-LOAD opcodes. Mirrors Swift `WhoopCommand.reportVersionInfo`.
    REPORT_VERSION_INFO(7),
    SET_CLOCK(10),
    GET_CLOCK(11),
    SEND_HISTORICAL_DATA(22),
    // The historical-offload trim/ack command. Sent (with response) to confirm one HISTORY_END
    // chunk so the strap may trim it; payload = [0x01] + the verbatim 8-byte HISTORY_END end_data.
    // Port of Swift `WhoopCommand.historicalDataResult` (whoop_protocol.json: 23 HISTORICAL_DATA_RESULT).
    HISTORICAL_DATA_RESULT(23),
    GET_BATTERY_LEVEL(26),
    // REBOOT_STRAP (29) — restart the strap. Empty body (the official app's builder passes a null
    // payload). The strap drops the link and re-advertises after boot; stored data is KEPT
    // (non-destructive), though an in-flight offload is interrupted (chunk-acked, so nothing is lost).
    // Opcode 29 is shared across WHOOP 4.0 (harvard/crc8) and 5/MG (puffin/crc16). The 5.0 form is
    // hardware-confirmed (fw 50.40.1.0, #227); the 4.0 form is NOT — a real 4.0 silently IGNORES this
    // empty-body frame (#235: no reboot, no disconnect, no COMMAND_RESPONSE), so the correct 4.0 frame
    // still needs an HCI capture. rebootStrap() logs the COMMAND_RESPONSE + a no-disconnect watchdog so a
    // strap log shows which case it hit. User-initiated + confirmation-gated only; never automatic.
    // Port of Swift WhoopCommand.rebootStrap.
    REBOOT_STRAP(29),
    // POWER_CYCLE_STRAP (32) — a harder restart than REBOOT_STRAP (a full power cycle of the strap SoC
    // vs a warm reboot). Non-destructive: stored data lives in flash and survives, the strap re-advertises
    // after boot. Included ONLY as a gated candidate for the WHOOP 4.0 reboot probe (#235: a real 4.0
    // silently ignores opcode 29/empty, and the correct 4.0 reboot frame is unknown). NOT hardware-confirmed
    // on any family. Sent only via rebootProbe(POWER_CYCLE_32_EMPTY), itself gated behind Test Centre →
    // Connection + a confirmation. Never sent automatically. Port of Swift WhoopCommand.powerCycleStrap.
    POWER_CYCLE_STRAP(32),
    GET_DATA_RANGE(34),
    GET_HELLO_HARVARD(35),
    // GET_HELLO (145): WHOOP 5.0/MG hello. The response carries the device name plus `fw_version`
    // a.b.c.d. Older 4.0 firmware replies "unsupported" (0a03) and is ignored. Mirrors Swift
    // `WhoopCommand.getHello`.
    GET_HELLO(145),
    SEND_R10_R11_REALTIME(63),
    // WHOOP 5.0/MG (device family GOOSE/MAVERICK) one-shot buzz. Gen-4 straps use the legacy
    // RUN_HAPTICS_PATTERN(79) below; a 5/MG strap only honors this command.
    RUN_HAPTIC_PATTERN_MAVERICK(19),
    SET_ALARM_TIME(66),
    GET_ALARM_TIME(67),
    RUN_ALARM(68),
    DISABLE_ALARM(69),
    // SET_ADVERTISING_NAME_HARVARD (77) — rename the WHOOP 4.0's BLE advertising name on the strap
    // firmware (the name the OS shows in Bluetooth). Payload: [0x00,0x00] + UTF-8 name + [0x00]; the
    // strap reboots to apply. WHOOP 4.0 only (a 5/MG uses puffin framing + a different config path).
    // Port of Swift WhoopCommand.setAdvertisingNameHarvard.
    SET_ADVERTISING_NAME(77),
    RUN_HAPTICS_PATTERN(79),
    GET_ALL_HAPTICS_PATTERN(80),
    // SET_CONFIG / SET_FF_VALUE (0x78) - write one persistent feature flag. The 5/MG "enable R22
    // packets" sequence (Whoop5Config) sends 15 of these to switch on the deep biometric streams.
    // Reversible; gated behind the deep-data opt-in; iOS/Android only. (#174)
    SET_CONFIG(120),
    // SET_DEVICE_CONFIG (0x77) — write one persistent DEVICE-config value (distinct from the
    // feature-flag SET_CONFIG/0x78). Used for the "Broadcast HR" flag whoop_live_hr_in_adv_ind_pkt,
    // which makes the strap advertise its HR as a standard 0x180D BLE sensor. Validated on real
    // hardware (paired on a Garmin Edge 840). Reversible; gated behind the broadcast-HR opt-in. (#181)
    SET_DEVICE_CONFIG(119),
    START_RAW_DATA(81),
    STOP_RAW_DATA(82),
    // GET_EXTENDED_BATTERY_INFO (98) — read-only extended battery read (mV etc.). The NUMBER is disputed
    // (#592): an independent APK decompile reads this family 11 lower (87), while whoomp's table says 98 —
    // partially supported by a real WHOOP 5 (fw 50.38.1.0) ANSWERING 98, though with a short stub that
    // could be valid-but-minimal or a generic unknown-command ack. Sent ONLY by probeExtendedBatteryInfo()
    // (user-initiated, Test Centre → Connection gated, never automatic); the raw COMMAND_RESPONSE is
    // dumped in full to the strap log so a normal export settles which number this firmware serves.
    // Mirrors Swift WhoopCommand.getExtendedBatteryInfo.
    GET_EXTENDED_BATTERY_INFO(98),
    // #690: read-only body-location/status probe. Documented in the WHOOP protocol; driven only by the
    // user-triggered, Test-Centre-gated probeBodyLocationAndStatus(). Decoded to a diagnostic report only.
    GET_BODY_LOCATION_AND_STATUS(84),
    STOP_HAPTICS(122),
    // SELECT_WRIST (123 / 0x7B) is left exactly where it already was. It has been in this enum since the
    // initial commit, predates any ECG work here, and is referenced by no Kotlin caller. This branch does
    // not add it and deliberately does not remove it either: dropping a pre-existing entry would change
    // the curated send surface for a reason that has nothing to do with decoding ECG packets, and that is
    // a separate decision from the one below.
    SELECT_WRIST(123);
    //
    // The three WHOOP MG ECG ("Labrador") TOGGLES (124 / 125 / 139) are deliberately ABSENT from this
    // enum. This branch originally listed them here so a COMMAND_RESPONSE for one would be labelled
    // rather than shown as a bare hex opcode — a reason #893 has since made obsolete, by giving Android
    // a read-only `CommandNames` label table that names every opcode the schema names without making any
    // of them constructible. Android has no ECG app layer and sends none of them, so growing the
    // SENDER enum to buy a label would widen what the command sender can express for nothing. Apple's
    // `WhoopCommand` carries them because Apple actually drives the gated probe. See
    // `com.noop.protocol.Whoop5Ecg` for the decoder and `Whoop5EcgProbe` for the verdict rules.

    companion object {
        private val byRaw = entries.associateBy { it.rawValue }
        fun fromRaw(raw: Int): CommandNumber? = byRaw[raw]
    }
}

/**
 * Decode-only command names from the canonical protocol schema. This map is deliberately separate
 * from [CommandNumber]: naming an inbound opcode must never make a destructive command sendable.
 */
object CommandNames {
    val byRaw: Map<Int, String> = mapOf(
        1 to "LINK_VALID", 2 to "GET_MAX_PROTOCOL_VERSION", 3 to "TOGGLE_REALTIME_HR",
        7 to "REPORT_VERSION_INFO", 10 to "SET_CLOCK", 11 to "GET_CLOCK",
        14 to "TOGGLE_GENERIC_HR_PROFILE", 16 to "TOGGLE_R7_DATA_COLLECTION",
        19 to "RUN_HAPTIC_PATTERN_MAVERICK", 20 to "ABORT_HISTORICAL_TRANSMITS",
        22 to "SEND_HISTORICAL_DATA", 23 to "HISTORICAL_DATA_RESULT", 25 to "FORCE_TRIM",
        26 to "GET_BATTERY_LEVEL", 29 to "REBOOT_STRAP", 32 to "POWER_CYCLE_STRAP",
        33 to "SET_READ_POINTER", 34 to "GET_DATA_RANGE", 35 to "GET_HELLO_HARVARD",
        36 to "START_FIRMWARE_LOAD", 37 to "LOAD_FIRMWARE_DATA", 38 to "PROCESS_FIRMWARE_IMAGE",
        39 to "SET_LED_DRIVE", 40 to "GET_LED_DRIVE", 41 to "SET_TIA_GAIN",
        42 to "GET_TIA_GAIN", 43 to "SET_BIAS_OFFSET", 44 to "GET_BIAS_OFFSET",
        45 to "ENTER_BLE_DFU", 48 to "SEND_EVENT_PACKETS", 52 to "SET_DP_TYPE",
        53 to "FORCE_DP_TYPE", 61 to "SET_AFE_PARAMETERS", 62 to "GET_AFE_PARAMETERS",
        63 to "SEND_R10_R11_REALTIME", 66 to "SET_ALARM_TIME", 67 to "GET_ALARM_TIME",
        68 to "RUN_ALARM", 69 to "DISABLE_ALARM", 76 to "GET_ADVERTISING_NAME_HARVARD",
        77 to "SET_ADVERTISING_NAME_HARVARD", 79 to "RUN_HAPTICS_PATTERN",
        80 to "GET_ALL_HAPTICS_PATTERN", 81 to "START_RAW_DATA", 82 to "STOP_RAW_DATA",
        83 to "VERIFY_FIRMWARE_IMAGE", 84 to "GET_BODY_LOCATION_AND_STATUS",
        96 to "ENTER_HIGH_FREQ_SYNC", 97 to "EXIT_HIGH_FREQ_SYNC",
        98 to "GET_EXTENDED_BATTERY_INFO", 99 to "RESET_FUEL_GAUGE",
        100 to "CALIBRATE_CAPSENSE", 105 to "TOGGLE_IMU_MODE_HISTORICAL",
        106 to "TOGGLE_IMU_MODE", 107 to "ENABLE_OPTICAL_DATA", 108 to "TOGGLE_OPTICAL_MODE",
        115 to "START_DEVICE_CONFIG_KEY_EXCHANGE", 116 to "SEND_NEXT_DEVICE_CONFIG",
        117 to "START_FF_KEY_EXCHANGE", 118 to "SEND_NEXT_FF",
        119 to "SET_DEVICE_CONFIG_VALUE", 120 to "SET_FF_VALUE",
        121 to "GET_DEVICE_CONFIG_VALUE", 122 to "STOP_HAPTICS", 123 to "SELECT_WRIST",
        124 to "TOGGLE_LABRADOR_DATA_GENERATION", 125 to "TOGGLE_LABRADOR_RAW_SAVE",
        128 to "GET_FF_VALUE", 131 to "SET_RESEARCH_PACKET", 132 to "GET_RESEARCH_PACKET",
        139 to "TOGGLE_LABRADOR_FILTERED", 140 to "SET_ADVERTISING_NAME",
        141 to "GET_ADVERTISING_NAME", 142 to "START_FIRMWARE_LOAD_NEW",
        143 to "LOAD_FIRMWARE_DATA_NEW", 144 to "PROCESS_FIRMWARE_IMAGE_NEW",
        145 to "GET_HELLO", 151 to "GET_BATTERY_PACK_INFO",
        153 to "TOGGLE_PERSISTENT_R20", 154 to "TOGGLE_PERSISTENT_R21",
    )

    fun label(v: Int): String = byRaw[v]?.let { "$it($v)" } ?: "0x%02X(%d)".format(v, v)
}

/**
 * Candidate reboot frames for the WHOOP 4.0 reboot probe (Test Centre → Connection, WHOOP 4.0 only).
 *
 * A real WHOOP 4.0 silently ignores NOOP's production reboot frame (opcode 29 REBOOT_STRAP, empty body
 * — #235: no reboot, no disconnect, no COMMAND_RESPONSE), and the correct 4.0 frame is unknown. These
 * are the plausible NON-DESTRUCTIVE candidates — a restart / power-cycle only, never a data-wiping
 * opcode — tried one at a time on real hardware so the strap log tells which one works: `reboot: link
 * dropped …` = the strap acted; `reboot: no disconnect within 12s …` = ignored.
 *
 * The definitive fix is still an HCI capture of the official app rebooting a 4.0 (exactly how the alarm
 * frame was pinned — @ujix's capture, #535). This probe is the interim way to find the frame when a 4.0
 * is in hand. Twin of Swift `RebootProbeVariant` (Commands.swift); the [logTag] strings are byte-identical
 * across platforms so a strap log reads the same either side.
 */
enum class RebootProbeVariant(
    val command: CommandNumber,
    val payload: ByteArray,
    /** Short menu label, e.g. "A · REBOOT_STRAP(29) empty". */
    val menuLabel: String,
    /** Tag written to the strap log so each attempt is correlatable (byte-identical to Swift). */
    val logTag: String,
) {
    // A — opcode 29 REBOOT_STRAP, empty body: NOOP's current production frame (ignored on 4.0).
    REBOOT_29_EMPTY(CommandNumber.REBOOT_STRAP, byteArrayOf(),
        "A · REBOOT_STRAP(29) empty", "A/reboot29-empty"),
    // B — opcode 32 POWER_CYCLE_STRAP, empty body: a harder restart, never tried.
    POWER_CYCLE_32_EMPTY(CommandNumber.POWER_CYCLE_STRAP, byteArrayOf(),
        "B · POWER_CYCLE(32) empty", "B/powercycle32-empty"),
    // C — opcode 29 REBOOT_STRAP, payload [0x01]: same opcode with a non-empty sub-command byte.
    // On a real 4.0 this DROPPED THE LINK but did NOT power-cycle (sensor stayed on) — a BLE
    // disconnect, not a reboot (#275). So the sub-command byte reaches the strap; the next two try it
    // on the harder power-cycle opcode and a different byte on reboot.
    REBOOT_29_PAYLOAD1(CommandNumber.REBOOT_STRAP, byteArrayOf(0x01),
        "C · REBOOT_STRAP(29) payload=01", "C/reboot29-payload01"),
    // D - opcode 32 POWER_CYCLE_STRAP, payload [0x01]: the "harder restart" opcode with the sub-command
    // byte that made 29 react (#275). Best remaining safe candidate for a genuine power-cycle.
    POWER_CYCLE_32_PAYLOAD1(CommandNumber.POWER_CYCLE_STRAP, byteArrayOf(0x01),
        "D · POWER_CYCLE(32) payload=01", "D/powercycle32-payload01"),
    // E — opcode 29 REBOOT_STRAP, payload [0x00]: the zero-byte sub-command (vs empty vs 0x01).
    REBOOT_29_PAYLOAD0(CommandNumber.REBOOT_STRAP, byteArrayOf(0x00),
        "E · REBOOT_STRAP(29) payload=00", "E/reboot29-payload00"),
}
