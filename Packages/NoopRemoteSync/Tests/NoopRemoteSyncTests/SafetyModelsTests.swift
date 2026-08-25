import XCTest
@testable import NoopRemoteSync

final class SafetyModelsTests: XCTestCase {
    func testAcknowledgedIncidentDecodesResponderAndRetryState() throws {
        let json = """
        {
          "dispatch_id": "11111111-1111-4111-8111-111111111111",
          "idempotency_key": "22222222-2222-4222-8222-222222222222",
          "trigger": "manual_sos",
          "share_duration_hours": 8,
          "escalation_rounds": 4,
          "escalation_interval_seconds": 900,
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
            "escalation_round": 2,
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
        XCTAssertEqual(incident.shareDurationHours, 8)
        XCTAssertEqual(incident.escalationRounds, 4)
        XCTAssertEqual(incident.escalationIntervalSeconds, 900)
        XCTAssertEqual(incident.deliveries.first?.escalationRound, 2)
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

    func testValidatedFallRequestEncodesBoundedEvidenceAndDuration() throws {
        let page = RemoteSafetyPageCreate(
            trigger: .validatedFall,
            shareDurationHours: .twelve,
            evidence: RemoteSafetyValidatedFallEvidence(
                detectorId: "noop_band_fall",
                detectorVersion: 1,
                eventId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                detectedAt: "2026-08-24T12:00:00Z",
                warningHapticConfirmedAt: "2026-08-24T12:00:01Z",
                responseDeadlineAt: "2026-08-24T12:00:46Z"
            )
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(page))
                as? [String: Any]
        )

        XCTAssertEqual(object["trigger"] as? String, "validated_fall")
        XCTAssertEqual(object["share_duration_hours"] as? Int, 12)
        let evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
        XCTAssertEqual(evidence["detector_id"] as? String, "noop_band_fall")
        XCTAssertEqual(evidence["detector_version"] as? Int, 1)
    }

    func testSafetyPageDurationUsesClosedEightOrTwelveHourType() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let eight = try JSONSerialization.jsonObject(
            with: encoder.encode(RemoteSafetyPageCreate())
        ) as? [String: Any]
        let twelve = try JSONSerialization.jsonObject(
            with: encoder.encode(
                RemoteSafetyPageCreate(shareDurationHours: .twelve)
            )
        ) as? [String: Any]

        XCTAssertEqual(eight?["share_duration_hours"] as? Int, 8)
        XCTAssertEqual(twelve?["share_duration_hours"] as? Int, 12)
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
