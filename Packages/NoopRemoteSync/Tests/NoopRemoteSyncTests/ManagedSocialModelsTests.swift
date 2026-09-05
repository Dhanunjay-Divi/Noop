import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedSocialModelsTests: XCTestCase {
    func testProfileURLCarriesOnlyAValidShareableNOOPID() throws {
        let noopID = "NOOP-ABCD-EFGH-JKLM-NPQR"
        let expected = try XCTUnwrap(
            URL(string: "noop://managed-friends/profile?noopId=\(noopID)")
        )

        XCTAssertEqual(
            ManagedSocialIdentifier.profileNOOPID(from: expected),
            noopID
        )
        XCTAssertEqual(
            ManagedSocialIdentifier.profileURL(noopID: noopID),
            expected
        )
        for value in [
            "noop://managed-friends/profile?noopId=\(noopID)&extra=1",
            "noop://managed-friends/profile?noopId=\(noopID)#fragment",
            "noop://user@managed-friends/profile?noopId=\(noopID)",
            "noop://managed-friends:443/profile?noopId=\(noopID)",
            "noop://other/profile?noopId=\(noopID)",
            "noop://managed-friends/profile?noopId=short",
        ] {
            XCTAssertNil(
                ManagedSocialIdentifier.profileNOOPID(
                    from: try XCTUnwrap(URL(string: value))
                )
            )
        }
    }

    func testInviteURLCarriesOnlyAValidCapability() throws {
        let capability = "noopinvite_" + String(repeating: "a", count: 43)
        let expected = try XCTUnwrap(
            URL(
                string:
                    "noop://managed-friends/invite?capability=\(capability)"
            )
        )

        XCTAssertEqual(
            ManagedSocialIdentifier.inviteCapability(from: expected),
            capability
        )
        XCTAssertEqual(
            ManagedSocialIdentifier.inviteURL(capability: capability),
            expected
        )
        for value in [
            "\(expected.absoluteString)&extra=1",
            "\(expected.absoluteString)#fragment",
            "noop://user@managed-friends/invite?capability=\(capability)",
            "noop://managed-friends:443/invite?capability=\(capability)",
            "noop://other/invite?capability=\(capability)",
            "noop://managed-friends/invite?capability=short",
        ] {
            XCTAssertNil(
                ManagedSocialIdentifier.inviteCapability(
                    from: try XCTUnwrap(URL(string: value))
                )
            )
        }
    }

    func testProjectionDigestMatchesCrossPlatformGoldenVector() {
        let digest = ManagedSocialProjection.digest(
            day: "2026-09-05",
            summary: ManagedSocialSummary(
                charge: 72.5,
                hrv: 54
            ),
            visibility: ManagedSocialVisibility(
                charge: true,
                hrv: true,
                pokeAllowed: true
            )
        )

        XCTAssertEqual(
            digest,
            "1ae7221f2694469e23c6fecd9beb8053439ba79f7eedd7c4f244b6d9cf0dc9ca"
        )
        XCTAssertNil(
            ManagedSocialProjection.digest(
                day: "not-a-day",
                summary: ManagedSocialSummary(),
                visibility: ManagedSocialVisibility()
            )
        )
    }
}
