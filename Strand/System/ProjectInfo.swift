import Foundation

/// Single source of truth for project identity and attribution. Deliberately
/// contains no author/AI identifiers so the public repo can stay anonymous.
enum ProjectInfo {
    static let appName = "NOOP"
    static let tagline = "Noop Band. Your data. Your machine. Local first; self-host when you choose."
    static let version = "0.1.0"
    /// Canonical support surface for questions, feedback, and bug reports.
    static let supportURL = "https://github.com/Dhanunjay-Divi/Noop/issues"

    /// Open-source reverse-engineering this is built on.
    static let attributions: [(repo: String, note: String)] = [
        ("johnmiddleton12/my-whoop", "WHOOP 4.0 BLE protocol"),
        ("b-nnett/goose", "WHOOP 5.0 BLE protocol"),
    ]
}
