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
