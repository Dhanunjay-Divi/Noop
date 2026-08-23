import XCTest

final class UserVisiblePunctuationPolicyTests: XCTestCase {
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

    func testLocalizationResourcesAndSourcesContainNoEmDash() throws {
        let forbidden = String(UnicodeScalar(0x2014)!)
        let paths = [
            "Strand/Resources/Localizable.xcstrings",
            "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
            "Tools/AppWideLocalization/appwide_strings.json",
            "Tools/CoachLocalization/coach_strings.json",
            "Tools/NutritionLocalization/nutrition_strings.json",
            "Tools/SafetyLocalization/safety_strings.json",
        ]

        for path in paths {
            XCTAssertFalse(try text(path).contains(forbidden), path)
        }
    }

    func testCoachDailyReflectionDoesNotClaimAHealthMeasurement() throws {
        let source = try text("Tools/CoachLocalization/coach_strings.json")
        XCTAssertTrue(source.contains(#""en":"Daily reflection""#))
        XCTAssertTrue(source.contains("It does not measure health, change scores, contact anyone"))
        XCTAssertFalse(source.contains(#""en":"Daily check-in""#))
    }
}
