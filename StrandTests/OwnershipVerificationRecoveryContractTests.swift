import Foundation
import XCTest

final class OwnershipVerificationRecoveryContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testAppleVerificationRecoveryUsesBoundedMonotonicCooldowns() throws {
        let service = try source("StrandiOS/System/OwnershipService.swift")

        XCTAssertTrue(
            service.contains(
                "private static let verificationResendCooldownSeconds = 60"
            )
        )
        XCTAssertTrue(
            service.contains(
                "ContinuousClock.now.advanced("
            )
        )
        XCTAssertFalse(
            service.contains(
                "Date().addingTimeInterval("
            )
        )
        XCTAssertTrue(
            service.contains(
                "try self.requireVerificationResendAvailable(.email)"
            )
        )
        XCTAssertTrue(
            service.contains(
                "try requireVerificationResendAvailable(.phone)"
            )
        )
        XCTAssertGreaterThanOrEqual(
            service.components(
                separatedBy: "clearAllVerificationCooldowns()"
            ).count - 1,
            3
        )
    }

    func testAppleVerificationRecoveryMapsStableFailureCategories() throws {
        let service = try source("StrandiOS/System/OwnershipService.swift")

        for expected in [
            "case .networkError:",
            "case .invalidVerificationCode:",
            "case .invalidVerificationID, .sessionExpired:",
            "case .tooManyRequests:",
            "case .verificationCodeInvalid:",
            "case .verificationSessionExpired:",
            "case .verificationRateLimited:",
            "case .verificationCooldown:",
            "return \"verification_code_invalid\"",
            "return \"verification_expired\"",
            "return \"rate_limit\"",
            "return \"resend_cooldown\"",
        ] {
            XCTAssertTrue(service.contains(expected), expected)
        }
    }

    func testAppleVerificationRecoveryDoesNotLogProviderPayloads() throws {
        let service = try source("StrandiOS/System/OwnershipService.swift")
        let start = try XCTUnwrap(
            service.range(of: "private func mappedVerificationError(")
        )
        let end = try XCTUnwrap(
            service.range(
                of: "private func beginBusy(",
                range: start.upperBound..<service.endIndex
            )
        )
        let mapping = service[start.lowerBound..<end.lowerBound]

        XCTAssertFalse(mapping.contains("localizedDescription"))
        XCTAssertFalse(mapping.contains("userInfo"))
        XCTAssertFalse(mapping.contains("String(describing: error)"))
    }

    func testAppleVerificationRecoveryCopyIsLocalizedAcrossSupportedLocales()
        throws
    {
        let catalogURL = repoRoot.appendingPathComponent(
            "Strand/Resources/Localizable.xcstrings"
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: catalogURL)
            ) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let locales = [
            "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant",
        ]
        let keys = [
            "Resend in %llds",
            "That code is incorrect. Check it and try again.",
            "That code expired. Request a new one.",
            "Too many attempts. Wait before requesting another code.",
            "Wait for the resend timer before requesting another code.",
        ]

        for key in keys {
            let entry = try XCTUnwrap(
                strings[key] as? [String: Any],
                "Missing recovery key: \(key)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for: \(key)"
            )
            for locale in locales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale) localization for: \(key)"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "Missing \(locale) string unit for: \(key)"
                )
                XCTAssertEqual(
                    unit["state"] as? String,
                    "translated",
                    "\(locale): \(key)"
                )
                XCTAssertFalse(
                    (unit["value"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty ?? true,
                    "\(locale): \(key)"
                )
            }
        }
    }
}
