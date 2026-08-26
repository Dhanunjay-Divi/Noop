import Foundation

/// Single source of truth for project identity and attribution. Deliberately
/// contains no author/AI identifiers so the public repo can stay anonymous.
enum ProjectInfo {
    static let appName = "NOOP"
    static let tagline = "Noop Band. Your data. Your machine. Local first; self-host when you choose."
    static let version = "0.1.0"

    /// Public App Store-facing documents. These must stay reachable without a repository account,
    /// preview credential, or access to the private source project.
    static let privacyPolicyURL = URL(
        string: "https://noop-private-trial.usetaptech.chatgpt.site/privacy"
    )!
    static let supportURL = URL(
        string: "https://noop-private-trial.usetaptech.chatgpt.site/support"
    )!

}
