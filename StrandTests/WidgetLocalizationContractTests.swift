import XCTest

final class WidgetLocalizationContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func catalogStrings() throws -> [String: Any] {
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "StrandiOSWidgets/Localizable.xcstrings"
            )
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertEqual(catalog["version"] as? String, "1.0")
        return try XCTUnwrap(catalog["strings"] as? [String: Any])
    }

    private func placeholders(in value: String) -> [String] {
        let expression = try! NSRegularExpression(
            pattern: #"%[0-9]*\$?(?:@|lld|ld|d|f)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
                .replacingOccurrences(
                    of: #"%[0-9]*\$"#,
                    with: "%",
                    options: .regularExpression
                )
        }.sorted()
    }

    func testWidgetTargetOwnsItsCatalogAndExtractionSetting() throws {
        let project = try text("project.yml")
        let targetStart = try XCTUnwrap(project.range(of: "\n  NOOPiOSWidgets:\n"))
        let followingTarget = try XCTUnwrap(
            project.range(
                of: "\n  NOOPWatch:\n",
                range: targetStart.upperBound..<project.endIndex
            )
        )
        let block = String(project[targetStart.lowerBound..<followingTarget.lowerBound])

        XCTAssertTrue(block.contains("- path: StrandiOSWidgets"))
        XCTAssertFalse(block.contains("Strand/Resources/Localizable.xcstrings"))
        XCTAssertTrue(project.contains("SWIFT_EMIT_LOC_STRINGS: YES"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repoRoot
                    .appendingPathComponent("StrandiOSWidgets/Localizable.xcstrings")
                    .path
            )
        )
    }

    func testWidgetCatalogCoversCompilerExtractedContract() throws {
        let strings = try catalogStrings()
        let requiredKeys: Set<String> = [
            "%@ bpm",
            "%lld out of 100",
            "%lld%%",
            "Battery",
            "Building your baseline",
            "Calibrating",
            "Capacity looks strong",
            "Connected",
            "Daily Signal",
            "Device",
            "Device battery",
            "Duration",
            "Effort",
            "HR",
            "HR %@ · HRV %@ · RHR %@",
            "HR now",
            "HRV",
            "HRV %@",
            "Heart rate",
            "Keep today balanced",
            "Last heart rate",
            "Last reading",
            "Live",
            "Live heart rate",
            "Live now",
            "Live or last heart rate, HRV, resting heart rate, connection, and wearable battery.",
            "Local data",
            "Locked",
            "NOOP Daily Signal",
            "NOOP Sleep",
            "NOOP Vitals",
            "NOOP · Open for your Daily Signal",
            "No HR sample",
            "No data",
            "No device",
            "Not paired",
            "Open NOOP",
            "Open NOOP for context, trends, and confidence.",
            "Paired",
            "Paused",
            "Prioritize recovery",
            "R %@ · E %@ · S %@",
            "RHR",
            "RHR %@",
            "Recovery",
            "Recovery, Effort, Sleep, and your three chosen supporting metrics in one honest glance.",
            "Refreshed now",
            "Resting HR",
            "Scores · %@",
            "Sleep",
            "Sleep %@",
            "Sleep %@ · %@",
            "Sleep %@ · HRV %@",
            "Sleep duration",
            "Sleep score, duration, HRV, and resting heart rate from your latest sleep.",
            "Today",
            "Unavailable",
            "Update paused",
            "Vitals",
            "Waiting for daily data",
            "Wear your device consistently to unlock scores.",
            "Wearable",
            "Yesterday",
            "appwide.day_overview.duration_hours_minutes_format",
            "appwide.day_overview.duration_minutes_format",
            "bpm",
            "launch.locked.inline",
            "launch.locked.instruction",
            "launch.locked.title",
            "sleep duration",
            "widget.duration_hours_format",
        ]

        XCTAssertEqual(Set(strings.keys), requiredKeys)
        XCTAssertNil(strings[""])
        XCTAssertNil(strings["%@"])
    }

    func testEveryTranslatableWidgetKeyHasFocusLocalesAndMatchingPlaceholders() throws {
        let strings = try catalogStrings()
        let focusLocales = ["de", "es", "fr", "pt-PT"]

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let sourceUnit = (localizations["en"] as? [String: Any]).flatMap {
                $0["stringUnit"] as? [String: Any]
            }
            let source = sourceUnit?["value"] as? String ?? key

            for locale in focusLocales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "\(key) [\(locale)]"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) [\(locale)]"
                )
                XCTAssertEqual(
                    unit["state"] as? String,
                    "translated",
                    "\(key) [\(locale)]"
                )
                let value = try XCTUnwrap(
                    unit["value"] as? String,
                    "\(key) [\(locale)]"
                )
                XCTAssertEqual(
                    placeholders(in: value),
                    placeholders(in: source),
                    "\(key) [\(locale)]"
                )
            }
        }
    }

    func testWidgetAuditUsesTheTargetOwnedCatalog() throws {
        let audit = try text("Tools/i18n_audit.py")
        XCTAssertTrue(
            audit.contains(
                #"[ROOT / "StrandiOSWidgets", ROOT / "StrandiOSShared"],"#
            )
        )
        XCTAssertTrue(
            audit.contains(
                #"ROOT / "StrandiOSWidgets/Localizable.xcstrings""#
            )
        )
    }
}
