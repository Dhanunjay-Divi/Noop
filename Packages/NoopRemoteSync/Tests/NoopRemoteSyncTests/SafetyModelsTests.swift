import XCTest
@testable import NoopRemoteSync

final class SafetyModelsTests: XCTestCase {
    func testAcknowledgedIncidentDecodesResponderAndRetryState() throws {
        let json = """
        {
          "dispatch_id": "11111111-1111-4111-8111-111111111111",
          "idempotency_key": "22222222-2222-4222-8222-222222222222",
          "trigger": "manual_sos",
          "status": "acknowledged",
          "created_at": "2026-08-22T12:00:00Z",
          "updated_at": "2026-08-22T12:01:00Z",
          "expires_at": "2026-08-22T12:30:00Z",
          "acknowledged_at": "2026-08-22T12:01:00Z",
          "acknowledged_contact_id": "33333333-3333-4333-8333-333333333333",
          "acknowledged_contact_display_name": "Alex",
          "completed_at": null,
          "idempotent_replay": false,
          "deliveries": [{
            "delivery_id": "44444444-4444-4444-8444-444444444444",
            "contact_id": "33333333-3333-4333-8333-333333333333",
            "contact_display_name": "Alex",
            "channel": "sms",
            "status": "retry_wait",
            "attempt_count": 1,
            "max_attempts": 3,
            "created_at": "2026-08-22T12:00:00Z",
            "updated_at": "2026-08-22T12:00:05Z"
          }],
          "responses": [{
            "contact_id": "33333333-3333-4333-8333-333333333333",
            "contact_display_name": "Alex",
            "decision": "responding",
            "source": "sms_link",
            "responded_at": "2026-08-22T12:01:00Z"
          }],
          "latest_location": {
            "sequence": 3,
            "latitude": 40.7131,
            "longitude": -74.0057,
            "horizontal_accuracy_meters": 12.0,
            "captured_at": "2026-08-22T12:00:45Z",
            "received_at": "2026-08-22T12:00:46Z"
          },
          "contact_summary": {
            "targeted": 3,
            "reached": 1,
            "pending": 1,
            "failed": 1,
            "last_reached_at": "2026-08-22T12:01:00Z",
            "all_contacts_failed": false
          },
          "delivery_summary": {"retry_wait": 1}
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let incident = try decoder.decode(
            RemoteSafetyDispatch.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(incident.status, .acknowledged)
        XCTAssertEqual(incident.deliveries.first?.status, .retryWait)
        XCTAssertEqual(incident.deliveries.first?.attemptCount, 1)
        XCTAssertEqual(incident.responses?.first?.decision, .responding)
        XCTAssertEqual(incident.acknowledgedContactDisplayName, "Alex")
        XCTAssertEqual(incident.latestLocation?.sequence, 3)
        XCTAssertEqual(incident.latestLocation?.horizontalAccuracyMeters, 12)
        XCTAssertEqual(incident.contactSummary?.targeted, 3)
        XCTAssertEqual(incident.contactSummary?.reached, 1)
        XCTAssertEqual(incident.contactSummary?.pending, 1)
        XCTAssertEqual(incident.contactSummary?.failed, 1)
        XCTAssertEqual(
            incident.contactSummary?.lastReachedAt,
            "2026-08-22T12:01:00Z"
        )
        XCTAssertEqual(incident.contactSummary?.allContactsFailed, false)
    }

    func testLegacyDispatchStillDecodesWithoutIncidentMetadata() throws {
        let json = """
        {
          "dispatch_id": "11111111-1111-4111-8111-111111111111",
          "idempotency_key": "22222222-2222-4222-8222-222222222222",
          "trigger": "manual_sos",
          "status": "submitted",
          "created_at": "2026-08-22T12:00:00Z",
          "completed_at": "2026-08-22T12:00:01Z",
          "idempotent_replay": false,
          "deliveries": []
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let dispatch = try decoder.decode(
            RemoteSafetyDispatch.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(dispatch.status, .submitted)
        XCTAssertNil(dispatch.expiresAt)
        XCTAssertNil(dispatch.responses)
        XCTAssertNil(dispatch.contactSummary)
        XCTAssertNil(dispatch.latestLocation)
    }

    func testAllContactsFailedSummaryDecodesExactContract() throws {
        let json = """
        {
          "targeted": 2,
          "reached": 0,
          "pending": 0,
          "failed": 2,
          "last_reached_at": null,
          "all_contacts_failed": true
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let summary = try decoder.decode(
            RemoteSafetyContactSummary.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(summary.targeted, 2)
        XCTAssertEqual(summary.reached, 0)
        XCTAssertEqual(summary.pending, 0)
        XCTAssertEqual(summary.failed, 2)
        XCTAssertNil(summary.lastReachedAt)
        XCTAssertTrue(summary.allContactsFailed)
        XCTAssertTrue(summary.isConsistent)
    }

    func testContactSummaryConsistencyRejectsImpossibleCounts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        func decode(_ body: String) throws -> RemoteSafetyContactSummary {
            try decoder.decode(
                RemoteSafetyContactSummary.self,
                from: Data(body.utf8)
            )
        }

        XCTAssertFalse(try decode("""
        {"targeted":2,"reached":1,"pending":1,"failed":1,
         "last_reached_at":null,"all_contacts_failed":false}
        """).isConsistent)
        XCTAssertFalse(try decode("""
        {"targeted":2,"reached":0,"pending":0,"failed":2,
         "last_reached_at":null,"all_contacts_failed":false}
        """).isConsistent)
        XCTAssertFalse(try decode("""
        {"targeted":0,"reached":0,"pending":0,"failed":0,
         "last_reached_at":null,"all_contacts_failed":true}
        """).isConsistent)
    }

    func testMalformedContactSummaryFallsBackWithoutDiscardingDispatch() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let malformedSummaries = [
            """
            {"targeted":2,"reached":1}
            """,
            """
            {"targeted":"2","reached":0,"pending":0,"failed":2,
             "last_reached_at":null,"all_contacts_failed":true}
            """,
            """
            {"targeted":2,"reached":1,"pending":1,"failed":1,
             "last_reached_at":null,"all_contacts_failed":false}
            """,
        ]

        for summary in malformedSummaries {
            let json = """
            {
              "dispatch_id": "11111111-1111-4111-8111-111111111111",
              "idempotency_key": "22222222-2222-4222-8222-222222222222",
              "trigger": "manual_sos",
              "status": "open",
              "created_at": "2026-08-22T12:00:00Z",
              "idempotent_replay": false,
              "deliveries": [],
              "contact_summary": \(summary)
            }
            """

            let dispatch = try decoder.decode(
                RemoteSafetyDispatch.self,
                from: Data(json.utf8)
            )

            XCTAssertEqual(dispatch.status, .open)
            XCTAssertNil(dispatch.contactSummary)
        }
    }

    func testPagingEnabledDecodesWhenPresentAndRemainsOptionalForLegacyPayloads() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let currentContacts = """
        {
          "contacts": [],
          "accepted_count": 2,
          "minimum_accepted": 2,
          "maximum_contacts": 5,
          "paging_configured": true,
          "paging_enabled": true
        }
        """
        let legacyContacts = """
        {
          "contacts": [],
          "accepted_count": 0,
          "minimum_accepted": 2,
          "maximum_contacts": 5,
          "paging_configured": true
        }
        """
        let currentProfile = """
        {
          "profile_id": "11111111-1111-4111-8111-111111111111",
          "enrollment_id": "22222222-2222-4222-8222-222222222222",
          "display_name": "Sam",
          "installation_id": "install-1",
          "created_at": "2026-08-22T12:00:00Z",
          "updated_at": "2026-08-22T12:00:00Z",
          "paging_enabled": false
        }
        """
        let legacyProfile = """
        {
          "profile_id": "11111111-1111-4111-8111-111111111111",
          "enrollment_id": "22222222-2222-4222-8222-222222222222",
          "display_name": "Sam",
          "installation_id": "install-1",
          "created_at": "2026-08-22T12:00:00Z",
          "updated_at": "2026-08-22T12:00:00Z"
        }
        """

        XCTAssertEqual(
            try decoder.decode(
                RemoteSafetyContactsResponse.self,
                from: Data(currentContacts.utf8)
            ).pagingEnabled,
            true
        )
        XCTAssertNil(
            try decoder.decode(
                RemoteSafetyContactsResponse.self,
                from: Data(legacyContacts.utf8)
            ).pagingEnabled
        )
        XCTAssertEqual(
            try decoder.decode(
                RemoteSafetyProfile.self,
                from: Data(currentProfile.utf8)
            ).pagingEnabled,
            false
        )
        XCTAssertNil(
            try decoder.decode(
                RemoteSafetyProfile.self,
                from: Data(legacyProfile.utf8)
            ).pagingEnabled
        )
    }
}
