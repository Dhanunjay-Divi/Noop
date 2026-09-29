import Foundation
import XCTest
@testable import Strand

final class VeepooBandCompatibilityPolicyTests: XCTestCase {
    private let identity = VeepooBandProductIdentity(
        modelCode: "4321",
        hardwareRevision: "HW-1",
        firmwareRevision: "FW-2"
    )

    func testExactAppleTupleIsApprovedAndMatchingIsCaseSensitive() throws {
        let policy = try policy(rows: [approvedRow()])

        XCTAssertEqual(policy.decision(for: identity), .approved)
        XCTAssertEqual(
            policy.decision(
                for: .init(
                    modelCode: "4321",
                    hardwareRevision: "hw-1",
                    firmwareRevision: "FW-2"
                )
            ),
            .notApproved
        )
    }

    func testWrongPlatformProtocolOrWrapperCannotApproveAppleIdentity()
        throws
    {
        var androidRow = approvedRow()
        androidRow["platform"] = "android"
        androidRow["wrapperRevision"] = "veepoo-android-display-v2"
        XCTAssertEqual(
            try policy(rows: [androidRow]).decision(for: identity),
            .notApproved
        )

        for override in [
            ["protocolVersion": "noop-band-v2"],
            ["wrapperRevision": "veepoo-apple-display-v2"],
            ["platform": "unsupported"],
        ] {
            var row = approvedRow()
            override.forEach { row[$0.key] = $0.value }
            XCTAssertThrowsError(try policy(rows: [row])) {
                XCTAssertEqual(
                    $0 as? VeepooBandCompatibilityManifestError,
                    .invalidRow
                )
            }
        }
    }

    func testEmptyManifestIsValidAndRejectsEveryBand() throws {
        let policy = try self.policy(rows: [])
        XCTAssertEqual(policy.decision(for: identity), .notApproved)
    }

    func testQualificationModeApprovesOnlyWhenManifestIsValidAndEmpty()
        throws
    {
        let qualification = try policy(
            rows: [],
            allowsUnlistedQualification: true
        )
        XCTAssertEqual(
            qualification.decision(for: identity),
            .qualificationApproved
        )

        let populated = try policy(
            rows: [approvedRow()],
            allowsUnlistedQualification: true
        )
        XCTAssertEqual(
            populated.decision(
                for: .init(
                    modelCode: "9999",
                    hardwareRevision: "HW-9",
                    firmwareRevision: "FW-9"
                )
            ),
            .notApproved
        )
        var androidRow = approvedRow()
        androidRow["platform"] = "android"
        androidRow["wrapperRevision"] = "veepoo-android-display-v2"
        XCTAssertEqual(
            try policy(
                rows: [androidRow],
                allowsUnlistedQualification: true
            ).decision(for: identity),
            .qualificationApproved
        )
        XCTAssertEqual(
            VeepooBandCompatibilityPolicy
                .rejectingInvalidManifest()
                .decision(for: identity),
            .invalidManifest
        )
    }

    func testMissingAndMalformedManifestFailClosed() {
        XCTAssertEqual(
            VeepooBandCompatibilityPolicy
                .rejectingInvalidManifest()
                .decision(for: identity),
            .invalidManifest
        )
        XCTAssertThrowsError(
            try VeepooBandCompatibilityPolicy(
                validatingManifestData: Data("{".utf8)
            )
        ) {
            XCTAssertEqual(
                $0 as? VeepooBandCompatibilityManifestError,
                .malformed
            )
        }
        XCTAssertThrowsError(
            try VeepooBandCompatibilityPolicy(
                validatingManifestData: Data(
                    """
                    {"schemaVersion":1,"approvedBands":[],"extra":true}
                    """.utf8
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? VeepooBandCompatibilityManifestError,
                .invalidTopLevel
            )
        }
    }

    func testDuplicateRowsAreRejected() throws {
        let row = approvedRow()
        XCTAssertThrowsError(try policy(rows: [row, row])) {
            XCTAssertEqual(
                $0 as? VeepooBandCompatibilityManifestError,
                .duplicateRow
            )
        }
    }

    func testBlankWildcardUnknownAndNonASCIIFieldsAreRejected() {
        let invalidOverrides = [
            ["modelCode": ""],
            ["hardwareRevision": "   "],
            ["firmwareRevision": "FW-*"],
            ["modelCode": "ANY"],
            ["modelCode": "all"],
            ["modelCode": "default"],
            ["modelCode": "unknown"],
            ["modelCode": String(repeating: "A", count: 65)],
            ["hardwareRevision": "H\u{00C9}"],
            ["unknown": "value"],
        ]

        for override in invalidOverrides {
            var row = approvedRow()
            override.forEach { row[$0.key] = $0.value }
            XCTAssertThrowsError(try policy(rows: [row])) {
                XCTAssertEqual(
                    $0 as? VeepooBandCompatibilityManifestError,
                    .invalidRow
                )
            }
        }
    }

    private func policy(
        rows: [[String: Any]],
        allowsUnlistedQualification: Bool = false
    ) throws -> VeepooBandCompatibilityPolicy {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "approvedBands": rows,
            ],
            options: [.sortedKeys]
        )
        return try VeepooBandCompatibilityPolicy(
            validatingManifestData: data,
            allowsUnlistedQualification: allowsUnlistedQualification
        )
    }

    private func approvedRow() -> [String: Any] {
        [
            "platform": "apple",
            "modelCode": identity.modelCode,
            "hardwareRevision": identity.hardwareRevision,
            "firmwareRevision": identity.firmwareRevision,
            "protocolVersion": "noop-band-v1",
            "wrapperRevision": "veepoo-apple-display-v1",
        ]
    }
}
