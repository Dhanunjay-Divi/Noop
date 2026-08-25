import Foundation

/// Removes transport-vendor wording from dynamic text before it reaches customer UI.
///
/// Protocol identifiers, persisted source IDs, and provenance records stay unchanged. This is for
/// strings such as historical release notes and diagnostic lines that cannot use String Catalog
/// overrides because they are rendered from runtime `String` values.
enum CustomerFacingBrand {
    private static let replacements: [(pattern: String, replacement: String)] = [
        (#"(?i)\bmy-whoop-noop\b"#, "primary-band-on-device"),
        (#"(?i)\bmy-whoop\b"#, "primary-band"),
        (#"(?i)\bopenwhoop\b"#, "NOOP legacy storage"),
        (#"(?i)\bwhoopstore\b"#, "local store"),
        (#"(?i)\bwhoopimporter\b"#, "wearable importer"),
        (#"(?i)\bwhoop_live_hr_in_adv_ind_pkt\b"#, "band broadcast setting"),
        (#"(?i)\bwhoop[- ]compatible\b"#, "wearable-compatible"),
        (#"(?i)\bwhoop(?=\d\w*[-_])"#, "band-"),
        (#"(?i)\bwhoop\s*5(?:\.0)?(?:\s*/?\s*mg)?\b"#, "newer band"),
        (#"(?i)\bwhoop\s*4(?:\.0)?\b"#, "legacy band"),
        (#"(?i)\bwhoop\s+mg\b"#, "ECG-capable band"),
        (#"(?i)\bwhoop\s+exports\b"#, "wearable exports"),
        (#"(?i)\bwhoop\s+export\b"#, "wearable export"),
        (#"(?i)\bwhoop\s+imports\b"#, "wearable imports"),
        (#"(?i)\bwhoop\s+import\b"#, "wearable import"),
        (#"(?i)\bwhoop[-_ ]csv\b"#, "wearable-csv"),
        (#"(?i)\bwhoop\s+app\b"#, "band app"),
        (#"(?i)\bwhoop-style\b"#, "wearable-style"),
        (#"(?i)\bwhoop(?:'s|’s)\b"#, "the provider's"),
        (#"(?i)\bwhoop(?=\d)"#, "band-"),
        (#"(?i)whoop"#, "compatible band"),
    ]

    static func text(_ raw: String) -> String {
        replacements.reduce(raw) { value, item in
            value.replacingOccurrences(
                of: item.pattern,
                with: item.replacement,
                options: .regularExpression
            )
        }
    }
}
