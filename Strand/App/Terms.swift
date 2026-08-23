import Foundation

/// The Terms of Use the first-run gate presents. Bump `currentVersion` when the terms MATERIALLY
/// change (risk / liability / medical / affiliation wording) to re-prompt every user for a fresh
/// acknowledgment; leave it for typo fixes. Mirrored on Android by `Terms.CURRENT_VERSION`. The
/// full text lives in `TERMS.md`, shipped with NOOP.
enum Terms {
    static let currentVersion = "2.3"

    /// The load-bearing points the user must accept on first launch — the plain-English summary of
    /// `TERMS.md` §1–§6. Kept identical to the Android `Terms.points`. Each is (headline, body).
    /// Wrapped in `String(localized:)` (the `RhythmView.points` pattern) so the gate is localized
    /// like the rest of the app (PR #984); the English wording is the key, and the binding text
    /// stays `TERMS.md` — a translation here is a courtesy, not the agreement.
    static let points: [(String, String)] = [
        (String(localized: "appwide.terms.point.compatibility.head"),
         String(localized: "appwide.terms.point.compatibility.body")),
        (String(localized: "appwide.terms.point.ownership.head"),
         String(localized: "appwide.terms.point.ownership.body")),
        (String(localized: "appwide.terms.point.medical.head"),
         String(localized: "appwide.terms.point.medical.body")),
        (String(localized: "appwide.terms.point.early_access.head"),
         String(localized: "appwide.terms.point.early_access.body")),
    ]

    /// The affirmative attestations the user must EACH tick before Accept enables (clickwrap). They are
    /// kept as separate, conspicuous consents rather than one blanket box so each is a distinct, knowing
    /// acknowledgment. Mirrors the Android `Terms.attestations`; `TERMS.md` is the full text.
    /// NOTE: the exact legal phrasing here should be reviewed by a solicitor before this ships publicly.
    static let attestations: [String] = [
        String(localized: "appwide.terms.attest.band"),
        String(localized: "appwide.terms.attest.early_access"),
        String(localized: "appwide.terms.attest.full_terms"),
    ]
}
