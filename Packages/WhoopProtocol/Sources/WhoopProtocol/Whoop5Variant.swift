import Foundation

// Whoop5Variant.swift — WHOOP MG vs plain WHOOP 5.0 hardware discrimination (#520).
//
// DELIBERATELY ORTHOGONAL to `DeviceFamily`. `DeviceFamily.whoop5` describes the WIRE PROTOCOL
// (CRC16-Modbus header, puffin packet types) and MG and 5.0 are byte-identical there — every
// framing/interpreter switch must keep treating them as one family. This type describes the
// HARDWARE instead: an MG carries the ECG-conductive clasp, a 5.0 does not. Keeping the two apart
// means a capability gate (ECG, and later BP) can never accidentally change how a frame is parsed.
//
// Pure: no CoreBluetooth, no I/O. The app layer supplies the two strings (see below) and this
// decides. The Kotlin twin is com.noop.protocol.Whoop5Variant — keep them byte-identical.
//
// Provenance: these prefixes are protocol facts read from the standard BLE Device Information
// Service, not copied implementation code. WG50/WS50 are independently corroborated by measured
// straps in the public whoop-rs variant table discussed in #520. MGB/WS50_r03 were then observed
// together on real WHOOP Life/MG hardware during NOOP's August 2026 device validation.

/// Which WHOOP 5-generation hardware a connection is talking to.
///
/// `DeviceFamily.whoop5` still governs all framing/decode; this only gates hardware capability.
public enum Whoop5Variant: String, Sendable, CaseIterable {
    /// WHOOP MG — has the ECG-conductive clasp.
    case mg
    /// WHOOP 5.0 — no ECG electrodes.
    case fiveZero
    /// Not identified yet, contradictory evidence, or a non-WHOOP strap. NEVER a guess.
    case unknown

    /// Short display label ("MG" / "5.0" / "—"). UI strings live in the app layer's catalogs;
    /// this is the bare token for logs + diagnostics.
    public var label: String {
        switch self {
        case .mg: return "MG"
        case .fiveZero: return "5.0"
        case .unknown: return "—"
        }
    }

    /// Exact registry/display label when Device Information Service positively attests the variant.
    /// Unknown or contradictory evidence has no label and therefore can never overwrite a known model.
    public var registryModelLabel: String? {
        switch self {
        case .mg: return "WHOOP MG"
        case .fiveZero: return "WHOOP 5.0"
        case .unknown: return nil
        }
    }

    /// True only when the strap is a POSITIVELY identified MG. `.unknown` is not MG, so an
    /// MG-only feature stays gated off until the hardware actually attests to it.
    public var isMG: Bool { self == .mg }

    /// Observed serial prefixes that attest an MG (BLE DIS Serial Number String, `0x2A25`).
    static let mgSerialPrefixes = ["MGB", "5AM"]
    /// Observed serial prefix that attests a plain 5.0.
    static let fiveZeroSerialPrefixes = ["5AG"]
    /// Observed board-family tokens in Hardware Revision String (`0x2A27`). Suffixes such as `_r03`
    /// are board revisions; only the leading token identifies the 5.0 vs MG hardware variant.
    static let mgHardwareIDToken = "WS50"
    static let fiveZeroHardwareIDToken = "WG50"

    /// Resolve the variant from the strap's Device Information Service strings.
    ///
    /// - Parameters:
    ///   - serial: DIS Serial Number String (`0x2A25`), or the advertised name — a leading
    ///     "WHOOP " is tolerated so a caller can pass either.
    ///   - hardwareRevision: DIS Hardware Revision String (`0x2A27`), when it has been read.
    ///
    /// Resolution order, and why:
    ///  1. Resolve each independent signal only from an observed prefix.
    ///  2. If two known signals CONTRADICT, return `.unknown`; never pick a convenient winner.
    ///  3. Otherwise prefer the hardware revision, then the serial prefix.
    ///  4. Anything else → `.unknown`. Never infer from a digit elsewhere in the name (#772).
    public static func from(serial: String?, hardwareRevision: String? = nil) -> Whoop5Variant {
        let normalize: (String?) -> String = { value in
            (value ?? "").uppercased().filter { !$0.isWhitespace }
        }
        let hw = normalize(hardwareRevision)
        var s = normalize(serial)
        if s.hasPrefix("WHOOP") { s = String(s.dropFirst("WHOOP".count)) }

        let hardwareSaysMG = hw.contains(mgHardwareIDToken)
        let hardwareSaysFiveZero = hw.contains(fiveZeroHardwareIDToken)
        if hardwareSaysMG && hardwareSaysFiveZero { return .unknown }
        let hardwareVariant: Whoop5Variant? = if hardwareSaysMG {
            .mg
        } else if hardwareSaysFiveZero {
            .fiveZero
        } else {
            nil
        }
        let serialVariant: Whoop5Variant? = if mgSerialPrefixes.contains(where: s.hasPrefix) {
            .mg
        } else if fiveZeroSerialPrefixes.contains(where: s.hasPrefix) {
            .fiveZero
        } else {
            nil
        }

        if let hardwareVariant, let serialVariant, hardwareVariant != serialVariant {
            return .unknown
        }
        return hardwareVariant ?? serialVariant ?? .unknown
    }
}
