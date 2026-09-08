import Foundation
import XCTest
@testable import NoopRemoteSync

final class ManagedSafetyModelsTests: XCTestCase {
    func testInviteURLCarriesOnlyOneValidCapability() throws {
        let capability = "noopsafety_" + String(repeating: "a", count: 43)
        let expected = try XCTUnwrap(
            URL(
                string:
                    "noop://managed-safety/invite?capability=\(capability)"
            )
        )

        XCTAssertEqual(
            ManagedSafetyIdentifier.inviteCapability(from: expected),
            capability
        )
        XCTAssertEqual(
            ManagedSafetyIdentifier.inviteURL(capability: capability),
            expected
        )
        for value in [
            "\(expected.absoluteString)&extra=1",
            "\(expected.absoluteString)#fragment",
            "noop://user@managed-safety/invite?capability=\(capability)",
            "noop://managed-safety:443/invite?capability=\(capability)",
            "noop://other/invite?capability=\(capability)",
            "noop://managed-safety/invite?capability=short",
        ] {
            XCTAssertNil(
                ManagedSafetyIdentifier.inviteCapability(
                    from: try XCTUnwrap(URL(string: value))
                )
            )
        }
    }

    func testGeneratedCapabilitiesAreValidAndDistinct() {
        let values = Set((0..<32).map { _ in
            ManagedSafetyIdentifier.makeInviteCapability()
        })

        XCTAssertEqual(values.count, 32)
        XCTAssertTrue(values.allSatisfy(ManagedSafetyIdentifier.valid))
    }

    func testPushPayloadRequiresTheFixedContract() throws {
        let incidentID = UUID()
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-08T08:00:00Z")
        )
        let values = [
            "kind": "managed_safety_incident",
            "schema": "1",
            "route": "safety",
            "expires_at": "2026-09-08T18:30:00.123456+00:00",
            "incident_id": incidentID.uuidString.lowercased(),
        ]

        XCTAssertEqual(
            ManagedSafetyPushPayload.incidentID(from: values, now: now),
            incidentID
        )
        XCTAssertEqual(
            ManagedSafetyPushPayload.incidentID(
                from: Dictionary(
                    uniqueKeysWithValues: values.map {
                        (AnyHashable($0.key), $0.value as Any)
                    }
                ),
                now: now
            ),
            incidentID
        )

        for key in values.keys {
            var incomplete = values
            incomplete.removeValue(forKey: key)
            XCTAssertNil(
                ManagedSafetyPushPayload.incidentID(
                    from: incomplete,
                    now: now
                ),
                "accepted payload without \(key)"
            )
        }

        for (key, value) in [
            ("kind", "other"),
            ("schema", "2"),
            ("route", "friends"),
            ("expires_at", "not-a-date"),
            ("incident_id", "not-a-uuid"),
        ] {
            var invalid = values
            invalid[key] = value
            XCTAssertNil(
                ManagedSafetyPushPayload.incidentID(
                    from: invalid,
                    now: now
                ),
                "accepted invalid \(key)"
            )
        }

        for expiry in [
            "2026-09-08T07:59:59Z",
            "2026-09-08T08:00:00Z",
        ] {
            var expired = values
            expired["expires_at"] = expiry
            XCTAssertNil(
                ManagedSafetyPushPayload.incidentID(
                    from: expired,
                    now: now
                ),
                "accepted expired payload at \(expiry)"
            )
        }
    }

    func testContactIdentityIncludesRelationshipRole() {
        let profileID = UUID()
        let acceptedAt = "2026-09-08T09:00:00Z"
        let owner = ManagedSafetyContact(
            profileID: profileID,
            displayName: "Owner",
            role: "owner",
            acceptedAt: acceptedAt
        )
        let contact = ManagedSafetyContact(
            profileID: profileID,
            displayName: "Owner",
            role: "contact",
            acceptedAt: acceptedAt
        )

        XCTAssertNotEqual(owner.id, contact.id)
        XCTAssertEqual(
            owner.id,
            "\(profileID.uuidString.lowercased()):owner"
        )
    }
}
