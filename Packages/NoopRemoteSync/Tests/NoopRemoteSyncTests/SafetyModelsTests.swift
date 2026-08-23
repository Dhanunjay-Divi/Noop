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
        XCTAssertNil(dispatch.latestLocation)
    }
}
