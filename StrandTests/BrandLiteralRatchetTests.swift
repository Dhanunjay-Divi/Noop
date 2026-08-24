import XCTest

/// Guards the localization debt created by renaming the device to "Noop Band".
///
/// Background: the rename rewrote user-visible sentences that were already translated into eight locales.
/// Because the new sentences are not String Catalog keys, they render in ENGLISH for every non-English
/// locale, while the old translations sit orphaned in the catalog under the previous wording. The strict
/// audit (`Tools/i18n_audit.py --ci`) still passes only because those literals were added to
/// `Tools/i18n_audit_baseline.json`: the iOS baseline grew from 57 to 166 entries, 64 of them containing
/// "Noop Band". A baseline is a fair tool, but absorbing a regression makes it invisible.
///
/// This test turns that baseline into a RATCHET. It cannot be satisfied by adding more entries — only by
/// removing them. The worklist with the orphaned translations to reuse is
/// `docs/localization/BRAND-RENAME-WORKLIST.md`.
///
/// Why a ratchet instead of asserting zero: demanding zero today would leave the suite red for work that
/// needs a human translator (the old translations inflect the device as a common noun with articles and
/// cases — "des Bands", "du bracelet", "della fascia" — so the proper noun cannot be substituted
/// mechanically without producing broken grammar). A ratchet keeps the suite honest and green while making
/// the debt impossible to grow.
final class BrandLiteralRatchetTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The count measured when this ratchet was introduced (2026-08-23). LOWER THIS as strings are
    /// extracted; never raise it. Raising it means a user-visible English literal was shipped to eight
    /// locales and then hidden in the baseline.
    private static let allowedBrandLiteralsInBaseline = 64

    /// The brand name as users see it, kept in sync with `WhoopModel.customerName`.
    private static let brandName = "Noop Band"

    private func baseline() throws -> [String: [[String]]] {
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("Tools/i18n_audit_baseline.json")
        )
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var out: [String: [[String]]] = [:]
        for (platform, value) in raw {
            let rows = (value as? [[Any]]) ?? []
            out[platform] = rows.map { $0.compactMap { $0 as? String } }
        }
        return out
    }

    func testBrandInlineLiteralsInTheAuditBaselineOnlyEverShrink() throws {
        let baseline = try baseline()
        let brandRows = (baseline["ios"] ?? []).filter { row in
            row.contains { $0.contains(Self.brandName) }
        }

        XCTAssertLessThanOrEqual(
            brandRows.count,
            Self.allowedBrandLiteralsInBaseline,
            """
            The number of unlocalized literals containing "\(Self.brandName)" in the iOS audit baseline \
            went UP (now \(brandRows.count), allowed \(Self.allowedBrandLiteralsInBaseline)). Each one is a \
            user-visible string that renders in English in all eight non-English locales. Extract it into \
            Strand/Resources/Localizable.xcstrings instead of baselining it — preferably in placeholder \
            form, e.g. String(format: String(localized: "Connect %@ ..."), WhoopModel.customerName), so a \
            future rename cannot orphan the translations again. \
            See docs/localization/BRAND-RENAME-WORKLIST.md.
            """
        )

        if brandRows.count < Self.allowedBrandLiteralsInBaseline {
            // Not a failure: prompts whoever fixed strings to tighten the ratchet in the same commit.
            print("""
            NOTE: brand-inline baseline literals are down to \(brandRows.count) from \
            \(Self.allowedBrandLiteralsInBaseline). Lower allowedBrandLiteralsInBaseline to \
            \(brandRows.count) so the gain is locked in.
            """)
        }
    }

    /// The orphaned translations the worklist depends on must stay in the catalog until the strings are
    /// re-extracted; deleting them early would destroy reviewed translation work.
    func testOrphanedPreRenameTranslationsAreStillAvailableToReuse() throws {
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("Strand/Resources/Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        // A sample of pre-rename keys the worklist pairs against; each still carries eight translations.
        let sampleOrphans = [
            "Use strap alarm time",
            "Awaiting strap",
            "Connect your strap to see live heart rate",
        ]
        for key in sampleOrphans {
            let entry = strings[key] as? [String: Any]
            XCTAssertNotNil(
                entry,
                """
                Pre-rename key "\(key)" is gone from the catalog. It holds reviewed translations that \
                docs/localization/BRAND-RENAME-WORKLIST.md reuses for the renamed sentence. Re-extract the \
                renamed string FIRST, then delete the old key.
                """
            )
            if let localizations = entry?["localizations"] as? [String: Any] {
                XCTAssertGreaterThanOrEqual(
                    localizations.count, 8,
                    "\"\(key)\" should still carry its eight locales plus source."
                )
            }
        }
    }
}
