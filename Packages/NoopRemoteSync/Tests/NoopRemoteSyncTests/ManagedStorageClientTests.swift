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

    func testConfigurationAllowsOnlyExplicitLoopbackHTTP() throws {
        for value in [
            "http://127.0.0.1:8765",
            "http://localhost:8765",
            "http://[::1]:8765",
        ] {
            XCTAssertNoThrow(
                try ManagedStorageConfiguration(
                    baseURL: XCTUnwrap(URL(string: value)),
                    policyVersion: "synthetic-v1",
                    policySHA256: String(repeating: "a", count: 64),
                    allowLocalHTTP: true
                )
            )
        }
        for value in [
            "http://noop.example",
            "http://192.168.1.20:8765",
            "http://10.0.2.2:8765",
        ] {
            XCTAssertThrowsError(
                try ManagedStorageConfiguration(
                    baseURL: XCTUnwrap(URL(string: value)),
                    policyVersion: "synthetic-v1",
                    policySHA256: String(repeating: "a", count: 64),
                    allowLocalHTTP: true
                )
            )
        }
    }

    func testRetryableServerResponsePreservesBoundedRetryAfter() async throws {
        let (client, authorization) = try makeClient()
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Retry-After": "300",
                    ]
                )!,
                Data(#"{"detail":"rate limited"}"#.utf8)
            )
        }

        do {
            _ = try await client.overview(authorization: authorization)
            XCTFail("Expected rate limiting")
        } catch {
            XCTAssertEqual(
                error as? ManagedStorageError,
                .server(status: 429, retryAfter: 300)
            )
        }
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

    func testSourceRegistrationDecodesProductionSnakeCaseResponse() async throws {
        let (client, authorization) = try makeClient()
        let sourceID = UUID(uuidString: "4baec329-3dc1-5f72-91bd-f9524c74bb22")!
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/managed/sources")
            let data = try requestBody(request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(
                (object["source_id"] as? String).flatMap(UUID.init(uuidString:)),
                sourceID
            )
            XCTAssertEqual(object["source_kind"] as? String, "live_ble")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "source": {
                    "source_id": "\(sourceID.uuidString.lowercased())",
                    "source_kind": "live_ble"
                  }
                }
                """.utf8)
            )
        }

        let response = try await client.registerSource(
            ManagedSourceRegistration(
                sourceID: sourceID,
                sourceKind: "live_ble",
                platform: .iOS,
                logicalSourceHash: String(repeating: "b", count: 64)
            ),
            authorization: authorization
        )

        XCTAssertEqual(response.source.sourceID, sourceID)
        XCTAssertEqual(response.source.sourceKind, "live_ble")
    }

    func testChangeFeedAndDocumentDecodeProductionSnakeCaseResponses() async throws {
        let (client, authorization) = try makeClient()
        let documentID = UUID(uuidString: "a2810672-1c29-5e68-9ddd-45e8c3164500")!
        let clientKeyID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
        let ciphertext = Data("noop-encrypted-journal-payload".utf8)
        let digest = ManagedDigest.sha256(ciphertext)
        ManagedURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/managed/changes"):
                XCTAssertTrue(
                    request.url?.query?.contains(
                        "document_kind=day_ownership"
                    ) == true
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("""
                    {
                      "changes": [{
                        "sequence": 1,
                        "change_event_id": "63c83b6e-6c36-4ad6-9477-831fe995fe41",
                        "resource_kind": "document",
                        "resource_id": "\(documentID.uuidString.lowercased())",
                        "resource_revision": 1,
                        "operation": "upsert",
                        "content_sha256": "\(digest)",
                        "data_class": null,
                        "event_start": null,
                        "event_end": null,
                        "metadata": {},
                        "occurred_at": "2026-09-04T12:00:00Z",
                        "document": {
                          "document_kind": "day_ownership",
                          "document_id": "\(documentID.uuidString.lowercased())",
                          "revision": 1,
                          "content_mode": "server_readable",
                          "client_key_id": null,
                          "updated_at": "2026-09-04T12:00:00Z",
                          "deleted_at": null
                        }
                      }],
                      "minimum_sequence": 1,
                      "high_watermark": 1,
                      "next_sequence": 1,
                      "has_more": false
                    }
                    """.utf8)
                )
            case ("GET", "/v1/managed/documents/journal/\(documentID.uuidString.lowercased())"):
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data("""
                    {
                      "document": {
                        "document_kind": "journal",
                        "document_id": "\(documentID.uuidString.lowercased())",
                        "revision": 1,
                        "origin_installation_id": "android-installation",
                        "content_mode": "client_encrypted",
                        "client_key_id": "\(clientKeyID.uuidString.lowercased())",
                        "content_sha256": "\(digest)",
                        "payload_json": null,
                        "payload_ciphertext_base64": "\(ciphertext.base64EncodedString())",
                        "updated_at": "2026-09-04T12:00:00Z",
                        "deleted_at": null,
                        "duplicate": false
                      }
                    }
                    """.utf8)
                )
            default:
                XCTFail("Unexpected managed request \(request.httpMethod ?? "")")
                throw ManagedStorageError.invalidResponse
            }
        }

        let feed = try await client.changes(
            after: 0,
            authorization: authorization
        )
        let change = try XCTUnwrap(feed.changes.first)
        XCTAssertEqual(change.resourceID, documentID)
        XCTAssertEqual(change.contentSHA256, digest)
        XCTAssertEqual(change.document?.documentID, documentID)
        XCTAssertNil(change.document?.clientKeyID)

        let document = try await client.document(
            kind: .journal,
            id: documentID,
            revision: 1,
            authorization: authorization
        )
        XCTAssertEqual(document.documentID, documentID)
        XCTAssertEqual(document.originInstallationID, "android-installation")
        XCTAssertNil(document.payloadJSON)
        XCTAssertEqual(document.clientKeyID, clientKeyID)
        XCTAssertEqual(
            document.payloadCiphertextBase64,
            ciphertext.base64EncodedString()
        )
    }

    func testManagedDocumentKeyPutUsesAuthenticatedOpaqueContract() async throws {
        let (client, authorization) = try makeClient()
        let keyID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let wrappedKey = Data(repeating: 0x6d, count: 40)
        let mutation = try ManagedWrappedKeyMutation(
            keyKind: .accountMaster,
            wrappingKeyID: nil,
            wrappingRevision: 1,
            wrappedKey: wrappedKey,
            masterKeyConfirmationHMACSHA256: String(repeating: "f", count: 64),
            recoveryMethod: .deviceTransfer
        )
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(
                request.url?.path,
                "/v1/managed/document-keys/\(keyID.uuidString.lowercased())"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer identity"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Firebase-AppCheck"),
                "app-check"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-ID"),
                "ios-installation"
            )
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: requestBody(request)
                ) as? [String: Any]
            )
            XCTAssertEqual(body["key_kind"] as? String, "account_master")
            XCTAssertNil(body["wrapping_key_id"] as? String)
            XCTAssertEqual(body["wrapping_revision"] as? Int, 1)
            XCTAssertEqual(body["algorithm"] as? String, "A256GCM")
            XCTAssertEqual(
                body["wrapped_key_base64"] as? String,
                wrappedKey.base64EncodedString()
            )
            XCTAssertEqual(
                body["wrapped_key_sha256"] as? String,
                ManagedDigest.sha256(wrappedKey)
            )
            XCTAssertEqual(
                body["master_key_confirmation_hmac_sha256"] as? String,
                String(repeating: "f", count: 64)
            )
            XCTAssertEqual(body["recovery_method"] as? String, "device_transfer")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                managedWrappedKeyResponse(
                    keyID: keyID,
                    keyKind: "account_master",
                    wrappingKeyID: nil,
                    wrappingRevision: 1,
                    wrappedKey: wrappedKey,
                    confirmation: String(repeating: "f", count: 64),
                    recoveryMethod: "device_transfer"
                )
            )
        }

        let stored = try await client.putManagedDocumentKey(
            keyID: keyID,
            mutation: mutation,
            authorization: authorization
        )

        XCTAssertEqual(stored.keyID, keyID)
        XCTAssertEqual(stored.keyKind, .accountMaster)
        XCTAssertEqual(stored.wrappedKey, wrappedKey)
        XCTAssertEqual(stored.status, .active)
    }

    func testManagedDocumentKeyCurrentVersionRotateAndRevokeRoutes() async throws {
        let (client, authorization) = try makeClient()
        let keyID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let firstMasterID = UUID(
            uuidString: "33333333-3333-4333-8333-333333333333"
        )!
        let secondMasterID = UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        )!
        let successorKeyID = UUID(
            uuidString: "55555555-5555-4555-8555-555555555555"
        )!
        let original = Data(repeating: 0x31, count: 72)
        let rotated = Data(repeating: 0x32, count: 72)
        let rotation = try ManagedWrappedKeyRotation(
            mutation: ManagedWrappedKeyMutation(
                keyKind: .document,
                wrappingKeyID: secondMasterID,
                wrappingRevision: 2,
                wrappedKey: rotated
            ),
            expectedWrappingRevision: 1
        )
        let requests = LockedRequestCount()
        ManagedURLProtocolStub.handler = { request in
            let index = requests.next()
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/managed/document-keys/\(keyID.uuidString.lowercased())"
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    managedWrappedKeyResponse(
                        keyID: keyID,
                        keyKind: "document",
                        wrappingKeyID: firstMasterID,
                        wrappingRevision: 1,
                        wrappedKey: original
                    )
                )
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/managed/document-keys/"
                        + keyID.uuidString.lowercased()
                        + "/versions/1"
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    managedWrappedKeyVersionResponse(
                        keyID: keyID,
                        wrappingKeyID: firstMasterID,
                        wrappingRevision: 1,
                        wrappedKey: original
                    )
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/managed/document-keys/"
                        + keyID.uuidString.lowercased()
                        + "/rotate"
                )
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(body["key_kind"] as? String, "document")
                XCTAssertEqual(
                    body["wrapping_key_id"] as? String,
                    secondMasterID.uuidString.lowercased()
                )
                XCTAssertEqual(body["wrapping_revision"] as? Int, 2)
                XCTAssertEqual(body["expected_wrapping_revision"] as? Int, 1)
                XCTAssertNil(body["recovery_method"] as? String)
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    managedWrappedKeyResponse(
                        keyID: keyID,
                        keyKind: "document",
                        wrappingKeyID: secondMasterID,
                        wrappingRevision: 2,
                        wrappedKey: rotated
                    )
                )
            case 3:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/managed/document-keys/"
                        + keyID.uuidString.lowercased()
                        + "/revoke"
                )
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(
                    body["successor_key_id"] as? String,
                    successorKeyID.uuidString.lowercased()
                )
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    managedWrappedKeyResponse(
                        keyID: keyID,
                        keyKind: "document",
                        wrappingKeyID: secondMasterID,
                        wrappingRevision: 2,
                        wrappedKey: rotated,
                        status: "revoked",
                        successorKeyID: successorKeyID,
                        revokedAt: "2026-09-20T05:04:00Z"
                    )
                )
            default:
                XCTFail("Unexpected managed document-key request")
                throw ManagedStorageError.invalidResponse
            }
        }

        let current = try await client.managedDocumentKey(
            keyID: keyID,
            authorization: authorization
        )
        let version = try await client.managedDocumentKeyVersion(
            keyID: keyID,
            wrappingRevision: 1,
            authorization: authorization
        )
        let rotatedRecord = try await client.rotateManagedDocumentKey(
            keyID: keyID,
            rotation: rotation,
            authorization: authorization
        )
        let revoked = try await client.revokeManagedDocumentKey(
            keyID: keyID,
            successorKeyID: successorKeyID,
            authorization: authorization
        )

        XCTAssertEqual(current.wrappedKey, original)
        XCTAssertEqual(version.wrappedKey, original)
        XCTAssertEqual(rotatedRecord.wrappingRevision, 2)
        XCTAssertEqual(revoked.status, .revoked)
        XCTAssertEqual(revoked.successorKeyID, successorKeyID)
        XCTAssertEqual(requests.value, 4)
    }

    func testManagedDocumentKeyResponsesRejectMalformedContracts() async throws {
        let (client, authorization) = try makeClient()
        let keyID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let otherKeyID = UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        )!
        let masterID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let validWrapped = Data(repeating: 0x41, count: 72)
        var malformedBodies: [Data] = [
            managedWrappedKeyResponse(
                keyID: otherKeyID,
                keyKind: "document",
                wrappingKeyID: masterID,
                wrappingRevision: 1,
                wrappedKey: validWrapped
            ),
            managedWrappedKeyResponse(
                keyID: keyID,
                keyKind: "document",
                wrappingKeyID: masterID,
                wrappingRevision: 0,
                wrappedKey: validWrapped
            ),
            managedWrappedKeyResponse(
                keyID: keyID,
                keyKind: "document",
                wrappingKeyID: masterID,
                wrappingRevision: 1,
                wrappedKey: Data(repeating: 0x42, count: 40)
            ),
            managedWrappedKeyResponse(
                keyID: keyID,
                keyKind: "document",
                wrappingKeyID: masterID,
                wrappingRevision: 1,
                wrappedKey: validWrapped,
                digest: String(repeating: "0", count: 64)
            ),
            managedWrappedKeyResponse(
                keyID: keyID,
                keyKind: "document",
                wrappingKeyID: masterID,
                wrappingRevision: 1,
                wrappedKey: validWrapped,
                status: "revoked",
                revokedAt: nil
            ),
        ]
        var noncanonicalBase64 = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: managedWrappedKeyResponse(
                    keyID: keyID,
                    keyKind: "document",
                    wrappingKeyID: masterID,
                    wrappingRevision: 1,
                    wrappedKey: validWrapped
                )
            ) as? [String: Any]
        )
        var noncanonicalKey = try XCTUnwrap(
            noncanonicalBase64["key"] as? [String: Any]
        )
        noncanonicalKey["wrapped_key_base64"] =
            validWrapped.base64EncodedString() + "\n"
        noncanonicalBase64["key"] = noncanonicalKey
        malformedBodies.append(
            try JSONSerialization.data(withJSONObject: noncanonicalBase64)
        )

        for body in malformedBodies {
            ManagedURLProtocolStub.handler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    body
                )
            }
            do {
                _ = try await client.managedDocumentKey(
                    keyID: keyID,
                    authorization: authorization
                )
                XCTFail("Expected malformed wrapped-key response rejection")
            } catch {
                XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
            }
        }

        for (field, value) in [
            ("key_kind", "unsupported"),
            ("algorithm", "A128GCM"),
            ("status", "unknown"),
        ] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: managedWrappedKeyResponse(
                        keyID: keyID,
                        keyKind: "document",
                        wrappingKeyID: masterID,
                        wrappingRevision: 1,
                        wrappedKey: validWrapped
                    )
                ) as? [String: Any]
            )
            var key = try XCTUnwrap(object["key"] as? [String: Any])
            key[field] = value
            object["key"] = key
            let body = try JSONSerialization.data(withJSONObject: object)
            ManagedURLProtocolStub.handler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    body
                )
            }
            do {
                _ = try await client.managedDocumentKey(
                    keyID: keyID,
                    authorization: authorization
                )
                XCTFail("Expected malformed \(field) rejection")
            } catch {
                XCTAssertEqual(error as? ManagedStorageError, .decoding)
            }
        }
    }

    func testManagedDocumentKeyDiagnosticsDoNotExposeKeyMaterial() async throws {
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
        let keyID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let wrappedKey = Data(repeating: 0x51, count: 72)
        let wrappingKeyID = UUID(
            uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )!
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Noop-Request-ID": String(repeating: "b", count: 32),
                    ]
                )!,
                managedWrappedKeyResponse(
                    keyID: keyID,
                    keyKind: "document",
                    wrappingKeyID: wrappingKeyID,
                    wrappingRevision: 1,
                    wrappedKey: wrappedKey
                )
            )
        }

        _ = try await client.managedDocumentKey(
            keyID: keyID,
            authorization: authorization
        )

        let diagnostic = try XCTUnwrap(diagnostics.values.first)
        let rendered = String(describing: diagnostic)
        XCTAssertEqual(diagnostic.routeGroup, "/v1/managed/document-keys")
        XCTAssertEqual(diagnostic.outcome, "completed")
        XCTAssertFalse(rendered.contains(keyID.uuidString.lowercased()))
        XCTAssertFalse(rendered.contains(wrappedKey.base64EncodedString()))
        XCTAssertFalse(rendered.contains(ManagedDigest.sha256(wrappedKey)))
    }

    func testChangeFeedRejectsSensitiveServerReadableMetadata() async throws {
        let (client, authorization) = try makeClient()
        let documentID = UUID(
            uuidString: "44444444-4444-5444-8444-444444444444"
        )!
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
                  "changes": [{
                    "sequence": 1,
                    "resource_kind": "document",
                    "resource_id": "\(documentID.uuidString.lowercased())",
                    "operation": "upsert",
                    "content_sha256": "\(String(repeating: "a", count: 64))",
                    "data_class": "user_documents",
                    "event_start": null,
                    "event_end": null,
                    "document": {
                      "document_kind": "journal",
                      "document_id": "\(documentID.uuidString.lowercased())",
                      "revision": 1,
                      "content_mode": "server_readable",
                      "client_key_id": null,
                      "updated_at": "2026-09-11T15:00:00Z",
                      "deleted_at": null
                    }
                  }],
                  "minimum_sequence": 1,
                  "high_watermark": 1,
                  "next_sequence": 1,
                  "has_more": false
                }
                """.utf8)
            )
        }

        do {
            _ = try await client.changes(
                after: 0,
                authorization: authorization
            )
            XCTFail("Expected plaintext journal metadata to fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testChangeFeedRejectsMissingOrMisroutedDocumentMetadata() async throws {
        let (client, authorization) = try makeClient()
        let documentID = UUID(
            uuidString: "55555555-5555-5555-8555-555555555555"
        )!
        let clientKeyID = UUID(
            uuidString: "66666666-6666-5666-8666-666666666666"
        )!
        let digest = ManagedDigest.sha256(
            Data("noop-encrypted-journal-payload".utf8)
        )
        let rows = [
            """
            {
              "sequence": 1,
              "resource_kind": "document",
              "resource_id": "\(documentID.uuidString.lowercased())",
              "operation": "upsert",
              "content_sha256": "\(digest)",
              "data_class": "user_documents",
              "event_start": null,
              "event_end": null
            }
            """,
            """
            {
              "sequence": 1,
              "resource_kind": "chunk",
              "resource_id": "\(documentID.uuidString.lowercased())",
              "operation": "upsert",
              "content_sha256": "\(digest)",
              "data_class": "user_documents",
              "event_start": null,
              "event_end": null,
              "document": {
                "document_kind": "journal",
                "document_id": "\(documentID.uuidString.lowercased())",
                "revision": 1,
                "content_mode": "client_encrypted",
                "client_key_id": "\(clientKeyID.uuidString.lowercased())",
                "updated_at": "2026-09-11T15:00:00Z",
                "deleted_at": null
              }
            }
            """,
        ]

        for row in rows {
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
                      "changes": [\(row)],
                      "minimum_sequence": 1,
                      "high_watermark": 1,
                      "next_sequence": 1,
                      "has_more": false
                    }
                    """.utf8)
                )
            }

            do {
                _ = try await client.changes(
                    after: 0,
                    authorization: authorization
                )
                XCTFail("Expected inconsistent document metadata to fail closed")
            } catch {
                XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
            }
        }
    }

    func testSnapshotDocumentListRequestsOnlySupportedKindsAndRejectsSensitivePlaintext() async throws {
        let (client, authorization) = try makeClient()
        let journalID = UUID(
            uuidString: "11111111-1111-5111-8111-111111111111"
        )!
        let ownershipID = UUID(
            uuidString: "22222222-2222-5222-8222-222222222222"
        )!
        let ownershipPayload: [String: Any] = [
            "schema_version": 1,
            "table": "dayOwnership",
            "key": ["day": "2026-09-11"],
            "record": [
                "day": "2026-09-11",
                "deviceId": "remote-band",
                "locked": 1,
            ],
        ]
        let ownership: [String: Any] = [
            "document_kind": "day_ownership",
            "document_id": ownershipID.uuidString.lowercased(),
            "revision": 1,
            "origin_installation_id": "android-installation",
            "content_mode": "server_readable",
            "client_key_id": NSNull(),
            "content_sha256": try canonicalDigest(ownershipPayload),
            "payload_json": ownershipPayload,
            "payload_ciphertext_base64": NSNull(),
            "updated_at": "2026-09-11T15:01:00Z",
            "deleted_at": NSNull(),
            "duplicate": false,
        ]
        ManagedURLProtocolStub.handler = { request in
            XCTAssertTrue(
                request.url?.query?.contains(
                    "document_kind=day_ownership"
                ) == true
            )
            XCTAssertTrue(
                request.url?.query?.contains("include_deleted=false") == true
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(
                    withJSONObject: [
                        "documents": [ownership],
                        "next_cursor": NSNull(),
                    ]
                )
            )
        }

        let page = try await client.documents(
            snapshotAt: "2026-09-11T16:00:00Z",
            limit: 25,
            includeDeleted: false,
            authorization: authorization
        )

        XCTAssertEqual(page.documents.map(\.contentMode), ["server_readable"])
        XCTAssertNil(page.nextCursor)

        let plaintextPayload: [String: Any] = ["secret": "not-readable"]
        let plaintextDigest = try canonicalDigest(plaintextPayload)
        ManagedURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(
                    withJSONObject: [
                        "documents": [[
                            "document_kind": "journal",
                            "document_id": journalID.uuidString.lowercased(),
                            "revision": 1,
                            "origin_installation_id": "ios-installation",
                            "content_mode": "server_readable",
                            "client_key_id": NSNull(),
                            "content_sha256": plaintextDigest,
                            "payload_json": plaintextPayload,
                            "payload_ciphertext_base64": NSNull(),
                            "updated_at": "2026-09-11T15:00:00Z",
                            "deleted_at": NSNull(),
                            "duplicate": false,
                        ]],
                        "next_cursor": NSNull(),
                    ]
                )
            )
        }

        do {
            _ = try await client.documents(
                snapshotAt: "2026-09-11T16:00:00Z",
                limit: 25,
                includeDeleted: false,
                authorization: authorization
            )
            XCTFail("Expected plaintext journal snapshot to fail closed")
        } catch {
            XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
        }
    }

    func testSnapshotDocumentListRejectsMalformedEncryptedMetadata() async throws {
        let (client, authorization) = try makeClient()
        let documentID = UUID(
            uuidString: "77777777-7777-5777-8777-777777777777"
        )!
        let clientKeyID = UUID(
            uuidString: "88888888-8888-5888-8888-888888888888"
        )!
        let ciphertext = Data("noop-encrypted-journal-payload".utf8)
        let encoded = ciphertext.base64EncodedString()
        let digest = ManagedDigest.sha256(ciphertext)
        let invalidDocuments: [[String: Any]] = [
            [
                "document_kind": "journal",
                "document_id": documentID.uuidString.lowercased(),
                "revision": 1,
                "origin_installation_id": "ios-installation",
                "content_mode": "client_encrypted",
                "client_key_id": NSNull(),
                "content_sha256": digest,
                "payload_json": NSNull(),
                "payload_ciphertext_base64": encoded,
                "updated_at": "2026-09-11T15:00:00Z",
                "deleted_at": NSNull(),
                "duplicate": false,
            ],
            [
                "document_kind": "day_ownership",
                "document_id": documentID.uuidString.lowercased(),
                "revision": 1,
                "origin_installation_id": "ios-installation",
                "content_mode": "client_encrypted",
                "client_key_id": clientKeyID.uuidString.lowercased(),
                "content_sha256": digest,
                "payload_json": NSNull(),
                "payload_ciphertext_base64": encoded,
                "updated_at": "2026-09-11T15:00:00Z",
                "deleted_at": NSNull(),
                "duplicate": false,
            ],
        ]

        for document in invalidDocuments {
            ManagedURLProtocolStub.handler = { request in
                (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    try JSONSerialization.data(
                        withJSONObject: [
                            "documents": [document],
                            "next_cursor": NSNull(),
                        ]
                    )
                )
            }

            do {
                _ = try await client.documents(
                    snapshotAt: "2026-09-11T16:00:00Z",
                    limit: 25,
                    includeDeleted: false,
                    authorization: authorization
                )
                XCTFail("Expected malformed encrypted snapshot to fail closed")
            } catch {
                XCTAssertEqual(error as? ManagedStorageError, .invalidResponse)
            }
        }
    }

    func testSnapshotDocumentListRequestsAndAcceptsDeletionTombstones() async throws {
        let (client, authorization) = try makeClient()
        let documentID = UUID(
            uuidString: "33333333-3333-5333-8333-333333333333"
        )!
        let digest = ManagedDigest.sha256(
            Data(
                (
                    "deleted:day_ownership:"
                        + "\(documentID.uuidString.lowercased()):2"
                ).utf8
            )
        )
        ManagedURLProtocolStub.handler = { request in
            XCTAssertTrue(
                request.url?.query?.contains("include_deleted=true") == true
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(
                    withJSONObject: [
                        "documents": [[
                            "document_kind": "day_ownership",
                            "document_id": documentID.uuidString.lowercased(),
                            "revision": 2,
                            "origin_installation_id": "ios-installation",
                            "content_mode": "server_readable",
                            "client_key_id": NSNull(),
                            "content_sha256": digest,
                            "payload_json": NSNull(),
                            "payload_ciphertext_base64": NSNull(),
                            "updated_at": "2026-09-11T15:00:00Z",
                            "deleted_at": "2026-09-11T15:00:00Z",
                            "duplicate": false,
                        ]],
                        "next_cursor": NSNull(),
                    ]
                )
            )
        }

        let page = try await client.documents(
            snapshotAt: "2026-09-11T16:00:00Z",
            limit: 25,
            includeDeleted: true,
            authorization: authorization
        )

        XCTAssertEqual(page.documents.map(\.documentID), [documentID])
        XCTAssertEqual(page.documents.first?.deletedAt, "2026-09-11T15:00:00Z")
    }

    func testManagedResponseModelsDecodeAcronymWireKeys() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let chunkID = UUID(uuidString: "790984d2-5569-5ba9-848a-475d2f299914")!
        let grantID = UUID(uuidString: "7d48d80a-a4dd-5f68-99a2-4b30952cf55d")!
        let documentID = UUID(uuidString: "2e959bb4-c6cd-5599-aefe-92aadf05b9fc")!

        let reservation = try decoder.decode(
            ManagedChunkReservationResponse.self,
            from: Data("""
            {
              "chunk": {
                "chunk_id": "\(chunkID.uuidString.lowercased())",
                "state": "reserved",
                "object_generation": null,
                "duplicate": false
              },
              "upload": {
                "grant_id": "\(grantID.uuidString.lowercased())",
                "method": "PUT",
                "url": "https://storage.googleapis.com/bucket/object",
                "headers": {"Content-Type": "application/octet-stream"},
                "expires_at": "2026-09-04T12:10:00Z"
              }
            }
            """.utf8)
        )
        XCTAssertEqual(reservation.chunk.chunkID, chunkID)
        XCTAssertEqual(reservation.upload?.grantID, grantID)

        let page = try decoder.decode(
            ManagedDocumentPage.self,
            from: Data("""
            {
              "documents": [],
              "next_cursor": {
                "after_updated_at": "2026-09-04T12:00:00Z",
                "after_document_kind": "preferences",
                "after_document_id": "\(documentID.uuidString.lowercased())"
              }
            }
            """.utf8)
        )
        XCTAssertEqual(page.nextCursor?.afterDocumentID, documentID)

        let download = try decoder.decode(
            ManagedDownloadCapability.self,
            from: Data("""
            {
              "grant_id": "\(grantID.uuidString.lowercased())",
              "method": "GET",
              "url": "https://storage.googleapis.com/bucket/object",
              "headers": {},
              "expires_at": "2026-09-04T12:10:00Z",
              "chunk": {
                "chunk_id": "\(chunkID.uuidString.lowercased())",
                "expected_sha256": "\(String(repeating: "b", count: 64))",
                "compression": "gzip",
                "content_type": "application/vnd.noop.chunk+json",
                "expected_uncompressed_bytes": 512
              }
            }
            """.utf8)
        )
        XCTAssertEqual(download.grantID, grantID)
        XCTAssertEqual(download.chunk.chunkID, chunkID)
        XCTAssertEqual(download.chunk.expectedSHA256, String(repeating: "b", count: 64))
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

    func testAccountErasureReceiptOmitsIdentityBearer() async throws {
        let (client, authorization) = try makeClient()
        let jobID = UUID(uuidString: "8519298E-C785-45E8-963A-81834BE94638")!
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/v1/managed/erasure/\(jobID.uuidString.lowercased())/receipt"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Firebase-AppCheck"),
                "app-check"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-ID"),
                "ios-installation"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Noop-Installation-Token"),
                "noopm_" + String(repeating: "a", count: 43)
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "erasure": {
                    "erasure_job_id": "\(jobID.uuidString.lowercased())",
                    "scope": "account",
                    "status": "completed",
                    "objects_selected": 0,
                    "objects_deleted": 0,
                    "bytes_selected": 0,
                    "bytes_deleted": 0,
                    "database_rows_deleted": 0,
                    "requested_at": "2026-09-04T04:00:00Z",
                    "not_before": "2026-09-05T04:00:00Z",
                    "started_at": "2026-09-05T04:00:00Z",
                    "completed_at": "2026-09-05T04:01:00Z",
                    "verification_expires_at": "2027-10-09T04:00:00Z",
                    "duplicate": false
                  }
                }
                """.utf8)
            )
        }

        let job = try await client.erasureReceipt(
            jobID: jobID,
            authorization: authorization
        )

        XCTAssertEqual(job.erasureJobID, jobID)
        XCTAssertEqual(job.status, "completed")
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
            XCTAssertEqual(
                body["document_kinds"] as? [String],
                ["day_ownership"]
            )
            XCTAssertEqual(
                body["data_classes"] as? [String],
                ["essential_timeseries", "raw_ppg"]
            )
            XCTAssertEqual(
                body["include_deleted_documents"] as? Bool,
                true
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
                includeDeletedDocuments: true,
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

    func testManagedSafetyContractIsBoundedAndLocationIsLatestOnly() async throws {
        let (client, authorization) = try makeClient()
        let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let incidentID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let token = "fcm-token:ABC_def-1234567890"

        ManagedURLProtocolStub.handler = { request in
            let path = request.url?.path ?? ""
            let json: String
            switch (request.httpMethod, path) {
            case ("PUT", "/v1/managed/push/installations/current"):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(body["platform"] as? String, "ios")
                XCTAssertEqual(body["environment"] as? String, "development")
                XCTAssertEqual(body["target_kind"] as? String, "token")
                XCTAssertEqual(body["token"] as? String, token)
                json = """
                {"registration":{
                  "installation_id":"ios-installation",
                  "platform":"ios",
                  "environment":"development",
                  "target_kind":"token",
                  "status":"active",
                  "updated_at":"2026-09-08T10:00:00Z",
                  "duplicate":false
                }}
                """
            case ("GET", "/v1/managed/safety/contacts"):
                json = """
                {
                  "contacts":[
                    {
                      "profile_id":"\(firstID)",
                      "display_name":"First",
                      "role":"contact",
                      "accepted_at":"2026-09-08T09:00:00Z"
                    },
                    {
                      "profile_id":"\(secondID)",
                      "display_name":"Second",
                      "role":"contact",
                      "accepted_at":"2026-09-08T09:01:00Z"
                    }
                  ],
                  "delivery_capable_count":2,
                  "minimum_required":2,
                  "maximum_allowed":5
                }
                """
            case ("POST", "/v1/managed/safety/incidents"):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual(body["trigger"] as? String, "band_sos")
                XCTAssertEqual(body["duration_hours"] as? Int, 8)
                XCTAssertEqual(body["share_location"] as? Bool, true)
                let initialLocation = try XCTUnwrap(
                    body["initial_location"] as? [String: Any]
                )
                XCTAssertEqual(
                    (initialLocation["sequence"] as? NSNumber)?.int64Value,
                    1
                )
                XCTAssertEqual(
                    initialLocation["captured_at"] as? String,
                    "2026-09-08T10:00:00Z"
                )
                json = """
                {
                  "incident":\(safetyIncidentJSON(
                    incidentID: incidentID,
                    ownerID: ownerID,
                    firstID: firstID,
                    secondID: secondID,
                    trigger: "band_sos",
                    includeLocation: true
                  )),
                  "push_outcome":"attempted"
                }
                """
            case (
                "PUT",
                "/v1/managed/safety/incidents/"
                    + "\(incidentID.uuidString.lowercased())/location"
            ):
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: requestBody(request)
                    ) as? [String: Any]
                )
                XCTAssertEqual((body["sequence"] as? NSNumber)?.int64Value, 99)
                json = """
                {"location":{
                  "sequence":3,
                  "latitude":17.385,
                  "longitude":78.4867,
                  "horizontal_accuracy_m":12.5,
                  "captured_at":"2026-09-08T10:01:00Z",
                  "received_at":"2026-09-08T10:01:01Z",
                  "duplicate":false
                }}
                """
            default:
                XCTFail("Unexpected managed Safety request: \(request.httpMethod ?? "") \(path)")
                json = "{}"
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }

        let registration = try await client.registerPushInstallation(
            platform: .iOS,
            environment: .development,
            targetKind: .token,
            token: token,
            authorization: authorization
        )
        XCTAssertEqual(registration.installationID, "ios-installation")
        XCTAssertEqual(registration.targetKind, .token)
        let contacts = try await client.safetyContacts(
            authorization: authorization
        )
        XCTAssertEqual(contacts.contacts.count, 2)
        XCTAssertEqual(contacts.deliveryCapableCount, 2)
        let creation = try await client.createSafetyIncident(
            trigger: "band_sos",
            durationHours: 8,
            shareLocation: true,
            initialLocation: ManagedSafetyLocationCreate(
                latitude: 17.385,
                longitude: 78.4867,
                horizontalAccuracyM: 12.5,
                capturedAt: "2026-09-08T10:00:00Z"
            ),
            requestID: UUID(),
            authorization: authorization
        )
        XCTAssertEqual(creation.incident.incidentID, incidentID)
        XCTAssertEqual(creation.pushOutcome, "attempted")
        let location = try await client.updateSafetyLocation(
            incidentID: incidentID,
            sequence: 99,
            latitude: 17.385,
            longitude: 78.4867,
            horizontalAccuracyM: 12.5,
            capturedAt: "2026-09-08T10:01:00Z",
            authorization: authorization
        )
        XCTAssertEqual(location.sequence, 3)
    }

    func testManagedSafetyContactsMissingDeliveryCapabilityFailsClosed() async throws {
        let (client, authorization) = try makeClient()
        let contactID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000109"
        )!
        ManagedURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/managed/safety/contacts")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("""
                {
                  "contacts":[{
                    "profile_id":"\(contactID)",
                    "display_name":"Contact",
                    "role":"contact",
                    "accepted_at":"2026-09-08T09:00:00Z"
                  }],
                  "minimum_required":2,
                  "maximum_allowed":5
                }
                """.utf8)
            )
        }

        let contacts = try await client.safetyContacts(
            authorization: authorization
        )
        XCTAssertEqual(contacts.contacts.count, 1)
        XCTAssertEqual(contacts.deliveryCapableCount, 0)
    }

    func testManagedSafetyCreateAllowsMissingLocationForDuplicateReplay() async throws {
        let (client, authorization) = try makeClient()
        let incidentID = UUID()
        let ownerID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let initialLocation = ManagedSafetyLocationCreate(
            latitude: 17.385,
            longitude: 78.4867,
            horizontalAccuracyM: 12.5,
            capturedAt: "2026-09-08T10:00:00Z"
        )

        ManagedURLProtocolStub.handler = { request in
            let json = """
            {
              "incident":\(safetyIncidentJSON(
                incidentID: incidentID,
                ownerID: ownerID,
                firstID: firstID,
                secondID: secondID,
                includeLocation: false,
                status: "expired",
                duplicate: true
              )),
              "push_outcome":"deferred"
            }
            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }

        let replay = try await client.createSafetyIncident(
            durationHours: 8,
            shareLocation: true,
            initialLocation: initialLocation,
            requestID: UUID(),
            authorization: authorization
        )
        XCTAssertTrue(replay.incident.duplicate)
        XCTAssertEqual(replay.incident.status, "expired")
        XCTAssertNil(replay.incident.location)

        ManagedURLProtocolStub.handler = { request in
            let json = """
            {
              "incident":\(safetyIncidentJSON(
                incidentID: incidentID,
                ownerID: ownerID,
                firstID: firstID,
                secondID: secondID,
                includeLocation: false,
                duplicate: true
              )),
              "push_outcome":"deferred"
            }
            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }

        let activeReplay = try await client.createSafetyIncident(
            durationHours: 8,
            shareLocation: true,
            initialLocation: initialLocation,
            requestID: UUID(),
            authorization: authorization
        )
        XCTAssertTrue(activeReplay.incident.duplicate)
        XCTAssertEqual(activeReplay.incident.status, "open")
        XCTAssertNil(activeReplay.incident.location)

        ManagedURLProtocolStub.handler = { request in
            let json = """
            {
              "incident":\(safetyIncidentJSON(
                incidentID: incidentID,
                ownerID: ownerID,
                firstID: firstID,
                secondID: secondID,
                includeLocation: false
              )),
              "push_outcome":"deferred"
            }
            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }

        do {
            _ = try await client.createSafetyIncident(
                durationHours: 8,
                shareLocation: true,
                initialLocation: initialLocation,
                requestID: UUID(),
                authorization: authorization
            )
            XCTFail("New incident without its accepted initial location was accepted")
        } catch ManagedStorageError.invalidResponse {
            // Expected.
        }
    }

    func testManagedSafetyRejectsLocationWhenSharingIsOff() async throws {
        let (client, authorization) = try makeClient()
        let incidentID = UUID()
        let ownerID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        ManagedURLProtocolStub.handler = { request in
            let json = """
            {"incidents":[\(safetyIncidentJSON(
              incidentID: incidentID,
              ownerID: ownerID,
              firstID: firstID,
              secondID: secondID,
              includeLocation: true,
              shareLocation: false
            ))]}
            """
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(json.utf8)
            )
        }

        do {
            _ = try await client.safetyIncidents(
                authorization: authorization
            )
            XCTFail("Location was accepted while sharing was off")
        } catch ManagedStorageError.invalidResponse {
            // Expected.
        }
    }

    func testManagedSafetyRetainedOwnerIncidentAllowsErasedParticipants() async throws {
        let (client, authorization) = try makeClient()
        let incidentID = UUID()
        let ownerID = UUID()
        let participantID = UUID()

        for participantCount in 0...1 {
            let participants = participantCount == 0
                ? ""
                : """
                  {
                    "profile_id":"\(participantID)",
                    "display_name":"Former contact",
                    "status":"revoked",
                    "paged_at":"2026-09-08T10:00:00Z",
                    "responded_at":"2026-09-08T10:05:00Z",
                    "push":{"configured":false,"reached":false}
                  }
                  """
            ManagedURLProtocolStub.handler = { request in
                XCTAssertEqual(
                    request.url?.path,
                    "/v1/managed/safety/incidents"
                )
                let json = """
                {"incidents":[{
                  "incident_id":"\(incidentID)",
                  "role":"owner",
                  "owner_profile_id":"\(ownerID)",
                  "owner_display_name":"Owner",
                  "trigger":"manual_sos",
                  "status":"expired",
                  "duration_hours":8,
                  "share_location":false,
                  "created_at":"2026-09-08T10:00:00Z",
                  "expires_at":"2026-09-08T18:00:00Z",
                  "acknowledged_at":null,
                  "ended_at":"2026-09-08T18:00:00Z",
                  "participants":[\(participants)],
                  "location":null,
                  "delivery":{
                    "contacts_targeted":0,
                    "contacts_reached":0,
                    "installations_targeted":0,
                    "installations_reached":0,
                    "installations_retryable":0,
                    "installations_terminal":0
                  },
                  "duplicate":false
                }]}
                """
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(json.utf8)
                )
            }

            let incidents = try await client.safetyIncidents(
                authorization: authorization
            )

            XCTAssertEqual(incidents.count, 1)
            XCTAssertEqual(
                incidents[0].participants.count,
                participantCount
            )
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

    private func canonicalDigest(_ object: [String: Any]) throws -> String {
        ManagedDigest.sha256(
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        )
    }
}

private func safetyIncidentJSON(
    incidentID: UUID,
    ownerID: UUID,
    firstID: UUID,
    secondID: UUID,
    trigger: String = "manual_sos",
    includeLocation: Bool,
    status: String = "open",
    shareLocation: Bool = true,
    duplicate: Bool = false
) -> String {
    let active = ["open", "acknowledged"].contains(status)
    let location = includeLocation
        ? """
        {
          "sequence":1,
          "latitude":17.385,
          "longitude":78.4867,
          "horizontal_accuracy_m":12.5,
          "captured_at":"2026-09-08T10:01:00Z",
          "received_at":"2026-09-08T10:01:01Z"
        }
        """
        : "null"
    let acknowledgedAt = status == "acknowledged"
        ? #""2026-09-08T10:05:00Z""#
        : "null"
    let endedAt = active ? "null" : #""2026-09-08T18:00:00Z""#
    return """
    {
      "incident_id":"\(incidentID)",
      "role":"owner",
      "owner_profile_id":"\(ownerID)",
      "owner_display_name":"Owner",
      "trigger":"\(trigger)",
      "status":"\(status)",
      "duration_hours":8,
      "share_location":\(shareLocation),
      "created_at":"2026-09-08T10:00:00Z",
      "expires_at":"2026-09-08T18:00:00Z",
      "acknowledged_at":\(acknowledgedAt),
      "ended_at":\(endedAt),
      "participants":[
        {
          "profile_id":"\(firstID)",
          "display_name":"First",
          "status":"pending",
          "paged_at":"2026-09-08T10:00:00Z",
          "responded_at":null,
          "push":{"configured":true,"reached":true}
        },
        {
          "profile_id":"\(secondID)",
          "display_name":"Second",
          "status":"pending",
          "paged_at":"2026-09-08T10:00:00Z",
          "responded_at":null,
          "push":{"configured":true,"reached":false}
        }
      ],
      "location":\(location),
      "delivery":{
        "contacts_targeted":2,
        "contacts_reached":1,
        "installations_targeted":2,
        "installations_reached":1,
        "installations_retryable":1,
        "installations_terminal":0
      },
      "duplicate":\(duplicate)
    }
    """
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

private final class LockedRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = storage
        storage += 1
        return value
    }
}

private func managedWrappedKeyResponse(
    keyID: UUID,
    keyKind: String,
    wrappingKeyID: UUID?,
    wrappingRevision: Int,
    wrappedKey: Data,
    digest: String? = nil,
    confirmation: String? = nil,
    recoveryMethod: String? = nil,
    status: String = "active",
    successorKeyID: UUID? = nil,
    revokedAt: String? = nil
) -> Data {
    let key: [String: Any] = [
        "key_id": keyID.uuidString.lowercased(),
        "key_kind": keyKind,
        "wrapping_key_id":
            wrappingKeyID?.uuidString.lowercased() ?? NSNull(),
        "wrapping_revision": wrappingRevision,
        "algorithm": "A256GCM",
        "wrapped_key_base64": wrappedKey.base64EncodedString(),
        "wrapped_key_sha256": digest ?? ManagedDigest.sha256(wrappedKey),
        "master_key_confirmation_hmac_sha256": confirmation ?? NSNull(),
        "recovery_method": recoveryMethod ?? NSNull(),
        "status": status,
        "successor_key_id":
            successorKeyID?.uuidString.lowercased() ?? NSNull(),
        "created_at": "2026-09-20T05:01:00Z",
        "updated_at": revokedAt ?? "2026-09-20T05:03:00Z",
        "revoked_at": revokedAt ?? NSNull(),
    ]
    return try! JSONSerialization.data(
        withJSONObject: ["key": key],
        options: [.sortedKeys]
    )
}

private func managedWrappedKeyVersionResponse(
    keyID: UUID,
    wrappingKeyID: UUID,
    wrappingRevision: Int,
    wrappedKey: Data
) -> Data {
    let key: [String: Any] = [
        "key_id": keyID.uuidString.lowercased(),
        "key_kind": "document",
        "wrapping_key_id": wrappingKeyID.uuidString.lowercased(),
        "wrapping_revision": wrappingRevision,
        "algorithm": "A256GCM",
        "wrapped_key_base64": wrappedKey.base64EncodedString(),
        "wrapped_key_sha256": ManagedDigest.sha256(wrappedKey),
        "master_key_confirmation_hmac_sha256": NSNull(),
        "recovery_method": NSNull(),
        "created_at": "2026-09-20T05:01:00Z",
    ]
    return try! JSONSerialization.data(
        withJSONObject: ["key_version": key],
        options: [.sortedKeys]
    )
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
