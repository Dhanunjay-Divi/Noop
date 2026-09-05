import XCTest
@testable import NoopRemoteSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ManagedStorageClientTests: XCTestCase {
    override func tearDown() {
        ManagedURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testConfigurationRequiresHTTPSAndPinnedPolicyDigest() throws {
        XCTAssertThrowsError(
            try ManagedStorageConfiguration(
                baseURL: XCTUnwrap(URL(string: "http://noop.example")),
                policyVersion: "synthetic-v1",
                policySHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertNoThrow(
            try ManagedStorageConfiguration(
                baseURL: XCTUnwrap(URL(string: "https://noop.example")),
                policyVersion: "synthetic-v1",
                policySHA256: String(repeating: "a", count: 64)
            )
        )
    }

    func testEnrollmentCarriesAppCheckIdentityAndExplicitPolicy() async throws {
        let (client, authorization) = try makeClient()
        let requestID = UUID(uuidString: "397f4624-1c42-49ea-8af7-ced2ca439a36")!
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/managed/enroll")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer identity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Noop-Installation-ID"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Noop-Installation-Token"))
            let data = try requestBody(request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(object["installation_id"] as? String, "ios-installation")
            XCTAssertEqual(
                object["installation_token"] as? String,
                "noopm_" + String(repeating: "a", count: 43)
            )
            XCTAssertEqual(object["policy_version"] as? String, "synthetic-v1")
            XCTAssertEqual(
                object["policy_sha256"] as? String,
                String(repeating: "a", count: 64)
            )
            XCTAssertEqual(
                object["data_classes"] as? [String],
                ["derived_summaries", "essential_timeseries"]
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "created": true,
                  "product_boundary": {
                    "account_optional": true,
                    "local_metrics_available": true,
                    "storage_only_entitlement": true
                  }
                }
                """.utf8)
            )
        }

        let response = try await client.enroll(
            platform: .iOS,
            dataClasses: ["essential_timeseries", "derived_summaries"],
            authorization: authorization,
            requestID: requestID
        )
        XCTAssertTrue(response.created)
        XCTAssertTrue(response.productBoundary.accountOptional)
        XCTAssertTrue(response.productBoundary.localMetricsAvailable)
    }

    func testOverviewAndInstallationManagementUseCurrentInstallationScope() async throws {
        let (client, authorization) = try makeClient()
        let otherInstallation = "android-installation"
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-ID"),
                "ios-installation"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-Token"),
                "noopm_" + String(repeating: "a", count: 43)
            )
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/managed/me"):
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("""
                    {
                      "account": {
                        "status": "active",
                        "plan_code": "noop_plus_staging",
                        "display_tier": "noop_plus",
                        "max_total_bytes": 1048576,
                        "max_installations": 3
                      },
                      "storage": {
                        "installations": 2,
                        "rules": [
                          {"committed_bytes": 128, "reserved_bytes": 32},
                          {"committed_bytes": 64, "reserved_bytes": 16}
                        ]
                      }
                    }
                    """.utf8)
                )
            case ("GET", "/v1/managed/installations"):
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("""
                    {
                      "installations": [
                        {
                          "installation_id": "ios-installation",
                          "platform": "ios",
                          "status": "active",
                          "attestation_state": "accepted",
                          "registered_at": "2026-09-03T10:00:00Z",
                          "last_seen_at": "2026-09-04T10:00:00Z",
                          "revoked_at": null,
                          "current": true
                        },
                        {
                          "installation_id": "\(otherInstallation)",
                          "platform": "android",
                          "status": "active",
                          "attestation_state": "accepted",
                          "registered_at": "2026-09-03T11:00:00Z",
                          "last_seen_at": "2026-09-04T11:00:00Z",
                          "revoked_at": null,
                          "current": false
                        }
                      ]
                    }
                    """.utf8)
                )
            case ("DELETE", "/v1/managed/installations/\(otherInstallation)"):
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("""
                    {
                      "installation": {
                        "installation_id": "\(otherInstallation)",
                        "platform": "android",
                        "status": "revoked",
                        "attestation_state": "accepted",
                        "registered_at": "2026-09-03T11:00:00Z",
                        "last_seen_at": "2026-09-04T11:00:00Z",
                        "revoked_at": "2026-09-04T12:00:00Z",
                        "current": false
                      }
                    }
                    """.utf8)
                )
            default:
                XCTFail("Unexpected request \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                throw ManagedStorageError.invalidResponse
            }
        }

        let overview = try await client.overview(authorization: authorization)
        XCTAssertEqual(overview.committedBytes, 192)
        XCTAssertEqual(overview.reservedBytes, 48)
        XCTAssertEqual(overview.installationCount, 2)
        XCTAssertEqual(overview.maximumInstallations, 3)

        let installations = try await client.installations(authorization: authorization)
        XCTAssertEqual(installations.count, 2)
        XCTAssertTrue(installations[0].current)
        XCTAssertEqual(installations[1].installationID, otherInstallation)

        let revoked = try await client.revokeInstallation(
            otherInstallation,
            authorization: authorization
        )
        XCTAssertEqual(revoked.status, "revoked")
    }

    func testSignedUploadReturnsGenerationBoundCompletionReceipt() async throws {
        let (client, _) = try makeClient()
        let capability = ManagedChunkReservationResponse.Upload(
            grantID: UUID(),
            method: "PUT",
            url: try XCTUnwrap(URL(string: "https://storage.googleapis.com/bucket/object")),
            headers: [
                "content-length": "3",
                "content-type": "application/vnd.noop.chunk+json",
                "host": "storage.googleapis.com",
                "x-goog-if-generation-match": "0",
            ],
            expiresAt: "2026-09-03T12:10:00Z"
        )
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.host, "storage.googleapis.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-if-generation-match"), "0")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "x-goog-generation": "42",
                        "x-goog-metageneration": "1",
                        "x-goog-hash": "crc32c=AAAAAA==,md5=BBBBBBBBBBBBBBBBBBBBBB==",
                    ]
                )!,
                Data()
            )
        }

        let receipt = try await client.upload(Data("abc".utf8), using: capability)
        XCTAssertEqual(receipt.objectGeneration, 42)
        XCTAssertEqual(receipt.objectMetageneration, 1)
        XCTAssertEqual(receipt.objectCRC32C, "AAAAAA==")
    }

    func testSignedDownloadRejectsNonHTTPSCapabilityBeforeNetwork() async throws {
        let (client, _) = try makeClient()
        let capability = ManagedDownloadCapability(
            grantID: UUID(),
            method: "GET",
            url: try XCTUnwrap(URL(string: "http://storage.googleapis.com/bucket/object")),
            headers: [:],
            expiresAt: "2026-09-03T12:10:00Z",
            chunk: ManagedDownloadCapability.Chunk(
                chunkID: UUID(),
                expectedSHA256: String(repeating: "a", count: 64),
                compression: "gzip",
                contentType: "application/vnd.noop.chunk+json",
                expectedUncompressedBytes: 3
            )
        )
        ManagedURLProtocolStub.handler = { _ in
            XCTFail("An insecure signed download must not reach the network.")
            throw ManagedStorageError.invalidResponse
        }

        do {
            _ = try await client.download(using: capability)
            XCTFail("Expected the insecure capability to be rejected.")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testAccountErasureUsesRecentIdentityAndInstallationCredential() async throws {
        let (client, authorization) = try makeClient()
        let requestID = UUID(uuidString: "541A96AD-5288-46DA-8F30-625E410362DF")!
        let jobID = UUID(uuidString: "8519298E-C785-45E8-963A-81834BE94638")!
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/managed/erasure")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer identity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-ID"),
                "ios-installation"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-Token"),
                "noopm_" + String(repeating: "a", count: 43)
            )
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(
                (body["request_id"] as? String)?.lowercased(),
                requestID.uuidString.lowercased()
            )
            XCTAssertEqual(body["scope"] as? String, "account")
            XCTAssertEqual(body["confirmation_sha256"] as? String, String(repeating: "c", count: 64))
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "erasure": {
                    "erasure_job_id": "\(jobID.uuidString.lowercased())",
                    "scope": "account",
                    "status": "cooling_off",
                    "objects_selected": 0,
                    "objects_deleted": 0,
                    "bytes_selected": 0,
                    "bytes_deleted": 0,
                    "database_rows_deleted": 0,
                    "requested_at": "2026-09-04T04:00:00Z",
                    "not_before": "2026-09-05T04:00:00Z",
                    "started_at": null,
                    "completed_at": null,
                    "verification_expires_at": "2027-10-09T04:00:00Z",
                    "duplicate": false
                  }
                }
                """.utf8)
            )
        }

        let request = try ManagedErasureRequest(
            requestID: requestID,
            scope: .account,
            confirmationSHA256: String(repeating: "c", count: 64)
        )
        let job = try await client.requestErasure(
            request,
            authorization: authorization
        )
        XCTAssertEqual(job.erasureJobID, jobID)
        XCTAssertEqual(job.scope, .account)
        XCTAssertEqual(job.status, "cooling_off")
    }

    func testSignedUploadRejectsInvalidGenerationReceipt() async throws {
        let (client, _) = try makeClient()
        let capability = ManagedChunkReservationResponse.Upload(
            grantID: UUID(),
            method: "PUT",
            url: try XCTUnwrap(URL(string: "https://storage.googleapis.com/bucket/object")),
            headers: [:],
            expiresAt: "2026-09-03T12:10:00Z"
        )
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "x-goog-generation": "0",
                        "x-goog-metageneration": "1",
                        "x-goog-hash": "crc32c=AAAAAA==",
                    ]
                )!,
                Data()
            )
        }

        do {
            _ = try await client.upload(Data("abc".utf8), using: capability)
            XCTFail("Expected invalid receipt")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testCursorExpiryDoesNotLeakTokensInError() async throws {
        let (client, authorization) = try makeClient()
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 410,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":{"minimum_sequence":55,"restore_required":true}}"#.utf8)
            )
        }
        do {
            let _: ManagedChangeFeed = try await client.changes(
                after: 1,
                authorization: authorization
            )
            XCTFail("Expected cursor expiry")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageError,
                .cursorExpired(minimumSequence: 55)
            )
            XCTAssertFalse(error.localizedDescription.contains("identity"))
            XCTAssertFalse(error.localizedDescription.contains("app-check"))
        }
    }

    func testExpiredRestoreReplayIsRestartableAndExcludesDocuments() async throws {
        let (client, authorization) = try makeClient()
        let requestID = UUID()
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/managed/restores")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request))
                    as? [String: Any]
            )
            XCTAssertEqual(body["include_documents"] as? Bool, true)
            XCTAssertEqual(body["document_kinds"] as? [String], [])
            XCTAssertEqual(
                body["data_classes"] as? [String],
                ["essential_timeseries", "raw_ppg"]
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "restore": {
                    "restore_job_id": "\(UUID().uuidString.lowercased())",
                    "status": "expired",
                    "snapshot_at": "2026-09-01T00:00:00Z",
                    "change_sequence": 42,
                    "selected_objects": 2,
                    "selected_bytes": 200,
                    "delivered_objects": 0,
                    "delivered_bytes": 0,
                    "expires_at": "2026-09-02T00:00:00Z",
                    "duplicate": true
                  }
                }
                """.utf8)
            )
        }

        do {
            _ = try await client.createRestore(
                requestID: requestID,
                dataClasses: ["raw_ppg", "essential_timeseries"],
                authorization: authorization
            )
            XCTFail("Expected stale restore replay")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .conflict)
        }
    }

    func testMissingManagedResourceHasDistinctError() async throws {
        let (client, authorization) = try makeClient()
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"managed account is not enrolled"}"#.utf8)
            )
        }

        do {
            _ = try await client.erasure(
                jobID: UUID(),
                authorization: authorization
            )
            XCTFail("Expected missing resource")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .notFound)
        }
    }

    func testRequestDiagnosticCorrelatesWithoutDynamicPathOrQuery() async throws {
        let diagnostics = LockedManagedDiagnostics()
        let (_, authorization) = try makeClient()
        let configuration = try ManagedStorageConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://noop.example")),
            policyVersion: "synthetic-v1",
            policySHA256: String(repeating: "a", count: 64)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ManagedURLProtocolStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        let requestID = String(repeating: "b", count: 32)
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 410,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Noop-Request-ID": requestID,
                    ]
                )!,
                Data(#"{"detail":{"minimum_sequence":55}}"#.utf8)
            )
        }
        let client = ManagedStorageClient(
            configuration: configuration,
            session: session,
            requestObserver: { diagnostics.append($0) }
        )

        do {
            let _: ManagedChangeFeed = try await client.changes(
                after: 123,
                authorization: authorization
            )
            XCTFail("Expected cursor expiry")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageError,
                .cursorExpired(minimumSequence: 55)
            )
        }

        let diagnostic = try XCTUnwrap(diagnostics.values.first)
        XCTAssertEqual(diagnostic.target, "managed_api")
        XCTAssertEqual(diagnostic.routeGroup, "/v1/managed/changes")
        XCTAssertEqual(diagnostic.method, "GET")
        XCTAssertEqual(diagnostic.statusCode, 410)
        XCTAssertEqual(diagnostic.requestID, requestID)
        XCTAssertEqual(diagnostic.outcome, "rejected")
        XCTAssertFalse(String(describing: diagnostic).contains("after_sequence"))
    }

    func testManagedSocialContractUsesExactConsentAndBoundedDiagnostics() async throws {
        let diagnostics = LockedManagedDiagnostics()
        let configuration = try ManagedStorageConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://noop.example")),
            policyVersion: "synthetic-v1",
            policySHA256: String(repeating: "a", count: 64)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ManagedURLProtocolStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "ios-installation",
            installationToken: "noopm_" + String(repeating: "a", count: 43)
        )
        let client = ManagedStorageClient(
            configuration: configuration,
            session: session,
            requestObserver: { diagnostics.append($0) }
        )
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let friendID = UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
        let pokeID = UUID(uuidString: "00000000-0000-0000-0000-000000000333")!
        let claimID = UUID(uuidString: "00000000-0000-0000-0000-000000000444")!
        let noopID = "NOOP-ABCD-EFGH-JKLM-NPQR"
        let capability = "noopinvite_" + String(repeating: "a", count: 43)

        ManagedURLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            let json: String
            switch (request.httpMethod, path) {
            case ("POST", "/v1/managed/social/profile"):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(body["display_name"] as? String, "Maya")
                json = """
                {"profile":{
                  "profile_id":"\(profileID)",
                  "display_name":"Maya",
                  "noop_id":"\(noopID)",
                  "poke_opt_in":false,
                  "quiet_start_minute":1320,
                  "quiet_end_minute":420,
                  "time_zone":"UTC",
                  "created_at":"2026-09-05T10:00:00Z",
                  "updated_at":"2026-09-05T10:00:00Z",
                  "duplicate":false
                }}
                """
            case ("GET", "/v1/managed/social/lookup"):
                XCTAssertEqual(
                    request.url?.query,
                    "noop_id=NOOP-ABCD-EFGH-JKLM-NPQR"
                )
                json = """
                {"profile":{
                  "profile_id":"\(friendID)",
                  "display_name":"Alex",
                  "noop_id":"\(noopID)",
                  "self":false
                }}
                """
            case ("POST", "/v1/managed/social/invites"):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(body["capability"] as? String, capability)
                json = """
                {"invite":{
                  "invite_id":"00000000-0000-0000-0000-000000000555",
                  "capability":"\(capability)",
                  "status":"active",
                  "created_at":"2026-09-05T10:00:00Z",
                  "expires_at":"2026-09-08T10:00:00Z",
                  "duplicate":false
                }}
                """
            case ("GET", "/v1/managed/social/friends"):
                json = """
                {"friends":[{
                  "profile_id":"\(friendID)",
                  "display_name":"Alex",
                  "friends_since":"2026-09-05T10:00:00Z",
                  "sharing":{
                    "charge":true,"effort":false,"rest":false,
                    "sleep_duration":false,"hrv":false,"rhr":false,
                    "poke_allowed":false
                  },
                  "shared_with_me":{
                    "charge":false,"effort":false,"rest":false,
                    "sleep_duration":false,"hrv":false,"rhr":false,
                    "poke_allowed":true
                  },
                  "latest":null,
                  "badges":[{
                    "code":"connected",
                    "earned_at":"2026-09-05T10:00:00Z"
                  }]
                }]}
                """
            case ("GET", "/v1/managed/social/blocks"):
                json = """
                {"blocks":[{
                  "profile_id":"\(friendID)",
                  "display_name":"Alex",
                  "blocked_at":"2026-09-05T10:00:00Z"
                }]}
                """
            case ("POST", "/v1/managed/social/pokes:claim"):
                json = """
                {"pokes":[{
                  "poke_id":"\(pokeID)",
                  "claim_id":"\(claimID)",
                  "sender_profile_id":"\(friendID)",
                  "sender_display_name":"Alex",
                  "created_at":"2026-09-05T10:00:00Z",
                  "expires_at":"2026-09-06T10:00:00Z",
                  "claim_expires_at":"2026-09-05T10:05:00Z"
                }]}
                """
            case ("POST", "/v1/managed/social/pokes/\(pokeID.uuidString.lowercased()):ack"):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(body["notification_outcome"] as? String, "scheduled")
                XCTAssertEqual(body["haptic_outcome"] as? String, "requested")
                json = """
                {"poke":{
                  "poke_id":"\(pokeID)",
                  "status":"acknowledged",
                  "duplicate":false,
                  "notification_outcome":"scheduled",
                  "haptic_outcome":"requested"
                }}
                """
            case ("DELETE", "/v1/managed/social/profile"):
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "X-Noop-Confirm"),
                    "DELETE MANAGED FRIENDS"
                )
                json = ""
            default:
                XCTFail("Unexpected managed social request \(request.httpMethod ?? "") \(path)")
                throw ManagedStorageError.invalidResponse
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: path.hasSuffix(":ack") ? 200 : 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Noop-Request-ID": String(repeating: "c", count: 32),
                    ]
                )!,
                Data(json.utf8)
            )
        }

        let profile = try await client.createSocialProfile(
            displayName: " Maya ",
            requestID: UUID(),
            authorization: authorization
        )
        XCTAssertEqual(profile.profileID, profileID)
        XCTAssertEqual(profile.badges, [])
        let lookup = try await client.lookupSocialProfile(
            noopID: noopID.lowercased(),
            authorization: authorization
        )
        XCTAssertEqual(lookup.profileID, friendID)
        let invite = try await client.createSocialInvite(
            capability: capability,
            requestID: UUID(),
            authorization: authorization
        )
        XCTAssertEqual(invite.capability, capability)
        let friends = try await client.socialFriends(authorization: authorization)
        XCTAssertTrue(friends[0].sharedWithMe.pokeAllowed)
        let blocks = try await client.socialBlockedProfiles(
            authorization: authorization
        )
        XCTAssertEqual(blocks[0].profileID, friendID)
        let claims = try await client.claimSocialPokes(authorization: authorization)
        XCTAssertEqual(claims[0].claimID, claimID)
        let receipt = try await client.acknowledgeSocialPoke(
            pokeID,
            acknowledgement: ManagedSocialPokeAcknowledgement(
                claimID: claimID,
                notificationOutcome: "scheduled",
                hapticOutcome: "requested"
            ),
            authorization: authorization
        )
        XCTAssertEqual(receipt.status, "acknowledged")
        try await client.deleteSocialProfile(authorization: authorization)

        XCTAssertEqual(diagnostics.values.count, 8)
        XCTAssertTrue(
            diagnostics.values.allSatisfy {
                $0.routeGroup == "/v1/managed/social"
                    && $0.target == "managed_api"
            }
        )
        let evidence = String(describing: diagnostics.values)
        XCTAssertFalse(evidence.contains(capability))
        XCTAssertFalse(evidence.contains(noopID))
        XCTAssertFalse(evidence.contains(profileID.uuidString))
    }

    func testManagedSocialRejectsOutOfRangeHealthResponse() async throws {
        let (client, authorization) = try makeClient()
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "start":"2026-09-05",
                  "end":"2026-09-05",
                  "days":[{
                    "profile_id":"00000000-0000-0000-0000-000000000222",
                    "display_name":"Alex",
                    "day":"2026-09-05",
                    "summary":{"hrv":1001}
                  }]
                }
                """.utf8)
            )
        }

        do {
            _ = try await client.socialFeed(
                startDay: "2026-09-05",
                endDay: "2026-09-05",
                authorization: authorization
            )
            XCTFail("Expected response validation failure")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testManagedSocialReturnsExpiredInviteReplayForRotation() async throws {
        let (client, authorization) = try makeClient()
        let capability = "noopinvite_" + String(repeating: "a", count: 43)
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {"invite":{
                  "invite_id":"00000000-0000-0000-0000-000000000555",
                  "capability":"\(capability)",
                  "status":"expired",
                  "created_at":"2026-09-01T10:00:00Z",
                  "expires_at":"2026-09-04T10:00:00Z",
                  "duplicate":true
                }}
                """.utf8)
            )
        }

        let invite = try await client.createSocialInvite(
            capability: capability,
            requestID: UUID(),
            authorization: authorization
        )

        XCTAssertEqual(invite.status, "expired")
        XCTAssertTrue(invite.duplicate)
    }

    private func makeClient() throws -> (ManagedStorageClient, ManagedAuthorization) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ManagedURLProtocolStub.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = try ManagedStorageConfiguration(
            baseURL: XCTUnwrap(URL(string: "https://noop.example")),
            policyVersion: "synthetic-v1",
            policySHA256: String(repeating: "a", count: 64)
        )
        let authorization = try ManagedAuthorization(
            identityToken: "identity",
            appCheckToken: "app-check",
            installationID: "ios-installation",
            installationToken: "noopm_" + String(repeating: "a", count: 43)
        )
        return (
            ManagedStorageClient(configuration: configuration, session: session),
            authorization
        )
    }
}

private final class LockedManagedDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ManagedStorageRequestDiagnostic] = []

    var values: [ManagedStorageRequestDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: ManagedStorageRequestDiagnostic) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private final class ManagedURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
